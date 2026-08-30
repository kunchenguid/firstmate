#!/usr/bin/env bash
# Deterministic Codex queue-doorbell coverage.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

PRIMARY="$ROOT/bin/fm-codex-primary.sh"
QUEUE="$ROOT/bin/fm-codex-queue-wake.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-queue-wake)
UUID_A=11111111-1111-4111-8111-111111111111
UUID_B=22222222-2222-4222-8222-222222222222

# Source present_handle_wake behind the daemon's source-safe boundary.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

hash_text() { # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

make_case() { # <name>
  local dir="$TMP_ROOT/$1" owner_identity home_hash identity_hash
  mkdir -p "$dir/state" "$dir/fakebin"
  owner_identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$$")
  identity_hash=$(hash_text "$owner_identity")
  home_hash=$(hash_text "$dir")
  printf '%s\n' "$$" > "$dir/state/.lock"
  printf 'fm-session-lock-generation-v1\n%s\ngen-a\n%s\n' "$$" "$identity_hash" > "$dir/state/.lock-generation"
  printf 'pending:downtime:recovery-a\n' > "$dir/state/.watcher-down"
  printf '1\t7\tsignal\tcrew.status\tdone: ready\n' > "$dir/state/.wake-queue"
  printf '%s\n' "$dir"
}

bind_primary() { # <dir> <uuid> <source> [lifecycle-uuid]
  local dir=$1 uuid=$2 source=${3:-startup} lifecycle=${4:-}
  CODEX_THREAD_ID="$uuid" FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" bind "$source" "$lifecycle"
}

write_fake_codex() { # <dir> <mode>
  local dir=$1 mode=$2
  cat > "$dir/fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  queue)
    if [ "${2:-}" = --help ]; then
      [ "${FM_FAKE_MODE:-}" != unsupported ] || { printf 'old help\n'; exit 0; }
      printf 'Usage: codex queue --thread THREAD --message TEXT\n'
      exit 0
    fi
    printf '%s\n' "$*" >> "${FM_FAKE_LOG:?}"
    case "${FM_FAKE_MODE:-ok}" in
      ok) printf 'accepted fake-id\n'; exit 0 ;;
      reject) exit 9 ;;
      timeout) sleep 5; exit 0 ;;
    esac
    ;;
esac
exit 2
SH
  chmod +x "$dir/fakebin/codex"
  printf '%s\n' "$dir/fakebin/codex"
}

deliver() { # <dir> [mode]
  local dir=$1 mode=${2:-ok} bin
  bin=$(write_fake_codex "$dir" "$mode")
  FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CODEX_QUEUE_BIN="$bin" FM_FAKE_MODE="$mode" FM_FAKE_LOG="$dir/queue.log" FM_CODEX_QUEUE_TIMEOUT=1 \
    "$QUEUE" deliver
}

present_with_fake_backend() { # <dir> <queue-mode> <composer-state> <fallback-log> <reason>...
  local dir=$1 queue_mode=$2 composer_state=$3 fallback_log=$4 queue_bin reason
  shift 4
  queue_bin="$dir/fakebin/codex"
  [ "$queue_mode" != missing ] || queue_bin="$dir/not-there"
  (
    LOG="$dir/present.log"
    export FM_DAEMON_PRIMARY_HARNESS=codex FM_SUPERVISOR_BACKEND=tmux \
      FM_SUPERVISOR_TARGET=fixture FM_SUPERVISE_PRESENT=1
    export FM_CODEX_QUEUE_BIN="$queue_bin" FM_FAKE_MODE="$queue_mode" \
      FM_FAKE_LOG="$dir/queue.log"
    export FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
      FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state"
    export FM_FAKE_COMPOSER_STATE="$composer_state" FM_FAKE_FALLBACK_LOG="$fallback_log"
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf 'idle'; }
    fm_backend_capture() { printf 'idle prompt\n'; }
    fm_backend_composer_state() { printf '%s' "$FM_FAKE_COMPOSER_STATE"; }
    supervisor_target_home_ok() { return 0; }
    supervisor_target_login_shell() { return 1; }
    fm_backend_send_text_submit() { printf '%s\n' "$3" >> "$FM_FAKE_FALLBACK_LOG"; printf 'empty'; }
    for reason in "$@"; do
      present_handle_wake "$reason" "$dir/state"
    done
  )
}

