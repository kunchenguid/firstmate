#!/usr/bin/env node
// Semantic policy for the push-guard: does a shell command run `git push`
// against `main` or `master` on any remote?
//
// Origin: 2026-09-04 firstmate pushed two configuration commits straight to a
// project's main from a scratch clone, without the pipeline that would have
// caught the regression; each turned that project's main red. GitHub branch
// protection needs a paid plan the captain declined, so this textual guard is
// the backstop. See docs/push-guard.md for this guard's exact contract and
// docs/cd-guard.md for the sibling family this guard belongs to.
//
// Unlike the cd-guard, this policy does not filter by whether a node persists
// to the parent shell: `git push` executes wherever control reaches it,
// including inside a subshell, a pipeline stage, or a background job, so every
// reachable command position is in scope. The shell tokenizer and
// command-position analysis are imported from bin/fm-arm-command-policy.mjs,
// the sole owner of firstmate's shell classification; this file never
// duplicates shell lexing. It never evaluates, expands, sources, or runs any
// byte of the submitted command - it inspects lexical command positions only.
//
// A `git push` with no repository/refspec argument (or with only a repository)
// pushes the current branch (git's own `simple`/`current` push.default), which
// this policy cannot determine from text alone. For that case it returns a
// `check-branch` decision naming the effective directory (from a `git -C <dir>`
// prefix, when present); the caller (bin/fm-push-guard-pretool-check.sh) is the
// only place that queries real repository state, by running `git symbolic-ref`
// in that directory - never by executing any byte of the submitted command.
//
// Fail direction is the opposite of the cd-guard's: an explicit textual
// main/master target always denies, and shell syntax this classifier cannot
// tokenize denies too when the raw text mentions both `git` and `push`,
// mirroring bin/fm-arm-command-policy.mjs's fail-closed stance for protected
// commands. A blocked push costs one clarifying turn; a red main costs a
// captain incident, so ambiguity here favors the deny.
//
// Accepted non-goals (documented rather than silently missed):
//   - `git push origin :main` (a refspec that DELETES the remote branch) is not
//     denied. Deleting main is a different, rarer mistake than overwriting it,
//     and is out of the enumerated case list this guard was built against.
//   - Indirection through a program this classifier does not treat as a
//     transparent wrapper (`xargs git push ...`, a Makefile target, a custom
//     script that shells out to `git push`) is not traced. The threat model is
//     an agent mistake typing `git push` directly, not deliberate obfuscation.
//   - Obscure git global options with an attached, unenumerated argument form
//     are treated as taking no argument; only the options germane to reaching
//     `push` (`-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`,
//     `--exec-path`, and `--`) are argument-aware.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "protected-branch-push":
    "a direct git push to main or master is blocked; land it through a PR so CI proves it before main - use bin/fm-pr-merge.sh or bin/fm-merge-local.sh.",
  "push-all-mirror":
    "a --all or --mirror push reaches main or master along with every other ref; land it through a PR so CI proves it before main - use bin/fm-pr-merge.sh or bin/fm-merge-local.sh.",
  "unclassifiable-push":
    "unsupported or malformed shell syntax contains a git push and cannot be classified safely; land it through a PR so CI proves it before main - use bin/fm-pr-merge.sh or bin/fm-merge-local.sh.",
};

// The explicit allowance the two merge owners set inline on the same command as
// the push, never inferred from a path or process name. Neither owner script
// currently issues `git push` itself (fm-merge-local.sh does a local
// `merge --ff-only`; fm-pr-merge.sh merges through gh/glab's server-side API),
// so this exemption is unexercised by any current call site - it exists so a
// future change to either owner has a sanctioned way to push directly without
// widening this policy into a path-based bypass.
const OWNER_MARKERS = new Set(["FM_PUSH_GUARD_OWNER=fm-pr-merge", "FM_PUSH_GUARD_OWNER=fm-merge-local"]);

const GIT_GLOBAL_OPTIONS_WITH_ARG = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]);
const GIT_GLOBAL_OPTIONS_WITH_ARG_PREFIXED = ["--git-dir=", "--work-tree=", "--namespace=", "--exec-path="];

