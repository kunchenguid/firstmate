#!/usr/bin/env bash
# Behavioral tests for the central task resource guard.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-resource-guard.sh"
ADAPTER="$ROOT/bin/fm-procevent-resource.sh"
TMP_ROOT=$(fm_test_tmproot fm-resource-guard)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ok() { printf 'ok - %s\n' "$1"; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_guard() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$GUARD" "$@"
}

# <path> <all-remaining> <weekly-reset> [model-remaining] [all-runway] [model-runway]
write_snapshot() {
  local path=$1 all=$2 reset=$3 model=${4:-} all_runway=${5:-through_reset} model_runway=${6:-through_reset}
  if [ -n "$model" ]; then
    jq -n --argjson all "$all" --argjson model "$model" --arg reset "$reset" \
      --arg ar "$all_runway" --arg mr "$model_runway" '
      {schemaVersion:5,providers:[{provider:"codex",quotaSemantics:{status:"known",effectiveAvailability:[
        {scope:"all_models",status:"known",effectivePercentRemaining:$all,boundedBy:["weekly"],runway:{status:$ar}},
        {scope:"model:fable",status:"known",effectivePercentRemaining:$model,boundedBy:["weekly","fable"],runway:{status:$mr}}
      ]},windows:[
        {id:"weekly",label:"Account weekly",percentRemaining:$all,resetsAt:$reset},
        {id:"fable",label:"Fable weekly",percentRemaining:$model,resetsAt:$reset}
      ]}]}' >"$path"
  else
    jq -n --argjson all "$all" --arg reset "$reset" --arg ar "$all_runway" '
      {schemaVersion:5,providers:[{provider:"codex",quotaSemantics:{status:"known",effectiveAvailability:[
        {scope:"all_models",status:"known",effectivePercentRemaining:$all,boundedBy:["weekly"],runway:{status:$ar}}
      ]},windows:[{id:"weekly",label:"Account weekly",percentRemaining:$all,resetsAt:$reset}]}]}' >"$path"
  fi
}

start_guard() {
  local home=$1 snapshot=$2 remaining_args=${3:-}
  # shellcheck disable=SC2086
  run_guard "$home" start sample --provider codex --snapshot "$snapshot" \
    --attribution exact --no-monitor --now 1800000000 $remaining_args
}

procevent() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$ROOT/bin/fm-procevent.sh" "$@"
}

monitor_count() {
  procevent "$1" list | grep -Ec '^resource-sample +resource +' || true
}

iso_epoch() {
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

# A version-compatible quota-axi stand-in: FAKE_QUOTA_MODE=fail exits nonzero,
# otherwise it prints FAKE_QUOTA_SNAPSHOT.
make_fake_quota() {
  local dir=$1
  mkdir -p "$dir"
  cat >"$dir/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in --version) echo "quota-axi 9.9.9"; exit 0 ;; esac
[ "${FAKE_QUOTA_MODE:-ok}" = fail ] && exit 1
cat "$FAKE_QUOTA_SNAPSHOT"
SH
  chmod +x "$dir/quota-axi"
}

run_captain_hold() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# <home> <authority-task> <decision-file>: hold, bind, and answer one captain call.
captain_answer() {
  local home=$1 authority=$2 decision=$3
  [ -f "$home/.tasks.toml" ] || cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  [ -f "$home/data/backlog.md" ] || printf '## In flight\n\n## Queued\n\n## Done\n' >"$home/data/backlog.md"
  (cd "$home" && tasks-axi add "$authority" "Approve revised resource budget" --kind scout --repo sample >/dev/null)
  run_captain_hold "$home" hold "$authority" --reason "revised resource budget needed" >/dev/null
  run_guard "$home" bind-authority sample "$authority" >/dev/null || fail "captain authority did not bind"
  run_captain_hold "$home" answer "$authority" --decision-file "$decision" >/dev/null
}

expect_rc() {
  local expected=$1
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected exit $expected, got $rc from $*"
}

if help=$($GUARD --help 2>&1); then
  fail "resource guard help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-resource-guard.sh start <task-id>' \
  || fail "resource guard help omitted start usage"
printf '%s\n' "$help" | grep -Fq 'set -eu' && fail "resource guard help leaked executable source"
ok "help renders only the complete owner header"

home=$(make_home baseline)
write_snapshot "$home/start.json" 80 2030-01-01T00:00:00Z 50
out=$(run_guard "$home" start sample --provider codex --model fable --snapshot "$home/start.json" \
  --scope all_models --scope model:fable --attribution exact --no-monitor --now 1800000000)
printf '%s\n' "$out" | jq -e '.state == "active" and .strictest_active_floor_points == 30' >/dev/null \
  || fail "known overlapping baseline was not active"
jq -e '
  .schema == "fm.task-resource-budget.v1" and
  .reserve_floor_points == 30 and .pause_after_points == 15 and .tranche_points == 15 and
  (.windows | map(.id) | sort) == ["fable","weekly"] and
  (.applicable_scopes | sort) == ["all_models","model:fable"]
' "$home/state/sample.resource-budget.json" >/dev/null || fail "baseline did not bind both independent windows"
events="$home/data/resource-events/2027-01.jsonl"
[ "$(wc -l <"$events" | tr -d ' ')" -eq 1 ] || fail "baseline did not emit exactly one event"
jq -s -e 'length == 1 and .[0].schema == "fm.resource-event.v1" and (.[] | .event_id | test("^[0-9a-f]{64}$"))' \
  "$events" >/dev/null || fail "baseline event schema/id is invalid"
[ "$(stat -f %Lp "$events" 2>/dev/null || stat -c %a "$events")" = 600 ] \
  || fail "resource event journal is not mode 0600"
ok "baseline binds overlapping windows and emits a private versioned event"

home_provider=$(make_home provider-neutral)
write_snapshot "$home_provider/claude.json" 80 2030-01-01T00:00:00Z
jq '.providers[0].provider="claude"' "$home_provider/claude.json" >"$home_provider/provider.json"
run_guard "$home_provider" start sample --provider claude --snapshot "$home_provider/provider.json" \
  --attribution exact --no-monitor --now 1800000000 >/dev/null \
  || fail "provider-neutral evaluator rejected a non-codex provider"
[ "$(jq -r .provider "$home_provider/state/sample.resource-budget.json")" = claude ] \
  || fail "provider-neutral baseline changed provider identity"

home_account=$(make_home account-selection)
jq -n '{schemaVersion:6,providers:[
  {provider:"codex",accountKey:"personal",quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:80,boundedBy:["weekly"],runway:{status:"through_reset"}}]},windows:[{id:"weekly",label:"Weekly",percentRemaining:80,resetsAt:"2030-01-01T00:00:00Z"}]},
  {provider:"codex",accountKey:"work",quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:70,boundedBy:["weekly"],runway:{status:"through_reset"}}]},windows:[{id:"weekly",label:"Weekly",percentRemaining:70,resetsAt:"2030-01-01T00:00:00Z"}]}
]}' >"$home_account/schema6.json"
expect_rc 3 run_guard "$home_account" start ambiguous --provider codex --snapshot "$home_account/schema6.json" \
  --attribution exact --no-monitor --now 1800000000
