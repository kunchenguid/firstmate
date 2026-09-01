#!/usr/bin/env node
// Policy for Jala self-do guard: block direct project writes at tool level.
// This file is the sole owner of the project-write decision.
// See docs/selfdo-guard.md (when present) for contract.
// Never executes or expands the submitted path/command; inspects strings only.

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASON = "Jala must delegate project work via workers (muse-spark etc.) - direct writes to projects/ are blocked. Use bin/fm-brief.sh and bin/fm-spawn.sh to delegate. [selfdo-project-write]";

function isProjectPath(target) {
  if (!target) return false;
  const normalized = target.replace(/\\/g, "/");
  // Check for projects/ segment anywhere.
  // Covers "projects/foo", "./projects/foo", "/abs/.../projects/foo",
  // and "projects" exact.
  if (normalized === "projects" || normalized.startsWith("projects/") || normalized.startsWith("./projects/")) return true;
  if (normalized.includes("/projects/") || normalized.includes("/projects")) {
    // Ensure it's a path segment, not substring of another word like "myprojects".
    // Check for "/projects/" or "/projects" at end or followed by "/" or "\".
    const idx = normalized.indexOf("/projects");
    if (idx !== -1) {
      const after = normalized.slice(idx + "/projects".length);
      if (after === "" || after.startsWith("/") || after.startsWith("\\")) return true;
      if (normalized.includes("/projects/")) return true;
    }
  }
  return false;
}

function decisionForPath(target) {
  if (isProjectPath(target)) return { decision: "deny", code: "selfdo-project-write", reason: REASON };
  return { decision: "allow" };
}

// Read-only first words (after basename and env-assignment stripping) that may
// read a projects/ path without being judged write-flavored. Everything not in
// this set - including unknown commands - is treated as write-flavored, so the
// default for an unrecognized command touching projects/ is deny.
const READ_ONLY_FIRST_WORDS = new Set([
  "grep", "egrep", "fgrep", "rg", "cat", "less", "more", "head", "tail",
  "find", "ls", "pwd", "cd", "which", "type", "file", "stat", "wc",
  "diff", "cmp", "sort", "uniq", "cut", "nl", "tac", "basename", "dirname",
  "realpath", "readlink", "du", "date", "echo", "printf", "true", "false",
  "test", "seq", "jq", "awk",
]);

// git subcommands considered read-only; anything else git does is write-flavored.
const GIT_READ_ONLY_SUBCOMMANDS = new Set([
  "status", "log", "diff", "show", "branch", "rev-parse", "rev-list",
  "remote", "ls-files", "ls-remote", "ls-tree", "blame", "shortlog",
  "describe", "cat-file", "reflog", "grep", "diff-tree", "diff-index",
  "diff-files", "whatchanged", "merge-base", "cherry", "version", "help",
  "var", "for-each-ref", "show-branch", "count-objects", "name-rev",
]);

// git global flags whose next token is the flag's value, not the subcommand.
const GIT_VALUE_FLAGS = new Set([
  "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix",
]);

function gitSubcommandFromTokens(tokens) {
  for (let i = 1; i < tokens.length; i++) {
    const token = tokens[i];
    if (GIT_VALUE_FLAGS.has(token)) { i++; continue; }
    if (token.startsWith("-")) continue;
    return token;
  }
  return "";
}

function segmentIsReadOnly(segment) {
  const tokens = segment.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return true;
  let index = 0;
  // Skip leading env assignments like FOO=1.
  while (index < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[index])) index++;
  if (index >= tokens.length) return true;
  const first = tokens[index].replace(/^.*\//, "");
  if (first === "git") return GIT_READ_ONLY_SUBCOMMANDS.has(gitSubcommandFromTokens(tokens.slice(index)));
  if (first === "sed") {
    // sed is stream-editing (read-only) unless -i/--in-place appears.
    return !tokens.some((t) => /^-[a-zA-Z]*i/.test(t)) && !tokens.includes("--in-place");
  }
  return READ_ONLY_FIRST_WORDS.has(first);
}

// Split a normalized command into pipeline/compound segments.
function commandSegments(normalized) {
  return normalized.split(/&&|\|\||;|\|/).map((s) => s.trim()).filter(Boolean);
}

// True when the command carries an output-redirect operator after benign
// stderr/stdout sinks are removed.
function containsRedirect(normalized) {
  let stripped = normalized;
  for (const sink of ["2>/dev/null", ">/dev/null", "&>/dev/null", "2>&1", ">/dev/null "]) {
    stripped = stripped.split(sink).join(" ");
  }
  return stripped.includes(">");
}

function decisionForCommand(command) {
  if (!command) return { decision: "allow" };
  const mentionsProjects = command.includes("projects/") || command.includes("projects\\") || isProjectPath(command) || /\bprojects\b/.test(command);
  if (!mentionsProjects) return { decision: "allow" };
  // Mirror arm-guard prefilter normalization: drop backslashes, quotes, newlines but keep substring detectable.
  const normalized = command.replace(/\\/g, "").replace(/"/g, "").replace(/'/g, "").replace(/\n/g, " ").replace(/\r/g, "");
  if (!normalized.includes("projects/") && !normalized.includes("projects\\") && !isProjectPath(normalized) && !/\bprojects\b/.test(normalized)) {
    return { decision: "allow" };
  }
  // Narrowed matrix: only write-flavored commands touching projects/ are
  // denied. Known read-only commands (grep, cat, git -C ... status, ...) that
  // merely reference projects/ paths are allowed. Unknown commands touching
  // projects/ deny conservatively.
  if (containsRedirect(normalized)) return { decision: "deny", code: "selfdo-project-write", reason: REASON };
  for (const segment of commandSegments(normalized)) {
    if (!segmentIsReadOnly(segment)) {
      return { decision: "deny", code: "selfdo-project-write", reason: REASON };
    }
  }
  return { decision: "allow" };
}

function parseArgs(argv) {
  const result = { path: "", command: "", pathSet: false, commandSet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--path") {
      if (i + 1 >= argv.length) throw new Error("--path requires a value");
      result.path = argv[i + 1];
      result.pathSet = true;
      i++;
      continue;
    }
    if (a.startsWith("--path=")) {
      result.path = a.slice("--path=".length);
      result.pathSet = true;
      continue;
    }
    if (a === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i++;
      continue;
    }
    if (a.startsWith("--command=")) {
      result.command = a.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${a}`);
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
    const args = parseArgs(process.argv.slice(2));
    let result = { decision: "allow" };
    if (args.pathSet) result = decisionForPath(args.path);
    else if (args.commandSet) result = decisionForCommand(args.command);
    else {
      process.stdout.write("allow\n");
      process.exit(0);
    }
    if (result.decision === "allow") process.stdout.write("allow\n");
    else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exitCode = 1;
  }
}

export { decisionForPath, decisionForCommand, isProjectPath };
