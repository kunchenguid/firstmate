#!/usr/bin/env node
// Semantic policy for the worker command guard: may an autonomous firstmate
// worker run this shell command, or touch this file path?
//
// THIS FILE IS THE SINGLE OWNER OF THE WORKER PERIMETER. Every application
// point - the Pi per-task extension and the Claude per-task PreToolUse hook,
// both written by bin/fm-spawn.sh - calls bin/fm-worker-pretool-check.sh, which
// calls this module. No application point restates a rule, so no two harnesses
// can drift apart: extending the perimeter means editing PERIMETER below and
// nothing else. See docs/worker-command-guard.md for the complete contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.
//
// Deliberate boundary: this policy classifies the command a worker submits, not
// the body of a script that command would run. Re-classifying arbitrary script
// bodies blocks this repo's own test suite (which legitimately chmods fixtures)
// and any project's build scripts, so a worker's own scripts stay out of scope.

import { Lexer, splitProgram, commandPosition, SHELL_RESERVED_WORDS } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "privilege-escalation":
    "sudo is forbidden for a firstmate worker: a task worktree never needs host privileges, and an escalated command escapes every isolation the task relies on.",
  "remote-transfer":
    "ssh, scp, and rsync are forbidden for a firstmate worker: they reach hosts and move data outside the task worktree. Ask firstmate if the task genuinely needs a remote host.",
  "permission-change":
    "chmod is forbidden for a firstmate worker: file modes outside the task's own new files are host state, not task output.",
  "global-git-config":
    "git config --global is forbidden for a firstmate worker: it mutates the captain's host-wide git configuration. Use repository-local git config instead.",
  "history-rewrite":
    "git rebase is forbidden for a firstmate worker: it rewrites history the delivery path depends on. Land work with ordinary commits and let the delivery path reconcile.",
  "protected-branch-push":
    "pushing to master/main is forbidden for a firstmate worker: work lands through a PR. Push the task branch instead, for example git push origin HEAD.",
  "dotenv-access":
    "reading a .env file, or copying one elsewhere, is forbidden for a firstmate worker: it holds live credentials. Ask firstmate if the task genuinely needs a secret.",
  "unclassifiable-perimeter-command":
    "unsupported or malformed shell syntax mentions a command inside the worker perimeter, so it cannot be classified and is refused rather than allowed.",
};

// Commands denied outright, keyed by the reason they earn. Matched on the
// executed command word's basename, so /usr/bin/ssh is the same denial as ssh.
const DENIED_COMMANDS = new Map([
  ["ssh", "remote-transfer"],
  ["scp", "remote-transfer"],
  ["rsync", "remote-transfer"],
  ["chmod", "permission-change"],
]);

// Commands that read file contents. Denied only when an argument names a .env.
// The sourcing builtins read their operand into the shell, which is the most
// ordinary way a worker loads a secrets file, so they belong here: `. .env` and
// `source .env` expose exactly what `cat .env` exposes. A sourced path whose
// basename is not `.env` is untouched, so `. ./scripts/env.sh` stays ordinary.
// `cmp` is deliberately absent: it prints the offset of the first differing
// byte, not the contents.
const READING_COMMANDS = new Set([
  "cat", "less", "more", "tail", "head", "strings", "od", "xxd", "hexdump",
  "base64", "nl", "tac", "bat", "diff", "sed", "awk", "grep", "egrep", "fgrep",
  "rg", "cut", "sort", "source", ".",
]);

// The reading commands whose FIRST positional operand is a pattern or a script
// rather than a path. `grep .env` searches for that text and opens no file of
// that name, so refusing it would block work this guard has no opinion about.
const PATTERN_READING_COMMANDS = new Set(["grep", "egrep", "fgrep", "rg", "sed", "awk"]);

// The options of that family which carry the pattern themselves - so no
// positional operand does - and, for the -f/--file spellings, NAME a file the
// command reads its patterns from, which is a path like any other.
const PATTERN_LONG_OPTION = /^--(regexp|expression|source|file)(?:=(.*))?$/;
const PATTERN_SHORT_OPTION = /^-[A-Za-z]*?([ef])(.*)$/;

