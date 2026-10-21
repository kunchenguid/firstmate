#!/usr/bin/env bash
# Behavioral coverage for the periodic-stow durable lifecycle: default read-only
# status, main-session ownership, CAS, stable run delivery, verified steps,
# partial recovery, disable semantics, and fail-closed identity checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-stow-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-periodic-stow)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data/stow-runs" "$home/data"
  printf '%s\n' "$home"
}

run_main() { # <home> <args...>
  local home=$1
  shift
  # shellcheck disable=SC2016 # The child shell expands its embedded script.
  env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    bash -c 'exec -a pi node -e '\''
      const fs = require("node:fs");
      const { spawnSync } = require("node:child_process");
      fs.writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
      const result = spawnSync(process.argv[1], process.argv.slice(2), { stdio: "inherit", env: process.env });
      process.exit(result.status ?? 99);
    '\'' "$@"' launcher "$RUN" "$@"
}

seed_session() { # <home> <name>
  local file="$1/$2.jsonl"
  printf '%s\n' '{"type":"session","version":3,"id":"session-1","timestamp":"2026-09-24T00:00:00Z","cwd":"/tmp"}' >"$file"
  printf '%s\n' "$file"
}

request_run() { # <home> <session-file> <reason>
  run_main "$1" request --reason "$3" --session-id session-1 --session-file "$2" \
    --target-entry-id entry-1 \
    --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}

test_status_is_read_only_and_default_idle() {
  local home out
  home=$(new_home status)
  out=$(FM_HOME="$home" "$RUN" status) || fail "status refused an empty home"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = idle ] || fail "empty status was not idle"
  [ ! -e "$home/state/stow" ] || fail "read-only status created coordinator state"
  pass "status is read-only and an absent state is idle"
}

test_request_delivery_begin_and_verified_finish() {
  local home session out run rev plan before target receipt memory_before memory_after
  home=$(new_home success)
  session=$(seed_session "$home" session)
  printf '%s\n' 'stable memory' >"$home/data/captain.md"
  memory_before=$(sha256sum "$home/data/captain.md" | awk '{print $1}')
  out=$(request_run "$home" "$session" periodic) || fail "request failed: $out"
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision "$rev") \
    || fail "delivery failed: $out"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-1 \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev") \
    || fail "begin failed: $out"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  mkdir -p "$home/data/stow-runs/$run"
  plan="data/stow-runs/$run/plan.json"
  printf '%s\n' '{"version":1}' >"$home/$plan"
  before=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  target=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  out=$(run_main "$home" step --run-id "$run" --generation generation-1 --operation-id memory-1 \
    --phase prepared --plan-ref "$plan" --before-sha256 "$before" --target-sha256 "$target" \
    --expected-revision "$rev") || fail "prepare failed: $out"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  set +e
  out=$(run_main "$home" step --run-id "$run" --generation generation-1 --operation-id memory-1 \
    --phase verified --plan-ref "$plan" --before-sha256 "$before" --target-sha256 "$target" \
    --actual-sha256 dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
    --expected-revision "$rev")
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "a mismatched readback was accepted: $out"
  out=$(run_main "$home" step --run-id "$run" --generation generation-1 --operation-id memory-1 \
    --phase verified --plan-ref "$plan" --before-sha256 "$before" --target-sha256 "$target" \
    --actual-sha256 "$target" --expected-revision "$rev") || fail "verification failed: $out"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  receipt="data/stow-runs/$run/receipt.json"
  jq -cn --arg run "$run" '{version:1,run_id:$run,generation:"generation-1",outcome:"succeeded",
    budget:{ok:true},local_steps:[{operation_id:"memory-1",verified:true}],cascade:[],
    preflight:{complete:true,homes:[]}}' >"$home/$receipt"
  out=$(run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" \
    --interval-seconds 86400 --expected-revision "$rev") || fail "finish failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = succeeded ] || fail "success outcome missing"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active')" = null ] || fail "successful run stayed active"
  memory_after=$(sha256sum "$home/data/captain.md" | awk '{print $1}')
  [ "$memory_before" = "$memory_after" ] || fail "coordinator itself edited memory"
  pass "request, delivery, begin, verified readback, and finish form one durable run"
}

test_cas_generation_and_role_refuse_stale_callers() {
  local home session out run rev rc
  home=$(new_home identity)
  session=$(seed_session "$home" session)
  out=$(request_run "$home" "$session" manual)
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  set +e
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision 0)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "stale revision was accepted: $out"
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  set +e
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-1 \
    --target-entry-id entry-1 --branch-fingerprint bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --expected-revision "$rev")
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a different ordered ancestry fingerprint began the run: $out"
  set +e
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-2 \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev")
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an unoffered generation began the run: $out"
  set +e
  out=$(env FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$RUN" disable)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a supervision branch changed run state: $out"
  pass "CAS, offered generation, branch role, and session lock fail closed"
}

test_partial_recovery_keeps_original_plan_and_hashes() {
  local home session out run rev plan before target
  home=$(new_home recovery)
  session=$(seed_session "$home" session)
  out=$(request_run "$home" "$session" periodic)
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation old-generation --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation old-generation \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  mkdir -p "$home/data/stow-runs/$run"
  plan="data/stow-runs/$run/plan.json"
  printf '%s\n' '{"version":1,"operation":"archive-once"}' >"$home/$plan"
  before=1111111111111111111111111111111111111111111111111111111111111111
  target=2222222222222222222222222222222222222222222222222222222222222222
  out=$(run_main "$home" step --run-id "$run" --generation old-generation --operation-id archive-1 \
    --phase prepared --plan-ref "$plan" --before-sha256 "$before" --target-sha256 "$target" \
    --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" defer --run-id "$run" --generation old-generation --reason user-input \
    --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation new-generation --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" recover --run-id "$run" --session-id session-1 --generation new-generation \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --expected-revision "$rev") || fail "recover failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.phase')" = partial ] || fail "prepared step was not recovered as partial"
  [ "$(printf '%s' "$out" | jq -r '.steps[0].target_sha256')" = "$target" ] || fail "recovery changed original target"
  [ "$(printf '%s' "$out" | jq -r '.steps|length')" -eq 1 ] || fail "recovery duplicated the operation"
  pass "partial recovery reuses the original operation and digests"
}

test_later_cutoff_is_promoted_after_completed_run() {
  local home session out run rev receipt promoted
  home=$(new_home pending)
  session=$(seed_session "$home" session)
  out=$(request_run "$home" "$session" manual)
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-1 \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" request --reason manual --session-id session-1 --session-file "$session" \
    --target-entry-id entry-2 \
    --branch-fingerprint bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
  rev=$(printf '%s' "$out" | jq -r '.revision')
  receipt="data/stow-runs/$run/receipt.json"
  mkdir -p "$home/data/stow-runs/$run"
  jq -cn --arg run "$run" '{version:1,run_id:$run,generation:"generation-1",outcome:"succeeded",
    budget:{ok:true},local_steps:[],cascade:[]}' >"$home/$receipt"
  out=$(run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" \
    --interval-seconds 86400 --expected-revision "$rev") || fail "finish with pending cutoff failed: $out"
  promoted=$(printf '%s' "$out" | jq -r '.active.run_id')
  [ "$promoted" != null ] && [ "$promoted" != "$run" ] || fail "later cutoff was not promoted to a new run"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active.cutoff_entry_id')" = entry-2 ] \
    || fail "promoted run lost its later cutoff"
  pass "material arriving beyond the fixed cutoff is promoted without widening or replaying the completed run"
}

