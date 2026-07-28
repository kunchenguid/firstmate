#!/usr/bin/env node
// Semantic policy for the Firstmate worker merge guard.
//
// The shell tokenizer and command-position analysis come from
// fm-arm-command-policy.mjs, the single shell-classification owner.
// This policy never executes, expands, or sources submitted command bytes.
// It denies merge-shaped GitHub CLI operations in executed positions, including
// path-qualified binaries, command/env wrappers, literal nested shells/eval,
// command substitutions, same-command aliases, literal binary variables, and
// gh alias creation whose expansion would reach a merge or cannot be read here.
// Subcommand classification is option-aware because gh accepts its persistent
// flags (-R/--repo and friends) between `pr` and the subcommand it runs.

import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const REASON = "workers may prepare and inspect pull requests but never merge them; stop with the full green PR URL for captain approval, and only firstmate may execute an approved bin/fm-pr-merge.sh";

function deny() {
  return { decision: "deny", code: "worker-pr-merge", reason: REASON };
}

function allow() {
  return { decision: "allow" };
}

function executableName(value) {
  return path.basename(value || "");
}

function parseAssignment(word) {
  const match = word?.value?.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
  if (!match) return null;
  if (word.literal && word.subs.length === 0) return { name: match[1], value: match[2] };
  if (word.subs.length === 1 && match[2] === "") {
    const nested = new Lexer(word.subs[0].content).tokenize();
    if (!nested.error) {
      const program = splitProgram(nested.tokens);
      if (program.nodes.length === 1) {
        const position = commandPosition(program.nodes[0]);
        const values = position.words.map((item) => item.value);
        if (executableName(position.command?.value) === "command" && values.includes("-v")) {
          const candidate = values.at(-1);
          if (candidate === "gh" || candidate === "gh-axi") return { name: match[1], value: candidate };
        }
      }
    }
  }
  return null;
}

function resolveExecutable(word, variables) {
  if (!word) return "";
  if (word.literal) return word.value;
  const match = word.value.match(/^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$/);
  if (!match) return word.value;
  return variables.get(match[1] || match[2]) || word.value;
}

// Every `gh pr` subcommand except `merge`. A word that is neither an option nor
// one of these is a flag value (`--repo owner/name`), so the scan continues.
// bin/fm-worker-github.sh carries the same list for the PATH layer; the two must
// stay identical, and tests/fm-worker-merge-guard.test.sh fails when they drift.
const PR_SUBCOMMANDS = new Set([
  "checkout", "checks", "close", "comment", "create", "diff", "edit", "list",
  "lock", "ready", "reopen", "revert", "review", "status", "unlock",
  "update-branch", "view",
]);

function hasPrMerge(args) {
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] !== "pr") continue;
    for (let scan = index + 1; scan < args.length; scan += 1) {
      const arg = args[scan];
      if (arg === "merge") return true;
      if (arg.startsWith("-")) continue;
      if (PR_SUBCOMMANDS.has(arg)) break;
    }
  }
  return false;
}

function hasMergeApi(args) {
  return args.some((arg) => /(?:^|\/)repos\/[^/]+\/[^/]+\/pulls\/[^/]+\/merge(?:\?.*)?$/.test(arg))
    || args.some((arg) => /\bmergePullRequest\b/.test(arg));
}

// An alias expands into a full gh command later, so the whole `gh alias`
// namespace is closed here. `set` carries its body as one word, which is
// re-split and classified; `list` and `delete` create nothing; every other
// alias-creating form (`import` reads a YAML file or stdin) supplies bytes this
// boundary cannot see, so it is refused. bin/fm-worker-github.sh mirrors this.
const ALIAS_NON_CREATING = new Set(["list", "delete"]);

function ghAliasMergeShaped(args) {
  const words = args.filter((arg) => !arg.startsWith("-"));
  if (words[0] !== "alias") return false;
  const subcommand = words[1];
  if (subcommand === undefined || ALIAS_NON_CREATING.has(subcommand)) return false;
  if (subcommand !== "set") return true;
  const body = args.flatMap((arg) => arg.split(/\s+/).filter(Boolean));
  return hasPrMerge(body) || hasMergeApi(body);
}

