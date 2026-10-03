#!/usr/bin/env bash
# fm-control.sh switch-model: live Pi session verb against a stubbed pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-switch-lib.sh"
. "$ROOT/bin/fm-wake-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-switch-model)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Reuse the control suite's tmux stub by sourcing its helpers via a thin copy
# of the case layout those tests already proved.
make_tmux_stub() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift; continue ;;
        -t) shift 2; continue ;;
      esac
      if [ "$literal" = 1 ]; then
        printf '%s\n' "$1" >> "$D/literal"
      else
        printf '%s\n' "$1" >> "$D/keys"
      fi
      shift
    done
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    cat "$D/cwd" 2>/dev/null || printf '%s\n' /
    ;;
  list-windows)
    cat "$D/windows" 2>/dev/null || true
    ;;
  list-panes)
    printf '%s\n' "${FM_FAKE_PANE_PID:-$$}"
    ;;
  capture-pane)
    cat "$D/pane" 2>/dev/null || true
    ;;
  has-session) exit 0 ;;
  display-panes|select-window|select-pane|kill-window|kill-pane|new-window|new-session|split-window) ;;
  *) ;;
esac
exit 0
SH
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_QUOTA:-}" ]; then printf '%s\n' "$FM_TEST_QUOTA";
else printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}},{"provider":"zai","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}},{"provider":"xai","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}},{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}}]}'; fi
SH
  cat > "$fb/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/wrong-pi"
exit 1
SH
  chmod +x "$fb/pi"
  chmod +x "$fb/tmux" "$fb/quota-axi"
}

new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

add_task() {
  local dir=$1 id=$2 harness=${3:-pi} kind=${4:-ship}
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=zai/glm-5.3"
    echo "effort=low"
    echo "dispatch_harness=$harness"
    echo "dispatch_model=zai/glm-5.3"
    echo "dispatch_effort=low"
    echo "dispatch_provider=zai"
  } > "$home/state/$id.meta"
  jq -n '{default: [
    {harness:"pi",model:"zai/glm-5.3",effort:"low",provider:"zai"},
    {harness:"pi",model:"zai/glm-5.3",effort:"high",provider:"zai"},
    {harness:"pi",model:"openai-codex/gpt-5.6-luna",effort:"low",provider:"codex"},
    {harness:"pi",model:"openai-codex/gpt-5.6-luna",effort:"medium",provider:"codex"}
  ]}' > "$home/config/crew-dispatch.json"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_control() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SWITCH_POLL=0.01 \
    FM_CONTROL_SWITCH_IDLE_WAIT="${FM_CONTROL_SWITCH_IDLE_WAIT:-1}" \
    FM_CONTROL_SWITCH_ACK_WAIT="${FM_CONTROL_SWITCH_ACK_WAIT:-1}" \
    FM_CONTROL_SWITCH_READY_WAIT="${FM_CONTROL_SWITCH_READY_WAIT:-1}" \
    FM_PI_SWITCH_LISTING="${FM_PI_SWITCH_LISTING:-}" \
    FM_PI_SWITCH_AUTH_JSON="${FM_PI_SWITCH_AUTH_JSON:-}" \
    "$CONTROL" "$@" 2>&1
}

seed_idle() {
  local dir=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") || return 1
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$id" idle \
    --gen "$gen" --source pi-ext --event agent-settled >/dev/null
}

seed_busy() {
  local dir=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id")
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
}

seed_handshake() {
  jq -n --arg gen "$(fm_meta_get "$1/home/state/$2.meta" busy_gen)" \
    '{schema:"fm-pi-switch-model.v1",incarnation:$gen,busy_gen:$gen,session_id:"sess-1"}' \
    > "$(fm_pi_switch_ready_path "$1/home/state" "$2")"
}

write_listing() {
  local dir=$1
  cat > "$dir/listing.txt" <<'EOF'
provider      model          context  max-out  thinking  images
zai           glm-5.3        1M       131.1K   yes       no
openai-codex  gpt-5.6-luna   272K     128K     yes       yes
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
xai           grok-4.5       500K     500K     yes       yes
EOF
  printf '%s' "$dir/listing.txt"
}