test_disable_withdraws_only_unconsumed_periodic_work() {
  local home session out run rev
  home=$(new_home disable-periodic)
  session=$(seed_session "$home" session)
  request_run "$home" "$session" periodic >/dev/null
  out=$(run_main "$home" disable) || fail "disable failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = disabled ] || fail "periodic-only request was not withdrawn"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active')" = null ] || fail "withdrawn periodic request remains"

  home=$(new_home disable-manual)
  session=$(seed_session "$home" session)
  out=$(request_run "$home" "$session" manual)
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" disable) || fail "manual disable check failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = preserved ] || fail "manual work was withdrawn"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active.run_id')" = "$run" ] || fail "manual recovery evidence disappeared"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.revision')" = "$rev" ] || fail "preserving disable rewrote state"
  pass "disable withdraws periodic-only requests and preserves manual evidence"
}

test_receipts_and_corrupt_state_fail_closed() {
  local home session out run rev receipt rc before
  home=$(new_home receipts)
  session=$(seed_session "$home" session)
  printf '%s\n' 'unchanged memory' >"$home/data/learnings.md"
  before=$(sha256sum "$home/data/learnings.md" | awk '{print $1}')
  out=$(request_run "$home" "$session" periodic)
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-1 \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev")
  rev=$(printf '%s' "$out" | jq -r '.revision')
  mkdir -p "$home/data/stow-runs/$run"
  receipt="data/stow-runs/$run/receipt.json"
  jq -cn --arg run "$run" '{version:1,run_id:$run,generation:"generation-1",outcome:"succeeded",
    budget:{ok:false},local_steps:[],cascade:[],preflight:{complete:true,homes:[]}}' >"$home/$receipt"
  set +e
  out=$(run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" \
    --interval-seconds 86400 --expected-revision "$rev")
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "over-budget success was accepted: $out"
  jq -cn --arg run "$run" '{version:1,run_id:$run,generation:"generation-1",outcome:"skipped",
    noop:{uncovered_material:false,due_maintenance:false,external_memory_change:false,
      budget_change:false,anomaly:false,unfinished_cascade:false},preflight:{complete:true,homes:[]}}' >"$home/$receipt"
  out=$(run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" \
    --interval-seconds 86400 --expected-revision "$rev") || fail "proved no-op was refused: $out"
  [ "$(sha256sum "$home/data/learnings.md" | awk '{print $1}')" = "$before" ] \
    || fail "no-op changed memory bytes"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.last_success_at')" = null ] \
    || fail "no-op advanced the successful full-pass clock"
  printf '%s\n' '{"version":1,"home":"wrong","revision":0,"pending":null,"active":null,"last_result":null}' \
    >"$home/state/stow/state.json"
  set +e
  out=$(FM_HOME="$home" "$RUN" status)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "corrupt/wrong-home state was accepted: $out"
  pass "budget, proven no-op, unchanged memory, full-pass clock, and corrupt-state guards are observable"
}

