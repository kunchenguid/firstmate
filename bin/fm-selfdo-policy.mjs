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

function decisionForCommand(command) {
  if (!command) return { decision: "allow" };
  // Mirror arm-guard prefilter normalization: drop backslashes, quotes, newlines but keep substring detectable.
  const normalized = command.replace(/\\/g, "").replace(/"/g, "").replace(/'/g, "").replace(/\n/g, " ").replace(/\r/g, "");
  if (normalized.includes("projects/") || normalized.includes("projects\\") || /\bprojects\b/.test(normalized) && normalized.includes("projects")) {
    // Use same isProjectPath check on raw command for safety: if it literally mentions projects as path.
    if (isProjectPath(command) || command.includes("projects/") || command.includes("projects\\")) {
      return { decision: "deny", code: "selfdo-project-write", reason: REASON };
    }
    // Fallback substring: any occurrence of "projects/" even after stripping quotes is a project touch.
    if (normalized.includes("projects/")) return { decision: "deny", code: "selfdo-project-write", reason: REASON };
  }
  // Also check raw for projects segment.
  if (command.includes("projects/")) return { decision: "deny", code: "selfdo-project-write", reason: REASON };
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