write_auth() {
  local dir=$1
  printf '%s\n' '{"status":"ready","provider":"openai-codex","authType":"oauth"}' > "$dir/auth.json"
  printf '%s' "$dir/auth.json"
}

ack_when_requested() {
  local dir=$1 id=$2 status=${3:-applied} model=${4-openai-codex/gpt-5.6-luna} effort=${5-low}
  local req ack
  req=$(fm_pi_switch_req_path "$dir/home/state" "$id")
  ack=$(fm_pi_switch_ack_path "$dir/home/state" "$id")
  (
    i=0
    while [ ! -s "$req" ] && [ "$i" -lt 500 ]; do
      sleep 0.02
      i=$((i + 1))
    done
    [ -s "$req" ] || exit 1
    req_id=$(jq -r '.id' "$req")
    [ -n "$req_id" ] && [ "$req_id" != null ] || exit 1
    jq -nc --arg incarnation "$(jq -r .incarnation "$req")" --arg id "$req_id" --arg status "$status" --arg model "$model" --arg effort "$effort" \
      '{schema:"fm-pi-switch-model.v1",id:$id,incarnation:$incarnation,status:$status,model:$model,effort:$effort,session_id:"sess-1"}' \
      > "$ack"
  ) >/dev/null 2>&1 &
  printf '%s' "$!"
}

test_switch_model_is_a_control_verb() {
  local dir out rc
  dir=$(new_case verbs)
  add_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  out=$(run_control "$dir" t1 restart); rc=$?
  expect_code 2 "$rc" "unknown verb should be a usage error"
  assert_contains "$out" "switch-model" "the allowlist should name switch-model"
  pass "switch-model is a listed control verb"
}

test_non_pi_harness_is_refused() {
  local dir out rc
  dir=$(new_case claude)
  add_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "claude must refuse a live Pi switch"
  assert_contains "$out" "Pi session operation" "the refusal should name the Pi-only contract"
  pass "switch-model refuses a non-Pi harness"
}

test_secondmate_is_refused() {
  local dir out rc
  dir=$(new_case mate)
  add_task "$dir" t1 pi secondmate
  printf 'pi' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a secondmate must refuse a live switch"
  assert_contains "$out" "secondmate" "the refusal should name the task kind"
  pass "switch-model refuses a secondmate"
}

test_unsupported_model_is_refused() {
  local dir out rc listing
  dir=$(new_case nosuch)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  seed_idle "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" run_control "$dir" t1 switch-model --model openai-codex/not-a-model); rc=$?
  expect_code 1 "$rc" "an unlisted model must refuse"
  assert_contains "$out" "does not list" "the refusal should cite the catalog"
  [ ! -f "$(fm_pi_switch_req_path "$dir/home/state" t1)" ] \
    || fail "an unlisted model must not publish a request"
  pass "switch-model refuses an unsupported model before publishing"
}

test_busy_worker_is_deferred_not_interrupted() {
  local dir out rc listing auth
  dir=$(new_case busy)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_busy "$dir" t1
  seed_handshake "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_IDLE_WAIT=0.05 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a busy worker must not switch"
  assert_contains "$out" "idle checkpoint" "the refusal should demand idle"
  [ -z "$(cat "$dir/fake/keys")" ] || fail "a busy switch must send no interrupt key"
  pass "switch-model defers a busy worker instead of interrupting"
}