test_pi_coordinator_waits_for_safe_settle_and_bounds_redelivery() {
  local home session out
  home=$(new_home extension)
  session=$(seed_session "$home" session)
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=5 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { existsSync, utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const commands = new Map();
const messages = [];
const notices = [];
const pi = {
  on(name, handler) {
    const list = handlers.get(name) || [];
    list.push(handler);
    handlers.set(name, list);
  },
  events: { on() {}, emit() {} },
  registerCommand(name, options) { commands.set(name, options.handler); },
  sendMessage(message, options) { messages.push({ message, options }); },
};
let pending = false;
let editor = "";
let idle = false;
const branch = [{ id: "root-1" }, { id: "entry-1" }];
const ctx = {
  mode: "tui",
  hasUI: true,
  isIdle: () => idle,
  hasPendingMessages: () => pending,
  ui: {
    getEditorText: () => editor,
    notify(message, kind) { notices.push({ message, kind }); },
  },
  sessionManager: {
    getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE,
    getLeafId: () => "entry-1",
    getBranch: () => branch,
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const emit = async (name, event = { type: name }) => {
  for (const handler of handlers.get(name) || []) await handler(event, ctx);
};

await emit("session_start", { type: "session_start", reason: "startup" });
if (messages.length !== 0 || existsSync(`${process.env.FM_HOME}/state/stow/state.json`)) {
  throw new Error("absent default-off configuration registered work");
}

writeFileSync(`${process.env.FM_HOME}/config/periodic-stow.json`,
  JSON.stringify({ version: 1, enabled: true, interval_seconds: 60, min_interval_seconds: 60 }));
await emit("session_start", { type: "session_start", reason: "startup" });
if (messages.length !== 0 || existsSync(`${process.env.FM_HOME}/state/stow/state.json`)) {
  throw new Error("invalid configuration registered work");
}
if (!notices.some((notice) => notice.kind === "error")) throw new Error("invalid configuration was silent");
writeFileSync(`${process.env.FM_HOME}/config/periodic-stow.json`,
  JSON.stringify({ version: 1, enabled: true, interval_seconds: 3600, min_interval_seconds: 3600 }));
const old = new Date(Date.now() - 7200000);
utimesSync(`${process.env.FM_HOME}/config/periodic-stow.json`, old, old);
await emit("tool_execution_start");
idle = true;
if (messages.length !== 0) throw new Error("active tool was interrupted");
await emit("agent_settled");
if (messages.length !== 0) throw new Error("settled event ignored active tool");
await emit("tool_execution_end");
pending = true;
await emit("agent_settled");
if (messages.length !== 0) throw new Error("pending input was interrupted");
pending = false;
editor = "draft";
await emit("agent_settled");
if (messages.length !== 0) throw new Error("editor input was interrupted");
editor = "";
await emit("agent_settled");
await new Promise((resolve) => setTimeout(resolve, 6));
await emit("agent_settled");
await new Promise((resolve) => setTimeout(resolve, 6));
await emit("agent_settled");
await new Promise((resolve) => setTimeout(resolve, 6));
await emit("agent_settled");
const requests = messages.filter((item) => item.message.customType === "fm-heartbeat-request");
if (requests.some((item) => item.message.display !== false)) throw new Error("automatic maintenance did not use silent heartbeat delivery");
if (requests.length !== 3) throw new Error(`expected three bounded offers, got ${requests.length}`);
if (requests.some((item) => !item.message.content.includes(".agents/stow.md"))) {
  throw new Error("heartbeat offer does not point at the relocated internal stow contract");
}
const ids = new Set(requests.map((item) => item.message.details.run_id));
if (ids.size !== 1) throw new Error("redelivery changed run_id");
if (messages.some((item) => item.options.deliverAs !== "followUp" || item.options.triggerTurn !== true)) {
  throw new Error("delivery did not preserve follow-up semantics");
}
await new Promise((resolve) => setTimeout(resolve, 6));
await emit("agent_settled");
const escalations = messages.filter((item) => item.message.customType === "fm-heartbeat-escalation");
if (escalations.length !== 1 || !escalations[0].message.display) throw new Error("exhausted heartbeat did not start one executable main handoff");
await new Promise((resolve) => setTimeout(resolve, 6));
await emit("agent_settled");
if (messages.filter((item) => item.message.customType === "fm-heartbeat-escalation").length !== 1) throw new Error("exhausted heartbeat duplicated its reserved handoff");
if (commands.has("stow")) throw new Error("manual stow command remains user-invocable");
await emit("session_before_compact", { type: "session_before_compact" });
const status = JSON.parse((await import("node:fs")).readFileSync(`${process.env.FM_HOME}/state/stow/state.json`, "utf8"));
if (status.active.reasons.includes("manual") || !status.active.reasons.includes("precompact")) {
  throw new Error("precompact internal retention was not preserved without a manual command");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ messages: requests.length, escalations: escalations.length, notices: notices.length, attempts: status.active.attempts }));
EOF
  ) || fail "Pi coordinator lifecycle failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.messages')" -eq 3 ] || fail "bounded redelivery evidence missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.attempts')" -eq 3 ] || fail "durable attempt count missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.escalations')" -eq 1 ] || fail "executable heartbeat handoff missing: $out"
  pass "Pi coordinator bounds heartbeat delivery and hands exhaustion to one executable main turn"
}
test_idle_reminder_uses_successful_settlement_cadence() {
  local home session out body
  home=$(new_home idle-reminder)
  session=$(seed_session "$home" session)
  mkdir -p "$home/projects/example"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add unfinished-work 'Finish the open outcome' --kind ship >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add choose-path 'Choose the rollout path' --kind ship >/dev/null
  body="$home/decision-body"
  printf '%s\n' 'Choose option A for the smaller reversible rollout or option B for the broader immediate rollout.' >"$body"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" update choose-path --body-file "$body" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" hold choose-path --kind captain \
    --reason 'Choose option A: smaller reversible rollout, or option B: broader immediate rollout.' >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add done-work 'Already done' --kind ship --start >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" 'done' done-work --note 'landed' >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add archived-work 'Already archived' --kind scout --start >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" archive archived-work --report data/archived-work/report.md >/dev/null
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=1000000 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { spawnSync } from "node:child_process";
import { unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let now = 2_000_000_000_000;
Date.now = () => now;
const configTime = new Date(now - 7_199_000);
writeFileSync(`${process.env.FM_HOME}/config/idle-reminder.json`,
  JSON.stringify({ version: 1, enabled: true, interval_seconds: 7200 }));
utimesSync(`${process.env.FM_HOME}/config/idle-reminder.json`, configTime, configTime);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);

const branch = [{ type: "session", id: "root-1", timestamp: new Date(now - 5000).toISOString() },
  { type: "message", id: "entry-1", timestamp: new Date(now - 4000).toISOString(),
    message: { role: "assistant", content: [{ type: "text", text: "ready" }], stopReason: "stop", timestamp: now - 4000 } }];
let nextEntry = 2;
let pending = false;
let editor = "";
let idle = false;
let snapshotFails = false;
let decisionSummaryMode = null;

function runtime() {
  const handlers = new Map();
  const messages = [];
  const entries = [];
  const emitted = [];
  const pi = {
    on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
    events: { on() {}, emit(name) { emitted.push(name); } },
    registerCommand() {},
    appendEntry(customType, data) {
      const entry = { type: "custom", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(), customType, data };
      branch.push(entry); entries.push(entry);
    },
    sendMessage(message, options) {
      messages.push({ message, options });
      branch.push({ type: "custom_message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
        customType: message.customType, content: message.content, display: message.display, details: message.details });
    },
    async exec(command, args, options) {
      if (snapshotFails && args.includes("--all-in-flight")) {
        return { stdout: "", stderr: "snapshot unavailable", code: 1, killed: false };
      }
      const result = spawnSync(command, args, { encoding: "utf8", cwd: options?.cwd, timeout: options?.timeout, env: process.env });
      let stdout = result.stdout || "";
      if (result.status === 0 && decisionSummaryMode && args.includes("--all-decisions")) {
        const value = JSON.parse(stdout);
        if (value.decisions_open[0]) {
          const material = value.decisions_open[0].summary.replace(/:\s+held \d+d:\s+/u, ": ");
          value.decisions_open[0].summary = decisionSummaryMode === "clock"
            ? material.replace(/:\s+/u, ": held 9d: ")
            : material.replace(/:\s+.*$/u, ": held 9d: provide a new deployment credential");
        }
        stdout = JSON.stringify(value);
      }
      return { stdout, stderr: result.stderr || "", code: result.status ?? 99, killed: false };
    },
  };
  const ctx = {
    mode: "tui", hasUI: true, isIdle: () => idle, hasPendingMessages: () => pending,
    ui: { getEditorText: () => editor, notify() {} },
    sessionManager: {
      getSessionId: () => "session-1", getSessionFile: () => process.env.SESSION_FILE,
      getLeafId: () => branch.at(-1)?.id, getBranch: () => branch,
    },
  };
  const emit = async (name, event = { type: name }) => {
    for (const handler of handlers.get(name) || []) await handler(event, ctx);
  };
  return { pi, ctx, emit, messages, entries, emitted };
}

async function settleAsync() {
  await new Promise((resolve) => setTimeout(resolve, 25));
}

async function finishReminder(rt, sent) {
  await rt.emit("before_agent_start", { type: "before_agent_start", messageType: "custom", message: sent.message,
    systemPrompt: "", systemPromptOptions: {} });
  const assistant = { role: "assistant", content: [{ type: "text", text: "captain，提醒内容" }],
    stopReason: "stop", timestamp: now };
  branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(), message: assistant });
  await rt.emit("message_end", { type: "message_end", message: assistant });
  await rt.emit("agent_settled", { type: "agent_settled", aborted: false });
  await settleAsync();
}

const first = runtime();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(first.pi);
await first.emit("session_start", { type: "session_start", reason: "startup" });
await settleAsync();
if (first.messages.length !== 0) throw new Error("reminder fired before 7200 seconds");

now += 1000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("busy main session was interrupted");
idle = true;
process.env.FM_TASK_ID = "worker";
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("worker identity emitted a main-session reminder");
delete process.env.FM_TASK_ID;
unlinkSync(`${process.env.FM_HOME}/state/.lock`);
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("session without the fleet lock emitted a reminder");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await first.emit("tool_execution_start", { type: "tool_execution_start" });
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("active tool was interrupted");
await first.emit("tool_execution_end", { type: "tool_execution_end" });
pending = true;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("pending input was interrupted");
pending = false; editor = "draft";
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("editor input was interrupted");
editor = "";
snapshotFails = true;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("failed inventory collection emitted a reminder");
if (!first.emitted.includes("firstmate:heartbeat-tick")) throw new Error("failed reminder collection starved existing scheduling");
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 0) throw new Error("failed inventory collection retried on the same clock boundary");
snapshotFails = false;
now += 60_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 1) throw new Error(`expected one due reminder, got ${first.messages.length}`);
const request = first.messages[0];
if (request.message.customType !== "fm-idle-reminder-request" || request.message.display !== false ||
    request.options.triggerTurn !== true || request.options.deliverAs !== "followUp") throw new Error("wrong reminder delivery surface");
