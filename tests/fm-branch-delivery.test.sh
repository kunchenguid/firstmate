#!/usr/bin/env bash
# Drives the supervision-branch mod's delivery state machine
# (.claude/mods/fm-branch-mod/lib/fm-branch-delivery.ts, the canonical copy
# the repo's lib/ symlinks to) through injected deps: the spawn-once-then-
# send rule, the pinned-ref retry on a failed send, the unresumable-agent
# rotation, the context-bound rotation handoff, the module-reload adoption,
# and the own-agent bookkeeping. This suite is lib-leg-only by design: the
# machine's binding into the real host drives $.tool.call SendMessage and
# $.agent.spawn surfaces only that host can run, and the engine suite
# (tests/fm-branch-claude-mod-plugin.test.sh, which runs the mod's own
# tests/branch.test.ts) pins that binding end to end - the same
# lib-leg-only shape tests/fm-branch-report-sequence.test.sh uses for the
# provider latch.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-delivery)

cat > "$TMP_ROOT/delivery-run.mjs" <<'DRIVER'
// One delivery machine, one scripted host: every send and spawn is
// answered from a per-step table and captured with its arguments.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const m = await import(pathToFileURL(`${root}/lib/fm-branch-delivery.ts`).href);
const out = [];
const events = [];
const sends = [];
const spawns = [];
let saves = 0;
const table = {
  sendOk: { text: JSON.stringify({ success: true, resumedAgentId: "agent-7", pin: { id: "agent-7", ref: "3a11a1" } }) },
  sendOkNoPin: { text: JSON.stringify({ success: true, resumedAgentId: "agent-8" }) },
  refHint: { text: JSON.stringify({ success: false, message: 'no agent named fm-branch - re-send with its ref: {"to": "fm-branch [5f77ac]"}' }) },
  unresumable: { deny: "SendMessage failed: no transcript found for fm-branch" },
  denied: { deny: "SendMessage failed: rate limited" },

};
let nextSend = "sendOk";
let hintAttempts = 0;
let refTwiceCount = 0;
const deps = {
  log: (kind, data) => events.push({ kind, data }),
  sessionTranscriptId: async () => "sess-1",
  sendMessage: async (to, prompt) => {
    sends.push({ to, prompt });
    if (nextSend === "refHint") {
      // Only the step's first send answers with the hint; the retry after
      // the learned ref succeeds.
      hintAttempts += 1;
      return hintAttempts <= 1 ? table.refHint : table.sendOk;
    }
    if (nextSend === "refHintTwice") {
      // The twice-rotating ref: every send of the step hints a new ref.
      refTwiceCount += 1;
      return { text: JSON.stringify({ success: false, message: `re-send with its ref: {"to": "fm-branch [deadbee${refTwiceCount}]"}` }) };
    }
    return table[nextSend];
  },
  spawnAgent: async (opts) => {
    spawns.push(opts);
    return { agentId: `spawned-${spawns.length}` };
  },
  listAgents: async () => [{ name: "fm-branch", id: "agent-7" }, { name: "fm-branch-2", id: "agent-9" }, { name: "other", id: "agent-x" }],
  readModel: async () => "sonnet",
  saveCounters: async () => {
    saves += 1;
  },
  toolText: (r) => String(r?.text ?? r?.result ?? ""),
  pluginName: "fm-branch-mod",
};
const machine = m.createBranchDelivery();
const deliver = async (name, send = "sendOk") => {
  nextSend = send;
  hintAttempts = 0;
  const before = { sends: sends.length, spawns: spawns.length };
  const r = await machine.deliverToBranch(deps, `PROMPT ${name}`);
  out.push({ name, result: r, sends: sends.slice(before.sends), spawns: spawns.slice(before.spawns) });
};