run_guard "$home_account" start selected --provider codex --account-key work --snapshot "$home_account/schema6.json" \
  --attribution exact --no-monitor --now 1800000000 >/dev/null \
  || fail "explicit schema-6 account did not start"
[ "$(jq -r .account_key "$home_account/state/selected.resource-budget.json")" = work ] \
  || fail "explicit account binding was not preserved"
jq -n '{schemaVersion:6,providers:[
  {provider:"claude",accountKey:"private@example.invalid",quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:80,boundedBy:["weekly"],runway:{status:"through_reset"}}]},windows:[{id:"weekly",label:"Private label",percentRemaining:80,resetsAt:"2030-01-01T00:00:00Z"}]}
]}' >"$home_account/private-account.json"
expect_rc 3 run_guard "$home_account" start private-account --provider claude --snapshot "$home_account/private-account.json" \
  --attribution exact --no-monitor --now 1800000000
if grep -R -F 'private@example.invalid' "$home_account/state" "$home_account/data" >/dev/null; then
  fail "non-privacy-safe provider account key leaked into guard records"
fi
ok "one evaluator handles providers centrally and refuses ambiguous or non-private account selection"

home=$(make_home baseline-retry)
write_snapshot "$home/start.json" 80 2030-01-01T00:00:00Z 50
run_guard "$home" start sample --provider codex --model fable --snapshot "$home/start.json" \
  --scope all_models --scope model:fable --attribution exact --no-monitor --now 1800000000 >/dev/null
events="$home/data/resource-events/2027-01.jsonl"
run_guard "$home" start sample --provider codex --model fable --snapshot "$home/start.json" \
  --scope all_models --scope model:fable --attribution exact --no-monitor --now 1800000000 >/dev/null \
  || fail "exact start retry was not idempotent"
[ "$(wc -l <"$events" | tr -d ' ')" -eq 1 ] || fail "idempotent start duplicated the baseline event"
expect_rc 1 run_guard "$home" start sample --provider codex --model fable --snapshot "$home/start.json" \
  --scope all_models --scope model:fable --attribution exact --no-monitor --now 1800000001
ok "start retries are idempotent and task-start drift is refused"

home=$(make_home concurrent-events)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
run_guard "$home" start lane-a --provider codex --snapshot "$home/base.json" --attribution shared \
  --concurrent-task lane-b --no-monitor --now 1800000000 >"$home/a.out" 2>"$home/a.err" &
pid_a=$!
run_guard "$home" start lane-b --provider codex --snapshot "$home/base.json" --attribution shared \
  --concurrent-task lane-a --no-monitor --now 1800000000 >"$home/b.out" 2>"$home/b.err" &
pid_b=$!
wait "$pid_a" || fail "first concurrent baseline failed: $(cat "$home/a.err")"
wait "$pid_b" || fail "second concurrent baseline failed: $(cat "$home/b.err")"
events="$home/data/resource-events/2027-01.jsonl"
[ "$(wc -l <"$events" | tr -d ' ')" -eq 2 ] || fail "concurrent baselines lost or duplicated an event"
jq -s -e 'length == 2 and (map(.task_id) | sort) == ["lane-a","lane-b"]' "$events" >/dev/null \
  || fail "concurrent baseline event journal is invalid"
ok "concurrent tasks serialize the shared append-only event journal"

home=$(make_home retention)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
run_guard "$home" start old-lane --provider codex --snapshot "$home/base.json" --attribution exact \
  --no-monitor --now 1790000000 >/dev/null
run_guard "$home" start current-lane --provider codex --snapshot "$home/base.json" --attribution exact \
  --no-monitor --now 1800000000 >/dev/null
find "$home/data/resource-events" -type f -name '*.jsonl' -exec jq -c . {} + >"$home/retained-events"
[ "$(wc -l <"$home/retained-events" | tr -d ' ')" -eq 1 ] \
  || fail "90-day retention did not retire the expired event"
[ "$(jq -r .task_id "$home/retained-events")" = current-lane ] \
  || fail "90-day retention kept the wrong event"
ok "event publication enforces a private 90-day retention horizon"

home=$(make_home strict-window)
write_snapshot "$home/strict.json" 80 2030-01-01T00:00:00Z 44
rc=0
out=$(run_guard "$home" start sample --provider codex --model fable --snapshot "$home/strict.json" \
  --scope all_models --scope model:fable --attribution exact --no-monitor --now 1800000000) || rc=$?
[ "$rc" -eq 3 ] || fail "strict model window crossing did not request a pause"
printf '%s\n' "$out" | jq -e '.state == "pause_pending" and .reason == "reserve_floor"' >/dev/null \
  || fail "strict window did not own the reserve decision"
jq -e '.windows[] | select(.id == "fable") | .current_remaining_points == 44 and .reserve_floor_points == 30' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "strict model-window evidence was not preserved"
ok "the strictest overlapping window wins independently"

home=$(make_home boundary)
write_snapshot "$home/equal.json" 45 2030-01-01T00:00:00Z
start_guard "$home" "$home/equal.json" >/dev/null || fail "tranche ending exactly on reserve floor was rejected"
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = active ] \
  || fail "reserve equality was not active"
ok "reserve boundary treats equality as safe"

home=$(make_home six-hours)
write_snapshot "$home/six.json" 30 2027-01-15T14:00:00Z
start_guard "$home" "$home/six.json" >/dev/null || fail "six-hour floor was not released"
jq -e '.windows[0].reserve_floor_points == 15 and .windows[0].near_reset_release == true' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "six-hour floor is not 15"

home=$(make_home quota-rfc3339)
write_snapshot "$home/fractional.json" 30 2027-01-15T16:00:00.397648+02:00
start_guard "$home" "$home/fractional.json" >/dev/null \
  || fail "quota-axi RFC3339 fractional offset timestamp was rejected"
