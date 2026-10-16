#!/usr/bin/env bash
# Default-on live guard for the opt-in restricted Pi supervision extension
# (.pi/extensions/restricted/fm-restricted-supervision.ts) against the installed
# Pi. Its restriction check reads Pi's active tool set, its lock must be anchored
# to the Pi process, and its tools must run inside a real agent turn, so only a
# running Pi can prove them; tests/fm-pi-restricted-supervision.test.sh pins the
# same logic against a fake Pi.
#
# No model turn reaches any provider: a local faux provider scripts one turn in
# which the model calls fm_drain and then acknowledges, against the real
# bin/fm-lock.sh and bin/fm-wake-drain.sh in a scratch FM_HOME. A second launch
# with Pi's default tools proves the extension refuses to take the lock there.
# Scratch FM_HOME, Pi agent directory, and session directory; nothing global is
# touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_RESTRICTED_SUPERVISION_LIVE pi node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-pi-restricted-live)
EXT="$ROOT/.pi/extensions/restricted/fm-restricted-supervision.ts"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

cat > "$TMP_ROOT/probe.ts" <<'TS'
import { appendFileSync, readFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const out = process.env.PROBE_OUT as string;
const record = (line: string): void => appendFileSync(out, `${line}\n`);

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "restricted-probe-api",
    provider: "restricted-probe",
    models: [{
      id: "deterministic",
      name: "Restricted supervision probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("restricted-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.on("session_start", async (_event, ctx) => {
    let lock = "";
    try {
      lock = readFileSync(`${process.env.FM_HOME}/state/.lock`, "utf8").split("\n")[0];
    } catch {
    }
    record(`active=${JSON.stringify(pi.getActiveTools())}`);
    record(`lock-anchor=${lock === String(process.pid) ? "pi" : lock ? "other" : "none"}`);
    const model = ctx.modelRegistry.find("restricted-probe", "deterministic");
    if (!model || !(await pi.setModel(model))) throw new Error("probe model unavailable");
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("fm_drain", {}, { id: "present" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("fm_drain", { acknowledge: true }, { id: "ack" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxText("handled")]),
    ]);
  });
  pi.on("tool_result", async (event) => {
    const text = event.content.map((item) => (item.type === "text" ? item.text : "")).join("\n");
    record(`tool ${event.toolCallId} ${JSON.stringify(text)}`);
  });
  pi.on("agent_end", async () => record("agent_end"));
}
TS

# launch_pi <home> <probe-out> <stdout> <builtin-tools on|off>
launch_pi() {
  local home=$1 out=$2 stdout=$3 builtins=$4 flags=(--no-extensions)
  [ "$builtins" = off ] && flags=(--no-builtin-tools --no-extensions)
  mkdir -p "$home/state" "$home/agent" "$home/sessions"
  (
    cd "$home" || exit 1
    {
      i=0
      until [ -s "$out" ] || [ "$i" -ge 200 ]; do
        i=$((i + 1))
        sleep 0.05
      done
      printf '%s\n' '{"id":"probe","type":"prompt","message":"handle the queued wake"}'
      i=0
      until grep -q '^agent_end$' "$out" 2>/dev/null || [ "$i" -ge 300 ]; do
        i=$((i + 1))
        sleep 0.05
      done
    } | env FM_HOME="$home" PI_CODING_AGENT_DIR="$home/agent" PI_OFFLINE=1 \
      FM_PI_RESTRICTED_SUPERVISION=1 PROBE_OUT="$out" \
      pi --mode rpc "${flags[@]}" --no-context-files --no-skills --no-prompt-templates \
        --session-dir "$home/sessions" -e "$EXT" -e "$TMP_ROOT/probe.ts" > "$stdout" 2>&1
  )
}

test_restricted_pi_drains_and_acknowledges_through_real_scripts() {
  local home="$TMP_ROOT/restricted" out="$TMP_ROOT/restricted.probe" probe queue
  mkdir -p "$home/state"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check live-probe "restricted live probe wake"' \
    _ "$ROOT/bin/fm-wake-lib.sh" || fail "could not seed the wake queue"
  launch_pi "$home" "$out" "$TMP_ROOT/restricted.stdout" off
  probe=$(cat "$out" 2>/dev/null)
  assert_contains "$probe" 'active=["fm_drain","fm_deliver"]' \
    "Pi $PI_VERSION with --no-builtin-tools --no-extensions must expose only the restricted tools"
  assert_contains "$probe" "lock-anchor=pi" "Pi $PI_VERSION: the session lock must name the Pi process itself"
  assert_contains "$probe" 'restricted live probe wake' "Pi $PI_VERSION: fm_drain must present the queued wake"
  assert_contains "$probe" 'tool ack "fm_drain: acknowledged the presented wakes through 1"' \
    "Pi $PI_VERSION: fm_drain with acknowledge must run the printed acknowledgement"
  assert_contains "$probe" 'agent_end' "Pi $PI_VERSION: the scripted turn must finish"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null)
  assert_equals "" "$queue" "Pi $PI_VERSION: the acknowledged wake must leave the durable queue"
  pass "Pi $PI_VERSION: a restricted session holds the lock and drains then acknowledges through the real scripts"
}

test_default_pi_tools_are_refused() {
  local home="$TMP_ROOT/default-tools" out="$TMP_ROOT/default-tools.probe" probe
  launch_pi "$home" "$out" "$TMP_ROOT/default-tools.stdout" on
  probe=$(cat "$out" 2>/dev/null)
  assert_contains "$probe" '"bash"' "Pi $PI_VERSION without --no-builtin-tools must expose bash"
  assert_contains "$probe" "lock-anchor=none" "Pi $PI_VERSION: no lock is taken beside a general shell tool"
  assert_contains "$(cat "$TMP_ROOT/default-tools.stdout")" "restricted supervision refused" \
    "Pi $PI_VERSION: the refusal must reach the captain's screen"
  assert_contains "$probe" 'restricted supervision refused' "Pi $PI_VERSION: fm_drain must refuse in that session"
  pass "Pi $PI_VERSION: a session with Pi's default tools takes no lock and drains nothing"
}

test_restricted_pi_drains_and_acknowledges_through_real_scripts
test_default_pi_tools_are_refused