test_same_provider_switch_confirms_and_preserves_dispatch() {
  local dir out rc listing auth waiter meta
  dir=$(new_case same)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  cat > "$dir/auth.json" <<'EOF'
{"status":"ready","provider":"zai","authType":"api_key"}
EOF
  auth="$dir/auth.json"
  seed_idle "$dir" t1
  seed_handshake "$dir" t1
  # Same-provider: stay on zai, raise effort.
  waiter=$(ack_when_requested "$dir" t1 applied zai/glm-5.3 high)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --effort high); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "a confirmed same-provider switch should succeed: $out"
  assert_contains "$out" "switched-model t1" "the outcome should name the verb"
  assert_contains "$out" "model=zai/glm-5.3" "readback model should be recorded"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail "model= was not confirmed"
  [ "$(fm_meta_get "$meta" effort)" = high ] || fail "effort= was not confirmed"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "dispatch snapshot was overwritten"
  [ "$(fm_meta_get "$meta" dispatch_effort)" = low ] || fail "original effort snapshot was lost"
  grep -q 'status=applied' "$(fm_pi_switch_log_path "$dir/home/state" t1)" \
    || fail "history did not record the applied switch"
  pass "same-provider switch confirms runtime readback and keeps the dispatch snapshot"
}

test_cross_provider_switch_updates_runtime_only() {
  local dir out rc listing auth waiter meta
  dir=$(new_case cross)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  seed_handshake "$dir" t1
  waiter=$(ack_when_requested "$dir" t1 applied openai-codex/gpt-5.6-luna low)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --effort low); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "a confirmed cross-provider switch should succeed: $out"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail "runtime model was not updated"
  [ "$(fm_meta_get "$meta" account_provider)" = openai-codex ] || fail "account_provider was not updated"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "original dispatch model was lost"
  [ "$(fm_meta_get "$meta" dispatch_provider)" = zai ] || fail "original dispatch provider was lost"
  pass "cross-provider switch updates runtime metadata and preserves dispatch_*"
}

test_failed_change_without_readback_keeps_old_model() {
  local dir out rc listing auth waiter meta
  dir=$(new_case fail)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  seed_handshake "$dir" t1
  waiter=$(ack_when_requested "$dir" t1 failed zai/glm-5.3 low)
  # Override ack to omit a different model so metadata stays put.
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 1 "$rc" "a failed switch should refuse"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail "failed switch must keep the old model"
  pass "a failed switch without a new readback keeps the recorded model"
}

test_partial_success_reconciles_to_readback() {
  local dir out rc listing auth waiter meta
  dir=$(new_case partial)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  seed_handshake "$dir" t1
  waiter=$(ack_when_requested "$dir" t1 refused openai-codex/gpt-5.6-luna low)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --effort medium); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 1 "$rc" "a partial switch should refuse overall"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] \
    || fail "partial success must reconcile metadata to the runtime readback"
  pass "partial success reconciles metadata to the runtime model"
}

test_restart_recovery_reads_last_confirmed_profile() {
  local dir meta
  dir=$(new_case recover)
  add_task "$dir" t1 pi
  meta="$dir/home/state/t1.meta"
  fm_pi_switch_confirm_meta "$meta" openai-codex/gpt-5.6-luna medium openai-codex
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail "confirmed model missing"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "dispatch snapshot missing after confirm"
  [ "$(fm_meta_get "$meta" effort)" = medium ] || fail "confirmed effort missing"
  [ -z "$(fm_meta_get "$meta" model_runtime)" ] || fail "redundant runtime model was published"
  [ -z "$(fm_meta_get "$meta" model_runtime_ts)" ] || fail "redundant runtime timestamp was published"
  pass "recovery reads the last confirmed profile beside the original dispatch snapshot"
}

test_missing_handshake_refuses() {
  local dir out rc listing auth
  dir=$(new_case ready)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_READY_WAIT=0.05 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a worker without the handshake must refuse"
  assert_contains "$out" "handshake" "the refusal should name the missing session handshake"
  pass "switch-model refuses when the Pi session handshake is missing"
}

test_harness_flag_stays_relaunch_only() {
  local dir out rc
  dir=$(new_case flags)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --harness grok --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "--harness must not apply to switch-model"
  assert_contains "$out" "relaunch" "the refusal should point at relaunch"
  pass "switch-model refuses --harness rather than changing runtime"
}