[ "$(jq -r '.windows[0].reserve_floor_points' "$home/state/sample.resource-budget.json")" = 15 ] \
  || fail "RFC3339 offset was not normalized to its UTC six-hour boundary"

home=$(make_home six-hours-plus)
write_snapshot "$home/plus.json" 30 2027-01-15T14:00:01Z
expect_rc 3 start_guard "$home" "$home/plus.json"
[ "$(jq -r .decision_reason "$home/state/sample.resource-budget.json")" = reserve_floor ] \
  || fail "one second outside six hours did not retain the 30-point floor"

home=$(make_home two-hours)
write_snapshot "$home/two.json" 20 2027-01-15T10:00:00Z
start_guard "$home" "$home/two.json" >/dev/null || fail "two-hour floor was not released"
[ "$(jq -r '.windows[0].reserve_floor_points' "$home/state/sample.resource-budget.json")" = 5 ] \
  || fail "two-hour floor is not 5"

home=$(make_home runway)
write_snapshot "$home/projected.json" 30 2027-01-15T14:00:00Z '' projected_exhaustion
expect_rc 3 start_guard "$home" "$home/projected.json"
[ "$(jq -r '.windows[0].reserve_floor_points' "$home/state/sample.resource-budget.json")" = 30 ] \
  || fail "unsafe runway received a near-reset release"
ok "near-reset floors use exact time boundaries and require safe runway plus tranche proof"

home=$(make_home burn)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/fifteen.json" 65 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
expect_rc 3 run_guard "$home" check sample --snapshot "$home/fifteen.json" --now 1800000100
[ "$(jq -r .decision_reason "$home/state/sample.resource-budget.json")" = burn_limit ] \
  || fail "exact 15-point burn did not stop at the documented boundary"
jq -e '.trigger == "burn_limit" and .measured_delta.value == 15 and .measured_delta.confidence == "exact"' \
  "$home/data/burn-evaluations/"*.json >/dev/null || fail "burn evaluation did not preserve exact measured delta"
ok "15-point task burn creates an immutable trigger evaluation"

home=$(make_home shared)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/fifteen.json" 65 2030-01-01T00:00:00Z
run_guard "$home" start sample --provider codex --snapshot "$home/base.json" --attribution shared \
  --concurrent-task sibling --no-monitor --now 1800000000 >/dev/null
expect_rc 3 run_guard "$home" check sample --snapshot "$home/fifteen.json" --now 1800000100
jq -e '.decision_reason == "attribution_uncertain" and .attribution_confidence == "shared" and .concurrent_tasks == ["sibling"]' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "shared use was falsely attributed as exact task burn"
ok "concurrent use remains shared and triggers conservative review without fabricated precision"

home=$(make_home telemetry)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
jq -n '{schemaVersion:5,providers:[{provider:"codex",quotaSemantics:{status:"unknown",effectiveAvailability:[]},windows:[]}]}' \
  >"$home/unavailable.json"
expect_rc 3 run_guard "$home" check sample --snapshot "$home/unavailable.json" --now 1800000100
jq -e '.telemetry_status == "unavailable" and .decision_reason == "telemetry_unavailable" and
  (.windows[0].current_remaining_points == null)' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "unavailable telemetry was replaced by an invented value"
cp "$home/state/sample.resource-budget.json" "$home/before-malformed.json"
printf '%s\n' '{"schemaVersion":5,"providers":[]}' >"$home/malformed.json"
# Empty providers are truthful unavailability, not malformed. A broken reset is malformed.
write_snapshot "$home/malformed.json" 70 not-a-time
expect_rc 1 run_guard "$home" check sample --snapshot "$home/malformed.json" --now 1800000200
cmp -s "$home/before-malformed.json" "$home/state/sample.resource-budget.json" \
  || fail "malformed telemetry mutated the previous guarded state"
write_snapshot "$home/impossible-date.json" 70 2027-02-31T06:00:00-04:00
expect_rc 1 run_guard "$home" check sample --snapshot "$home/impossible-date.json" --now 1800000200
cmp -s "$home/before-malformed.json" "$home/state/sample.resource-budget.json" \
  || fail "an impossible reset date mutated the previous guarded state"
ok "unavailable and malformed telemetry stop safely without invented percentages"

home=$(make_home reset-transition)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/reset.json" 95 2031-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
expect_rc 3 run_guard "$home" check sample --snapshot "$home/reset.json" --now 1800000100
jq -e '.decision_reason == "telemetry_unavailable" and
  (.telemetry_reasons | index("window_reset_changed")) and
  .windows[0].reset_continuity == false and .windows[0].burn_points == null' \
  "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "window reset fabricated a continuous task-burn measurement"
ok "window reset transitions pause instead of rebasing an invented exact burn"

home=$(make_home safe-pause)
# One fixed reset is seven hours away at task start and exactly six hours away
# at the later check; this proves time progression without inventing a reset.
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
expect_rc 1 run_guard "$home" pause sample --now 1800000010
printf 'working [at=1800000011]: still owns a write\n' >"$home/state/sample.status"
expect_rc 1 run_guard "$home" pause sample --now 1800000012
printf 'paused [at=1800000013]: resource guard safe boundary reached\n' >>"$home/state/sample.status"
run_guard "$home" pause sample --now 1800000014 >/dev/null || fail "safe worker boundary did not finalize pause"
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = paused ] \
  || fail "safe pause did not close the lane"
run_guard "$home" check sample --snapshot "$home/far.json" --now 1800000100 >/dev/null 2>&1 && \
  fail "ordinary recovered telemetry silently resumed a paused lane"
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = paused ] \
  || fail "ordinary recovered telemetry silently resumed the lane"
run_guard "$home" check sample --snapshot "$home/far.json" --now 1800003600 >/dev/null \
  || fail "proved near-reset release did not auto-resume the reserve pause"
jq -e '.guard_state == "active" and .decision_reason == null' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "near-reset automatic resume did not reopen the budget"
jq -e '.state == "resumed" and .resume_authority == "auto_near_reset"' "$home/state/sample.resource-pause.json" >/dev/null \
  || fail "automatic resume authority was not recorded"
ok "pause waits for a worker boundary and only the proved near-reset rule resumes automatically"

home=$(make_home stale-pause)
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
printf 'paused [at=1799999990]: an earlier unrelated pause\n' >"$home/state/sample.status"
expect_rc 1 run_guard "$home" pause sample --now 1800000010
printf 'paused: no boundary stamp\n' >>"$home/state/sample.status"
expect_rc 1 run_guard "$home" pause sample --now 1800000011
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = pause_pending ] \
  || fail "a paused event older than the pause request finalized the resource pause"
