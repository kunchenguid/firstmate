#!/usr/bin/env node
// fm-branch-dispatch.mjs - the command-line entry to supervision-branch wake
// dispatch, for a host that is not a Pi process (bin/fm-supervision-host.sh,
// docs/supervision-host.md).
//
// It reimplements nothing: .pi/extensions/lib/fm-branch-dispatch.ts stays the
// single owner of which queued rows the branch may claim and of the wake text,
// and this file only prints that module's answers in a shape a shell can read.
// The Pi branch extension and this entry therefore apply identical rules.
//
// Usage:
//   fm-branch-dispatch.mjs scope [--heartbeat] [--afk]
//     Print scopeForUnreadWake's verdict for this home's wake queue, one
//     key=value line each:
//       status=safe|empty|unsafe
//       corrupted=0|1   1 only when the scan itself is untrustworthy
//       rows=<seq> ...  the exact sequence numbers the branch may claim
//       tasks=<id> ...  the task ids those rows resolve to
//       unscoped=0|1    1 when the claim names no task (a heartbeat review, or
//                       a claimed heartbeat or check row), so a report on any
//                       task or on fleet is in scope
//     --heartbeat marks a heartbeat wake; --afk applies the away-posture
//     collapse (docs/pi-supervision-branch.md "Postures").
//   fm-branch-dispatch.mjs wake-prompt --report <surface> [--away [--readback-file <path>]]
//     Read the watcher's wake reason from stdin and print the branch wake
//     prompt naming <surface> as the report surface. --away appends the away
//     tail with the record read-back from <path>; a missing or empty read-back
//     prints the tail's fixed unavailable notice instead.
//
// The state directory is FM_STATE_OVERRIDE, else $FM_HOME/state, else the
// repository's own state/. Exit 0 on success, 2 on invalid use.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dispatch = await import(pathToFileURL(path.join(root, ".pi", "extensions", "lib", "fm-branch-dispatch.ts")).href);

function usage() {
  process.stderr.write(
    "usage: fm-branch-dispatch.mjs scope [--heartbeat] [--afk] | wake-prompt --report <surface> [--away [--readback-file <path>]]\n",
  );
  process.exit(2);
}

function stateDir() {
  if (process.env.FM_STATE_OVERRIDE) return process.env.FM_STATE_OVERRIDE;
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  return path.join(home, "state");
}

const [command, ...args] = process.argv.slice(2);

if (command === "scope") {
  let heartbeat = false;
  let afk = false;
  for (const arg of args) {
    if (arg === "--heartbeat") heartbeat = true;
    else if (arg === "--afk") afk = true;
    else usage();
  }
  const scope = dispatch.scopeForUnreadWake(stateDir(), heartbeat, afk);
  const unscoped = heartbeat || scope.checkSeqs.length > 0 || scope.heartbeatSeqs.length > 0;
  process.stdout.write(
    `status=${scope.status}\n` +
      `corrupted=${scope.corrupted ? 1 : 0}\n` +
      `rows=${scope.eligibleSeqs.join(" ")}\n` +
      `tasks=${scope.eligibleTasks.join(" ")}\n` +
      `unscoped=${unscoped ? 1 : 0}\n`,
  );
} else if (command === "wake-prompt") {
  let report = "";
  let away = false;
  let readbackFile = "";
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--report" && index + 1 < args.length) report = args[++index];
    else if (arg === "--away") away = true;
    else if (arg === "--readback-file" && index + 1 < args.length) readbackFile = args[++index];
    else usage();
  }
  if (!report) usage();
  const message = readFileSync(0, "utf8").replace(/\n+$/, "");
  let tail = "";
  if (away) {
    let readback = "";
    if (readbackFile) {
      try {
        readback = readFileSync(readbackFile, "utf8");
      } catch {
        readback = "";
      }
    }
    tail = dispatch.awayPostureTailFor(readback);
  }
  process.stdout.write(`${dispatch.branchWakePrompt(message, report, tail)}\n`);
} else {
  usage();
}