test_authoritative_binding_and_stale_rejection() {
  local dir out
  dir=$(make_case binding)
  env -u CODEX_THREAD_ID FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" bind startup "$UUID_A" \
    || fail "authoritative SessionStart identity did not publish without a shell fallback"
  bind_primary "$dir" "$UUID_A" startup "$UUID_A" \
    || fail "matching SessionStart and native-environment identities did not publish"
  out=$(FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" validate) \
    || fail "valid binding did not validate"
  [ "$out" = "$UUID_A"$'\t'gen-a ] || fail "binding returned the wrong UUID/generation: $out"
  sed -i 's/^thread_uuid=.*/thread_uuid=not-a-uuid/' "$dir/state/.codex-primary-binding"
  if FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" validate >/dev/null 2>&1; then
    fail "invalid UUID passed binding validation"
  fi
  bind_primary "$dir" "$UUID_A" startup || fail "binding did not recover after invalid UUID"
  sed -i 's/^owner_identity_sha256=.*/owner_identity_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$dir/state/.codex-primary-binding"
  if FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" validate >/dev/null 2>&1; then
    fail "mismatched primary process identity passed binding validation"
  fi
  bind_primary "$dir" "$UUID_A" startup || fail "binding did not recover after process identity mismatch"
  sed -i 's/^gen-a$/gen-stale/' "$dir/state/.lock-generation"
  if FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" validate >/dev/null 2>&1; then
    fail "mismatched lock generation passed binding validation"
  fi
  if CODEX_THREAD_ID=not-a-uuid FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$PRIMARY" bind startup >/dev/null 2>&1; then
    fail "invalid native CODEX_THREAD_ID was accepted for binding"
  fi
  if bind_primary "$dir" "$UUID_A" resume "$UUID_B" >/dev/null 2>&1; then
    fail "mismatched SessionStart and native-environment identities were accepted"
  fi
  pass "Codex lifecycle and native thread identities create an authoritative binding and stale/mismatched identities fail closed"
}

test_resume_rebind_and_compact_stability() {
  local dir before after
  dir=$(make_case rebind)
  bind_primary "$dir" "$UUID_A" startup || fail "startup binding failed"
  before=$(cat "$dir/state/.codex-primary-binding")
  bind_primary "$dir" "$UUID_A" compact || fail "compact binding refresh failed"
  after=$(cat "$dir/state/.codex-primary-binding")
  assert_contains "$after" "thread_uuid=$UUID_A" "compact changed the stable thread identity"
  assert_contains "$after" "session_generation=gen-a" "compact changed the stable session generation"
  printf 'fm-codex-queue-outstanding-v1\nthread_uuid=%s\nsession_generation=gen-a\nrecovery_generation=recovery-a\nwake_sequence=7\nstatus=accepted\n' \
    "$UUID_A" > "$dir/state/.codex-queue-outstanding"
  printf 'fm-codex-present-fallback-v1\nthread_uuid=%s\nsession_generation=gen-a\nrecovery_generation=recovery-a\nstatus=accepted\n' \
    "$UUID_A" > "$dir/state/.codex-present-fallback-outstanding"
  bind_primary "$dir" "$UUID_B" resume || fail "resume rebind failed"
  assert_contains "$(cat "$dir/state/.codex-primary-binding")" "thread_uuid=$UUID_B" "resume did not atomically replace the thread"
  [ ! -e "$dir/state/.codex-queue-outstanding" ] \
    || fail "resume rebind retained a native delivery record for the old thread"
  [ ! -e "$dir/state/.codex-present-fallback-outstanding" ] \
    || fail "resume rebind retained a terminal delivery record for the old thread"
  [ -n "$before" ] || fail "startup binding was empty"
  pass "compact preserves stable identity while resume/restart can authoritatively rebind"
}

test_stale_outstanding_thread_does_not_coalesce() {
  local dir result count
  dir=$(make_case stale-outstanding-thread)
  bind_primary "$dir" "$UUID_A" startup || fail "stale outstanding thread binding setup failed"
  printf 'fm-codex-queue-outstanding-v1\nthread_uuid=%s\nsession_generation=gen-a\nrecovery_generation=recovery-a\nwake_sequence=7\nstatus=accepted\n' \
    "$UUID_B" > "$dir/state/.codex-queue-outstanding"
  result=$(deliver "$dir" ok) || fail "stale outstanding thread blocked delivery to the validated thread"
  [ "$result" = accepted ] || fail "stale outstanding thread was coalesced instead of replaced: $result"
  count=$(wc -l < "$dir/queue.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "stale outstanding thread did not produce exactly one corrected queue call"
  assert_contains "$(cat "$dir/queue.log")" "--thread $UUID_A" \
    "replacement queue call did not target the validated thread"
  pass "an outstanding record for another thread cannot suppress delivery to the validated primary"
}

test_idle_busy_and_burst_coalescing() {
  local dir first second count prompt
  dir=$(make_case coalesce)
  bind_primary "$dir" "$UUID_A" startup || fail "binding setup failed"
  first=$(deliver "$dir" ok) || fail "idle queue delivery failed"
  [ "$first" = accepted ] || fail "first queue delivery was not accepted: $first"
  printf '2\t8\tsignal\tcrew2.status\tdone: also ready\n' >> "$dir/state/.wake-queue"
  second=$(deliver "$dir" ok) || fail "busy/burst queue delivery failed"
  [ "$second" = coalesced ] || fail "busy/burst delivery did not coalesce: $second"
  count=$(wc -l < "$dir/queue.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "burst queued $count model turns instead of one"
  prompt=$(cat "$dir/queue.log")
  assert_contains "$prompt" "--thread $UUID_A" "queue adapter did not target the validated UUID"
  assert_contains "$prompt" "FIRSTMATE_OP: v1 watcher:" "queue adapter did not use a typed operational prompt"
  assert_contains "$prompt" "Drain durable wakes with bin/fm-wake-drain.sh" \
    "queue prompt omitted the durable drain duty"
  assert_contains "$prompt" "run the printed post-handling acknowledgement" \
    "queue prompt omitted the post-handling acknowledgement duty"
  assert_contains "$prompt" "preserve watcher continuity per the emitted supervision protocol" \
    "queue prompt omitted the supervision-continuity duty"
  assert_contains "$prompt" "give the captain a project-facing outcome" \
    "queue prompt omitted the captain-facing project outcome duty"
  assert_contains "$prompt" "re-anchor to the preceding captain conversation" \
    "queue prompt omitted the conversational re-anchor duty"
  assert_contains "$prompt" "resume or explicitly close any captain goal that remained active" \
    "queue prompt omitted the active-goal resume-or-close duty"
  assert_contains "$prompt" "do not end on internal Watcher mechanics alone" \
    "queue prompt allowed an internal-mechanics-only ending"
  assert_not_contains "$prompt" "crew.status" "queue prompt leaked the event payload"
  [ -s "$dir/state/.wake-queue" ] || fail "queue acceptance acknowledged durable wakes"
  pass "idle delivery emits the full handling and conversational contract while busy/burst delivery serializes behind one outstanding doorbell"
}

test_failures_preserve_wakes_and_fallback_safely() {
  local mode dir fallback invalid_fallback
  for mode in reject timeout unsupported; do
    dir=$(make_case "failure-$mode")
    bind_primary "$dir" "$UUID_A" startup || fail "$mode binding setup failed"
    if deliver "$dir" "$mode" >/dev/null 2>&1; then
      fail "$mode queue failure was reported as delivered"
    fi
    [ -s "$dir/state/.wake-queue" ] || fail "$mode queue failure consumed durable wakes"
  done
  dir=$(make_case missing)
  bind_primary "$dir" "$UUID_A" startup || fail "missing-command binding setup failed"
  if FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CODEX_QUEUE_BIN="$dir/not-there" "$QUEUE" deliver >/dev/null 2>&1; then
    fail "missing codex command was reported as delivered"
  fi
  [ -s "$dir/state/.wake-queue" ] || fail "missing command consumed durable wakes"

  dir=$(make_case invalid-binding-fallback)
  bind_primary "$dir" "$UUID_A" startup || fail "invalid-binding fallback setup failed"
  sed -i 's/^thread_uuid=.*/thread_uuid=not-a-uuid/' "$dir/state/.codex-primary-binding"
  write_fake_codex "$dir" ok >/dev/null
  invalid_fallback="$dir/invalid-fallback.txt"
  present_with_fake_backend "$dir" ok empty "$invalid_fallback" "signal: invalid binding"
  [ -s "$invalid_fallback" ] || fail "invalid UUID binding did not use terminal fallback"
  [ ! -e "$dir/queue.log" ] || fail "invalid UUID binding reached the native queue command"
  [ -s "$dir/state/.wake-queue" ] || fail "invalid UUID fallback consumed durable wakes"

  fallback="$dir/fallback.txt"
  present_with_fake_backend "$dir" missing pending "$fallback" "signal: private payload"
  [ ! -e "$fallback" ] || fail "terminal fallback typed into a pending user composer"
  [ -s "$dir/state/.wake-queue" ] || fail "unsafe fallback path consumed durable wakes"
  pass "queue rejection, timeout, unsupported/missing command, and pending-composer fallback preserve durable wakes"
}

test_ambiguous_submission_is_idempotent_until_ack() {
  local dir count
  dir=$(make_case ambiguous)
  bind_primary "$dir" "$UUID_A" startup || fail "ambiguous binding setup failed"
  deliver "$dir" timeout >/dev/null 2>&1 || true
  [ "$(sed -n 's/^status=//p' "$dir/state/.codex-queue-outstanding")" = ambiguous ] \
    || fail "timeout did not record ambiguous acceptance"
  deliver "$dir" ok >/dev/null || fail "ambiguous retry did not coalesce"
  count=$(wc -l < "$dir/queue.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "ambiguous acceptance was resubmitted ($count queue calls)"
  FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" "$QUEUE" acknowledge 7 "$UUID_A" gen-a recovery-a
  [ ! -e "$dir/state/.codex-queue-outstanding" ] || fail "post-handling acknowledgement did not retire the doorbell record"
  [ -s "$dir/state/.wake-queue" ] || fail "doorbell acknowledgement consumed the durable queue itself"
  pass "ambiguous acceptance is idempotent and only the handling acknowledgement retires its delivery record"
}

test_interrupted_submission_falls_back_without_native_retry() {
  local dir fallback
  dir=$(make_case interrupted)
  bind_primary "$dir" "$UUID_A" startup || fail "interrupted binding setup failed"
  printf 'fm-codex-queue-outstanding-v1\nthread_uuid=%s\nsession_generation=gen-a\nrecovery_generation=recovery-a\nwake_sequence=7\nstatus=submitting\n' \
    "$UUID_A" > "$dir/state/.codex-queue-outstanding"
  write_fake_codex "$dir" ok >/dev/null
  fallback="$dir/fallback.log"
  present_with_fake_backend "$dir" ok empty "$fallback" "signal: interrupted submission"
  [ ! -e "$dir/queue.log" ] || fail "interrupted submission was retried through the ambiguous native path"
  [ "$(wc -l < "$fallback" | tr -d ' ')" = 1 ] || fail "interrupted submission did not use one safe terminal fallback"
  [ "$(sed -n 's/^status=//p' "$dir/state/.codex-queue-outstanding")" = submitting ] \
    || fail "interrupted submission record was not retained until handling acknowledgement"
  [ -s "$dir/state/.wake-queue" ] || fail "interrupted submission fallback consumed durable wakes"
  pass "interrupted queue submission suppresses a duplicate native call and falls back safely"
}

test_rejection_fallback_coalesces_and_diagnostics_rate_limit() {
  local dir fallback count
  dir=$(make_case reject-fallback)
  bind_primary "$dir" "$UUID_A" startup || fail "rejection fallback binding setup failed"
  write_fake_codex "$dir" reject >/dev/null
  printf 'fm-codex-present-fallback-v1\nthread_uuid=%s\nsession_generation=gen-a\nrecovery_generation=recovery-a\nstatus=accepted\n' \
    "$UUID_B" > "$dir/state/.codex-present-fallback-outstanding"
  fallback="$dir/fallback.log"
  present_with_fake_backend "$dir" reject empty "$fallback" \
    "signal: first" "signal: duplicate"
  count=$(wc -l < "$fallback" | tr -d ' ')
  [ "$count" = 1 ] || fail "queue rejection burst or stale-thread record injected $count terminal fallbacks instead of one"
  [ "$(grep -c 'native queue rejected' "$dir/present.log" 2>/dev/null || true)" = 1 ] \
    || fail "repeated queue rejection was not rate-limited to one diagnostic"
  [ -s "$dir/state/.wake-queue" ] || fail "rejection/fallback coalescing consumed durable wakes"
  pass "queue rejection bursts coalesce one safe fallback and rate-limit their diagnostic"
}

test_stop_guard_does_not_queue_recursively() {
  local dir out status=0
  dir=$(make_case stop-loop)
  mkdir -p "$dir/bin" "$dir/.codex"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-hook-host-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/"
  printf '# primary\n' > "$dir/AGENTS.md"
  printf '{"hooks":{"Stop":[{"hooks":[{"command":"fm-turnend-guard.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
  : > "$dir/state/task.meta"
  out=$(printf '{"session_id":"%s","stop_hook_active":true}\n' "$UUID_A" \
    | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-turnend-guard.sh" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "queue-triggered Stop was not loop-guarded: $out"
  [ ! -e "$dir/queue.log" ] || fail "Stop guard recursively submitted another queue turn"
  pass "stop_hook_active prevents a queue-triggered turn from recursively waking itself"
}

test_end_to_end_doorbell_and_ack_boundary() {
  local dir drain_err ack sequence generation
  dir=$(make_case e2e)
  bind_primary "$dir" "$UUID_A" startup || fail "e2e binding setup failed"
  deliver "$dir" ok >/dev/null || fail "e2e doorbell failed"
  drain="$dir/drain.out"; drain_err="$dir/drain.err"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" > "$drain" 2> "$drain_err" || fail "e2e drain presentation failed"
  assert_contains "$(cat "$drain")" "done: ready" "e2e drain omitted the done signal"
  ack=$(grep '^WAKE_ACK_REQUIRED:' "$drain_err" | tail -1)
  sequence=$(printf '%s\n' "$ack" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  generation=$(printf '%s\n' "$ack" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "e2e drain omitted its acknowledgement command"
  FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" \
    >/dev/null 2>&1 || fail "e2e acknowledgement failed"
  [ ! -s "$dir/state/.wake-queue" ] || fail "e2e acknowledgement left the handled row queued"
  [ ! -e "$dir/state/.codex-queue-outstanding" ] || fail "e2e acknowledgement left the doorbell outstanding"
  pass "done signal flows through durable row, queue doorbell, drain/report, and post-handling acknowledgement"
}

test_ack_requeues_same_generation_successor() {
  local dir drain_err ack sequence generation count outstanding_sequence
  dir=$(make_case same-generation-successor)
  bind_primary "$dir" "$UUID_A" startup || fail "same-generation successor binding setup failed"
  deliver "$dir" ok >/dev/null || fail "same-generation initial doorbell failed"
  drain_err="$dir/drain.err"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$drain_err" \
    || fail "same-generation drain presentation failed"
  ack=$(grep '^WAKE_ACK_REQUIRED:' "$drain_err" | tail -1)
  sequence=$(printf '%s\n' "$ack" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  generation=$(printf '%s\n' "$ack" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
  [ "$sequence" = 7 ] && [ "$generation" = recovery-a ] \
    || fail "same-generation drain returned the wrong acknowledgement boundary: $ack"
  printf '2\t8\tsignal\tcrew2.status\tdone: arrived during handling\n' >> "$dir/state/.wake-queue"
  FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE=$$ \
    FM_CODEX_QUEUE_BIN="$dir/fakebin/codex" FM_FAKE_MODE=ok FM_FAKE_LOG="$dir/queue.log" \
    FM_CODEX_QUEUE_ONLY=1 FM_DAEMON_PRIMARY_HARNESS=codex \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" \
    >/dev/null 2>&1 || fail "same-generation acknowledgement failed"
  assert_contains "$(cat "$dir/state/.wake-queue")" $'\t8\t' \
    "same-generation acknowledgement consumed the row beyond its boundary"
  count=$(wc -l < "$dir/queue.log" | tr -d ' ')
  [ "$count" = 2 ] || fail "same-generation survivor received $count total queue calls instead of two"
  outstanding_sequence=$(sed -n 's/^wake_sequence=//p' "$dir/state/.codex-queue-outstanding")
  [ "$outstanding_sequence" = 8 ] \
    || fail "successor doorbell did not advance its high-water mark to row 8: $outstanding_sequence"
  pass "ack-through 7 preserves and re-delivers same-generation row 8 with a new high-water mark"
}

test_authoritative_binding_and_stale_rejection
test_resume_rebind_and_compact_stability
test_stale_outstanding_thread_does_not_coalesce
test_idle_busy_and_burst_coalescing
test_failures_preserve_wakes_and_fallback_safely
test_ambiguous_submission_is_idempotent_until_ack
test_interrupted_submission_falls_back_without_native_retry
test_rejection_fallback_coalesces_and_diagnostics_rate_limit
test_stop_guard_does_not_queue_recursively
test_end_to_end_doorbell_and_ack_boundary
test_ack_requeues_same_generation_successor