printf 'paused [at=1800000012]: resource guard safe boundary reached\n' >>"$home/state/sample.status"
run_guard "$home" pause sample --now 1800000013 >/dev/null || fail "fresh safe boundary did not finalize pause"
ok "pause requires a paused boundary no older than the pause request"

home=$(make_home monitor-read-failure)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
make_fake_quota "$home/fakebin"
out=$(PATH="$home/fakebin:$PATH" FAKE_QUOTA_MODE=fail run_guard "$home" monitor sample --interval 1) \
  || fail "monitor failed on an unavailable quota read"
printf '%s\n' "$out" | grep -qx 'status: pause-required' \
  || fail "unavailable monitor telemetry did not request a cooperative pause: $out"
jq -e '.guard_state == "pause_pending" and .decision_reason == "telemetry_unavailable" and
  (.telemetry_reasons | index("telemetry_read_failed")) and
  .windows[0].baseline_remaining_points == 80 and .windows[0].current_remaining_points == null' \
  "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "monitor read failure did not pause over the last known baseline"
printf '%s\n' "$out" >"$home/result"
$ADAPTER terminal "$home/result" || fail "monitor telemetry pause was not a terminal wake"
home=$(make_home monitor-malformed)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/malformed.json" 70 not-a-time
start_guard "$home" "$home/base.json" >/dev/null
make_fake_quota "$home/fakebin"
out=$(PATH="$home/fakebin:$PATH" FAKE_QUOTA_SNAPSHOT="$home/malformed.json" \
  run_guard "$home" monitor sample --interval 1) || fail "monitor failed on malformed quota telemetry"
printf '%s\n' "$out" | grep -qx 'status: pause-required' \
  || fail "malformed monitor telemetry did not request a cooperative pause: $out"
jq -e '.decision_reason == "telemetry_unavailable" and .windows[0].baseline_remaining_points == 80' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "malformed monitor telemetry lost the baseline"
ok "monitor-time unavailable or malformed telemetry pauses cooperatively instead of retiring unguarded"

home=$(make_home monitor-near-reset)
now_real=$(date +%s)
reset_epoch=$((now_real + 10800))
write_snapshot "$home/near.json" 30 "$(iso_epoch "$reset_epoch")"
start_epoch=$((reset_epoch - 25200))
expect_rc 3 run_guard "$home" start sample --provider codex --snapshot "$home/near.json" \
  --attribution exact --interval 1 --now "$start_epoch"
printf 'paused [at=%s]: resource guard safe boundary reached\n' "$((start_epoch + 1))" >"$home/state/sample.status"
run_guard "$home" pause sample --now "$((start_epoch + 2))" >/dev/null || fail "reserve pause did not finalize"
[ "$(monitor_count "$home")" = 1 ] || fail "finalized reserve pause left no monitor to prove near-reset resume"
make_fake_quota "$home/fakebin"
out=$(PATH="$home/fakebin:$PATH" FAKE_QUOTA_SNAPSHOT="$home/near.json" run_guard "$home" monitor sample --interval 1) \
  || fail "paused-reserve monitor failed"
printf '%s\n' "$out" | grep -qx 'status: resumed' || fail "monitor did not report the near-reset resume: $out"
jq -e '.guard_state == "active" and .decision_reason == null' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "monitor near-reset proof did not reopen the budget"
printf '%s\n' "$out" >"$home/result"
[ "$($ADAPTER classify "$home/result")" = resumed ] || fail "resume result was not classified"
if $ADAPTER terminal "$home/result"; then
  fail "a resumed budget retired its own monitor"
fi
[ "$(monitor_count "$home")" = 1 ] || fail "near-reset resume duplicated or dropped the monitor"
ok "a reserve pause keeps one monitor armed and its near-reset proof resumes without retiring it"

home=$(make_home monitor-reset-escalation)
now_real=$(date +%s)
reset_epoch=$((now_real + 10800))
write_snapshot "$home/near.json" 30 "$(iso_epoch "$reset_epoch")"
write_snapshot "$home/after-reset.json" 30 "$(iso_epoch "$((reset_epoch + 604800))")"
start_epoch=$((reset_epoch - 25200))
expect_rc 3 run_guard "$home" start sample --provider codex --snapshot "$home/near.json" \
  --attribution exact --interval 1 --now "$start_epoch"
run_guard "$home" pause sample --pre-dispatch --now "$((start_epoch + 1))" >/dev/null \
  || fail "reserve pause raised at start did not finalize before dispatch"
[ "$(monitor_count "$home")" = 1 ] || fail "pre-dispatch reserve pause did not keep a monitor armed"
make_fake_quota "$home/fakebin"
out=$(PATH="$home/fakebin:$PATH" FAKE_QUOTA_SNAPSHOT="$home/after-reset.json" run_guard "$home" monitor sample --interval 1) \
  || fail "reserve-paused monitor failed across a reset"
printf '%s\n' "$out" | grep -qx 'status: awaiting-authority' \
  || fail "reset discontinuity left the reserve-paused monitor looping silently: $out"
jq -e '.guard_state == "paused" and .decision_reason == "telemetry_unavailable" and
  (.telemetry_reasons | index("window_reset_changed"))' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "reset discontinuity did not escalate the reserve pause to durable authority"
jq -e '.state == "paused" and .reason == "telemetry_unavailable" and .escalated_at != null' \
  "$home/state/sample.resource-pause.json" >/dev/null || fail "pause record did not record the escalation"
printf '%s\n' "$out" >"$home/result"
$ADAPTER terminal "$home/result" || fail "authority-required escalation was not a terminal wake"
ok "a reserve-paused monitor escalates to durable authority when reset discontinuity ends near-reset proof"

home=$(make_home monitor-local-error)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
printf 'not-json\n' >"$home/state/sample.resource-budget.json"
out=$(run_guard "$home" monitor sample --interval 1) || fail "monitor crashed on a local record error"
printf '%s\n' "$out" | grep -qx 'status: error' || fail "persistent local errors were not surfaced: $out"
printf '%s\n' "$out" >"$home/result"
if $ADAPTER terminal "$home/result"; then
  fail "a local monitor error retired the guarded source"
fi
home=$(make_home monitor-retired)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
run_guard "$home" retire sample >/dev/null
out=$(run_guard "$home" monitor sample --interval 1) || fail "monitor failed on a retired budget"
printf '%s\n' "$out" | grep -qx 'status: retired' || fail "retired budget kept its monitor polling: $out"
printf '%s\n' "$out" >"$home/result"
$ADAPTER terminal "$home/result" || fail "retired monitor result was not terminal"
ok "local monitor errors back off and stay registered while retirement ends the source"