test_timeout_and_late_ack() {
  local dir out rc listing auth req meta
  dir=$(new_case timeout)
  add_task "$dir" t1 pi
  printf pi > "$dir/fake/command"
  listing=$(write_listing "$dir"); auth=$(write_auth "$dir")
  seed_idle "$dir" t1; seed_handshake "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=0.05 run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna)
  rc=$?
  expect_code 1 "$rc" 'missing acknowledgement must time out'
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = unknown ] || fail 'timeout must record runtime unknown'
  req="$dir/home/state/t1.model-switch.req"
  jq -e '.cancelled == true' "$req" >/dev/null || fail 'timeout must cancel the request'
  jq '. + {status:"partial",model:"zai/glm-5.3",effort:"high"}' "$req" > "$dir/home/state/t1.model-switch.ack"
  fm_pi_switch_reconcile "$dir/home/state" t1 "$meta" || fail 'late acknowledgement did not reconcile'
  [ "$(fm_meta_get "$meta" effort)" = high ] || fail 'same-model partial effort must reconcile'
  [ "$(fm_meta_get "$meta" account_provider)" = zai ] || fail 'provider must derive from readback'
  [ ! -e "$req" ] || fail 'reconciled request must retire'
  pass 'timeout cancellation and late partial readback reconcile'
}

test_exhausted_quota_refuses() {
  local dir out rc listing auth
  dir=$(new_case exhausted)
  add_task "$dir" t1 pi
  printf pi > "$dir/fake/command"
  listing=$(write_listing "$dir"); auth=$(write_auth "$dir")
  seed_idle "$dir" t1; seed_handshake "$dir" t1
  out=$(FM_TEST_QUOTA='{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}' \
    FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna)
  rc=$?
  expect_code 1 "$rc" 'direct calls must reject exhausted quota'
  assert_contains "$out" 'quota exhausted' 'quota veto must explain exhaustion'
  [ ! -e "$dir/home/state/t1.model-switch.req" ] || fail 'exhausted route published a request'
  pass 'direct switch refuses exhausted quota before publication'
}

test_unmeasured_quota_needs_explicit_confirmation() {
  local dir out rc listing auth waiter meta
  local unmeasured='{"schemaVersion":5,"providers":[]}'
  dir=$(new_case unmeasured)
  add_task "$dir" t1 pi
  printf pi > "$dir/fake/command"
  listing=$(write_listing "$dir"); auth=$(write_auth "$dir")
  seed_idle "$dir" t1; seed_handshake "$dir" t1
  out=$(FM_TEST_QUOTA="$unmeasured" FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth"     run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna)
  rc=$?
  expect_code 1 "$rc" 'unmeasured quota must not silently authorize a direct switch'
  assert_contains "$out" 'explicit supervisor confirmation required' 'refusal must ask for supervisor confirmation'
  [ ! -e "$dir/home/state/t1.model-switch.req" ] || fail 'unconfirmed unmeasured route published a request'
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail 'refusal must leave the confirmed model untouched'
  waiter=$(ack_when_requested "$dir" t1 applied openai-codex/gpt-5.6-luna low)
  out=$(FM_TEST_QUOTA="$unmeasured" FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth"     FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --confirm-unmeasured-quota)
  rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "explicit confirmation must allow an unmeasured eligible destination: $out"
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail 'confirmed unmeasured switch was not recorded'
  out=$(run_control "$dir" t1 relaunch --confirm-unmeasured-quota --note x); rc=$?
  expect_code 1 "$rc" '--confirm-unmeasured-quota must be rejected outside switch-model'
  assert_contains "$out" "applies to 'switch-model' only" 'flag scope refusal must be explicit'
  pass 'unmeasured quota requires explicit confirmation and known exhaustion still refuses'
}

test_unconfirmed_selection() {
  local dir out listing auth waiter meta
  dir=$(new_case unknown)
  add_task "$dir" t1 pi
  printf pi > "$dir/fake/command"
  listing=$(write_listing "$dir"); auth=$(write_auth "$dir")
  seed_idle "$dir" t1; seed_handshake "$dir" t1
  waiter=$(ack_when_requested "$dir" t1 applied openai-codex/gpt-5.6-luna '')
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna)
  expect_code 1 "$?" 'missing effort must not report success'
  wait "$waiter" 2>/dev/null || true
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" effort)" = unknown ] || fail 'missing effort must remain unknown'
  assert_contains "$out" 'not confirmed' 'unconfirmed effort must explain refusal'
  pass 'applied acknowledgements cannot substitute an unconfirmed effort'
}

