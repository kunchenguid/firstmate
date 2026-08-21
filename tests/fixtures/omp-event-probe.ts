// Test-only event probe for omp verification (tests/fixtures/omp-event-probe.ts).
// Logs every event omp fires plus ctx facts to a probe log file, so the
// verification plan's layer 4 cases (A-F) can assert exact event sequences
// without depending on model behavior.
//
// Usage: omp -p -e tests/fixtures/omp-event-probe.ts -e <watch> -e <guard> \
//          --session-dir <tmp> --auto-approve "prompt"
//        then read <tmp>/omp-event-probe.log
//
// This file is NOT shipped as a firstmate extension; it lives under tests/fixtures.
import { appendFileSync } from "node:fs";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const probeLog = process.env.OMP_EVENT_PROBE_LOG || "/tmp/omp-event-probe.log";

function log(line: string): void {
  const ts = new Date().toISOString();
  appendFileSync(probeLog, `${ts} ${line}\n`);
}

export default function (pi: ExtensionAPI) {
  log("probe: loaded");

  pi.on?.("session_start", () => log("event: session_start"));
  pi.on?.("session_switch", (event: { reason?: string }) =>
    log(`event: session_switch reason=${event.reason ?? "?"}`));
  pi.on?.("session_branch", () => log("event: session_branch"));
  pi.on?.("session_shutdown", () => log("event: session_shutdown"));
  pi.on?.("session_compact", () => log("event: session_compact"));
  pi.on?.("session_stop", (event: { stop_hook_active?: boolean }) =>
    log(`event: session_stop stop_hook_active=${event.stop_hook_active ?? "?"}`));
  pi.on?.("agent_start", () => log("event: agent_start"));
  pi.on?.("agent_end", (event: { willContinue?: boolean }) =>
    log(`event: agent_end willContinue=${event.willContinue ?? "false"}`));
  pi.on?.("turn_start", (event: { turnIndex?: number }) =>
    log(`event: turn_start turnIndex=${event.turnIndex ?? "?"}`));
  pi.on?.("turn_end", (event: { turnIndex?: number }) =>
    log(`event: turn_end turnIndex=${event.turnIndex ?? "?"}`));
  pi.on?.("tool_call", (event: { toolName?: string }) => {
    log(`event: tool_call toolName=${event.toolName ?? "?"}`);
    return {};
  });

  log("probe: handlers registered");
}