home=$(make_home pre-dispatch)
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
expect_rc 1 run_guard "$home" pause sample --now 1800000010
run_guard "$home" pause sample --pre-dispatch --now 1800000010 >/dev/null \
  || fail "a pause raised by start could not finalize before dispatch"
jq -e '.guard_state == "paused"' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "pre-dispatch pause was not durable"
jq -e '.state == "paused" and .safe_boundary == "pre_dispatch"' "$home/state/sample.resource-pause.json" >/dev/null \
  || fail "pre-dispatch boundary was not recorded"
[ ! -e "$home/state/sample.status" ] || fail "pre-dispatch pause invented a worker status"
expect_rc 3 run_guard "$home" worker-overlay sample
run_guard "$home" check sample --snapshot "$home/far.json" --now 1800003600 >/dev/null \
  || fail "near-reset proof did not reopen a pre-dispatch reserve pause"
run_guard "$home" worker-overlay sample >/dev/null || fail "reopened budget still refused guarded launch"
home=$(make_home pre-dispatch-check)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/fifteen.json" 65 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
expect_rc 3 run_guard "$home" check sample --snapshot "$home/fifteen.json" --now 1800000100
run_guard "$home" pause sample --pre-dispatch --now 1800000101 >/dev/null \
  || fail "a check pause raised before dispatch could not finalize"