if (!request.message.content.includes("unfinished-work") || !request.message.content.includes("choose-path")) {
  throw new Error("canonical unfinished work or decision was missing");
}
if (request.message.content.includes("done-work") || request.message.content.includes("archived-work")) {
  throw new Error("terminal task leaked into reminder inventory");
}
if (!request.message.content.includes("Simplified Chinese") || !request.message.content.includes("captain")) {
  throw new Error("runtime prompt lost language or address contract");
}
await finishReminder(first, request);
if (!first.entries.some((entry) => entry.customType === "fm-idle-reminder-delivered")) {
  throw new Error("successful assistant settlement did not create delivery evidence");
}

now += 7_199_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 1) throw new Error("successful delivery did not anchor the next interval");
decisionSummaryMode = "clock";
now += 1000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 1) throw new Error("unchanged inventory or a clock-only decision label repeated the handled reminder");
if (!first.entries.some((entry) => entry.customType === "fm-idle-reminder-unchanged")) {
  throw new Error("unchanged inventory did not persist its checked cadence");
}

branch.push({ type: "custom_message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-branch-merge", content: "unchanged fleet note", display: false });
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "user", content: [{ type: "text", text: "\u2063FIRSTMATE_OP: v1 watcher: internal poll" }], timestamp: now } });
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "assistant", content: [{ type: "text", text: "internal handling" }], stopReason: "stop", timestamp: now } });
now += 7_200_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 1) throw new Error("silent fleet note, operational input, or its assistant reply re-armed the reminder");

decisionSummaryMode = "material";
now += 7_200_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 2) throw new Error("materially changed decision request did not re-arm the reminder");
await finishReminder(first, first.messages[1]);

branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "user", content: [{ type: "text", text: "What changed?" }], timestamp: now } });
now += 7_200_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 3) throw new Error("genuine user conversation did not re-arm the reminder");
await finishReminder(first, first.messages[2]);

branch.push({ type: "custom", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-branch-visible-outcome", data: { version: 1, seq: 7, task: "result-task", verdict: "captain",
    taskGeneration: "generation-1", evidenceKey: "result-1" } });
branch.push({ type: "custom_message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-branch-merge", content: "visible routine result", display: true });
now += 7_200_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 4) throw new Error("new structural supervision outcome did not re-arm the reminder");
await finishReminder(first, first.messages[3]);

branch.push({ type: "custom", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-branch-visible-outcome", data: { version: 1, seq: 8, task: "result-task", verdict: "captain",
    taskGeneration: "generation-1", evidenceKey: "result-1" } });
branch.push({ type: "custom_message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-branch-merge", content: "visible routine result", display: true });
now += 7_200_000;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 4) throw new Error("replayed outcome identity or routine note re-armed the reminder");

idle = false;
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "user", content: [{ type: "text", text: "Continue after idle." }], timestamp: now } });
now += 21_600_000;
for (let i = 0; i < 4; i++) {
  await first.emit("agent_settled", { type: "agent_settled", aborted: false });
  await settleAsync();
}
if (first.messages.length !== 4) throw new Error("prolonged busy interval emitted a reminder");
idle = true;
await first.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (first.messages.length !== 5) throw new Error("idle recovery did not collapse missed intervals to one reminder");
await finishReminder(first, first.messages[4]);
await first.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });

const reloaded = runtime();
const reloadMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?reload=1`);
reloadMod.default(reloaded.pi);
now += 7_200_000;
await reloaded.emit("session_start", { type: "session_start", reason: "reload" });
await settleAsync();
if (reloaded.messages.length !== 0) throw new Error("extension reload duplicated a due but unchanged handled reminder");
now += 7_200_000;
branch.push({ type: "custom_message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  customType: "fm-idle-reminder-request", content: "orphaned request", display: false,
  details: { version: 1, reminder_id: "orphaned-after-restart" } });
await reloaded.emit("session_shutdown", { type: "session_shutdown", reason: "cold-restart" });

const restarted = runtime();
const restartMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?reload=2`);
restartMod.default(restarted.pi);
await restarted.emit("session_start", { type: "session_start", reason: "startup" });
await settleAsync();
if (restarted.messages.length !== 0) throw new Error("cold restart duplicated an orphaned reminder request");
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "user", content: [{ type: "text", text: "ordinary user turn" }], timestamp: now } });
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(),
  message: { role: "assistant", content: [{ type: "text", text: "ordinary answer" }], stopReason: "stop", timestamp: now } });
await restarted.emit("session_shutdown", { type: "session_shutdown", reason: "ordinary-reload" });

const ordinaryReload = runtime();
const ordinaryMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?reload=3`);
ordinaryMod.default(ordinaryReload.pi);
await ordinaryReload.emit("session_start", { type: "session_start", reason: "reload" });
await settleAsync();
if (ordinaryReload.messages.length !== 0 || branch.some((entry) => entry.customType === "fm-idle-reminder-delivered" &&
    entry.data?.reminder_id === "orphaned-after-restart")) {
  throw new Error("ordinary reply after orphan retirement was credited as reminder delivery");
}
now += 60_000;
await ordinaryReload.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (ordinaryReload.messages.length !== 1) throw new Error("cold restart did not release the orphaned reminder after a paced boundary");
const failed = ordinaryReload.messages[0];
await ordinaryReload.emit("before_agent_start", { type: "before_agent_start", messageType: "custom", message: failed.message,
  systemPrompt: "", systemPromptOptions: {} });
const toolPreamble = { role: "assistant", content: [{ type: "text", text: "reading details" }],
  stopReason: "toolUse", timestamp: now };
branch.push({ type: "message", id: `entry-${nextEntry++}`, timestamp: new Date(now).toISOString(), message: toolPreamble });
await ordinaryReload.emit("message_end", { type: "message_end", message: toolPreamble });
await ordinaryReload.emit("agent_settled", { type: "agent_settled", aborted: true });
await settleAsync();
if (ordinaryReload.messages.length !== 1) throw new Error("aborted reminder retried from its own settlement");
await ordinaryReload.emit("session_shutdown", { type: "session_shutdown", reason: "failed-restart" });

const failedReload = runtime();
const failedMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?reload=4`);
failedMod.default(failedReload.pi);
await failedReload.emit("session_start", { type: "session_start", reason: "startup" });
await settleAsync();
if (failedReload.messages.length !== 0) throw new Error("tool preamble or failed receipt was reconstructed as successful delivery");
now += 60_000;
await failedReload.emit("agent_settled", { type: "agent_settled", aborted: false });
await settleAsync();
if (failedReload.messages.length !== 1) throw new Error("failed reminder did not retry at a paced later boundary");
await finishReminder(failedReload, failedReload.messages[0]);
await failedReload.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ reminders: first.messages.length, receipts: first.entries.filter((e) => e.customType === "fm-idle-reminder-delivered").length }));
EOF
  ) || fail "idle reminder lifecycle failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.reminders')" -eq 5 ] || fail "idle reminder count evidence missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.receipts')" -eq 5 ] || fail "idle reminder receipt evidence missing: $out"
  pass "two-hour idle reminders deduplicate unchanged evidence, then re-arm on material decisions, conversation, or outcomes"
}