function ghMergeShaped(args) {
  return hasPrMerge(args) || hasMergeApi(args) || ghAliasMergeShaped(args);
}

function directMerge(position, variables, aliases, depth) {
  const resolved = resolveExecutable(position.command, variables);
  const name = executableName(resolved);
  const args = position.words.slice(position.index + 1).map((word) => word.value);

  if ((name === "gh" || name === "gh-axi") && ghMergeShaped(args)) return true;

  // A literal alias defined earlier in the same submitted shell program expands
  // before execution. Reclassify its body with the invocation arguments.
  if (aliases.has(name) && depth < 8) {
    const expansion = `${aliases.get(name)} ${args.map((arg) => `'${arg.replaceAll("'", "'\\''")}'`).join(" ")}`;
    if (decision(expansion, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return true;
  }

  // Catch a literal or variable/alias-shaped GitHub executable that preserves
  // the standard `pr merge` argument surface without blocking data commands.
  if (hasPrMerge(args) && (!position.command?.literal || /(?:^|[-_])gh(?:-axi)?$/i.test(name))) return true;

  return false;
}

function shellPayload(position) {
  const name = executableName(position.command?.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  for (let index = position.index + 1; index < position.words.length; index += 1) {
    const option = position.words[index];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.value)) {
      let payloadIndex = index + 1;
      if (position.words[payloadIndex]?.value === "--") payloadIndex += 1;
      const payload = position.words[payloadIndex];
      return payload?.literal && payload.subs.length === 0 ? payload.value : null;
    }
    if (/^[-+]O$/.test(option.value)) {
      index += 1;
      continue;
    }
    if (option.value === "--" || /^[-+]/.test(option.value)) continue;
    return null;
  }
  return null;
}

function evalPayload(position) {
  if (executableName(position.command?.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

function recordAlias(position, aliases) {
  if (executableName(position.command?.value) !== "alias") return;
  for (const word of position.words.slice(position.index + 1)) {
    const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$/s);
    if (match && word.literal && word.subs.length === 0) aliases.set(match[1], match[2]);
  }
}

function rawLooksMergeShaped(command) {
  const normalized = command.replace(/\\\r?\n/g, "");
  const words = normalized.split(/[\s'"`()]+/).filter(Boolean);
  return (/(?:^|[/\s'"`(])gh(?:-axi)?(?:[\s'"`]|$)/i.test(normalized) && hasPrMerge(words))
    || /\bmergePullRequest\b/.test(normalized)
    || /\/pulls\/[^/\s'"`]+\/merge\b/.test(normalized);
}

function decision(command, context = {}) {
  const depth = context.depth || 0;
  if (depth > 12) return rawLooksMergeShaped(command) ? deny() : allow();

  const variables = context.variables || new Map();
  const aliases = context.aliases || new Map();
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return rawLooksMergeShaped(command) ? deny() : allow();

  const program = splitProgram(lexed.tokens);
  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);

    for (const payload of position.wrapperPayloads) {
      if (decision(payload, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return deny();
    }

    for (const token of tokens) {
      if (token.type === "group") {
        if (decision(token.content, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return deny();
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          if (decision(substitution.content, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return deny();
        }
      }
    }

    const shell = shellPayload(position);
    if (shell !== null && decision(shell, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return deny();
    const evaluated = evalPayload(position);
    if (evaluated !== null && decision(evaluated, { variables: new Map(variables), aliases: new Map(aliases), depth: depth + 1 }).decision === "deny") return deny();

    if (directMerge(position, variables, aliases, depth)) return deny();
    recordAlias(position, aliases);
    for (const word of position.words.slice(0, position.prefixAssignments)) {
      const assignment = parseAssignment(word);
      if (assignment) variables.set(assignment.name, assignment.value);
    }
  }

  return allow();
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--command") {
      if (index + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[index + 1];
      result.commandSet = true;
      index += 1;
      continue;
    }
    if (argv[index].startsWith("--command=")) {
      result.command = argv[index].slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${argv[index]}`);
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
    const result = args.commandSet && args.command ? decision(args.command) : allow();
    if (result.decision === "allow") process.stdout.write("allow\n");
    else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