test_metadata_lock_preserves_concurrent_fields() {
  local dir meta lock waiter
  dir=$(new_case lock)
  add_task "$dir" t1 pi
  meta="$dir/home/state/t1.meta"
  lock=$(fm_meta_lock_path "$meta")
  fm_lock_acquire_wait "$lock" || fail 'could not acquire metadata lock'
  bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-pi-switch-lib.sh";
    fm_pi_switch_confirm_meta "$2" openai-codex/gpt-5.6-luna high' _ "$ROOT" "$meta" &
  waiter=$!
  printf 'x_request=concurrent-relay\n' >> "$meta"
  fm_lock_release "$lock"
  wait "$waiter" || fail 'metadata confirmation failed'
  [ "$(fm_meta_get "$meta" x_request)" = concurrent-relay ] || fail 'concurrent field lost'
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail 'runtime confirmation lost'
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail 'dispatch snapshot lost'
  pass 'locked metadata confirmation preserves concurrent fields and dispatch snapshot'
}

test_signed_runtime_preflight() {
  local dir listing auth out waiter rc
  dir=$(new_case signed)
  add_task "$dir" t1 pi-signed
  jq '.default |= map(.harness="pi-signed")' "$dir/home/config/crew-dispatch.json" > "$dir/config.json"
  mv "$dir/config.json" "$dir/home/config/crew-dispatch.json"
  printf pi-signed > "$dir/fake/command"
  listing=$(write_listing "$dir"); auth=$(write_auth "$dir")
  cp "$listing" "$dir/fake/catalog"
  cp "$auth" "$dir/fake/auth"
  cat > "$dir/fakebin/pi-signed" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/signed-calls"
case "$1" in
  --list-models) cat "$FM_FAKE_DIR/catalog" ;;
  auth) cat "$FM_FAKE_DIR/auth" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/pi-signed"
  seed_idle "$dir" t1; seed_handshake "$dir" t1
  waiter=$(ack_when_requested "$dir" t1 applied openai-codex/gpt-5.6-luna low)
  out=$(FM_PI_SWITCH_LISTING='' FM_PI_SWITCH_AUTH_JSON='' FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --effort low)
  rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "pi-signed must use its own preflight executable: $out"
  [ ! -e "$dir/fake/wrong-pi" ] || fail 'signed worker used ordinary pi'
  assert_contains "$(cat "$dir/fake/signed-calls")" --list-models 'signed catalog must be queried'
  assert_contains "$(cat "$dir/fake/signed-calls")" 'auth check' 'signed auth must be queried'
  pass 'pi-signed checks catalog and credentials through its recorded executable'
}

test_signed_runtime_preflight

test_unconfirmed_selection
test_metadata_lock_preserves_concurrent_fields

test_timeout_and_late_ack
test_exhausted_quota_refuses
test_unmeasured_quota_needs_explicit_confirmation

test_switch_model_is_a_control_verb
test_non_pi_harness_is_refused
test_secondmate_is_refused
test_unsupported_model_is_refused
test_busy_worker_is_deferred_not_interrupted
test_same_provider_switch_confirms_and_preserves_dispatch
test_cross_provider_switch_updates_runtime_only
test_failed_change_without_readback_keeps_old_model
test_partial_success_reconciles_to_readback
test_restart_recovery_reads_last_confirmed_profile
test_missing_handshake_refuses
test_harness_flag_stays_relaunch_only