test_idle_reminder_restores_legacy_receipt_fingerprint() {
  local home session out
  home=$(new_home idle-reminder-legacy-receipt)
  session=$(seed_session "$home" session)
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=1000000 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let now = 2_000_000_000_000;
Date.now = () => now;
const snapshot = { schema: "fm-bearings.v1", generated: "legacy",
  in_flight: [{ id: "same-task", kind: "ship", state: "working", repo: "example" }],
  gates: [], decisions_open: [] };
writeFileSync(`${process.env.FM_HOME}/config/idle-reminder.json`,
  JSON.stringify({ version: 1, enabled: true, interval_seconds: 7200 }));
const old = new Date(now - 14_400_000);
utimesSync(`${process.env.FM_HOME}/config/idle-reminder.json`, old, old);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const branch = [
  { type: "session", id: "root-1", timestamp: old.toISOString() },
  { type: "custom_message", id: "entry-1", timestamp: old.toISOString(),
    customType: "fm-idle-reminder-request", display: false,
    content: `\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE IDLE REMINDER\nCanonical snapshot:\n${JSON.stringify(snapshot)}`,
    details: { version: 1, reminder_id: "legacy-reminder" } },
  { type: "custom", id: "entry-2", timestamp: old.toISOString(), customType: "fm-idle-reminder-delivered",
    data: { version: 1, reminder_id: "legacy-reminder", handled_at: old.toISOString() } },
];
const handlers = new Map();
const messages = [];
const entries = [];
const pi = {
  on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
  events: { on() {}, emit() {} }, registerCommand() {},
  sendMessage(message) { messages.push(message); },
  appendEntry(customType, data) {
    const entry = { type: "custom", id: `entry-${branch.length + 1}`, timestamp: new Date(now).toISOString(), customType, data };
    branch.push(entry); entries.push(entry);
  },
  async exec() { return { stdout: JSON.stringify(snapshot), stderr: "", code: 0, killed: false }; },
};
const ctx = { mode: "tui", hasUI: true, isIdle: () => true, hasPendingMessages: () => false,
  ui: { getEditorText: () => "", notify() {} }, sessionManager: { getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE, getLeafId: () => branch.at(-1)?.id, getBranch: () => branch } };
const emit = async (name, event = { type: name }) => {
  for (const handler of handlers.get(name) || []) await handler(event, ctx);
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await emit("session_start", { type: "session_start", reason: "startup" });
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 0) throw new Error("legacy successful receipt repeated its unchanged reminder after restart");
if (entries.filter((entry) => entry.customType === "fm-idle-reminder-unchanged").length !== 1) {
  throw new Error("legacy successful receipt did not restore its request snapshot baseline");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ unchanged: 1 }));
EOF
  ) || fail "legacy reminder receipt recovery failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.unchanged')" -eq 1 ] || fail "legacy receipt recovery evidence missing: $out"
  pass "legacy reminder receipts recover their request snapshot fingerprint across restart"
}

test_idle_reminder_stays_silent_for_empty_inventory() {
  local home session out
  home=$(new_home idle-reminder-empty)
  session=$(seed_session "$home" session)
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=1000000 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { spawnSync } from "node:child_process";
import { utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let now = 2_000_000_000_000;
Date.now = () => now;
writeFileSync(`${process.env.FM_HOME}/config/idle-reminder.json`, JSON.stringify({ version: 1, enabled: true, interval_seconds: 1800 }));
const old = new Date(now - 3_600_000);
utimesSync(`${process.env.FM_HOME}/config/idle-reminder.json`, old, old);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const branch = [{ id: "entry-1" }];
const handlers = new Map();
const messages = [];
const entries = [];
const pi = {
  on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
  events: { on() {}, emit() {} }, registerCommand() {}, sendMessage(message) { messages.push(message); },
  appendEntry(customType, data) { entries.push({ customType, data }); branch.push({ type: "custom", customType, data, timestamp: new Date(now).toISOString() }); },
  async exec(command, args, options) { const result = spawnSync(command, args, { encoding: "utf8", cwd: options?.cwd, timeout: options?.timeout, env: process.env });
    return { stdout: result.stdout || "", stderr: result.stderr || "", code: result.status ?? 99, killed: false }; },
};
const ctx = { mode: "tui", hasUI: true, isIdle: () => true, hasPendingMessages: () => false,
  ui: { getEditorText: () => "", notify() {} }, sessionManager: { getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE, getLeafId: () => "entry-1", getBranch: () => branch } };
const emit = async (name, event = { type: name }) => { for (const handler of handlers.get(name) || []) await handler(event, ctx); };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await emit("session_start", { type: "session_start", reason: "startup" });
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 0) throw new Error("empty inventory emitted a reminder");
if (entries.filter((entry) => entry.customType === "fm-idle-reminder-empty").length !== 1) throw new Error("empty inventory lacked a checked cadence receipt");
await emit("agent_settled", { type: "agent_settled", aborted: false });
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 0 || entries.filter((entry) => entry.customType === "fm-idle-reminder-empty").length !== 1) {
  throw new Error("empty inventory was rechecked before the next interval");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ empty: 1 }));
EOF
  ) || fail "empty idle reminder lifecycle failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.empty')" -eq 1 ] || fail "empty reminder evidence missing: $out"
  pass "idle reminder stays quiet for an empty canonical inventory"
}

