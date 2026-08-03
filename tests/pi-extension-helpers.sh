#!/usr/bin/env bash
# tests/pi-extension-helpers.sh - shared fixtures for the tracked Pi primary
# extension suites. The Pi session fake below reproduces the exact AgentSession
# ordering these extensions have to survive (the run flag is cleared BEFORE
# agent_settled is emitted, and prompt() only queues a follow-up while that flag
# is set), so it lives here rather than in the generic tests/lib.sh. Generic
# reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_install_pi_guard_extension <repo>: copy the tracked turn-end guard extension
# and every tracked module it imports into <repo>, plus the operational-input
# encoder the extension shells out to.
fm_install_pi_guard_extension() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-extension-env.ts" "$repo/.pi/extensions/lib/fm-extension-env.ts"
  cp "$ROOT/.pi/extensions/lib/fm-followup-delivery.ts" "$repo/.pi/extensions/lib/fm-followup-delivery.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
}

# fm_install_pi_session_fake <dir>: write <dir>/pi-session-fake.mjs, a fake
# ExtensionAPI plus agent-run driver that mirrors Pi's real re-entrancy shape.
fm_install_pi_session_fake() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/pi-session-fake.mjs" <<'JS'
// Fake Pi AgentSession, faithful to the ordering that makes a follow-up sent
// from inside an agent_settled handler re-entrant (verified against pi 0.83.0):
//
//   _runAgentPrompt()  sets the run flag, runs the turn, and in its finally
//                      awaits _emitAgentSettled() - so the run FRAME is still
//                      open while agent_settled handlers run.
//   _emitAgentSettled() clears the run flag BEFORE emitting, so isStreaming is
//                      already false inside a settled handler.
//   prompt()           only takes the follow-up queueing branch when streaming;
//                      otherwise it falls through to a whole new agent run.
//
// `reentrantRuns` counts agent runs started while another run frame is still
// open. That is exactly the defect, so a test asserts it stays zero.

export function createPiSessionFake(options = {}) {
  // Pi's ExtensionRunner.emit walks every extension's handlers for the event and
  // awaits each one in turn, so several settled handlers share one open run frame.
  const handlers = new Map();
  const session = {
    activeRuns: 0,
    reentrantRuns: 0,
    isStreaming: false,
    settledDepth: 0,
    maxSettledDepth: 0,
    followUps: [],
    followUpOptions: [],
    customMessages: [],
  };

  async function runAgentPrompt() {
    if (session.activeRuns > 0) session.reentrantRuns += 1;
    session.activeRuns += 1;
    session.isStreaming = true;
    try {
      if (options.onTurn) await options.onTurn();
    } finally {
      session.isStreaming = false;
      const settled = handlers.get("agent_settled") ?? [];
      if (settled.length > 0) {
        session.settledDepth += 1;
        if (session.settledDepth > session.maxSettledDepth) {
          session.maxSettledDepth = session.settledDepth;
        }
        try {
          for (const handler of settled) {
            await handler({ type: "agent_settled" }, {});
          }
        } finally {
          session.settledDepth -= 1;
        }
      }
      session.activeRuns -= 1;
    }
  }

  const pi = {
    on(event, handler) {
      const existing = handlers.get(event) ?? [];
      existing.push(handler);
      handlers.set(event, existing);
    },
    registerCommand(name, definition) {
      handlers.set(`command:${name}`, [definition.handler]);
    },
    registerTool() {},
    sendMessage(message) {
      session.customMessages.push(message);
    },
    async sendUserMessage(content, sendOptions) {
      session.followUps.push(content);
      session.followUpOptions.push(sendOptions);
      if (session.isStreaming && sendOptions?.deliverAs) return;
      await runAgentPrompt();
    },
  };

  /** First registered handler for `event`, the only one single-extension tests need. */
  const handler = (event) => handlers.get(event)?.[0];

  return { pi, handlers, handler, session, runAgentPrompt };
}

export function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

/** Resolve once no run is open and no new delivery has landed for two ticks. */
export async function quiesce(session, tickMs = 10, maxTicks = 400) {
  let previous = -1;
  let stable = 0;
  for (let i = 0; i < maxTicks; i += 1) {
    await sleep(tickMs);
    const deliveries = session.followUps.length + session.customMessages.length;
    if (session.activeRuns === 0 && deliveries === previous) {
      stable += 1;
      if (stable >= 2) return;
    } else {
      stable = 0;
    }
    previous = deliveries;
  }
  throw new Error("fake Pi session never quiesced");
}

/** Resolve once `predicate()` is true, or throw after the bounded wait. */
export async function waitFor(predicate, label, tickMs = 10, maxTicks = 400) {
  for (let i = 0; i < maxTicks; i += 1) {
    if (predicate()) return;
    await sleep(tickMs);
  }
  throw new Error(`timed out waiting for ${label}`);
}
JS
}