// First delivery: spawn.
await deliver("first-spawn");
// Second delivery: send to the pinned agent, learning the ref.
await deliver("second-send");
// Third delivery: send again (the learned ref pins the target).
await deliver("third-send", "sendOkNoPin");
// A failed send with a ref hint: retried once with the learned ref.
nextSend = "refHint";
{
  const before = { sends: sends.length, spawns: spawns.length };
  const r = await machine.deliverToBranch(deps, "PROMPT ref-hint");
  out.push({ name: "ref-hint-retry", result: r, sends: sends.slice(before.sends), spawns: spawns.slice(before.spawns) });
}
// The ref changing twice: the send fails outright.
nextSend = "refHintTwice";
refTwiceCount = 0;
{
  const before = { sends: sends.length };
  const r = await machine.deliverToBranch(deps, "PROMPT ref-twice");
  out.push({ name: "ref-changed-twice", result: r, sends: sends.slice(before.sends) });
}
// An unresumable agent: rotate to a fresh generation.
await deliver("unresumable-rotates", "unresumable");
// A plain denial: the delivery fails, no rotation.
await deliver("denied-fails", "denied");
// The module-reload adoption: state resets, the counters restore a spawn
// count, and the named agent still lives (the production reload shape:
// session.start resets, restoreCounters brings the counters back).
machine.resetForSession();
machine.restoreFromCounters({ spawnCount: 2, sendCount: 3, branchGeneration: 1, branchRef: "", branchAgentId: "" });
await deliver("adopt-after-reload", "sendOk");
// A failed adoption falls through to a spawn.
machine.resetForSession();
machine.restoreFromCounters({ spawnCount: 1, sendCount: 1, branchGeneration: 1, branchRef: "", branchAgentId: "" });
await deliver("adopt-fails-spawns", "denied");
// The context-bound rotation handoff.
machine.setRotatePending(true);
await deliver("rotate-on-bound");
// The own-agent bookkeeping, keyed on the currently pinned agent.
{
  const current = machine.currentAgentId();
  out.push({
    name: "bookkeeping",
    knows: [machine.knowsAgent("agent-7"), machine.knowsAgent("stranger")],
    handback: [machine.isOwnHandback("fm-branch-2", "text"), machine.isOwnHandback("stranger", "text"), machine.isOwnHandback("stranger", "fm-branch said hi")],
    notification: [machine.isOwnAgentNotification(`${current} finished`), machine.isOwnAgentNotification("random text"), machine.isOwnAgentNotification(`${current} finished (Stop hook feedback)`)],
    snapshot: machine.snapshot(),
  });
}
machine.adoptAgent("agent-new");
out.push({ name: "adopted", knows: machine.knowsAgent("agent-new"), current: machine.currentAgentId() });
// The counters round-trip.
machine.restoreFromCounters({ spawnCount: 4, sendCount: 9, branchGeneration: 2, branchRef: "ff00", branchAgentId: "agent-9" });
out.push({ name: "restored", snapshot: machine.snapshot(), knows: machine.knowsAgent("agent-9") });
out.push({ name: "saves", count: saves });
out.push({ name: "resolve-named", id: await machine.resolveNamedAgent(deps) });
out.push({ name: "events", kinds: events.map((e) => `${e.kind}:${JSON.stringify(e.data.to ?? e.data.why ?? e.data.agentId ?? "")}`) });
console.log(JSON.stringify(out));
DRIVER