test_idle_reminder_decisions_only_filters_unfinished_work() {
  local home session out
  home=$(new_home idle-reminder-decisions-only)
  session=$(seed_session "$home" session)
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add unfinished-work 'Finish the open outcome' --kind ship >/dev/null
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=1000000 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { spawnSync } from "node:child_process";
import { utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let now = 2_000_000_000_000;
Date.now = () => now;
const configFile = `${process.env.FM_HOME}/config/idle-reminder.json`;
writeFileSync(configFile, JSON.stringify({ version: 1, enabled: true, interval_seconds: 1800,
  reporting_scope: "decisions-only" }));
utimesSync(configFile, new Date(now - 3_600_000), new Date(now - 3_600_000));
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const branch = [{ id: "entry-1" }];
const handlers = new Map();
const messages = [];
const entries = [];
const pi = {
  on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
  events: { on() {}, emit() {} }, registerCommand() {}, sendMessage(message) { messages.push(message);
    branch.push({ type: "custom_message", id: `entry-${branch.length + 1}`, timestamp: new Date(now).toISOString(),
      customType: message.customType, content: message.content, display: message.display, details: message.details }); },
  appendEntry(customType, data) { entries.push({ customType, data });
    branch.push({ type: "custom", id: `entry-${branch.length + 1}`, customType, data, timestamp: new Date(now).toISOString() }); },
  async exec(command, args, options) { const result = spawnSync(command, args,
    { encoding: "utf8", cwd: options?.cwd, timeout: options?.timeout, env: process.env });
    return { stdout: result.stdout || "", stderr: result.stderr || "", code: result.status ?? 99, killed: false }; },
};
const ctx = { mode: "tui", hasUI: true, isIdle: () => true, hasPendingMessages: () => false,
  ui: { getEditorText: () => "", notify() {} }, sessionManager: { getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE, getLeafId: () => branch.at(-1)?.id, getBranch: () => branch } };
const emit = async (name, event = { type: name }) => { for (const handler of handlers.get(name) || []) await handler(event, ctx); };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await emit("session_start", { type: "session_start", reason: "startup" });
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 0) throw new Error("unfinished work emitted a decisions-only reminder");
if (entries.filter((entry) => entry.customType === "fm-idle-reminder-empty").length !== 1) {
  throw new Error("filtered unfinished work did not settle the reminder cadence");
}
const taskScript = `${process.env.FM_ROOT_OVERRIDE}/bin/fm-tasks-axi.sh`;
let result = spawnSync(taskScript, ["add", "choose-path", "Choose the rollout path", "--kind", "ship"],
  { encoding: "utf8", env: process.env });
if (result.status !== 0) throw new Error(`decision task add failed: ${result.stderr}`);
result = spawnSync(taskScript, ["hold", "choose-path", "--kind", "captain", "--reason",
  "Choose option A for the smaller rollout or option B for the broader rollout; recommend A."],
  { encoding: "utf8", env: process.env });
if (result.status !== 0) throw new Error(`decision hold failed: ${result.stderr}`);
now += 1_800_000;
await emit("agent_settled", { type: "agent_settled", aborted: false });
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 1) throw new Error(`expected one decision reminder, got ${messages.length}`);
if (!messages[0].content.includes("choose-path") || messages[0].content.includes("unfinished-work")) {
  throw new Error(`decision reminder leaked unfinished work or omitted the decision: ${messages[0].content}`);
}
if (!messages[0].content.includes("concrete options") || !messages[0].content.includes("recommendation")) {
  throw new Error("decisions-only prompt lost its options and recommendation contract");
}
await emit("before_agent_start", { type: "before_agent_start", messageType: "custom", message: messages[0],
  systemPrompt: "", systemPromptOptions: {} });
const silentAssistant = { role: "assistant", content: [], stopReason: "stop", timestamp: now };
branch.push({ type: "message", id: `entry-${branch.length + 1}`, timestamp: new Date(now).toISOString(),
  message: silentAssistant });
await emit("message_end", { type: "message_end", message: silentAssistant });
await emit("session_shutdown", { type: "session_shutdown", reason: "reload-before-receipt" });
handlers.clear();
const reloaded = await import(`${pathToFileURL(process.env.PLUGIN).href}?silent-reload=1`);
reloaded.default(pi);
await emit("session_start", { type: "session_start", reason: "reload" });
await new Promise((resolve) => setTimeout(resolve, 30));
if (entries.filter((entry) => entry.customType === "fm-idle-reminder-delivered").length !== 1 ||
    entries.some((entry) => entry.customType === "fm-idle-reminder-failed") || messages.length !== 1) {
  throw new Error("a permitted silent decision reminder did not recover successfully at the ordinary cadence");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ reminders: messages.length, empty: entries.filter((entry) => entry.customType === "fm-idle-reminder-empty").length,
  delivered: entries.filter((entry) => entry.customType === "fm-idle-reminder-delivered").length }));
EOF
  ) || fail "decisions-only idle reminder lifecycle failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.reminders')" -eq 1 ] || fail "decision reminder evidence missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.empty')" -eq 1 ] || fail "unfinished-filter evidence missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.delivered')" -eq 1 ] || fail "silent settlement evidence missing: $out"
  pass "decisions-only idle reminders suppress unfinished work, preserve concrete decisions, and settle permitted silence"
}

test_idle_reminder_is_not_suppressed_by_old_maintenance() {
  local home session out
  home=$(new_home idle-reminder-maintenance)
  session=$(seed_session "$home" session)
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add unfinished-work 'Finish the open outcome' --kind ship >/dev/null
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_PERIODIC_STOW_TICK_MS=1000000 PLUGIN="$ROOT/.pi/extensions/fm-periodic-stow.ts" \
    RUN_SCRIPT="$RUN" SESSION_FILE="$session" bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { readFileSync, utimesSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const now = Date.now();
writeFileSync(`${process.env.FM_HOME}/config/idle-reminder.json`, JSON.stringify({ version: 1, enabled: true, interval_seconds: 1800 }));
const old = new Date(now - 3_600_000);
utimesSync(`${process.env.FM_HOME}/config/idle-reminder.json`, old, old);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const common = ["--session-id", "session-1", "--session-file", process.env.SESSION_FILE,
  "--target-entry-id", "entry-1", "--branch-fingerprint", "a".repeat(64)];
for (const reason of ["manual", "precompact"]) {
  const requested = spawnSync(process.env.RUN_SCRIPT, ["request", "--reason", reason, ...common], { encoding: "utf8", env: process.env });
  if (requested.status !== 0) throw new Error(`could not seed old maintenance: ${requested.stdout} ${requested.stderr}`);
}
const handlers = new Map();
const messages = [];
const branch = [{ id: "root-1" }, { id: "entry-1" }];
const pi = {
  on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
  events: { on() {}, emit() {} }, registerCommand() {}, appendEntry() {},
  sendMessage(message, options) { messages.push({ message, options }); },
  async exec(command, args, options) { const result = spawnSync(command, args, { encoding: "utf8", cwd: options?.cwd, timeout: options?.timeout, env: process.env });
    return { stdout: result.stdout || "", stderr: result.stderr || "", code: result.status ?? 99, killed: false }; },
};
const ctx = { mode: "tui", hasUI: true, isIdle: () => true, hasPendingMessages: () => false,
  ui: { getEditorText: () => "", notify() {} }, sessionManager: { getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE, getLeafId: () => "entry-1", getBranch: () => branch } };
const emit = async (name, event = { type: name }) => { for (const handler of handlers.get(name) || []) await handler(event, ctx); };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await emit("session_start", { type: "session_start", reason: "startup" });
await new Promise((resolve) => setTimeout(resolve, 50));
if (messages.length !== 1 || messages[0].message.customType !== "fm-idle-reminder-request") {
  throw new Error("old requested maintenance ran before or suppressed the due idle reminder");
}
const state = JSON.parse(readFileSync(`${process.env.FM_HOME}/state/stow/state.json`, "utf8"));
if (!state.active.reasons.includes("manual") || !state.active.reasons.includes("precompact")) {
  throw new Error("idle reminder changed old maintenance custody");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ first: messages[0].message.customType, reasons: state.active.reasons.length }));
EOF
  ) || fail "old-maintenance idle reminder priority failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.first')" = fm-idle-reminder-request ] || fail "idle reminder priority evidence missing: $out"
  pass "old requested maintenance keeps its custody without suppressing a due idle reminder"
}