jq -e '.guard_state == "paused" and .dispatch_state == "pre_dispatch"' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "pre-dispatch check pause was not finalized"
expect_rc 3 run_guard "$home" dispatch sample --now 1800000102
home=$(make_home pre-dispatch-refusals)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
write_snapshot "$home/fifteen.json" 65 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
out=$(run_guard "$home" dispatch sample --now 1800000050) || fail "active budget refused dispatch"
token=${out##*at=}
[ "$(run_guard "$home" dispatch sample --rollback 2000-01-01T00:00:00Z)" = 'dispatch-unchanged: sample' ] \
  || fail "a mismatched rollback token changed the dispatch lifecycle"
run_guard "$home" dispatch sample --rollback "$token" >/dev/null
[ "$(jq -r .dispatch_state "$home/state/sample.resource-budget.json")" = pre_dispatch ] \
  || fail "failed-launch rollback did not return the budget to pre-dispatch"
out=$(run_guard "$home" dispatch sample --now 1800000060) || fail "dispatch retry after rollback failed"
run_guard "$home" dispatch sample --now 1800000070 | grep -q '^already-dispatched: sample ' \
  || fail "a second dispatch was not idempotent"
expect_rc 3 run_guard "$home" check sample --snapshot "$home/fifteen.json" --now 1800000100
expect_rc 1 run_guard "$home" pause sample --pre-dispatch --now 1800000101
home=$(make_home pre-dispatch-worker)
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
printf 'working [at=1800000005]: already launched\n' >"$home/state/sample.status"
expect_rc 1 run_guard "$home" pause sample --pre-dispatch --now 1800000010
ok "a pause raised at start finalizes before dispatch without inventing worker status"

home=$(make_home pre-dispatch-escalation)
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
write_snapshot "$home/reset.json" 44 2031-01-01T00:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
requested=$(jq -r .requested_at "$home/state/sample.resource-pause.json")
expect_rc 3 run_guard "$home" check sample --snapshot "$home/reset.json" --now 1800000100
jq -e --arg requested "$requested" '.reason == "telemetry_unavailable" and .raised_by == "task_baseline" and
  .requested_at == $requested and .reason_history[0].reason == "reserve_floor"' \
  "$home/state/sample.resource-pause.json" >/dev/null \
  || fail "pending-pause escalation rewrote the original request identity"
run_guard "$home" pause sample --pre-dispatch --now 1800000101 >/dev/null \
  || fail "an escalated pre-dispatch pause could no longer finalize"
[ "$(jq -r .decision_reason "$home/state/sample.resource-budget.json")" = telemetry_unavailable ] \
  || fail "pre-dispatch finalization lost the escalated reason"

home=$(make_home worker-escalation)
write_snapshot "$home/base.json" 40 2027-01-15T13:00:00Z
write_snapshot "$home/low.json" 40 2027-01-15T13:00:00Z '' projected_exhaustion
write_snapshot "$home/reset.json" 40 2031-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
printf 'working [at=1800000050]: guarded work\n' >"$home/state/sample.status"
expect_rc 3 run_guard "$home" check sample --snapshot "$home/low.json" --now 1800000100
[ "$(jq -r .decision_reason "$home/state/sample.resource-budget.json")" = reserve_floor ] \
  || fail "worker-escalation fixture did not start from a reserve pause"
printf 'paused [at=1800000110]: resource guard safe boundary reached\n' >>"$home/state/sample.status"
expect_rc 3 run_guard "$home" check sample --snapshot "$home/reset.json" --now 1800000200
run_guard "$home" pause sample --now 1800000201 >/dev/null \
  || fail "escalation invalidated the worker's already delivered safe boundary"
jq -e '.state == "paused" and .reason == "telemetry_unavailable" and .safe_boundary == "worker_reported"' \
  "$home/state/sample.resource-pause.json" >/dev/null || fail "escalated worker pause was not finalized"
ok "pending-pause escalation keeps the original request so delivered and pre-dispatch boundaries still finalize"

home=$(make_home review)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
run_guard "$home" review sample creator --head aaaaaaa --actor creator-1 --provider codex --family gpt5 --now 1800000010 >/dev/null
run_guard "$home" review sample creator --head aaaaaaa --actor creator-1 --provider codex --family gpt5 --now 1800000010 >/dev/null \
  || fail "exact creator replay was not idempotent"
expect_rc 1 run_guard "$home" review sample critic --head aaaaaaa --actor creator-1 --provider codex --family gpt5 --now 1800000020
expect_rc 1 run_guard "$home" review sample critic --head aaaaaaa --actor critic-1 --provider codex --family gpt5 --now 1800000020
run_guard "$home" review sample critic --head aaaaaaa --actor critic-1 --provider claude --family sonnet --now 1800000020 >/dev/null
run_guard "$home" review sample failure --head aaaaaaa --actor critic-1 --provider claude --family sonnet --theme auth-boundary --now 1800000030 >/dev/null
run_guard "$home" review sample correction --head bbbbbbb --actor creator-1 --provider codex --family gpt5 --theme auth-boundary --now 1800000040 >/dev/null
run_guard "$home" review sample delta --head bbbbbbb --actor critic-1 --provider claude --family sonnet --theme auth-boundary --now 1800000050 >/dev/null
expect_rc 3 run_guard "$home" review sample failure --head bbbbbbb --actor critic-1 --provider claude --family sonnet --theme auth-boundary --now 1800000060
jq -e '.guard_state == "pause_pending" and .decision_reason == "repeated_review_theme" and
  .review.consecutive_same_theme_failures == 2' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "repeated same-theme review failure did not open the circuit breaker"
printf 'paused [at=1800000061]: resource guard safe boundary reached\n' >"$home/state/sample.status"
run_guard "$home" pause sample --now 1800000061 >/dev/null
run_guard "$home" review sample redesign --head ccccccc --actor creator-2 --provider codex --family gpt5 --theme auth-boundary --now 1800000070 >/dev/null \
  || fail "explicit redesign did not resolve the bounded-review stop"
run_guard "$home" review sample critic --head ccccccc --actor critic-2 --provider codex --family gpt5 \
  --same-family-reason alternate-provider-unavailable --now 1800000080 >/dev/null
run_guard "$home" review sample final --head ccccccc --actor critic-2 --provider claude --family sonnet --now 1800000090 >/dev/null
jq -e '.guard_state == "active" and .review.final.scope == "full" and .review.final.head == "ccccccc" and
  .review.critic.same_family_reason == "alternate-provider-unavailable" and
  (.review.redesigns | length) == 1' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "redesign and final independent review were not recorded"
ok "bounded review stops same-theme loops and permits an explicit redesign with final full review"

home=$(make_home review-final-sequence)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
run_guard "$home" review sample creator --head aaaaaaa --actor creator-1 --provider codex --family gpt5 --now 1800000010 >/dev/null
expect_rc 1 run_guard "$home" review sample final --head bbbbbbb --actor final-1 --provider claude --family sonnet --now 1800000020
run_guard "$home" review sample critic --head aaaaaaa --actor critic-1 --provider claude --family sonnet --now 1800000030 >/dev/null
run_guard "$home" review sample failure --head aaaaaaa --actor critic-1 --provider claude --family sonnet --theme theme-a --now 1800000040 >/dev/null
run_guard "$home" review sample failure --head aaaaaaa --actor critic-1 --provider claude --family sonnet --theme theme-a --now 1800000041 >/dev/null \
  || fail "exact critic failure replay was not idempotent"
jq -e '.guard_state == "active" and .review.consecutive_same_theme_failures == 1 and
  (.review.failures | length) == 1 and .review.failures[0].stage == "critic"' \
  "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "exact critic failure replay consumed another bounded attempt"
expect_rc 1 run_guard "$home" review sample final --head bbbbbbb --actor final-1 --provider claude --family sonnet --now 1800000050
run_guard "$home" review sample correction --head bbbbbbb --actor creator-1 --provider codex --family gpt5 --theme theme-a --now 1800000060 >/dev/null
expect_rc 1 run_guard "$home" review sample final --head bbbbbbb --actor final-1 --provider claude --family sonnet --now 1800000070
run_guard "$home" review sample delta --head bbbbbbb --actor critic-1 --provider claude --family sonnet --theme theme-a --now 1800000080 >/dev/null
run_guard "$home" review sample failure --head aaaaaaa --actor critic-1 --provider claude --family sonnet --theme theme-a --now 1800000081 >/dev/null \
  || fail "critic failure replay was not idempotent after delta progression"
jq -e '.guard_state == "active" and .review.consecutive_same_theme_failures == 1 and
  .review.post_correction_failures == 0 and (.review.failures | length) == 1 and
  .review.failures[0].stage == "critic"' "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "critic failure replay after delta progression consumed the failure budget"
run_guard "$home" review sample final --head bbbbbbb --actor final-1 --provider claude --family sonnet --now 1800000090 >/dev/null \
  || fail "completed correction and delta sequence did not permit final review"
jq -e '.review.final.head == "bbbbbbb" and (.review.deltas | length) == 1' \
  "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "final review did not preserve the completed predecessor sequence"
cp "$home/state/sample.resource-budget.json" "$home/final-budget.json"
expect_rc 1 run_guard "$home" review sample creator --head bbbbbbb --actor creator-1 --provider codex --family gpt5 --now 1800000100
expect_rc 1 run_guard "$home" review sample critic --head bbbbbbb --actor critic-2 --provider claude --family sonnet --now 1800000101
expect_rc 1 run_guard "$home" review sample failure --head bbbbbbb --actor critic-1 --provider claude --family sonnet --theme theme-a --now 1800000102
expect_rc 1 run_guard "$home" review sample correction --head ccccccc --actor creator-1 --provider codex --family gpt5 --theme theme-a --now 1800000103
expect_rc 1 run_guard "$home" review sample delta --head bbbbbbb --actor critic-1 --provider claude --family sonnet --now 1800000104
expect_rc 1 run_guard "$home" review sample final --head bbbbbbb --actor final-2 --provider claude --family sonnet --now 1800000105
expect_rc 1 run_guard "$home" review sample redesign --head ccccccc --actor creator-2 --provider codex --family gpt5 --theme theme-a --now 1800000106
expect_rc 1 run_guard "$home" review sample rescope --head ccccccc --actor creator-2 --provider codex --family gpt5 --theme theme-a --now 1800000107
cmp -s "$home/final-budget.json" "$home/state/sample.resource-budget.json" \
  || fail "a post-final phase mutated the closed review ledger"
ok "final review requires critic resolution and corrected-head delta evidence"

home=$(make_home review-bound)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
run_guard "$home" start sample --provider codex --snapshot "$home/base.json" --attribution exact \
  --interval 1 --now 1800000000 >/dev/null
[ "$(monitor_count "$home")" = 1 ] || fail "healthy start did not arm the monitor"
# The process-event runner retires a terminal pause result's source itself.
procevent "$home" retire resource-sample >/dev/null
[ "$(monitor_count "$home")" = 0 ] || fail "could not simulate a retired terminal monitor"
review_args='--provider claude --family sonnet'
run_guard "$home" review sample creator --head aaaaaaa --actor creator-1 --provider codex --family gpt5 --now 1800000010 >/dev/null
# shellcheck disable=SC2086
run_guard "$home" review sample critic --head aaaaaaa --actor critic-1 $review_args --now 1800000020 >/dev/null
# shellcheck disable=SC2086
run_guard "$home" review sample failure --head aaaaaaa --actor critic-1 $review_args --theme theme-a --now 1800000030 >/dev/null
run_guard "$home" review sample correction --head bbbbbbb --actor creator-1 --provider codex --family gpt5 --theme theme-a --now 1800000040 >/dev/null
# shellcheck disable=SC2086
expect_rc 1 run_guard "$home" review sample delta --head ccccccc --actor critic-1 $review_args --now 1800000050
# shellcheck disable=SC2086
run_guard "$home" review sample delta --head bbbbbbb --actor critic-1 $review_args --now 1800000050 >/dev/null \
  || fail "focused delta of the correction head was refused"
# shellcheck disable=SC2086
run_guard "$home" review sample delta --head bbbbbbb --actor critic-1 $review_args --now 1800000050 >/dev/null \
  || fail "exact delta replay was not idempotent"
# shellcheck disable=SC2086
expect_rc 1 run_guard "$home" review sample delta --head bbbbbbb --actor critic-3 $review_args --now 1800000055
# shellcheck disable=SC2086
expect_rc 3 run_guard "$home" review sample failure --head bbbbbbb --actor critic-1 $review_args --theme theme-b --now 1800000060
# shellcheck disable=SC2086
run_guard "$home" review sample failure --head bbbbbbb --actor critic-1 $review_args --theme theme-b --now 1800000061 >/dev/null \
  || fail "exact delta failure replay was not idempotent after the circuit breaker"
jq -e '.guard_state == "pause_pending" and .decision_reason == "review_loop_exhausted" and
  .review.post_correction_failures == 1 and (.review.deltas | length) == 1 and
  ([.review.failures[] | select(.stage == "delta")] | length) == 1' \
  "$home/state/sample.resource-budget.json" >/dev/null \
  || fail "an alternating-theme failure after the correction did not stop the loop"
printf 'paused [at=1800000061]: resource guard safe boundary reached\n' >"$home/state/sample.status"
run_guard "$home" pause sample --now 1800000062 >/dev/null
[ "$(monitor_count "$home")" = 0 ] || fail "a captain-held pause armed a monitor"
run_guard "$home" review sample rescope --head ddddddd --actor creator-2 --provider codex --family gpt5 --theme theme-b --now 1800000070 >/dev/null \
  || fail "re-scope did not resolve the exhausted review loop"
jq -e '.guard_state == "active" and .review.post_correction_failures == 0' \
  "$home/state/sample.resource-budget.json" >/dev/null || fail "re-scope did not reset the review bound"
[ "$(monitor_count "$home")" = 1 ] || fail "re-scope back to active did not re-arm exactly one monitor"
ok "delta review is bounded to one pass and any post-correction failure stops alternating-theme loops"

home=$(make_home hostile)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
events="$home/data/resource-events/2027-01.jsonl"
printf '%s\n' "\$(touch $home/pwned)" >>"$events"
expect_rc 1 run_guard "$home" milestone sample --type checks-green --snapshot "$home/base.json" --now 1800000100
[ ! -e "$home/pwned" ] || fail "hostile event input was evaluated as shell"
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = active ] \
  || fail "hostile journal partially published a budget decision"