// Commands that copy or relocate a file. Denied when a .env is a SOURCE.
// `tee` is deliberately absent: it has no source operand, it reads stdin and
// writes every operand, so a .env there is a destination. Nothing escapes that
// way - a pipeline's reading stage is classified by its own node.
const COPYING_COMMANDS = new Set(["cp", "mv", "install", "ln", "rsync", "scp"]);

// Options that move a copy's destination out of the trailing operand, so every
// remaining operand is a source: `cp -t /tmp .env` copies the secret out too.
// A short target-directory option carries its value attached to the cluster
// (`-t/tmp`, `-rt/tmp`) or in the next token (`-t /tmp`, `-rt /tmp`), and it may
// sit anywhere inside a cluster, so all of those spellings are recognized: a
// spelling read as an ordinary flag would put the destination back on the
// trailing operand and let a secret out as a source.
const TARGET_DIRECTORY_SHORT = /^-[A-Za-z]*?t(.*)$/;
const TARGET_DIRECTORY_LONG = /^--target-directory(?:=(.*))?$/;

// Redirections that make the shell READ the named file. `> .env` and `>> .env`
// write a file and expose nothing; `<<` and `<<<` name a delimiter or a string
// rather than a path.
const READING_REDIRECTIONS = new Set(["<", "<>"]);

// Harness file tools that only WRITE at the path they name. Every other tool is
// treated as a reader, so an unknown tool name still fails closed.
const PATH_WRITING_TOOLS = new Set(["write", "edit", "multiedit", "notebookedit"]);

// Shells whose -c payload is another program this policy must classify too.
const SHELLS = new Set(["sh", "bash", "zsh", "ksh", "dash"]);

// find's options that carry a command, and the two words that end the carried
// argument list. The carried command really runs, so it is classified exactly
// like a submitted one.
const FIND_CARRIER_OPTIONS = new Set(["-exec", "-execdir", "-ok", "-okdir"]);
const FIND_CARRIER_TERMINATORS = new Set([";", "+"]);

// Raw-text markers for the fail-closed unclassifiable path: when the tokenizer
// cannot parse a command that mentions one of these, refusing beats guessing.
// Anchored on word boundaries so an ordinary word that merely CONTAINS one -
// "legitimate", "digits", a github URL - is not mistaken for the command, which
// would refuse work this guard has no opinion about.
// COUPLED to the rules above - a new perimeter command needs a marker here.
const PERIMETER_MARKERS = /(?:^|[^\w-])(?:sudo|ssh|scp|rsync|chmod|git)(?![\w-])|\.env(?![\w.-])/;

const MAX_DEPTH = 6;

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

const ALLOW = { decision: "allow" };

function basename(value) {
  const cleaned = String(value).replace(/^@/, "").replace(/\\/g, "/").replace(/\/+$/, "");
  return cleaned.split("/").filter(Boolean).at(-1) || cleaned;
}

// A path is inside the perimeter when its own name is exactly .env. Deliberately
// narrower than "anything containing env": firstmate itself tracks ordinary
// files such as config/x-mode.env that workers legitimately read.
function isDotenvPath(value) {
  return basename(value) === ".env";
}

function isOption(value) {
  return value.startsWith("-");
}

// The operands a copy or move READS. The perimeter covers exposing a secret,
// not creating a file: `cp .env.example .env` writes a fresh local config and
// exposes nothing, while `cp .env /tmp/x` and `mv .env /tmp/x` carry the secret
// out. The destination is the trailing operand unless an explicit
// target-directory option holds it, in which case every operand is a source.
function copySourceOperands(args) {
  const operands = [];
  let destinationIsTrailing = true;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    const isLong = value.startsWith("--");
    const target = isLong
      ? TARGET_DIRECTORY_LONG.exec(value)
      : (isOption(value) ? TARGET_DIRECTORY_SHORT.exec(value) : null);
    if (target) {
      destinationIsTrailing = false;
      if (isLong ? target[1] === undefined : !target[1]) index += 1;
      continue;
    }
    if (isOption(value)) continue;
    operands.push(value);
  }
  return destinationIsTrailing ? operands.slice(0, -1) : operands;
}