test_heartbeat_requires_three_verified_duties() {
  local home session out run rev receipt proof hash
  home=$(new_home heartbeat)
  session=$(seed_session "$home" session)
  out=$(request_run "$home" "$session" heartbeat) || fail "heartbeat request failed: $out"
  run=$(printf '%s' "$out" | jq -r '.run_id')
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" deliver --run-id "$run" --generation generation-1 --expected-revision "$rev") || fail "heartbeat delivery failed"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation generation-1 \
    --target-entry-id entry-1 --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev") || fail "heartbeat begin failed"
  rev=$(printf '%s' "$out" | jq -r '.revision')
  mkdir -p "$home/data/stow-runs/$run"
  receipt="data/stow-runs/$run/receipt.json"
  proof="data/stow-runs/$run/readback.md"
  printf '%s\n' 'No accepted landed archive candidates; all continuations evidenced; pinned knowledge unchanged.' >"$home/$proof"
  hash=$(sha256sum "$home/$proof" | awk '{print $1}')
  jq -cn --arg run "$run" '{version:1,run_id:$run,generation:"generation-1",outcome:"succeeded",budget:{ok:true},local_steps:[],cascade:[],preflight:{complete:true,homes:[]}}' >"$home/$receipt"
  if run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" --interval-seconds 3600 --expected-revision "$rev" >/dev/null; then
    fail "heartbeat completed without its three duty readbacks"
  fi
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active.run_id')" = "$run" ] || fail "failed heartbeat lost its obligation"
  jq --arg ref "$proof" --arg hash "$hash" '.heartbeat={archival:{status:"unchanged",evidence_ref:$ref,sha256:$hash},continuation:{status:"complete",evidence_ref:$ref,sha256:$hash},knowledge:{status:"unchanged",evidence_ref:$ref,sha256:$hash}}' "$home/$receipt" >"$home/next.json"
  mv "$home/next.json" "$home/$receipt"
  printf 'changed' >>"$home/$proof"
  if run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" --interval-seconds 3600 --expected-revision "$rev" >/dev/null; then
    fail "heartbeat accepted changed readback evidence"
  fi
  printf '%s\n' 'No accepted landed archive candidates; all continuations evidenced; pinned knowledge unchanged.' >"$home/$proof"
  out=$(run_main "$home" finish --run-id "$run" --generation generation-1 --receipt-ref "$receipt" --interval-seconds 3600 --expected-revision "$rev") || fail "verified heartbeat refused: $out"
  [ "$(FM_HOME="$home" "$RUN" status | jq -r '.active')" = null ] || fail "verified heartbeat remains active"
  pass "heartbeat retains failed duties and completes only with three unchanged bound readbacks"
}