ok "hostile and corrupt local events are inert and block partial publication"

home=$(make_home forged-event)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
start_guard "$home" "$home/base.json" >/dev/null
run_guard "$home" milestone sample --type checks-green --snapshot "$home/base.json" --now 1800000050 >/dev/null
events="$home/data/resource-events/2027-01.jsonl"
jq -c 'if .kind == "task_baseline" then .kind = "forged" else . end' "$events" >"$home/forged"
cp "$home/forged" "$events"
cp "$home/state/sample.resource-budget.json" "$home/before-forged.json"
expect_rc 1 run_guard "$home" milestone sample --type report-accepted --snapshot "$home/base.json" --now 1800000100
cmp -s "$home/before-forged.json" "$home/state/sample.resource-budget.json" \
  || fail "a forged event with a stale digest was accepted by a later append"
ok "event digests are re-verified whenever the journal changes outside the guard"

home=$(make_home overlay-refusal)
write_snapshot "$home/far.json" 44 2027-01-15T15:00:00Z
expect_rc 3 start_guard "$home" "$home/far.json"
expect_rc 3 run_guard "$home" worker-overlay sample
ok "a non-active budget refuses the guarded worker overlay"

home=$(make_home privacy)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
jq '.providers[0].secret="prompt and credential material" | .providers[0].windows[0].rawTokens=123456' \
  "$home/base.json" >"$home/private.json"
start_guard "$home" "$home/private.json" >/dev/null
if grep -R -E 'prompt and credential material|rawTokens|123456' "$home/state" "$home/data" >/dev/null; then
  fail "minimized guard records retained raw or sensitive telemetry"
fi
ok "guard records minimize telemetry to privacy-safe budget fields"