// The operands a reading command actually opens, and which of its arguments its
// own grammar makes a pattern rather than a path. The one positional operand
// that carries the pattern is dropped, and only when no option supplied the
// pattern instead: every operand after it is a search target, and a file an
// option names is a path, so `grep -f .env .`, `grep --file=.env .` and
// `grep TODO .env` all stay inside the perimeter. `patternIndexes` is the sole
// answer to "which argument is a pattern", covering the positional operand and
// the token a pattern-carrying option takes separately, so no caller works that
// out a second way.
function readOperands(name, args) {
  if (!PATTERN_READING_COMMANDS.has(name)) return { paths: args, patternIndexes: [] };
  const paths = [];
  const patternIndexes = [];
  let patternIsPositional = true;
  let firstPositional = -1;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (!isOption(value)) {
      if (firstPositional < 0) firstPositional = index;
      paths.push(value);
      continue;
    }
    const long = PATTERN_LONG_OPTION.exec(value);
    const short = long ? null : (value.startsWith("--") ? null : PATTERN_SHORT_OPTION.exec(value));
    if (!long && !short) continue;
    patternIsPositional = false;
    const attached = long ? long[2] : short[2];
    const detached = attached === undefined || attached === "";
    const carried = detached ? args[index += 1] : attached;
    const namesFile = long ? long[1] === "file" : short[1] === "f";
    if (namesFile) {
      if (carried !== undefined) paths.push(carried);
      continue;
    }
    if (detached && carried !== undefined) patternIndexes.push(index);
  }
  if (!patternIsPositional) return { paths, patternIndexes };
  return {
    paths: paths.slice(1),
    patternIndexes: firstPositional < 0 ? [] : [firstPositional],
  };
}

// A harness file tool that only writes at the path it names exposes no secret,
// so the path perimeter follows the same source/destination line as the shell
// rules. An absent or unknown tool name is treated as a read.
function pathToolReads(tool) {
  return !PATH_WRITING_TOOLS.has(String(tool).trim().toLowerCase());
}

// git's own options before the subcommand. -C/-c and the long forms take a
// value; everything else here is a bare flag.
function gitSubcommandIndex(words, start) {
  let index = start;
  while (words[index]) {
    const value = words[index].value;
    if (!isOption(value)) return index;
    if (value === "-C" || value === "-c" || value === "--git-dir" || value === "--work-tree" || value === "--namespace" || value === "--exec-path") {
      index += 2;
      continue;
    }
    index += 1;
  }
  return index;
}

