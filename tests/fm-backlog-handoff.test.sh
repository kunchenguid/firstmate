#!/usr/bin/env bash
# tests/fm-backlog-handoff.test.sh - full item-block handoff (header + indented body).
#
# The happy single-line path and broad safety refusals live in the secondmate
# lifecycle and safety suites. This file owns focused delegated-handoff
# regressions: the multi-line body contract and registry home parsing edge cases.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

# The move is delegated to `tasks-axi mv`, so this suite exercises the real
# binary. Skip cleanly when it is absent (matching the backend smoke suites).
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated handoff path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff)
HANDOFF_FAKEBIN=$(make_fake_tmux "$TMP_ROOT/default-fake")
export PATH="$HANDOFF_FAKEBIN:$PATH"
export FM_FAKE_TMUX_WINDOW='firstmate:fm-design'
export FM_FAKE_TMUX_LOG="$TMP_ROOT/default-tmux.log"
export FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/default-fake/pane.txt"
export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1

setup_homes() {
  local home=$1 subhome=$2 id=${3:-design}
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" "$id"
  local sub_abs
  sub_abs=$(cd "$subhome" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
  cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
kind=secondmate
harness=claude
backend=tmux
home=$sub_abs
worktree=$sub_abs
EOF
}

inbox_body_stream() { # <state-dir> <task-id>
  local rec
  for rec in "$1/$2.inbox"/*.msg; do
    [ -f "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ \
      "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
  done
}

inbox_record_count() { # <state-dir> <task-id>
  find "$1/$2.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | wc -l | tr -d '[:space:]'
}

doorbell_count() { # <backend-log>
  grep -cF 'Firstmate instruction waiting:' "$1" 2>/dev/null || true
}

# A live local receiver gets the routed-work instruction through its durable
# inbox record while the endpoint receives only the constant doorbell.
test_handoff_wakes_live_local_receiver() {
  local home="$TMP_ROOT/live-wake-main" sub="$TMP_ROOT/live-wake-sub" fakebin out wake_count
  setup_homes "$home" "$sub"
  mkdir -p "$sub/state" "$sub/data"
  cat > "$home/state/design.meta" <<EOF
window=firstmate:fm-design
kind=secondmate
harness=claude
backend=tmux
home=$sub
worktree=$sub
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] wake-item - routed to a live receiver (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/live-wake-fake")
  out="$TMP_ROOT/live-wake.out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/live-wake-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/live-wake-fake/pane.txt" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    "$ROOT/bin/fm-backlog-handoff.sh" design wake-item > "$out" 2>&1 \
    || fail "handoff to a live receiver failed: $(cat "$out")"
  grep -F 'wake-item' "$sub/data/backlog.md" >/dev/null \
    || fail "live receiver did not receive the routed backlog item"
  grep -F 'send-keys' "$TMP_ROOT/live-wake-tmux.log" >/dev/null \
    || fail "handoff did not ring the live receiver endpoint"
  assert_contains "$(inbox_body_stream "$home/state" design)" \
    'New routed work is in your backlog.' \
    "receiver inbox did not carry the routed-work instruction"
  wake_count=$(inbox_record_count "$home/state" design)
  [ "$(doorbell_count "$TMP_ROOT/live-wake-tmux.log")" -eq 1 ] \
    || fail "handoff did not ring exactly one constant receiver doorbell"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/live-wake-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/live-wake-fake/pane.txt" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    "$ROOT/bin/fm-backlog-handoff.sh" design wake-item > "$TMP_ROOT/live-wake-rerun.out" 2>&1 \
    || fail "idempotent successful handoff rerun failed: $(cat "$TMP_ROOT/live-wake-rerun.out")"
  [ "$(inbox_record_count "$home/state" design)" -eq "$wake_count" ] \
    || fail "idempotent successful handoff rerun duplicated the receiver inbox record"
  [ "$(doorbell_count "$TMP_ROOT/live-wake-tmux.log")" -eq 1 ] \
    || fail "idempotent successful handoff rerun duplicated the receiver doorbell"
  pass "a routed handoff wakes once and a successful rerun stays idempotent"
}

test_failed_wake_retries_when_the_item_is_already_present() {
  local home="$TMP_ROOT/retry-wake-main" sub="$TMP_ROOT/retry-wake-sub" out corr rc=0
  setup_homes "$home" "$sub"
  rm -f "$home/state/design.meta"
  mkdir -p "$sub/data"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] retry-item - wake must be retried (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design retry-item 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff without a receiver endpoint reported success"
  assert_contains "$out" "receiver was not woken" "missing receiver failure was not observable"
  assert_grep 'retry-item' "$sub/data/backlog.md" "failed wake lost the durably handed-off item"
  corr=$(cut -d: -f2- "$home/state/.backlog-handoff-design.wake-pending")
  assert_absent "$home/state/pending-replies/.delivery-confirmed-$corr" \
    "missing endpoint was recorded as an attempted delivery"

  cat > "$home/state/design.meta" <<EOF
window=firstmate:fm-design
kind=secondmate
harness=claude
backend=tmux
home=$sub
worktree=$sub
EOF
  : > "$TMP_ROOT/default-tmux.log"
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design retry-item > "$TMP_ROOT/retry-wake.out" 2>&1 \
    || fail "an already-present handoff did not retry its receiver wake: $(cat "$TMP_ROOT/retry-wake.out")"
  assert_contains "$(inbox_body_stream "$home/state" design)" \
    'New routed work is in your backlog.' \
    "the recovery handoff did not enqueue the receiver instruction"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 1 ] \
    || fail "the recovery handoff did not ring the receiver doorbell"
  pass "a failed receiver wake is loud and retries from an already-present handoff"
}

test_known_receiver_failure_remains_retryable_after_grace() {
  local home="$TMP_ROOT/known-fail-main" sub="$TMP_ROOT/known-fail-sub"
  local basebin rejectbin="$TMP_ROOT/known-fail-reject" out corr rec_count rc=0
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$rejectbin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] known-fail - retain delivery across a failed doorbell (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  basebin=$(make_fake_tmux "$TMP_ROOT/known-fail-fake")
  cat > "$rejectbin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != send-keys ] || exit 1
exec "$FM_BASE_TMUX" "$@"
SH
  chmod +x "$rejectbin/tmux"

  out=$(PATH="$rejectbin:$basebin:$PATH" FM_BASE_TMUX="$basebin/tmux" \
    FM_HOME="$home" FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/known-fail-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/known-fail-fake/pane.txt" \
    "$ROOT/bin/fm-backlog-handoff.sh" design known-fail 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "failed advisory doorbell negated durable handoff: $out"
  assert_contains "$out" 'doorbell did not reach' \
    "failed advisory doorbell was not reported"
  assert_grep 'known-fail' "$sub/data/backlog.md" "failed doorbell lost the durable item"
  assert_contains "$(inbox_body_stream "$home/state" design)" \
    'New routed work is in your backlog.' "failed doorbell lost the durable receiver instruction"
  rec_count=$(inbox_record_count "$home/state" design)
  [ "$rec_count" -eq 1 ] || fail "failed doorbell produced $rec_count inbox records"
  corr=$(grep -l '^task_id=design$' "$home/state/pending-replies"/* 2>/dev/null | head -n 1)
  [ -n "$corr" ] || fail "durable receiver instruction lost its reply expectation"
  [ -n "$(grep '^delivered_epoch=' "$corr" | cut -d= -f2-)" ] \
    || fail "durable enqueue was not recorded as delivered"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design known-fail \
    > "$TMP_ROOT/known-fail-retry.out" 2>&1 \
    || fail "idempotent handoff after failed doorbell failed: $(cat "$TMP_ROOT/known-fail-retry.out")"
  [ "$(inbox_record_count "$home/state" design)" -eq "$rec_count" ] \
    || fail "retry duplicated a receiver instruction already delivered by inbox"
  pass "a failed advisory doorbell leaves the inbox delivery successful and idempotent"
}

test_known_failure_restores_retry_after_reconciliation_race() {
  local home="$TMP_ROOT/reconcile-race-main" sub="$TMP_ROOT/reconcile-race-sub"
  local basebin blockbin="$TMP_ROOT/reconcile-race-block" handoff i corr phase
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$blockbin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] reconcile-race - retry after concurrent reconciliation (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  basebin=$(make_fake_tmux "$TMP_ROOT/reconcile-race-fake")
  cat > "$blockbin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ]; then
  touch "$FM_RECONCILE_RACE_ENTERED"
  while [ ! -f "$FM_RECONCILE_RACE_RELEASE" ]; do sleep 0.02; done
  exit 1
fi
exec "$FM_BASE_TMUX" "$@"
SH
  chmod +x "$blockbin/tmux"

  PATH="$blockbin:$basebin:$PATH" FM_BASE_TMUX="$basebin/tmux" FM_HOME="$home" \
    FM_RECONCILE_RACE_ENTERED="$TMP_ROOT/reconcile-race.entered" \
    FM_RECONCILE_RACE_RELEASE="$TMP_ROOT/reconcile-race.release" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/reconcile-race-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/reconcile-race-fake/pane.txt" \
    "$ROOT/bin/fm-backlog-handoff.sh" design reconcile-race \
    > "$TMP_ROOT/reconcile-race.out" 2>&1 &
  handoff=$!
  i=0
  while [ ! -f "$TMP_ROOT/reconcile-race.entered" ]; do
    kill -0 "$handoff" 2>/dev/null || fail "reconciliation-race handoff exited before backend delivery"
    i=$((i + 1))
    [ "$i" -le 250 ] || fail "reconciliation-race handoff never reached backend delivery"
    sleep 0.02
  done
  corr=$(cut -d: -f2- "$home/state/.backlog-handoff-design.wake-pending")
  FM_PENDING_REPLY_NOW=9999999999 bash -c '
    . "$1"
    fm_pending_reply_reconcile_delivery "$2" "$3"
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$home/state" "$corr" \
    || fail "concurrent watcher could not reconcile the durable enqueue"
  phase=$(sed -n 's/^phase=//p' "$home/state/pending-replies/$corr")
  [ "$phase" = awaiting_report ] \
    || fail "advisory ring race changed the delivered expectation to $phase"
  touch "$TMP_ROOT/reconcile-race.release"
  wait "$handoff" || fail "failed advisory ring negated the durable enqueue"
  assert_absent "$home/state/pending-replies/.delivery-confirmed-$corr" \
    "delivered enqueue retained a recovery marker"
  [ "$(inbox_record_count "$home/state" design)" -eq 1 ] \
    || fail "advisory ring race did not retain exactly one inbox record"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design reconcile-race \
    > "$TMP_ROOT/reconcile-race-retry.out" 2>&1 \
    || fail "idempotent handoff after the ring race failed: $(cat "$TMP_ROOT/reconcile-race-retry.out")"
  [ "$(inbox_record_count "$home/state" design)" -eq 1 ] \
    || fail "ring-race retry duplicated the durable receiver instruction"
  pass "concurrent reconciliation treats enqueue as delivery despite a failed advisory ring"
}

test_move_crash_keeps_wake_pending_for_recovery() {
  local home="$TMP_ROOT/move-crash-main" sub="$TMP_ROOT/move-crash-sub"
  local fakebin="$TMP_ROOT/move-crash-fakebin" real_tasks rc=0 prepared_state
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$fakebin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] crash-item - survive the post-move crash (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  real_tasks=$(command -v tasks-axi)
  fm_fake_crash_injector "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
"$FM_REAL_TASKS_AXI" "$@"
rc=$?
case " $* " in
  *" --file "*" --to "*)
    if [ "$rc" -eq 0 ] && [ "${1:-}" = mv ]; then
      # Crash AFTER the durable move lands, and only return once the handoff is
      # observably gone so it cannot run its own post-move bookkeeping.
      handoff_pid=$(ps -o ppid= -p "$PPID" | tr -d '[:space:]')
      fm-crash-inject "$handoff_pid" || exit 1
    fi
    ;;
esac
exit "$rc"
SH
  chmod +x "$fakebin/tasks-axi"

  set +e
  FM_REAL_TASKS_AXI="$real_tasks" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-backlog-handoff.sh" design crash-item > "$TMP_ROOT/move-crash.out" 2>&1
  rc=$?
  set +e
  [ "$rc" -ne 0 ] || fail "post-move crash fixture unexpectedly reported success"
  assert_grep 'crash-item' "$sub/data/backlog.md" "post-move crash did not leave the item durable"
  assert_present "$home/state/.backlog-handoff-design.wake-pending" \
    "post-move crash lost receiver wake intent"
  prepared_state=$(cat "$home/state/.backlog-handoff-design.wake-pending")
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] unrelated-move - still waiting in the main backlog (repo: alpha)

## Done
EOF
  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design unrelated-move \
    > "$TMP_ROOT/move-crash-unrelated.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "unrelated moving handoff discarded a post-move prepared wake"
  assert_contains "$(cat "$TMP_ROOT/move-crash-unrelated.out")" \
    'belongs to a different routed batch' \
    "unrelated handoff did not surface the unresolved prepared batch"
  [ "$(cat "$home/state/.backlog-handoff-design.wake-pending")" = "$prepared_state" ] \
    || fail "unrelated moving handoff changed the post-move prepared wake"
  assert_grep 'unrelated-move' "$home/data/backlog.md" \
    "unrelated moving handoff changed its source item before resolving the older wake"
  assert_no_grep 'unrelated-move' "$sub/data/backlog.md" \
    "unrelated moving handoff moved work despite the unresolved older wake"

  : > "$TMP_ROOT/default-tmux.log"
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design crash-item \
    > "$TMP_ROOT/move-crash-retry.out" 2>&1 \
    || fail "post-move crash recovery failed: $(cat "$TMP_ROOT/move-crash-retry.out")"
  assert_contains "$(inbox_body_stream "$home/state" design)" \
    'New routed work is in your backlog.' \
    "post-move crash recovery did not enqueue the receiver instruction"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 1 ] \
    || fail "post-move crash recovery did not ring the receiver doorbell"
  assert_absent "$home/state/.backlog-handoff-design.wake-pending" \
    "confirmed crash recovery left receiver wake pending"
  pass "a post-move crash preserves wake intent for an idempotent retry"
}

test_pre_move_crash_does_not_wake_until_move_lands() {
  local home="$TMP_ROOT/pre-move-crash-main" sub="$TMP_ROOT/pre-move-crash-sub"
  local fakebin="$TMP_ROOT/pre-move-crash-fakebin" real_tasks rc=0 wake_count
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$fakebin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] pre-move-crash - wake only after durable move (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  real_tasks=$(command -v tasks-axi)
  fm_fake_crash_injector "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --file "*" --to "*)
    if [ "${1:-}" = mv ]; then
      # Crash BEFORE the move and never run it. This fake outlives the handoff
      # it kills, so delegating to the real binary at all - even after a pause -
      # lets an orphan complete the move the case requires left undone.
      handoff_pid=$(ps -o ppid= -p "$PPID" | tr -d '[:space:]')
      fm-crash-inject "$handoff_pid" || exit 1
      exit 137
    fi
    ;;
esac
exec "$FM_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$fakebin/tasks-axi"
  : > "$TMP_ROOT/default-tmux.log"

  set +e
  FM_REAL_TASKS_AXI="$real_tasks" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-backlog-handoff.sh" design pre-move-crash > "$TMP_ROOT/pre-move-crash.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-move crash fixture unexpectedly reported success"
  assert_grep 'pre-move-crash' "$home/data/backlog.md" "pre-move crash changed the source backlog"
  assert_no_grep 'pre-move-crash' "$sub/data/backlog.md" "pre-move crash changed the destination backlog"
  assert_present "$home/state/.backlog-handoff-design.wake-pending" \
    "pre-move crash lost its prepared wake intent"

  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] unrelated-ready - already durable from another handoff (repo: alpha)

## Done
EOF
  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design unrelated-ready \
    > "$TMP_ROOT/pre-move-unrelated.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "unrelated handoff accepted another batch's prepared wake"
  assert_contains "$(cat "$TMP_ROOT/pre-move-unrelated.out")" \
    'belongs to a different routed batch' \
    "unrelated handoff did not report the prepared batch conflict"
  [ ! -s "$TMP_ROOT/default-tmux.log" ] \
    || fail "unrelated already-present work promoted another batch's prepared wake"
  assert_grep 'pre-move-crash' "$home/data/backlog.md" \
    "unrelated handoff changed the prepared batch's source item"
  assert_present "$home/state/.backlog-handoff-design.wake-pending" \
    "unrelated handoff discarded another batch's prepared wake"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design pre-move-crash \
    > "$TMP_ROOT/pre-move-crash-retry.out" 2>&1 \
    || fail "pre-move crash recovery failed: $(cat "$TMP_ROOT/pre-move-crash-retry.out")"
  assert_grep 'pre-move-crash' "$sub/data/backlog.md" "pre-move crash recovery did not move the item"
  wake_count=$(inbox_record_count "$home/state" design)
  [ "$wake_count" -eq 1 ] || fail "pre-move crash recovery emitted $wake_count receiver records"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 1 ] \
    || fail "pre-move crash recovery did not ring exactly one receiver doorbell"
  pass "a pre-move crash wakes only after retry makes the item durable"
}

test_delivery_confirmation_crash_does_not_resend() {
  local home="$TMP_ROOT/confirm-crash-main" sub="$TMP_ROOT/confirm-crash-sub"
  local fakebin="$TMP_ROOT/confirm-crash-fakebin" real_rm rc=0 wake_count
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$fakebin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] confirm-crash - preserve confirmed delivery (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  real_rm=$(command -v rm)
  fm_fake_crash_injector "$fakebin"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_CONFIRM_WAKE_MARKER" ] \
    && mkdir "$FM_CONFIRM_CRASH_ONCE" 2>/dev/null; then
    # Crash instead of clearing the marker, and confirm the handoff is gone
    # before returning so it cannot proceed past this step.
    fm-crash-inject "$PPID" || exit 1
    exit 0
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$fakebin/rm"
  : > "$TMP_ROOT/default-tmux.log"

  set +e
  PATH="$fakebin:$PATH" FM_REAL_RM="$real_rm" \
    FM_CONFIRM_CRASH_ONCE="$TMP_ROOT/confirm-crash.once" \
    FM_CONFIRM_WAKE_MARKER="$home/state/.backlog-handoff-design.wake-pending" \
    FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design confirm-crash \
    > "$TMP_ROOT/confirm-crash.out" 2>&1
  rc=$?
  set +e
  [ "$rc" -ne 0 ] || fail "post-confirmation crash fixture unexpectedly reported success"
  wake_count=$(inbox_record_count "$home/state" design)
  [ "$wake_count" -eq 1 ] || fail "post-confirmation crash did not deliver exactly one receiver record"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 1 ] \
    || fail "post-confirmation crash did not ring exactly one receiver doorbell"
  case "$(cat "$home/state/.backlog-handoff-design.wake-pending")" in
    pending:*) ;;
    *) fail "post-confirmation crash lost its stable delivery correlation" ;;
  esac

  # Route different work before explicitly retrying the crashed invocation. The
  # completed old correlation must be reconciled, but must not stand in as the
  # delivery proof for this new durable move.
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] after-crash - requires its own receiver wake (repo: alpha)

## Done
EOF
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design after-crash \
    > "$TMP_ROOT/after-confirm-crash.out" 2>&1 \
    || fail "new handoff after a confirmation crash failed: $(cat "$TMP_ROOT/after-confirm-crash.out")"
  [ "$(inbox_record_count "$home/state" design)" -eq "$((wake_count + 1))" ] \
    || fail "completed stale correlation suppressed or duplicated the new receiver record"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 2 ] \
    || fail "completed stale correlation suppressed or duplicated the new doorbell"
  assert_grep 'after-crash' "$sub/data/backlog.md" \
    "new item after a confirmation crash was not durably handed off"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design confirm-crash \
    > "$TMP_ROOT/confirm-crash-retry.out" 2>&1 \
    || fail "post-confirmation crash recovery failed: $(cat "$TMP_ROOT/confirm-crash-retry.out")"
  [ "$(inbox_record_count "$home/state" design)" -eq "$((wake_count + 1))" ] \
    || fail "post-confirmation crash recovery duplicated the receiver record"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 2 ] \
    || fail "post-confirmation crash recovery duplicated the doorbell"
  assert_absent "$home/state/.backlog-handoff-design.wake-pending" \
    "post-confirmation crash recovery left wake state pending"
  pass "a post-confirmation crash reconciles once without suppressing a later handoff wake"
}

test_unresolved_delivery_attempt_refuses_immediate_resend() {
  local home="$TMP_ROOT/attempt-crash-main" sub="$TMP_ROOT/attempt-crash-sub"
  local fakebin="$TMP_ROOT/attempt-crash-fakebin" real_mv rc=0 wake_count out
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$fakebin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] attempt-crash - do not resend an unresolved delivery (repo: alpha)

## Done
EOF
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  real_mv=$(command -v mv)
  fm_fake_crash_injector "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -f "$arg" ] && grep -q '^confirmed=' "$arg" 2>/dev/null; then
    # Crash instead of publishing the confirmed record, and confirm the handoff
    # is gone before returning so it cannot reach its later doorbell step.
    fm-crash-inject "$PPID" || exit 1
    exit 1
  fi
done
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  : > "$TMP_ROOT/default-tmux.log"

  set +e
  PATH="$fakebin:$PATH" FM_REAL_MV="$real_mv" FM_HOME="$home" \
    "$ROOT/bin/fm-backlog-handoff.sh" design attempt-crash \
    > "$TMP_ROOT/attempt-crash.out" 2>&1
  rc=$?
  set +e
  [ "$rc" -ne 0 ] || fail "unresolved-attempt crash fixture unexpectedly reported success"
  wake_count=$(inbox_record_count "$home/state" design)
  [ "$wake_count" -eq 1 ] || fail "unresolved-attempt crash did not deliver exactly one receiver record"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 0 ] \
    || fail "delivery bookkeeping crash unexpectedly reached the later doorbell step"

  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design attempt-crash 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "immediate retry resent or accepted an unresolved delivery attempt"
  assert_contains "$out" 'delivery for design is unresolved; refusing to resend correlation' \
    "immediate retry did not report the unresolved delivery boundary"
  [ "$(inbox_record_count "$home/state" design)" -eq "$wake_count" ] \
    || fail "immediate retry duplicated the unresolved receiver record"
  [ "$(doorbell_count "$TMP_ROOT/default-tmux.log")" -eq 0 ] \
    || fail "immediate retry rang for an unresolved delivery correlation"
  pass "an unresolved delivery attempt refuses an immediate duplicate wake"
}

test_concurrent_local_handoffs_serialize_move_and_wake() {
  local home="$TMP_ROOT/concurrent-main" sub="$TMP_ROOT/concurrent-sub"
  local basebin blockbin="$TMP_ROOT/concurrent-blockbin" first second i wake_count
  setup_homes "$home" "$sub"
  mkdir -p "$sub/data" "$blockbin"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] concurrent-a - first routed item (repo: alpha)

## Done
EOF
  basebin=$(make_fake_tmux "$TMP_ROOT/concurrent-fake")
  cat > "$blockbin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"Firstmate instruction waiting:"*)
    if mkdir "$FM_BLOCK_WAKE_ONCE" 2>/dev/null; then
      touch "$FM_BLOCK_WAKE_ENTERED"
      while [ ! -f "$FM_BLOCK_WAKE_RELEASE" ]; do sleep 0.02; done
    fi
    ;;
esac
exec "$FM_BASE_TMUX" "$@"
SH
  chmod +x "$blockbin/tmux"

  PATH="$blockbin:$basebin:$PATH" FM_HOME="$home" FM_BASE_TMUX="$basebin/tmux" \
    FM_BLOCK_WAKE_ONCE="$TMP_ROOT/concurrent.once" \
    FM_BLOCK_WAKE_ENTERED="$TMP_ROOT/concurrent.entered" \
    FM_BLOCK_WAKE_RELEASE="$TMP_ROOT/concurrent.release" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/concurrent-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/concurrent-fake/pane.txt" \
    "$ROOT/bin/fm-backlog-handoff.sh" design concurrent-a > "$TMP_ROOT/concurrent-a.out" 2>&1 &
  first=$!
  i=0
  while [ ! -f "$TMP_ROOT/concurrent.entered" ]; do
    kill -0 "$first" 2>/dev/null || fail "first concurrent handoff exited before its blocked wake"
    i=$((i + 1))
    [ "$i" -le 250 ] || fail "first concurrent handoff never reached its receiver wake"
    sleep 0.02
  done
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] concurrent-b - second routed item (repo: alpha)

## Done
EOF
  PATH="$blockbin:$basebin:$PATH" FM_HOME="$home" FM_BASE_TMUX="$basebin/tmux" \
    FM_BLOCK_WAKE_ONCE="$TMP_ROOT/concurrent.once" \
    FM_BLOCK_WAKE_ENTERED="$TMP_ROOT/concurrent.entered" \
    FM_BLOCK_WAKE_RELEASE="$TMP_ROOT/concurrent.release" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/concurrent-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/concurrent-fake/pane.txt" \
    "$ROOT/bin/fm-backlog-handoff.sh" design concurrent-b > "$TMP_ROOT/concurrent-b.out" 2>&1 &
  second=$!
  sleep 0.2
  assert_grep 'concurrent-b' "$home/data/backlog.md" \
    "second local handoff moved while the first still owned its wake"
  touch "$TMP_ROOT/concurrent.release"
  wait "$first" || fail "first serialized local handoff failed"
  wait "$second" || fail "second serialized local handoff failed"
  assert_grep 'concurrent-a' "$sub/data/backlog.md" "first serialized item was lost"
  assert_grep 'concurrent-b' "$sub/data/backlog.md" "second serialized item was lost"
  wake_count=$(inbox_record_count "$home/state" design)
  [ "$wake_count" -eq 2 ] || fail "serialized local handoffs produced $wake_count receiver records"
  [ "$(doorbell_count "$TMP_ROOT/concurrent-tmux.log")" -eq 2 ] \
    || fail "serialized local handoffs did not produce two receiver doorbells"
  pass "concurrent local handoffs serialize each durable move with its wake"
}

test_local_teardown_waits_for_handoff_wake() {
  local home="$TMP_ROOT/teardown-race-main" sub="$TMP_ROOT/teardown-race-sub"
  local basebin blockbin="$TMP_ROOT/teardown-race-blockbin" handoff teardown i
  setup_homes "$home" "$sub"
  printf 'project=%s\n' "$ROOT" >> "$home/state/design.meta"
  mkdir -p "$sub/data" "$blockbin"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] teardown-race - routed while teardown starts (repo: alpha)

## Done
EOF
  basebin=$(make_fake_tmux "$TMP_ROOT/teardown-race-fake")
  cat > "$blockbin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"Firstmate instruction waiting:"*)
    touch "$FM_BLOCK_WAKE_ENTERED"
    while [ ! -f "$FM_BLOCK_WAKE_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$FM_BASE_TMUX" "$@"
SH
  chmod +x "$blockbin/tmux"
  PATH="$blockbin:$basebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BASE_TMUX="$basebin/tmux" FM_BLOCK_WAKE_ENTERED="$TMP_ROOT/teardown-race.entered" \
    FM_BLOCK_WAKE_RELEASE="$TMP_ROOT/teardown-race.release" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/teardown-race-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-race-fake/pane.txt" \
    "$ROOT/bin/fm-backlog-handoff.sh" design teardown-race > "$TMP_ROOT/teardown-race-handoff.out" 2>&1 &
  handoff=$!
  i=0
  while [ ! -f "$TMP_ROOT/teardown-race.entered" ]; do
    kill -0 "$handoff" 2>/dev/null || fail "teardown-race handoff exited before its blocked wake"
    i=$((i + 1))
    [ "$i" -le 250 ] || fail "teardown-race handoff never reached its receiver wake"
    sleep 0.02
  done
  PATH="$basebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/teardown-race-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-race-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" design --force --retire-secondmate design > "$TMP_ROOT/teardown-race-teardown.out" 2>&1 &
  teardown=$!
  sleep 0.3
  kill -0 "$teardown" 2>/dev/null \
    || fail "local teardown bypassed the in-flight handoff lock: $(cat "$TMP_ROOT/teardown-race-teardown.out")"
  [ -d "$sub" ] || fail "local teardown removed the receiver home before handoff wake completed"
  assert_grep 'teardown-race' "$sub/data/backlog.md" \
    "local teardown removed routed work before handoff wake completed"
  touch "$TMP_ROOT/teardown-race.release"
  wait "$handoff" || fail "teardown-race handoff failed after releasing its wake"
  wait "$teardown" 2>/dev/null || true
  pass "local teardown waits for the routed move and receiver wake"
}

test_local_teardown_preserves_wake_when_home_removal_fails() {
  local home="$TMP_ROOT/teardown-home-fail-main" sub="$TMP_ROOT/teardown-home-fail-sub"
  local fakebin rm_bin="$TMP_ROOT/teardown-home-fail-rm" real_rm corr rc=0 marker rec fail_home
  local marker_before="$TMP_ROOT/teardown-home-fail-marker.before"
  local rec_before="$TMP_ROOT/teardown-home-fail-record.before"
  setup_homes "$home" "$sub"
  printf 'project=%s\n' "$ROOT" >> "$home/state/design.meta"
  mkdir -p "$sub/data" "$rm_bin"
  printf '## Queued\n- [ ] still-routed - preserve its wake (repo: alpha)\n\n## Done\n' > "$sub/data/backlog.md"
  corr=$(FM_HOME="$home" bash -c '
    . "$1"
    fm_pending_reply_create "$2" "$2/state" design "New routed work is in your backlog."
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$home") \
    || fail "could not seed teardown wake state"
  marker="$home/state/.backlog-handoff-design.wake-pending"
  rec="$home/state/pending-replies/$corr"
  printf 'pending:%s\n' "$corr" > "$marker"
  cp -p -- "$marker" "$marker_before"
  cp -p -- "$rec" "$rec_before"
  real_rm=$(command -v rm)
  fail_home=$(cd "$sub" && pwd -P)
  cat > "$rm_bin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_FAIL_HOME" ] || exit 1
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$rm_bin/rm"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-home-fail-fake")

  set +e
  PATH="$rm_bin:$fakebin:$PATH" FM_REAL_RM="$real_rm" FM_FAIL_HOME="$fail_home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/teardown-home-fail-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-home-fail-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" design --force --retire-secondmate design > "$TMP_ROOT/teardown-home-fail.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown ignored the receiver-home removal failure"
  assert_present "$sub" "failed teardown did not preserve the receiver home"
  assert_grep 'still-routed' "$sub/data/backlog.md" "failed teardown lost routed backlog work"
  cmp -s "$marker_before" "$marker" \
    || fail "failed home removal changed the pending wake marker"
  cmp -s "$rec_before" "$rec" \
    || fail "failed home removal changed the pending wake correlation"
  assert_present "$home/state/design.meta" "failed teardown removed route metadata"
  assert_grep '- design ' "$home/data/secondmates.md" "failed teardown removed the registry route"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/teardown-home-fail-tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-home-fail-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" design --force --retire-secondmate design > "$TMP_ROOT/teardown-home-retry.out" 2>&1 \
    || fail "teardown retry did not retire the preserved wake: $(cat "$TMP_ROOT/teardown-home-retry.out")"
  assert_absent "$sub" "teardown retry left the receiver home"
  assert_absent "$marker" "teardown retry left the pending wake marker"
  assert_absent "$rec" "teardown retry left the pending wake correlation"
  assert_no_grep '- design ' "$home/data/secondmates.md" "teardown retry left the registry route"
  pass "failed local home removal preserves its wake and a retry retires both"
}

# Exact multi-line block extract: header matching key plus following body lines
# (indented lines and blank separators between paragraphs), stopping at the next
# item header or unindented section heading (column-0 ##).
extract_item_block() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { print; capturing = 1; next }
      next
    }
    capturing && /^## / { exit }
    capturing && /^- \[[ x]\] / { exit }
    capturing && /^([ \t].*)?$/ { print; next }
    capturing { exit }
  ' "$file"
}

assert_block_equals() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" != "$actual" ]; then
    printf 'expected block:\n%s\nactual block:\n%s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

# seed_public_commitment <home> <obligation> <work-home> <work-id>: the intake
# half of a promised public reply - the typed obligation, its bound work, and
# this home's registration - so a later handoff can be observed against a real
# unresolved commitment rather than a stub.
seed_public_commitment() {
  local home=$1 obligation=$2 work_home=$3 work_id=$4
  printf 'FMX_PAIRING_TOKEN=test-token\n' > "$home/.env"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  jq -n '{request_id:"req-handoff", platform:"x",
          context_binding:{version:"ctx1", value:"ctx1_req-handoff"},
          public_safe_summary:"looking into the sign-in redirect",
          received_at:"2026-07-30T10:00:00Z",
          followup_expires_at:"2026-08-06T10:00:00Z",
          reservation_expires_at:"2026-08-06T10:00:00Z"}' > "$home/request.json"
  jq -n '{type:"pr-merged", project:"alpha",
          required_deliverables:["pr_url"], completion_policy:"all-required"}' \
    > "$home/expected.json"
  jq -n --arg h "$work_home" --arg w "$work_id" \
    '{relation_id:"rel-code", work_ref:{home_id:$h, task_id:$w},
      role:"fulfills", required:true, generation:1}' > "$home/relation.json"
  (cd "$home" && tasks-axi public-followup add "$obligation" \
    --request-context-file "$home/request.json" --purpose promised-final \
    --expected-final-file "$home/expected.json" --expires-at 2026-10-01T00:00:00Z) >/dev/null \
    || fail "could not create the public commitment"
  (cd "$home" && tasks-axi public-followup bind-work "$obligation" \
    --relation-file "$home/relation.json") >/dev/null \
    || fail "could not bind work to the public commitment"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-public-followup.sh" register \
    "$obligation" --relation rel-code --work-home "$work_home" --work-id "$work_id" \
    --generation 1 >/dev/null \
    || fail "could not register the public commitment"
}

# A public promise binds its work by home AND id. Handing that work to a
# secondmate leaves the binding naming a home that no longer owns it, which used
# to go unnoticed until the promised reply was never delivered. The move itself
# stays safe; the staleness must be reported at the moment it is created.
test_handoff_warns_when_a_moved_item_still_owes_a_public_reply() {
  local home="$TMP_ROOT/pf-stale-main"
  local sub="$TMP_ROOT/pf-stale-sub"
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the public-commitment guard)"; return 0; }
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] promised-item - fix the sign-in redirect (repo: alpha)
- [ ] plain-item - unrelated queued work (repo: alpha)

## Done
EOF
  seed_public_commitment "$home" pf-handoff main promised-item

  local out rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design promised-item plain-item 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "handoff must still succeed while reporting the stale binding: $out"
  assert_contains "$out" "handed off 2 item(s)" "the move itself must still be reported"
  assert_grep 'promised-item' "$sub/data/backlog.md" "the promised item did not reach the secondmate backlog"
  assert_contains "$out" "promised-item still owes a public reply bound to main/promised-item" \
    "the stale public-commitment binding was not reported"
  # The report must come from a genuinely unresolved commitment, not from a state
  # the guard merely could not verify.
  assert_contains "$out" "public commitment pf-handoff is still" \
    "the report did not carry the unresolved commitment the guard actually found"
  assert_contains "$out" "--work-home secondmate:design" \
    "the report did not name the rebinding that keeps the promise reachable"
  case "$out" in
    *"plain-item still owes"*) fail "an item with no public commitment must not be reported" ;;
  esac

  pass "handoff reports a moved item whose public commitment still binds this home"
}

# A home that never opted into the relay must pay nothing and say nothing here.
test_handoff_is_silent_about_public_commitments_without_the_relay() {
  local home="$TMP_ROOT/pf-silent-main"
  local sub="$TMP_ROOT/pf-silent-sub"
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] quiet-item - ordinary queued work (repo: alpha)

## Done
EOF

  local out rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design quiet-item 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "handoff failed in a relay-free home: $out"
  case "$out" in
    *"public reply"*) fail "a relay-free home must not mention public commitments: $out" ;;
  esac
  assert_grep 'quiet-item' "$sub/data/backlog.md" "the item did not reach the secondmate backlog"
  pass "handoff says nothing about public commitments in a relay-free home"
}

test_body_moves_when_followed_by_another_item() {
  local home="$TMP_ROOT/body-next-item-main"
  local sub="$TMP_ROOT/body-next-item-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] keep-a - stays first (repo: alpha)
  keep-a body line
- [ ] body-item - has a body (repo: alpha)
  Spec detail one.
  ## Intent
  Move the full block.
  trailing body line
- [ ] keep-b - stays after (repo: beta)
  keep-b body stays

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" body-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design body-item >/dev/null \
    || fail "handoff of body-followed-by-item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" body-item)
  assert_block_equals "destination body block mismatch after item-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'body-item' "$home/data/backlog.md" "body-item header still in source"
  assert_no_grep 'Spec detail one' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'Move the full block' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'trailing body line' "$home/data/backlog.md" "orphaned trailing body stayed in source"
  # Indented heading must move with the item, not be left or treated as a section.
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  assert_grep 'keep-a' "$home/data/backlog.md" "keep-a was wrongly removed"
  assert_grep '  keep-a body line' "$home/data/backlog.md" "keep-a body was disturbed"
  assert_grep 'keep-b' "$home/data/backlog.md" "keep-b was wrongly removed"
  assert_grep '  keep-b body stays' "$home/data/backlog.md" "keep-b body was disturbed"

  # keep-a's body must not have grown the orphaned lines of body-item.
  local keep_a_block
  keep_a_block=$(extract_item_block "$home/data/backlog.md" keep-a)
  assert_block_equals "keep-a block must not absorb orphaned body-item lines" \
    $'- [ ] keep-a - stays first (repo: alpha)\n  keep-a body line' \
    "$keep_a_block"

  pass "body followed by another item moves intact with no source orphans"
}

test_body_moves_when_followed_by_section_heading() {
  local home="$TMP_ROOT/body-section-main"
  local sub="$TMP_ROOT/body-section-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] section-tail - body ends at section (repo: alpha)
  last queued body
  ## Intent
  still body until column-0 section

## Done
- [x] old-task - shipped - local main (merged 2026-07-01)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" section-tail)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design section-tail >/dev/null \
    || fail "handoff of body-followed-by-section failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" section-tail)
  assert_block_equals "destination body block mismatch after section-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'section-tail' "$home/data/backlog.md" "section-tail still in source"
  assert_no_grep 'last queued body' "$home/data/backlog.md" "body orphaned before ## Done"
  assert_no_grep 'still body until' "$home/data/backlog.md" "body after ## Intent orphaned"
  assert_grep 'old-task' "$home/data/backlog.md" "Done section item was disturbed"
  assert_grep '## Done' "$home/data/backlog.md" "Done section heading was disturbed"

  pass "body followed by section heading moves intact; section stays"
}

test_body_moves_when_last_lines_of_file() {
  local home="$TMP_ROOT/body-eof-main"
  local sub="$TMP_ROOT/body-eof-sub"
  setup_homes "$home" "$sub"

  # A source item that ends the file with no trailing newline is a valid shape;
  # printf builds that deliberately. It must move whole, indented ## line
  # included, into the destination the handoff seeds.
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s' '  eof body line two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination format: the moved block lands under ## Queued
  # in the standard three-section scaffold the handoff seeds for a fresh home.
  local expected_destination="$TMP_ROOT/body-eof-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s\n' '  eof body line two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" eof-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design eof-item >/dev/null \
    || fail "handoff of EOF body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" eof-item)
  assert_block_equals "destination body block mismatch for EOF item" \
    "$expected_block" "$dest_block"
  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF item did not land byte-exact under the seeded destination scaffold"

  # Source should have no item residual - only the section heading remains.
  if grep -E 'eof-item|eof body|## Intent' "$home/data/backlog.md" >/dev/null; then
    fail "EOF item left residual header or body lines in source"
  fi
  assert_grep '## Queued' "$home/data/backlog.md" "Queued section heading was lost"

  pass "body as last lines of the file moves intact"
}

test_eof_body_before_seeded_destination_section_keeps_boundary() {
  local home="$TMP_ROOT/body-eof-seeded-main"
  local sub="$TMP_ROOT/body-eof-seeded-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s' '  seeded eof body two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination whitespace: the moved block sits directly
  # under ## Queued with the section separator before the following ## Done, and
  # the EOF body stays a clean line above that heading (its boundary is kept).
  local expected_destination="$TMP_ROOT/body-eof-seeded-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s\n' '  seeded eof body two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design seeded-eof-item >/dev/null \
    || fail "handoff of EOF body into seeded backlog failed"

  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF body did not remain separate from the seeded ## Done heading"

  pass "EOF body before a seeded destination section keeps its boundary"
}

test_untouched_eof_line_preserves_terminator() {
  local home="$TMP_ROOT/untouched-eof-main"
  local sub="$TMP_ROOT/untouched-eof-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] move-item - remove this block (repo: alpha)'
    printf '%s\n' '  move body'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$home/data/backlog.md"
  local expected_source="$TMP_ROOT/untouched-eof-expected.md"
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$expected_source"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design move-item >/dev/null \
    || fail "handoff before untouched EOF preservation check failed"

  cmp -s "$expected_source" "$home/data/backlog.md" \
    || fail "handoff changed an untouched final-record terminator"

  pass "untouched EOF line preserves its original terminator"
}

test_body_handoff_is_idempotent() {
  local home="$TMP_ROOT/body-idem-main"
  local sub="$TMP_ROOT/body-idem-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] neighbor - untouched (repo: alpha)
  neighbor body
- [ ] idem-item - multi-line for re-run (repo: alpha)
  ## Intent
  Idempotent body must not duplicate.
  final note

## Done
EOF

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item >/dev/null \
    || fail "first handoff of body-carrying item failed"

  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")

  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item 2>&1) \
    || fail "idempotent re-run of body-carrying item failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"

  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"

  local count
  count=$(grep -cF -- '- [ ] idem-item - multi-line for re-run (repo: alpha)' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated the item header (count=$count)"
  count=$(grep -cF -- 'Idempotent body must not duplicate.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a body line (count=$count)"
  count=$(grep -cF -- '  ## Intent' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated indented ## Intent (count=$count)"

  assert_grep 'neighbor' "$home/data/backlog.md" "neighbor item was disturbed by re-run"
  assert_grep '  neighbor body' "$home/data/backlog.md" "neighbor body was disturbed by re-run"

  pass "body-carrying handoff is idempotent: re-run changes nothing"
}

test_noncanonical_indented_continuations_refuse_without_changes() {
  local home="$TMP_ROOT/noncanonical-main"
  local sub="$TMP_ROOT/noncanonical-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] malformed-body - must not orphan continuations (repo: alpha)
 one-space continuation
EOF
  printf '\ttab continuation\n' >> "$home/data/backlog.md"
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] untouched-item - remains in the main backlog (repo: beta)
  canonical body
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] resident-item - remains in the secondmate backlog (repo: alpha)
  resident body
EOF

  local source_before="$TMP_ROOT/noncanonical-source-before.md"
  local destination_before="$TMP_ROOT/noncanonical-destination-before.md"
  local out
  cp "$home/data/backlog.md" "$source_before"
  cp "$sub/data/backlog.md" "$destination_before"

  if out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design malformed-body 2>&1); then
    fail "handoff accepted a noncanonical indented continuation"
  fi

  assert_contains "$out" "malformed-body" "refusal did not name the selected item"
  assert_contains "$out" "one-space continuation" "refusal did not name the one-space continuation"
  assert_contains "$out" "tab continuation" "refusal did not name the tab continuation"
  cmp -s "$source_before" "$home/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the main backlog"
  cmp -s "$destination_before" "$sub/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the secondmate backlog"

  pass "noncanonical one-space and tab continuations refuse without changes"
}

test_indented_heading_is_not_section_boundary() {
  # Standalone focus on the tokenizer trap that caused the live incident.
  local home="$TMP_ROOT/intent-trap-main"
  local sub="$TMP_ROOT/intent-trap-sub"
  setup_homes "$home" "$sub" design

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] ha-codex-fast-default-4e - harness default work (repo: firstmate)
  Context for the secondmate.
  ## Intent
  Deliver the full spec, not the title alone.
  ## Acceptance
  - body survives handoff
  - ## headings inside body stay body
- [ ] next-item - after the trap (repo: firstmate)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" ha-codex-fast-default-4e)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design ha-codex-fast-default-4e >/dev/null \
    || fail "handoff of ## Intent body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" ha-codex-fast-default-4e)
  assert_block_equals "tokenizer trap: indented ## lines must move with the item" \
    "$expected_block" "$dest_block"

  # Source must not treat ## Intent / ## Acceptance as new sections that split the file.
  if grep -E 'ha-codex-fast-default-4e|Deliver the full spec|body survives handoff' \
    "$home/data/backlog.md" >/dev/null; then
    fail "tokenizer trap left item fragments in the source backlog"
  fi
  assert_grep 'next-item' "$home/data/backlog.md" "following item was lost after ## Intent body"
  # Exactly one real Queued section; no spurious column-0 ## Intent section invented.
  local heading_count
  heading_count=$(grep -cE '^## ' "$home/data/backlog.md")
  [ "$heading_count" -eq 1 ] || fail "source gained extra column-0 ## headings (count=$heading_count)"
  heading_count=$(grep -cE '^## ' "$sub/data/backlog.md")
  # sub scaffold has In flight / Queued / Done
  [ "$heading_count" -eq 3 ] || fail "destination has unexpected ## section count (count=$heading_count)"

  pass "indented ## Intent / ## Acceptance are body, not section boundaries"
}

test_multi_paragraph_body_with_internal_blanks_moves_whole() {
  # The live re-orphan risk: a blank line inside a multi-paragraph body must not
  # terminate the block and strand the paragraphs after it. Blank lines are body
  # content and move with the item; only the next item header or a column-0
  # section heading ends the block. Includes an indented ## after a blank.
  local home="$TMP_ROOT/multi-para-main"
  local sub="$TMP_ROOT/multi-para-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] before-multi - stays put (repo: alpha)
  before body
- [ ] multi-para - multi-paragraph body (repo: alpha)
  First paragraph line.

  Second paragraph after a blank.
  ## Intent

  Indented heading then blank then more.
  final line
- [ ] after-multi - subsequent item (repo: alpha)
  after body

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" multi-para)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para >/dev/null \
    || fail "handoff of multi-paragraph body failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" multi-para)
  assert_block_equals "multi-paragraph body with internal blanks must move whole" \
    "$expected_block" "$dest_block"

  # Every body line, including the ones after each internal blank, must leave the source.
  assert_no_grep 'multi-para' "$home/data/backlog.md" "multi-para header still in source"
  assert_no_grep 'First paragraph line' "$home/data/backlog.md" "first paragraph orphaned in source"
  assert_no_grep 'Second paragraph after a blank' "$home/data/backlog.md" "post-blank paragraph orphaned in source"
  assert_no_grep 'Indented heading then blank then more' "$home/data/backlog.md" "post-blank body orphaned in source"
  assert_no_grep 'final line' "$home/data/backlog.md" "trailing body orphaned in source"
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"

  # The post-blank paragraphs must actually arrive at the destination.
  assert_grep '  Second paragraph after a blank.' "$sub/data/backlog.md" "post-blank paragraph did not arrive"
  assert_grep '  Indented heading then blank then more.' "$sub/data/backlog.md" "post-blank body did not arrive"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  # Neighbors on both sides stay intact.
  assert_grep 'before-multi' "$home/data/backlog.md" "before-multi was wrongly removed"
  assert_grep '  before body' "$home/data/backlog.md" "before-multi body was disturbed"
  assert_grep 'after-multi' "$home/data/backlog.md" "after-multi was wrongly removed"
  assert_grep '  after body' "$home/data/backlog.md" "after-multi body was disturbed"

  # Idempotent re-run: already present, no duplication, no mutation.
  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")
  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para 2>&1) \
    || fail "idempotent re-run of multi-paragraph body failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"
  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"
  local count
  count=$(grep -cF -- '  Second paragraph after a blank.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a post-blank paragraph (count=$count)"

  pass "multi-paragraph body with internal blank lines moves whole and is idempotent"
}

# Registry lines may carry parentheticals in the summary before the structured
# (home: ...) field (e.g. "(id is legacy)"). The home extractor must still find
# the field; the old ^[^(]* regex treated those entries as home-less.
test_registry_home_with_pre_home_parentheses() {
  local home="$TMP_ROOT/reg-parens-main"
  local sub="$TMP_ROOT/reg-parens-sub"
  local id=oss-triage-t4
  setup_homes "$home" "$sub" "$id"
  local sub_abs
  sub_abs=$(cd "$sub" && pwd -P)
  # Prose parentheses before (home: ...) and punctuation inside scope match the live registry shape.
  printf -- '- %s - issue triage (id is legacy) (home: %s; scope: issue triage (child); semicolon is meaningful; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "home-seed validation rejected punctuation-bearing registry fields"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] paren-item - should hand off (repo: alpha)
  body line

## Done
EOF

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" "$id" paren-item >/dev/null \
    || fail "handoff failed for registry entry with parentheses before (home: ...)"

  assert_grep 'paren-item' "$sub/data/backlog.md" \
    "item did not arrive when registry summary had pre-home parentheses"
  assert_no_grep 'paren-item' "$home/data/backlog.md" \
    "item still in source after handoff with pre-home parentheses"

  pass "registry home parses when summary has parentheses before (home: ...)"
}

# An entry that genuinely lacks (home: ...) must still fail cleanly (empty parse
# surfaces as "has no home"), not succeed or mis-parse prose.
test_registry_home_missing_field_fails_cleanly() {
  local home="$TMP_ROOT/reg-nohome-main"
  local sub="$TMP_ROOT/reg-nohome-sub"
  local id=no-home-mate
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$sub" "$id"
  # Registered, but no structured (home: ...) field at all.
  printf -- '- %s - charter only (scope prose mentions home: /tmp/ignored-path)\n' \
    "$id" > "$home/data/secondmates.md"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] orphan-item - never moves (repo: alpha)

## Done
EOF

  local out rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" "$id" orphan-item 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff succeeded for registry entry with no (home: ...) field"
  assert_contains "$out" "has no home" \
    "missing (home: ...) field did not report the clean 'has no home' error"
  assert_grep 'orphan-item' "$home/data/backlog.md" \
    "source backlog was mutated despite missing home"
  [ ! -f "$sub/data/backlog.md" ] || ! grep -q 'orphan-item' "$sub/data/backlog.md" 2>/dev/null \
    || fail "item appeared in secondmate backlog despite missing home"

  pass "registry entry without (home: ...) fails cleanly with has no home"
}

test_handoff_wakes_live_local_receiver
test_failed_wake_retries_when_the_item_is_already_present
test_known_receiver_failure_remains_retryable_after_grace
test_known_failure_restores_retry_after_reconciliation_race
test_move_crash_keeps_wake_pending_for_recovery
test_pre_move_crash_does_not_wake_until_move_lands
test_delivery_confirmation_crash_does_not_resend
test_unresolved_delivery_attempt_refuses_immediate_resend
test_concurrent_local_handoffs_serialize_move_and_wake
test_local_teardown_waits_for_handoff_wake
test_local_teardown_preserves_wake_when_home_removal_fails
test_body_moves_when_followed_by_another_item
test_body_moves_when_followed_by_section_heading
test_multi_paragraph_body_with_internal_blanks_moves_whole
test_body_moves_when_last_lines_of_file
test_eof_body_before_seeded_destination_section_keeps_boundary
test_untouched_eof_line_preserves_terminator
test_body_handoff_is_idempotent
test_noncanonical_indented_continuations_refuse_without_changes
test_indented_heading_is_not_section_boundary
test_registry_home_with_pre_home_parentheses
test_registry_home_missing_field_fails_cleanly
test_handoff_warns_when_a_moved_item_still_owes_a_public_reply
test_handoff_is_silent_about_public_commitments_without_the_relay

echo "ALL TESTS PASSED"