if [ -n "$TASKS_AXI_BIN" ]; then
  home=$(make_home authority)
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat >"$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
  write_snapshot "$home/burn.json" 65 2030-01-01T00:00:00Z
  start_guard "$home" "$home/base.json" >/dev/null
  expect_rc 3 run_guard "$home" check sample --snapshot "$home/burn.json" --now 1800000100
  printf 'paused [at=1800000101]: resource guard safe boundary reached\n' >"$home/state/sample.status"
  run_guard "$home" pause sample --now 1800000101 >/dev/null
  (cd "$home" && tasks-axi add resource-call "Approve revised resource budget" --kind scout --repo sample >/dev/null)
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold resource-call --reason "revised resource budget needed" >/dev/null
  run_guard "$home" bind-authority sample resource-call >/dev/null
  printf 'resource_budget_points=30\nprivate_reason=continue bounded work\n' >"$home/decision.txt"
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer resource-call --decision-file "$home/decision.txt" >/dev/null
  run_guard "$home" resume sample --authority-task resource-call --decision-file "$home/decision.txt" \
    --snapshot "$home/burn.json" --now 1800000200 >/dev/null || fail "matching captain authority did not resume"
  jq -e '.guard_state == "active" and .revision == 2 and .pause_after_points == 30' \
    "$home/state/sample.resource-budget.json" >/dev/null || fail "captain revised budget was not applied"
  resolution=$(PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" resolution resource-call \
      --lifecycle "$(jq -r .authority_lifecycle "$home/state/sample.resource-pause.json")")
  printf '%s\n' "$resolution" | grep -qx 'mode=answered' \
    || fail "captain hold did not expose a privacy-safe resolution proof"
  if grep -R -F 'private_reason=continue bounded work' "$home/state" "$home/data/resource-events" "$home/data/burn-evaluations" >/dev/null; then
    fail "captain decision text leaked into resource records"
  fi
  printf 'resource_budget_points=31\n' >"$home/drift.txt"
  expect_rc 1 run_guard "$home" resume sample --authority-task resource-call --decision-file "$home/drift.txt" \
    --snapshot "$home/burn.json" --now 1800000300
  ok "resume spends one exact durable captain answer without copying its text"

  home=$(make_home authority-rebaseline)
  write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
  write_snapshot "$home/reset.json" 95 2031-01-01T00:00:00Z
  jq -n '{schemaVersion:5,providers:[{provider:"codex",quotaSemantics:{status:"unknown",effectiveAvailability:[]},windows:[]}]}' \
    >"$home/unavailable.json"
  run_guard "$home" start sample --provider codex --snapshot "$home/base.json" --attribution exact \
    --interval 1 --now 1800000000 >/dev/null
  procevent "$home" retire resource-sample >/dev/null
  expect_rc 3 run_guard "$home" check sample --snapshot "$home/reset.json" --now 1800000100
  printf 'paused [at=1800000101]: resource guard safe boundary reached\n' >"$home/state/sample.status"
  run_guard "$home" pause sample --now 1800000102 >/dev/null
  expect_rc 3 run_guard "$home" check sample --snapshot "$home/reset.json" --now 1800000150
  jq -e '.guard_state == "paused" and .windows[0].reset_continuity == false and
    .windows[0].resets_at == "2030-01-01T00:00:00Z" and .windows[0].burn_points == null' \
    "$home/state/sample.resource-budget.json" >/dev/null \
    || fail "a repeated post-reset check healed the discontinuity or reopened the pause"
  printf 'resource_budget_points=15\n' >"$home/decision.txt"
  captain_answer "$home" reset-call "$home/decision.txt"
  expect_rc 1 run_guard "$home" resume sample --authority-task reset-call --decision-file "$home/decision.txt" \
    --snapshot "$home/unavailable.json" --now 1800000200
  [ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = paused ] \
    || fail "unavailable telemetry established an invented baseline"
  run_guard "$home" resume sample --authority-task reset-call --decision-file "$home/decision.txt" \
    --snapshot "$home/reset.json" --now 1800000300 >/dev/null \
    || fail "an exact captain answer could not resume a reset-discontinuous pause"
  jq -e '.guard_state == "active" and .revision == 2 and .telemetry_status == "known" and
    .baseline_telemetry_reasons == [] and
    .windows[0].baseline_remaining_points == 95 and .windows[0].resets_at == "2031-01-01T00:00:00Z" and
    .windows[0].burn_points == 0 and (.rebaselines | length) == 1 and
    (.rebaselines[0].discarded_reasons | index("window_reset_changed"))' \
    "$home/state/sample.resource-budget.json" >/dev/null \
    || fail "captain resume did not start a fresh versioned baseline from current telemetry"
  [ "$(monitor_count "$home")" = 1 ] || fail "captain resume did not re-arm exactly one monitor"
  ok "a captain answer rebaselines reset-discontinuous telemetry and re-arms one monitor"

  home=$(make_home authority-pre-dispatch)
  write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
  jq -n '{schemaVersion:5,providers:[{provider:"codex",quotaSemantics:{status:"unknown",effectiveAvailability:[]},windows:[]}]}' \
    >"$home/unavailable.json"
  expect_rc 3 run_guard "$home" start sample --provider codex --snapshot "$home/unavailable.json" \
    --attribution exact --no-monitor --now 1800000000
  run_guard "$home" pause sample --pre-dispatch --now 1800000001 >/dev/null \
    || fail "unavailable start telemetry could not finalize before dispatch"
  printf 'resource_budget_points=15\n' >"$home/decision.txt"
  captain_answer "$home" start-call "$home/decision.txt"
  run_guard "$home" resume sample --authority-task start-call --decision-file "$home/decision.txt" \
    --snapshot "$home/base.json" --now 1800000100 >/dev/null \
    || fail "captain authority could not resume a pre-dispatch unavailable-telemetry pause"
  jq -e '.guard_state == "active" and .windows[0].baseline_remaining_points == 80' \
    "$home/state/sample.resource-budget.json" >/dev/null || fail "pre-dispatch captain resume did not establish a baseline"
  run_guard "$home" worker-overlay sample >/dev/null || fail "captain-resumed budget still refused guarded launch"
  ok "a pre-dispatch pause reaches exact captain authority and then permits launch"
else
  ok "captain-authority integration skipped because tasks-axi is unavailable"
fi

cat >"$TMP_ROOT/result" <<'EOF'
resource: sample
status: pause-required
decision: minimized
EOF
[ "$($ADAPTER classify "$TMP_ROOT/result")" = pause-required ] || fail "resource adapter did not classify pause result"
$ADAPTER terminal "$TMP_ROOT/result" || fail "resource adapter did not terminate a pause result"
ok "process-event adapter remains a thin terminal classifier"

home=$(make_home monitor-lifecycle)
write_snapshot "$home/base.json" 80 2030-01-01T00:00:00Z
run_guard "$home" start sample --provider codex --snapshot "$home/base.json" --attribution exact \
  --interval 17 --now 1800000000 >/dev/null || fail "resource monitor registration failed"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$ROOT/bin/fm-procevent.sh" list \
  | grep -Eq '^resource-sample +resource +' || fail "resource monitor was not registered centrally"
run_guard "$home" retire sample >/dev/null || fail "resource monitor retirement failed"
[ "$(jq -r .guard_state "$home/state/sample.resource-budget.json")" = retired ] \
  || fail "resource budget did not retire"
if FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$ROOT/bin/fm-procevent.sh" list | grep -Fq 'resource-sample'; then
  fail "resource monitor registration survived retirement"
fi
find "$home/data/resource-events" -type f -name '*.jsonl' -exec jq -r .kind {} + | grep -qx retire \
  || fail "resource retirement event was not finalized"
before_retire_events=$(find "$home/data/resource-events" -type f -name '*.jsonl' -exec jq -r .event_id {} + | wc -l | tr -d ' ')
run_guard "$home" retire sample >/dev/null || fail "resource retirement retry failed"
after_retire_events=$(find "$home/data/resource-events" -type f -name '*.jsonl' -exec jq -r .event_id {} + | wc -l | tr -d ' ')
[ "$before_retire_events" = "$after_retire_events" ] || fail "resource retirement retry duplicated its event"
ok "resource monitor registration and retirement use the generic process-event lifecycle idempotently"

printf 'all resource guard tests passed\n'