test_heartbeat_persistent_recovery_keeps_budget_and_identity() {
  local home session out run rev id next_id due base_path clockbin
  home=$(new_home paced-recovery); session=$(seed_session "$home" session)
  clockbin="$home/clockbin"; mkdir -p "$clockbin"
  base_path=$PATH
  # Advance only the fixture wall clock; no production timing override exists.
  printf '2000000000\n' >"$home/clock"
  cat >"$clockbin/date" <<'DATE'
#!/usr/bin/env python3
from datetime import datetime, timezone
from pathlib import Path
import sys
value=int((Path(__file__).parent.parent/'clock').read_text())
print(value if sys.argv[-1]=='+%s' else datetime.fromtimestamp(value,timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
DATE
  chmod +x "$clockbin/date"
  PATH="$clockbin:$base_path"
  out=$(request_run "$home" "$session" heartbeat) || fail "heartbeat request: $out"
  run=$(printf '%s' "$out" | jq -r .run_id)
  rev=$(printf '%s' "$out" | jq -r .revision)
  for _ in 1 2 3 4; do
    out=$(run_main "$home" deliver --run-id "$run" --generation gen-1 --expected-revision "$rev") || fail "offer: $out"
    rev=$(printf '%s' "$out" | jq -r .revision)
  done
  id=$(printf '%s' "$out" | jq -r .escalation_id)
  out=$(run_main "$home" delivery --run-id "$run" --generation gen-1 --operation-id "$id" --expected-revision "$rev") || fail "receipt: $out"
  rev=$(printf '%s' "$out" | jq -r .revision)
  for _ in 1 2 3; do
    out=$(run_main "$home" deliver --run-id "$run" --generation gen-reloaded --expected-revision "$rev") || fail "cooldown: $out"
    [ "$(printf '%s' "$out" | jq -r .outcome)" = escalated ] || fail "reload bypassed deadline"
  done
  printf '2000000060\n' >"$home/clock"
  out=$(run_main "$home" deliver --run-id "$run" --generation gen-reloaded --expected-revision "$rev") || fail "recovery: $out"
  rev=$(printf '%s' "$out" | jq -r .revision); next_id=$(printf '%s' "$out" | jq -r .escalation_id)
  [ "$next_id" = "$id.r.1" ] || fail "first recovery identity: $out"
  out=$(run_main "$home" deliver --run-id "$run" --generation gen-third --expected-revision "$rev") || fail "reservation rebind: $out"
  rev=$(printf '%s' "$out" | jq -r .revision)
  [ "$(printf '%s' "$out" | jq -r .escalation_id)" = "$next_id" ] || fail "generation replaced undelivered recovery"
  out=$(run_main "$home" begin --run-id "$run" --session-id session-1 --generation gen-third --target-entry-id entry-1 \
    --branch-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --expected-revision "$rev") || fail "begin recovery: $out"
  rev=$(printf '%s' "$out" | jq -r .revision)
  out=$(run_main "$home" delivery --run-id "$run" --generation gen-third --operation-id "$next_id" --expected-revision "$rev") || fail "recovery receipt: $out"
  rev=$(printf '%s' "$out" | jq -r .revision)
  due=$(FM_HOME="$home" "$RUN" status | jq -r .active.recovery_not_before)
  [ "$due" = 2000000180 ] || fail "recovery backoff was not anchored to delivery: $due"
  printf '%s\n' "$due" >"$home/clock"
  out=$(run_main "$home" deliver --run-id "$run" --generation gen-third --expected-revision "$rev") || fail "second recovery: $out"
  [ "$(printf '%s' "$out" | jq -r .escalation_id)" = "$id.r.2" ] || fail "unfinished heartbeat stopped recovering"
  FM_HOME="$home" "$RUN" status | jq -e '.active.attempts==3 and .active.recovery_attempts==2 and .active.phase=="running" and .last_result==null' >/dev/null || fail "recovery fabricated progress or reset budget"
  PATH=$base_path
  pass "heartbeat persists paced recovery across generations without resetting attempts or fabricating progress"
}

test_idle_reminder_runs_through_installed_pi() {
  local home out sdk status=0
  sdk=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$sdk/dist/index.js" ]; then
    printf 'skip: installed-Pi idle reminder regression requires installed Pi SDK\n'
    return
  fi
  home=$(new_home installed-pi-idle-reminder)
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add installed-pi-work \
    'Continue the installed Pi reminder validation' --kind ship >/dev/null
  set +e
  # shellcheck disable=SC2016 # Positional parameters belong to the nested shell.
  out=$(env -u FIRSTMATE_OP -u FM_TASK_ID -u FM_SUPERVISION_ACTOR FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_PERIODIC_STOW_TICK_MS=20 bash -c \
    'exec -a pi node "$1" "$2" "$3" "$4"' launcher \
    "$ROOT/tests/fm-periodic-stow-installed.mjs" "$ROOT" "$home" "$sdk" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "installed Pi idle reminder lifecycle failed: $out"
  case "$out" in
    *'"providerCalls":2'*'"networkCalls":0'*'"runtime":"installed AgentSession + DefaultResourceLoader"'*) ;;
    *) fail "installed Pi idle reminder evidence was incomplete: $out" ;;
  esac
  pass "installed Pi delivers one idle reminder and restores its successful cadence without network access"
}

test_idle_reminder_waits_for_owned_settlement_followup() {
  local repo home session out
  repo="$TMP_ROOT/idle-reminder-owned-followup-root"
  home=$(new_home idle-reminder-owned-followup)
  session=$(seed_session "$home" session)
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-periodic-stow.ts" "$repo/.pi/extensions/fm-periodic-stow.ts"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-idle-reminder-config.ts" "$repo/.pi/extensions/lib/fm-idle-reminder-config.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/.pi/extensions/lib/fm-task-continuation.ts" "$repo/.pi/extensions/lib/fm-task-continuation.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat >"$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
: >"${FM_GUARD_STARTED:?}"
while [ ! -e "${FM_GUARD_RELEASE:?}" ]; do sleep 0.01; done
printf 'synthetic missing watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(env -i PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/tmp}" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_PERIODIC_STOW_TICK_MS=1000000 PERIODIC="$repo/.pi/extensions/fm-periodic-stow.ts" \
    GUARD="$repo/.pi/extensions/fm-primary-turnend-guard.ts" SESSION_FILE="$session" \
    FM_GUARD_STARTED="$home/guard-started" FM_GUARD_RELEASE="$home/guard-release" \
    bash -c 'exec -a pi node --input-type=module' launcher 2>&1 <<'EOF'
import { existsSync, utimesSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let now = 2_000_000_000_000;
Date.now = () => now;
writeFileSync(`${process.env.FM_HOME}/config/idle-reminder.json`,
  JSON.stringify({ version: 1, enabled: true, interval_seconds: 1800 }));
const configured = new Date(now - 1_799_000);
utimesSync(`${process.env.FM_HOME}/config/idle-reminder.json`, configured, configured);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);

const handlers = new Map();
const eventHandlers = new Map();
const messages = [];
let pending = false;
const branch = [{ type: "custom", id: "entry-1", timestamp: new Date(now - 5000).toISOString() }];
const pi = {
  on(name, handler) { const list = handlers.get(name) || []; list.push(handler); handlers.set(name, list); },
  events: {
    on(name, handler) { const list = eventHandlers.get(name) || []; list.push(handler); eventHandlers.set(name, list); },
    emit(name, value) { for (const handler of eventHandlers.get(name) || []) handler(value); },
  },
  registerCommand() {}, appendEntry() {},
  sendMessage(message) { messages.push({ kind: "reminder", message }); pending = true; },
  async sendUserMessage(message) { messages.push({ kind: "guard", message }); pending = true; },
  async exec(_command, args) {
    if (!args.includes("--all-in-flight")) return { stdout: "", stderr: "", code: 0, killed: false };
    await new Promise((resolve) => setTimeout(resolve, 20));
    return { stdout: JSON.stringify({ schema: "fm-bearings.v1", generated: "2033-05-18T00:00:00+08:00",
      in_flight: [], gates: [{ id: "unfinished", title: "Finish outcome", reason: "next action" }],
      decisions_open: [] }), stderr: "", code: 0, killed: false };
  },
};
const ctx = { mode: "tui", hasUI: true, isIdle: () => true, hasPendingMessages: () => pending,
  ui: { getEditorText: () => "", notify() {} }, sessionManager: { getSessionId: () => "session-1",
    getSessionFile: () => process.env.SESSION_FILE, getLeafId: () => branch.at(-1).id, getBranch: () => branch } };
const emit = async (name, event) => { for (const handler of handlers.get(name) || []) await handler(event, ctx); };

const periodic = await import(pathToFileURL(process.env.PERIODIC).href);
periodic.default(pi);
const periodicStart = handlers.get("session_start")[0];
const guard = await import(pathToFileURL(process.env.GUARD).href);
guard.default(pi);
await periodicStart({ type: "session_start", reason: "startup" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 30));
if (messages.length !== 0) throw new Error("reminder fired before due boundary");

now += 1000;
const settling = emit("agent_settled", { type: "agent_settled", aborted: false });
for (let attempt = 0; attempt < 200 && !existsSync(process.env.FM_GUARD_STARTED); attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 5));
}
if (!existsSync(process.env.FM_GUARD_STARTED)) throw new Error("turn-end guard did not claim settlement ownership");
await new Promise((resolve) => setTimeout(resolve, 40));
if (messages.length !== 0) throw new Error("reminder overtook an owned settlement follow-up");
writeFileSync(process.env.FM_GUARD_RELEASE, "release\n");
await settling;
await new Promise((resolve) => setTimeout(resolve, 40));
if (messages.length !== 1 || messages[0].kind !== "guard") throw new Error("guard follow-up did not retain first delivery ownership");

pending = false;
await emit("agent_settled", { type: "agent_settled", aborted: false });
await new Promise((resolve) => setTimeout(resolve, 60));
if (messages.length !== 2 || messages[1].kind !== "reminder") throw new Error("reminder did not wait for the owned follow-up to settle");
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ order: messages.map(({ kind }) => kind) }));
EOF
  ) || fail "combined settlement ownership lifecycle failed: $out"
  case "$out" in
    *'"order":["guard","reminder"]'*) ;;
    *) fail "combined settlement ownership evidence was incomplete: $out" ;;
  esac
  pass "idle reminder waits for the existing turn-end owner before entering the follow-up queue"
}

test_status_is_read_only_and_default_idle
test_request_delivery_begin_and_verified_finish
test_cas_generation_and_role_refuse_stale_callers
test_partial_recovery_keeps_original_plan_and_hashes
test_later_cutoff_is_promoted_after_completed_run
test_disable_withdraws_only_unconsumed_periodic_work
test_receipts_and_corrupt_state_fail_closed
test_pi_coordinator_waits_for_safe_settle_and_bounds_redelivery
test_idle_reminder_uses_successful_settlement_cadence
test_idle_reminder_restores_legacy_receipt_fingerprint
test_idle_reminder_stays_silent_for_empty_inventory
test_idle_reminder_decisions_only_filters_unfinished_work
test_idle_reminder_is_not_suppressed_by_old_maintenance
test_idle_reminder_runs_through_installed_pi
test_idle_reminder_waits_for_owned_settlement_followup

test_heartbeat_requires_three_verified_duties

test_heartbeat_persistent_recovery_keeps_budget_and_identity