const PUSH_OPTIONS_WITH_ARG = new Set(["-o", "--push-option", "--repo", "--receive-pack", "--exec"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function hasOwnerMarker(words, uptoIndex) {
  return words.slice(0, uptoIndex).some((word) => OWNER_MARKERS.has(word.value));
}

// Skip git's own global options (before the subcommand). Returns the index of
// the first word that is not a recognized global option, plus the last `-C`
// argument seen (the effective directory for a later branch check).
function skipGitGlobalOptions(words, start) {
  let index = start;
  let dir = "";
  while (index < words.length) {
    const value = words[index].value;
    if (value === "--") {
      index += 1;
      break;
    }
    if (!value.startsWith("-")) break;
    if (value === "-C") {
      dir = words[index + 1]?.value ?? dir;
      index += 2;
      continue;
    }
    if (GIT_GLOBAL_OPTIONS_WITH_ARG.has(value)) {
      index += 2;
      continue;
    }
    if (GIT_GLOBAL_OPTIONS_WITH_ARG_PREFIXED.some((prefix) => value.startsWith(prefix))) {
      index += 1;
      continue;
    }
    // Any other flag (paginate/no-pager/bare/literal-pathspecs/... or an
    // option this list does not enumerate) is treated as taking no argument;
    // see the "Accepted non-goals" note at the top of this file.
    index += 1;
  }
  return { index, dir };
}

// Classify one `git push ...` invocation's arguments. Returns a site
// descriptor or null when nothing about it targets a protected branch.
function classifyPushArgs(words, dir) {
  let sawAll = false;
  let sawMirror = false;
  const positionals = [];
  let onlyPositionals = false;
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (!onlyPositionals && value === "--") {
      onlyPositionals = true;
      continue;
    }
    if (!onlyPositionals && value.startsWith("-")) {
      if (value === "--all" || value === "--mirror") {
        if (value === "--all") sawAll = true;
        else sawMirror = true;
        continue;
      }
      if (PUSH_OPTIONS_WITH_ARG.has(value)) {
        i += 1;
        continue;
      }
      continue;
    }
    positionals.push(words[i]);
  }

  if (sawAll || sawMirror) return { kind: "deny", code: "push-all-mirror" };

  if (positionals.length <= 1) return { kind: "bare", dir };

  for (const refspecWord of positionals.slice(1)) {
    const refspec = refspecWord.value.replace(/^\+/, "");
    const colon = refspec.indexOf(":");
    const src = colon === -1 ? refspec : refspec.slice(0, colon);
    const target = colon === -1 ? refspec : refspec.slice(colon + 1);
    if (colon !== -1 && !src) continue; // a delete refspec (`:main`); see accepted non-goals.
    if (!target) continue;
    const normalized = target.replace(/^refs\/heads\//, "");
    if (normalized === "main" || normalized === "master") return { kind: "deny", code: "protected-branch-push" };
  }
  return null;
}

// The fail-closed trigger for text this classifier cannot tokenize: `git` and
// `push` within the same short run of text, not merely present anywhere in
// the command. A heredoc body or a long commit message routinely mentions
// both words far apart (this very file's own commit messages do), and a
// naive "contains both words" test would fail closed on ordinary prose - most
// visibly on the exact `git commit -m "$(cat <<'EOF' ... EOF)"` shape used to
// land this guard's own commits, whose heredoc body breaks this classifier's
// paren-balance tracking in a `$(...)` substitution. Requiring proximity
// keeps the fail-closed net tight to an actual attempted invocation
// (`git push "unterminated`) while not misfiring on distant, unrelated
// mentions of the two words.
function mentionsGitPushNearby(command) {
  return /\bgit\b[^\n]{0,80}\bpush\b/.test(command);
}

// Find every reachable `git push` site in `command`, recursing into subshells,
// brace groups, command/backtick substitutions, `eval` payloads, and a
// literal `sh -c`/`bash -c`/`zsh -c` payload - the same reachability surface
// bin/fm-arm-command-policy.mjs traces for its own protected commands, because
// none of those constructs stop a `git push` from executing.
function findSites(command, depth) {
  if (depth > 12) return { sites: [], unparseable: mentionsGitPushNearby(command) };
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return { sites: [], unparseable: mentionsGitPushNearby(command) };

  const { nodes } = splitProgram(lexed.tokens);
  const sites = [];
  let unparseable = false;

  for (const tokens of nodes) {
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = findSites(token.content, depth + 1);
        sites.push(...nested.sites);
        unparseable ||= nested.unparseable;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = findSites(substitution.content, depth + 1);
          sites.push(...nested.sites);
          unparseable ||= nested.unparseable;
        }
      }
    }

    const position = commandPosition(tokens);
    if (!position.command) continue;

    // A literal `sh -c '...'`/`bash -c '...'`/`zsh -c '...'` payload runs in a
    // child shell but still executes; a dynamic (non-literal) payload cannot be
    // inspected further and is covered by the raw-substring fail-closed check.
    const shellName = basename(position.command.value);
    if (["sh", "bash", "zsh"].includes(shellName)) {
      for (let i = position.index + 1; i < position.words.length; i += 1) {
        if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(position.words[i].value)) continue;
        const payload = position.words[i + 1];
        if (payload && payload.literal && payload.subs.length === 0) {
          const nested = findSites(payload.value, depth + 1);
          sites.push(...nested.sites);
          unparseable ||= nested.unparseable;
        } else if (payload) {
          unparseable ||= mentionsGitPushNearby(command);
        }
        break;
      }
    }
    if (shellName === "eval") {
      const payloads = position.words.slice(position.index + 1);
      if (payloads.length > 0 && payloads.every((word) => word.literal && word.subs.length === 0)) {
        const nested = findSites(payloads.map((word) => word.value).join(" "), depth + 1);
        sites.push(...nested.sites);
        unparseable ||= nested.unparseable;
      } else if (payloads.length > 0) {
        unparseable ||= mentionsGitPushNearby(command);
      }
    }

    if (basename(position.command.value) !== "git") continue;

    const afterGit = skipGitGlobalOptions(position.words, position.index + 1);
    const subcommand = position.words[afterGit.index];
    if (!subcommand || subcommand.value !== "push") continue;
    if (hasOwnerMarker(position.words, position.index)) continue;

    const pushArgs = position.words.slice(afterGit.index + 1);
    const site = classifyPushArgs(pushArgs, afterGit.dir);
    if (site) sites.push(site);
  }

  return { sites, unparseable };
}

function decision(command) {
  const { sites, unparseable } = findSites(command, 0);
  if (unparseable) return deny("unclassifiable-push");
  const denySite = sites.find((site) => site.kind === "deny");
  if (denySite) return deny(denySite.code);
  const bareSite = sites.find((site) => site.kind === "bare");
  if (bareSite) return { decision: "check-branch", dir: bareSite.dir };
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
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
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else if (result.decision === "check-branch") {
        process.stdout.write(`check-branch\t${result.dir}\n`);
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