// The destination of a push argument: `+HEAD:main` and `refs/heads/main` both
// resolve to main, while `HEAD` and `fm/task-branch` do not.
function pushDestination(value) {
  const refspec = value.replace(/^\+/, "");
  const destination = refspec.includes(":") ? refspec.slice(refspec.lastIndexOf(":") + 1) : refspec;
  return destination.replace(/^refs\/heads\//, "");
}

function isRebasingPull(value) {
  if (value === "-r" || value === "--rebase") return true;
  if (value.startsWith("--rebase=")) return value.slice("--rebase=".length) !== "false";
  return false;
}

function classifyGit(position) {
  const index = gitSubcommandIndex(position.words, position.index + 1);
  const subcommand = position.words[index]?.value;
  if (!subcommand) return ALLOW;
  const rest = position.words.slice(index + 1).map((word) => word.value);
  if (subcommand === "rebase") return deny("history-rewrite");
  // `git pull --rebase` replays the task branch exactly as `git rebase` does,
  // without naming the refused subcommand. The negated spellings do not.
  if (subcommand === "pull" && rest.some(isRebasingPull)) return deny("history-rewrite");
  if (subcommand === "config" && rest.some((value) => value === "--global" || value.startsWith("--global="))) {
    return deny("global-git-config");
  }
  if (subcommand === "push") {
    for (const value of rest) {
      // --all pushes every local branch and --mirror every ref, so both carry
      // master/main along without ever naming them.
      if (value === "--all" || value === "--mirror") return deny("protected-branch-push");
      if (isOption(value)) continue;
      const destination = pushDestination(value);
      if (destination === "master" || destination === "main") return deny("protected-branch-push");
    }
  }
  return ALLOW;
}

// A redirection target is skipped by commandPosition's word list, so `cat < .env`
// must be read off the raw node tokens. Only an input redirection reads the
// file; `echo x > .env` creates one, which the perimeter does not cover.
function redirectionReadsDotenv(tokens) {
  let pendingTarget = false;
  for (const token of tokens) {
    if (token.type === "redir") {
      pendingTarget = !token.inlineTarget && READING_REDIRECTIONS.has(token.value);
      continue;
    }
    if (pendingTarget && token.type === "word") {
      pendingTarget = false;
      if (isDotenvPath(token.value)) return true;
    }
  }
  return false;
}

// A compound command's body arrives as a node introduced by the reserved word
// that opened it - `do chmod +x $f`, `then git push origin main`, `time chmod
// +x a`. commandPosition would read that keyword as the executed command and
// never reach the body, so the keywords are dropped and the remainder is
// classified exactly like the same command written on its own. `!` leads the
// same way, negating the command that follows it rather than being one.
//
// A keyword can carry its own options - `time -p chmod +x a` - and neither a
// compound body nor a timing keyword can legitimately begin with one, so once a
// keyword has been dropped the options that follow it are dropped too. An option
// whose value sits in a SEPARATE token leaves that value in command position
// (`time -o log chmod +x a` resolves to `log`), which is why a node that dropped
// an option has each of its remaining operands classified as a command too.
function withoutLeadingKeywords(tokens) {
  let start = 0;
  let keywordDropped = false;
  let optionDropped = false;
  while (tokens[start]?.type === "word") {
    const value = tokens[start].value;
    const reserved = value === "!" || SHELL_RESERVED_WORDS.has(basename(value));
    if (!reserved && !(keywordDropped && isOption(value))) break;
    if (reserved) keywordDropped = true;
    else optionDropped = true;
    start += 1;
  }
  return {
    body: start === 0 ? tokens : tokens.slice(start),
    dropped: tokens.slice(0, start),
    optionDropped,
  };
}

// Whether any of these words names something inside the perimeter. Redirection
// targets are deliberately absent from what commandPosition returns, so an
// ordinary `done > /tmp/git.log` is never mistaken for a perimeter mention.
function mentionsPerimeter(words) {
  return words.some((word) => PERIMETER_MARKERS.test(word.value));
}

// The command each carrier tool runs out of its own arguments, as token lists
// classified through the same node path a submitted command takes.
//
// find delimits its payload explicitly, so it is read exactly. xargs does not:
// its option set is large and several options take a separate value, so rather
// than resolve the boundary with a second option table this treats a non-option
// argument as the start of a candidate command. An xargs option value that
// happens to name a perimeter command is then refused, which is the direction an
// unresolvable spelling has to fall for a perimeter. What a candidate's own
// grammar makes its PATTERN is not a candidate, though: `xargs grep -l ssh`
// searches for that text and runs nothing, so refusing it would block ordinary
// work exactly as the direct `grep -l ssh` never does.
function carriedPrograms(position) {
  const name = basename(position.command.value);
  const words = position.words.slice(position.index + 1);
  if (name === "find") {
    const programs = [];
    for (let index = 0; index < words.length; index += 1) {
      if (!FIND_CARRIER_OPTIONS.has(words[index].value)) continue;
      const carried = [];
      index += 1;
      while (index < words.length && !FIND_CARRIER_TERMINATORS.has(words[index].value)) {
        carried.push(words[index]);
        index += 1;
      }
      if (carried.length > 0) programs.push(carried);
    }
    return programs;
  }
  if (name === "xargs") {
    const programs = [];
    const patterns = new Set();
    for (let index = 0; index < words.length; index += 1) {
      if (isOption(words[index].value) || patterns.has(index)) continue;
      const carried = words.slice(index);
      programs.push(carried);
      const args = carried.slice(1).map((word) => word.value);
      const { patternIndexes } = readOperands(basename(carried[0].value), args);
      for (const offset of patternIndexes) patterns.add(index + 1 + offset);
    }
    return programs;
  }
  return [];
}

// The payload of `eval '<program>'`. eval runs the concatenation of its
// arguments, minus a leading end-of-options marker.
function evalPayload(position) {
  let words = position.words.slice(position.index + 1);
  if (words[0]?.value === "--") words = words.slice(1);
  return { carried: true, payload: words.map((word) => word.value).join(" ") };
}

// The payload of `sh -c '<program>'`. `carried` says the invocation asked for an
// inline program at all, so an unreadable one can be told apart from a shell
// running a script. The option letter may sit anywhere in a short cluster
// (`sh -cx`, `sh -xc`), and an end-of-options marker may stand between the
// option and its program (`bash -c -- '<program>'`).
function shellPayload(position) {
  const words = position.words;
  for (let index = position.index + 1; index < words.length; index += 1) {
    if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(words[index].value)) continue;
    let payload = index + 1;
    if (words[payload]?.value === "--") payload += 1;
    return { carried: true, payload: words[payload]?.value ?? "" };
  }
  return { carried: false, payload: "" };
}

