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
  events: { on() {} },
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
if (messages.length !== 3) throw new Error(`expected three bounded offers, got ${messages.length}`);
const ids = new Set(messages.map((item) => item.message.details.run_id));
if (ids.size !== 1) throw new Error("redelivery changed run_id");
if (messages.some((item) => item.options.deliverAs !== "followUp" || item.options.triggerTurn !== true)) {
  throw new Error("delivery did not preserve follow-up semantics");
}
await commands.get("stow")("", ctx);
await emit("session_before_compact", { type: "session_before_compact" });
const status = JSON.parse((await import("node:fs")).readFileSync(`${process.env.FM_HOME}/state/stow/state.json`, "utf8"));
if (!status.active.reasons.includes("manual") || !status.active.reasons.includes("precompact")) {
  throw new Error("manual and precompact reasons did not deduplicate into the active run");
}
await emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
console.log(JSON.stringify({ messages: messages.length, notices: notices.length, attempts: status.active.attempts }));
EOF
  ) || fail "Pi coordinator lifecycle failed: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.messages')" -eq 3 ] || fail "bounded redelivery evidence missing: $out"
  [ "$(printf '%s' "$out" | tail -1 | jq -r '.attempts')" -eq 3 ] || fail "durable attempt count missing: $out"
  pass "Pi coordinator stays default-off, waits for tools, queues, and editor input, then redelivers one run at most three times"
}

test_status_is_read_only_and_default_idle
test_request_delivery_begin_and_verified_finish
test_cas_generation_and_role_refuse_stale_callers
test_partial_recovery_keeps_original_plan_and_hashes
test_later_cutoff_is_promoted_after_completed_run
test_disable_withdraws_only_unconsumed_periodic_work
test_receipts_and_corrupt_state_fail_closed
test_pi_coordinator_waits_for_safe_settle_and_bounds_redelivery