export FM_RS_ROOT="$ROOT"
node --experimental-strip-types "$TMP_ROOT/delivery-run.mjs" > "$TMP_ROOT/lib.json"
if [ ! -s "$TMP_ROOT/lib.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/lib.json" > /dev/null; then
  fail "the delivery driver produced no usable output"
fi

# ---------- assertions -------------------------------------------------------

entry() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP_ROOT/lib.json"; }

if [ "$(entry first-spawn | jq -c '.spawns[0] | {subagentType, model, background, name}')" = '{"subagentType":"fm-branch-mod:fm-branch","model":"sonnet","background":true,"name":"fm-branch"}' ] && [ "$(entry first-spawn | jq -c '.result')" = '{"ok":true,"via":"spawn","detail":"spawned-1"}' ]; then
  pass "the first delivery spawns the named branch agent once"
else
  fail "the first spawn drifted: $(entry first-spawn)"
fi
if [ "$(entry second-send | jq -r '.sends[0].to')" = "fm-branch" ] && [ "$(entry second-send | jq -c '.result.via')" = '"send"' ]; then
  pass "the second delivery sends to the named agent"
else
  fail "the second send drifted"
fi
if [ "$(entry third-send | jq -r '.sends[0].to')" = "fm-branch [3a11a1]" ]; then
  pass "a learned pin ref pins every later send target"
else
  fail "the pinned-ref targeting drifted: $(entry third-send | jq -c '.sends')"
fi
if [ "$(jq -r '.[] | select(.name == "ref-hint-retry") | .sends[0].to' "$TMP_ROOT/lib.json")" = "fm-branch [3a11a1]" ] && [ "$(jq -r '.[] | select(.name == "ref-hint-retry") | .sends[1].to' "$TMP_ROOT/lib.json")" = "fm-branch [5f77ac]" ] && [ "$(jq -r '.[] | select(.name == "ref-hint-retry") | .result.ok' "$TMP_ROOT/lib.json")" = "true" ]; then
  pass "a ref-hint failure learns the new ref and retries the send once"
else
  fail "the ref-hint retry drifted"
fi
if [ "$(entry unresumable-rotates | jq -c '.result.via')" = '"spawn"' ] && [ "$(entry unresumable-rotates | jq -r '.spawns[0].name')" = "fm-branch-2" ]; then
  pass "an unresumable agent rotates to the next generation name"
else
  fail "the unresumable rotation drifted: $(entry unresumable-rotates)"
fi
if [ "$(entry denied-fails | jq -c '.result')" = '{"ok":false,"via":"send","detail":"SendMessage failed: rate limited"}' ] && [ "$(entry denied-fails | jq -c '.spawns | length')" = "0" ]; then
  pass "a plain send denial fails the delivery without rotating"
else
  fail "the plain denial drifted: $(entry denied-fails)"
fi
if [ "$(jq -r '.[] | select(.name == "ref-changed-twice") | .result.detail' "$TMP_ROOT/lib.json")" = "ref changed twice" ]; then
  pass "a ref that changes twice fails the send outright"
else
  fail "the twice-changing ref drifted"
fi
if [ "$(entry adopt-after-reload | jq -c '.result')" = '{"ok":true,"via":"send","detail":"agent-7"}' ] && [ "$(jq -r '.[] | select(.name == "events") | .kinds[] | select(startswith("agent.adopted"))' "$TMP_ROOT/lib.json" | head -1 | grep -c "agent-7")" = "1" ]; then
  pass "after a reload the delivery adopts the live named agent through the send itself"
else
  fail "the reload adoption drifted: $(entry adopt-after-reload)"
fi
if [ "$(entry adopt-fails-spawns | jq -c '.result.via')" = '"spawn"' ]; then
  pass "a failed adoption falls through to a spawn"
else
  fail "the failed adoption drifted"
fi
if [ "$(entry rotate-on-bound | jq -r '.spawns[0].name')" = "fm-branch-2" ] && [ "$(jq -r '.[] | select(.name == "events") | .kinds[] | select(startswith("agent.rotated"))' "$TMP_ROOT/lib.json" | grep -c '"context bound"')" = "1" ]; then
  pass "a pending context bound rotates the next delivery under a fresh name"
else
  fail "the context-bound rotation drifted: $(entry rotate-on-bound)"
fi
if [ "$(jq -c '.[] | select(.name == "bookkeeping") | .knows' "$TMP_ROOT/lib.json")" = '[true,false]' ] \
  && [ "$(jq -c '.[] | select(.name == "bookkeeping") | .handback' "$TMP_ROOT/lib.json")" = '[true,false,true]' ] \
  && [ "$(jq -c '.[] | select(.name == "bookkeeping") | .notification' "$TMP_ROOT/lib.json")" = '[true,false,false]' ]; then
  pass "the own-agent bookkeeping gates ids, handbacks, and notifications"
else
  fail "the own-agent bookkeeping drifted: $(jq -c '.[] | select(.name == "bookkeeping")' "$TMP_ROOT/lib.json")"
fi
if [ "$(jq -r '.[] | select(.name == "adopted") | .current' "$TMP_ROOT/lib.json")" = "agent-new" ] && [ "$(jq -r '.[] | select(.name == "adopted") | .knows' "$TMP_ROOT/lib.json")" = "true" ]; then
  pass "an adopted agent id becomes the pinned branch agent"
else
  fail "the adoption drifted"
fi
if [ "$(jq -c '.[] | select(.name == "restored") | .snapshot' "$TMP_ROOT/lib.json")" = '{"spawnCount":4,"sendCount":9,"branchGeneration":2,"branchRef":"ff00","branchAgentId":"agent-9"}' ] && [ "$(jq -r '.[] | select(.name == "restored") | .knows' "$TMP_ROOT/lib.json")" = "true" ]; then
  pass "the counters round-trip restores the delivery state and the own-agent set"
else
  fail "the counters round-trip drifted"
fi
if [ "$(jq -r '.[] | select(.name == "resolve-named") | .id' "$TMP_ROOT/lib.json")" = "agent-9" ]; then
  pass "the named-agent resolution finds the live branch agent under the current generation name"
else
  fail "the named-agent resolution drifted"
fi