// The single point where an inline payload becomes a verdict, whatever carrier
// transported it. A carrier's only job is EXTRACTING its payload text from its
// own option grammar, and extraction legitimately differs between carriers;
// classification must not, or two implementations that agree today drift at the
// first correction that touches only one of them. A carrier that asked for a
// payload but could not read one falls back on the ambiguity rule, so an
// unrecognized spelling refuses rather than passing.
function classifyInlinePayload({ carried, payload }, position, depth) {
  if (!carried) return ALLOW;
  if (payload) return classifyCommand(payload, depth + 1);
  return mentionsPerimeter(position.words) ? deny("unclassifiable-perimeter-command") : ALLOW;
}

function classifyCommand(command, depth) {
  // Nesting deeper than this is not classified, so it is refused on the same
  // terms as unparseable syntax rather than allowed: a perimeter command buried
  // under seven layers of substitution must not fall out of the perimeter.
  if (depth > MAX_DEPTH) {
    return PERIMETER_MARKERS.test(command) ? deny("unclassifiable-perimeter-command") : ALLOW;
  }
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    // Fail closed only where it matters: unparseable syntax that mentions a
    // perimeter command is refused, while unrelated exotic syntax stays allowed
    // so the guard never blocks ordinary work it has no opinion about.
    return PERIMETER_MARKERS.test(command) ? deny("unclassifiable-perimeter-command") : ALLOW;
  }

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    // Every stage of every list matters: a pipeline stage or a backgrounded
    // node runs the command just as surely as a top-level one.
    const verdict = classifyNode(node, depth);
    if (verdict.decision === "deny") return verdict;
  }
  return ALLOW;
}

