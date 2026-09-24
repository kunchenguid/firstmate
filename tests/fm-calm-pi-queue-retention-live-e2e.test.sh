#!/usr/bin/env bash
# Default-on live guard for the capability Calm's queued-row adapter preflights: a real
# interactive Pi session must expose every session member the adapter uses to keep a hidden
# queued notification across Escape. Those members live on Pi's session object, not on an
# exported class, so only a running Pi can answer.
#
# When a member is missing, the adapter degrades quietly by design: queued Firstmate rows
# stay visible and one warning appears. This guard fails loudly naming the installed Pi
# version instead, so a Pi release that removes the capability is noticed rather than
# silently costing the captain the hidden rows. The Escape flow itself is pinned by
# test_queued_operational_rows and test_queued_operational_escape_e2e in
# tests/fm-calm-pi-extension.test.sh.
#
# No model turn reaches any provider: a local faux provider holds one turn in a tool so a
# message can queue, and a probe extension records the live session's members from Pi's
# own queued-listing redraw. Scratch FM_HOME, project, Pi agent directory, session
# directory, and a private tmux socket; nothing global is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CALM_PI_QUEUE_RETENTION_LIVE pi tmux node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
SOCKET="fm-calm-queue-retention-$$"
SESSION=calm-queue-retention
TMP_ROOT=$(fm_test_tmproot fm-calm-queue-retention)
PROJECT="$TMP_ROOT/project"
PROBE_OUT="$TMP_ROOT/session-members.json"
mkdir -p "$PROJECT/.pi/extensions/lib" "$TMP_ROOT/home/config" "$TMP_ROOT/agent" "$TMP_ROOT/sessions"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_init_commit "$PROJECT"
cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/"

cat >"$PROJECT/queue-retention-probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { CALM_QUEUE_RETENTION_SESSION_METHODS } from "./.pi/extensions/lib/fm-calm-pending-operational-layout.ts";

const out = process.env.QUEUE_RETENTION_PROBE_OUT as string;

export default function (pi: ExtensionAPI): void {
  const prototype = (PiCodingAgent.InteractiveMode as unknown as { prototype: Record<string, unknown> }).prototype;
  const prototypeMembers = Object.fromEntries(
    ["getAllQueuedMessages", "updatePendingMessagesDisplay", "clearAllQueues", "restoreQueuedMessagesToEditor"]
      .map((name) => [name, typeof prototype[name]]),
  );
  const original = prototype.updatePendingMessagesDisplay as (this: Record<string, unknown>) => void;
  prototype.updatePendingMessagesDisplay = function (this: Record<string, unknown>): void {
    const session = this.session as Record<string, unknown> | undefined;
    if (session && (session.getFollowUpMessages as () => string[])().length > 0) {
      writeFileSync(out, JSON.stringify({
        prototype: prototypeMembers,
        session: Object.fromEntries(CALM_QUEUE_RETENTION_SESSION_METHODS.map((name) => [name, typeof session[name]])),
        isIdle: typeof session.isIdle,
        compactionQueuedMessages: Array.isArray(this.compactionQueuedMessages),
      }));
    }
    original.call(this);
  };

  const faux = createFauxCore({
    api: "queue-retention-probe-api",
    provider: "queue-retention-probe",
    models: [{
      id: "deterministic",
      name: "Calm queue-retention capability probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("queue-retention-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerTool({
    name: "hold_turn",
    label: "hold_turn",
    description: "Queue one follow-up, then hold the turn until it is aborted.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal) {
      await pi.sendUserMessage("QUEUE_RETENTION_PROBE_FOLLOW_UP", { deliverAs: "followUp" });
      await new Promise<void>((resolve) => signal?.addEventListener("abort", () => resolve(), { once: true }));
      return { content: [{ type: "text", text: "released" }], details: {} };
    },
  });
  pi.registerCommand("queue-retention-probe", {
    description: "Hold a turn open while one follow-up queues.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("queue-retention-probe", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("probe model unavailable");
      faux.setResponses([
        fauxAssistantMessage([fauxToolCall("hold_turn", {}, { id: "hold_probe" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxText("QUEUE_RETENTION_PROBE_DONE")]),
      ]);
      pi.sendUserMessage("QUEUE_RETENTION_PROBE_PROMPT");
    },
  });
}
TS

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 36 \
  "cd '$PROJECT' && env FM_HOME='$TMP_ROOT/home' PI_CODING_AGENT_DIR='$TMP_ROOT/agent' QUEUE_RETENTION_PROBE_OUT='$PROBE_OUT' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e ./queue-retention-probe.ts --session-dir '$TMP_ROOT/sessions'; sleep 30"

i=0
until tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null | grep -Fq 'queue-retention-probe.ts'; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || fail "Pi $PI_VERSION did not reach its composer: $(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null)"
  sleep 0.05
done
tmux -L "$SOCKET" send-keys -t "$SESSION" -l '/queue-retention-probe'
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
i=0
until [ -s "$PROBE_OUT" ]; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || fail "Pi $PI_VERSION never redrew its queued listing for a queued follow-up: $(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null)"
  sleep 0.05
done
tmux -L "$SOCKET" send-keys -t "$SESSION" Escape

# shellcheck disable=SC2016 # Literal JavaScript; its template expressions are not shell expansions.
missing=$(node -e '
const probe = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
const missing = [];
for (const [name, type] of Object.entries(probe.prototype)) if (type !== "function") missing.push(`InteractiveMode.${name}`);
for (const [name, type] of Object.entries(probe.session)) if (type !== "function") missing.push(`session.${name}`);
if (probe.isIdle !== "boolean") missing.push("session.isIdle");
if (!probe.compactionQueuedMessages) missing.push("InteractiveMode.compactionQueuedMessages");
if (Object.keys(probe.session).length === 0) missing.push("(no session members were probed)");
process.stdout.write(missing.join(", "));
' "$PROBE_OUT") || fail "could not read the Pi $PI_VERSION capability probe"
[ -z "$missing" ] \
  || fail "Pi $PI_VERSION lacks the queue-retention capability Calm needs to hide queued Firstmate rows: $missing"
pass "Pi $PI_VERSION exposes every queue-retention member Calm preflights before hiding queued Firstmate rows"