function classifyNode(node, depth) {
  if (depth > MAX_DEPTH) {
    return node.some((token) => token.type === "word" && PERIMETER_MARKERS.test(token.value))
      ? deny("unclassifiable-perimeter-command")
      : ALLOW;
  }
  if (redirectionReadsDotenv(node)) return deny("dotenv-access");

  const { body, dropped, optionDropped } = withoutLeadingKeywords(node);
  const position = commandPosition(body);

  // A nested program runs whatever it contains, so every place the shared
  // lexer parks one is classified against the same perimeter: subshells and
  // brace groups, the command substitutions, backticks, and process
  // substitutions it stores on a word's `subs`, and the payload a wrapper
  // carries inline such as `env -S '<program>'`. Without this descent, a
  // plain `$(...)` would carry the whole perimeter straight through.
  for (const payload of position.wrapperPayloads) {
    const nested = classifyCommand(payload, depth + 1);
    if (nested.decision === "deny") return nested;
  }
  for (const token of node) {
    if (token.type === "group") {
      const nested = classifyCommand(token.content, depth + 1);
      if (nested.decision === "deny") return nested;
    }
    if (token.type === "word") {
      for (const substitution of token.subs) {
        const nested = classifyCommand(substitution.content, depth + 1);
        if (nested.decision === "deny") return nested;
      }
    }
  }

  if (position.wrappers.includes("sudo")) return deny("privilege-escalation");
  if (!position.command) {
    // A wrapper option the shared classifier could not resolve, or a keyword
    // whose body reduced to nothing, can hide the real command position, so a
    // node that mentions the perimeter and resolves to no command is refused
    // rather than skipped. What was dropped is searched too, because the marker
    // may sit there.
    const unresolved = position.unresolvedWrapperOption || dropped.length > 0;
    if (unresolved && mentionsPerimeter([...dropped, ...position.words])) {
      return deny("unclassifiable-perimeter-command");
    }
    return ALLOW;
  }

  const name = basename(position.command.value);
  const denied = DENIED_COMMANDS.get(name);
  if (denied) return deny(denied);

  const args = position.words.slice(position.index + 1).map((word) => word.value);
  if (READING_COMMANDS.has(name) && readOperands(name, args).paths.some(isDotenvPath)) {
    return deny("dotenv-access");
  }
  if (COPYING_COMMANDS.has(name) && copySourceOperands(args).some(isDotenvPath)) {
    return deny("dotenv-access");
  }

  if (name === "git") {
    const gitDecision = classifyGit(position);
    if (gitDecision.decision === "deny") return gitDecision;
  }

  if (SHELLS.has(name)) {
    const nested = classifyInlinePayload(shellPayload(position), position, depth);
    if (nested.decision === "deny") return nested;
  }

  if (name === "eval") {
    const nested = classifyInlinePayload(evalPayload(position), position, depth);
    if (nested.decision === "deny") return nested;
  }

  for (const carried of carriedPrograms(position)) {
    const nested = classifyNode(carried, depth + 1);
    if (nested.decision === "deny") return nested;
  }

  // The resolved command word is not always the one that runs. A dropped keyword
  // option can have left its VALUE standing in command position, and a command
  // word that is an expansion can be empty at run time. Either way the command
  // that runs is the operand immediately after it, so that ONE operand is
  // classified as a command too - not the ones after it, which are its
  // arguments, and not the operand of a command whose own grammar makes it a
  // pattern, or `time -p grep -rn ssh src/` would refuse an ordinary search.
  const commandWordUncertain = optionDropped || !position.command.literal;
  if (commandWordUncertain && !PATTERN_READING_COMMANDS.has(name)) {
    const next = position.words[position.index + 1];
    if (next && !isOption(next.value)) {
      const nested = classifyNode(position.words.slice(position.index + 1), depth + 1);
      if (nested.decision === "deny") return nested;
    }
  }
  return ALLOW;
}

// The single entry point. A tool call carries a command, a path, or both, plus
// the harness's own tool name when it has one; each is classified against the
// same perimeter regardless of which harness delivered it. The tool name is
// data, never a rule: this owner alone decides what it means.
function decision({ command = "", path = "", tool = "" } = {}) {
  if (path && isDotenvPath(path) && pathToolReads(tool)) return deny("dotenv-access");
  if (command) return classifyCommand(command, 0);
  return ALLOW;
}

const OPTIONS = ["command", "path", "tool"];

function parseArguments(argv) {
  const result = { command: "", path: "", tool: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const option = OPTIONS.find((key) => name === `--${key}` || name.startsWith(`--${key}=`));
    if (!option) throw new Error(`unknown argument: ${name}`);
    if (name.startsWith(`--${option}=`)) {
      result[option] = name.slice(option.length + 3);
      continue;
    }
    if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
    result[option] = argv[i + 1];
    i += 1;
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = decision(args);
    if (result.decision === "allow") {
      process.stdout.write("allow\n");
    } else {
      process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
