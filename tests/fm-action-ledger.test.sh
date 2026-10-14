#!/usr/bin/env bash
# tests/fm-action-ledger.test.sh - the per-task action ledger
# (bin/fm-action-lib.sh, bin/fm-action.sh).
#
# The steering inbox proves a message was queued and acknowledged; it cannot
# prove the acknowledged work ever started, produced a concrete refusal, or was
# accepted. These tests drive the executable surface with an injected clock and
# pin the failures observed in fleet operation:
#   1. ready-but-unstarted: an admitted authorized action past its start bound
#      with no start and no refusal is an incident; before the bound it is not.
#   2. handled-but-unexecuted: a steering-inbox acknowledgement alone never
#      satisfies the action; the incident names the acknowledged state.
#   3. concrete refusal and native start both satisfy the start bound, and a
#      long-running started action is never an incident (healthy long run).
#   4. legitimate holds (safe boundary, resource wait) suppress the incident
#      only until their finite deadline, then the incident returns.
#   5. a blocked action (human decision, external gate) stays visible with its
#      question and never suppresses an independent ready action.
#   6. no blanket grant: a generic permission word cannot admit an authorized
#      action, and a counted grant cannot be spent past its count.
#   7. the fold is read-only: it never records, closes, or answers anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION="$ROOT/bin/fm-action.sh"
TMP_ROOT=$(fm_test_tmproot fm-action-ledger)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

T0=1800000000

act() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash "$ACTION" "$@"
}

fresh_state() {  # <name>
  local s="$TMP_ROOT/$1/state"
  mkdir -p "$s"
  printf '%s\n' "$s"
}

admit_authorized() {  # <state> <id> [extra args...]
  local state=$1 id=$2
  shift 2
  act "$state" admit t1 --id "$id" --class authorized \
    --source "captain:2026-10-14:run-e2e-one-runner" --operation "run the e2e job" \
    --owner worker --at "$T0" "$@"
}

incident_kinds() {  # <state> <now>
  act "$1" incidents t1 --now "$2" | awk -F'\t' '{print $1 ":" $4}'
}

test_ready_but_unstarted() {
  local s out
  s=$(fresh_state ready)
  admit_authorized "$s" a1 || fail "admit authorized action failed"
  out=$(incident_kinds "$s" $((T0 + 299)))
  assert_equals "" "$out" "an action inside its start bound is not an incident"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:unacked-unstarted" "$out" "ready action past 300s with no start is an incident"
  pass "ready-but-unstarted becomes an incident only past the start bound"
}

test_handled_but_unexecuted() {
  local s out
  s=$(fresh_state handled)
  admit_authorized "$s" a1 --inbox 001.msg || fail "admit failed"
  mkdir -p "$s/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\nrun it\n' > "$s/t1.inbox/handled/001.msg"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:acked-unexecuted" "$out" "an inbox acknowledgement must not satisfy execution"
  act "$s" ack t1 a1 --at $((T0 + 20)) || fail "explicit ack failed"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:acked-unexecuted" "$out" "an explicit acknowledgement must not satisfy execution"
  pass "handled-but-unexecuted stays an incident after acknowledgement"
}

test_start_and_refusal_satisfy_the_bound() {
  local s out
  s=$(fresh_state start)
  admit_authorized "$s" a1 || fail "admit a1"
  admit_authorized "$s" a2 || fail "admit a2"
  act "$s" start t1 a1 --at $((T0 + 30)) || fail "start a1"
  act "$s" result t1 a2 refused --reason "runner pool offline" --at $((T0 + 40)) || fail "refuse a2"
  out=$(incident_kinds "$s" $((T0 + 7200)))
  assert_equals "" "$out" "a started long-running action and a concrete refusal are not incidents"
  pass "native start and concrete refusal satisfy the bound; a healthy long run is quiet"
}

test_holds_are_finite() {
  local s out
  s=$(fresh_state hold)
  admit_authorized "$s" a1 || fail "admit"
  act "$s" hold t1 a1 --kind resource-wait --until $((T0 + 900)) --reason "controller above ceiling" --at $((T0 + 100)) \
    || fail "hold"
  out=$(incident_kinds "$s" $((T0 + 600)))
  assert_equals "" "$out" "a live resource wait suppresses the incident"
  out=$(incident_kinds "$s" $((T0 + 901)))
  assert_equals "a1:unacked-unstarted" "$out" "an expired hold no longer suppresses the incident"
  if act "$s" hold t1 a1 --kind safe-boundary --reason "no deadline" --at "$T0" 2>/dev/null; then
    fail "a hold without a finite deadline must be refused"
  fi
  pass "legitimate holds suppress only until their finite deadline"
}

test_gate_never_freezes_independent_work() {
  local s out show
  s=$(fresh_state gate)
  act "$s" admit t1 --id g1 --class human-decision --owner captain \
    --operation "approve production export of image X?" --due $((T0 + 3600)) \
    --ready-with a1 --at "$T0" || fail "admit gate"
  admit_authorized "$s" a1 || fail "admit independent"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:unacked-unstarted" "$out" "the gate must not suppress the independent ready action"
  show=$(act "$s" show t1)
  assert_contains "$show" "approve production export of image X?" "the gate stays visible with its question"
  assert_contains "$show" "gated" "the gate reports the gated phase"
  out=$(incident_kinds "$s" $((T0 + 3601)))
  assert_contains "$out" "g1:gate-overdue" "an unanswered gate past its due time is an incident"
  if act "$s" admit t1 --id g2 --class external-gate --owner maintainer --operation "merge upstream?" --at "$T0" 2>/dev/null; then
    fail "a gate must declare its independent ready work explicitly"
  fi
  pass "a blocked action stays visible and never freezes independent ready work"
}

test_no_blanket_grant_and_counted_grant() {
  local s src
  s=$(fresh_state grant)
  for src in yolo auto standing blanket any all; do
    if act "$s" admit t1 --id g-$src --class authorized --source "$src" \
      --operation "x" --owner worker --at "$T0" 2>/dev/null; then
      fail "generic permission word '$src' must not admit an authorized action"
    fi
  done
  if act "$s" admit t1 --id g-nosrc --class authorized --operation x --owner worker --at "$T0" 2>/dev/null; then
    fail "an authorized action without an exact source must be refused"
  fi
  admit_authorized "$s" one --units 1 || fail "admit counted grant"
  act "$s" start t1 one --units 1 --at $((T0 + 5)) || fail "first unit"
  act "$s" start t1 one --units 3 --at $((T0 + 6)) || fail "recording the over-spend must itself succeed"
  assert_equals "one:over-grant" "$(incident_kinds "$s" $((T0 + 10)))" "spending past the counted grant is an incident"
  pass "no blanket grant can admit an action and counted grants cannot be exceeded"
}

test_fold_is_read_only() {
  local s before after
  s=$(fresh_state readonly)
  admit_authorized "$s" a1 || fail "admit"
  act "$s" admit t1 --id g1 --class human-decision --owner captain --operation "pick?" \
    --ready-with a1 --at "$T0" || fail "admit gate"
  before=$(cksum "$s/t1.actions")
  act "$s" incidents t1 --now $((T0 + 9000)) > /dev/null
  act "$s" show t1 > /dev/null
  after=$(cksum "$s/t1.actions")
  assert_equals "$before" "$after" "reading incidents must not write the ledger"
  pass "incident detection never records, closes, or answers anything"
}

# The loop the action-followthrough skill describes, run end to end: an incident
# appears, the owner acts, and the incident clears because of a start/result and
# not because of the acknowledgement.
test_runbook_loop() {
  local s out
  s=$(fresh_state loop)
  admit_authorized "$s" a1 --inbox 001.msg || fail "admit"
  mkdir -p "$s/t1.inbox/handled"
  : > "$s/t1.inbox/handled/001.msg"
  assert_equals "a1:acked-unexecuted" "$(incident_kinds "$s" $((T0 + 400)))" "loop: acknowledged work is an incident"
  act "$s" start t1 a1 --at $((T0 + 410)) || fail "start"
  assert_equals "" "$(incident_kinds "$s" $((T0 + 420)))" "loop: the native start clears the incident"
  act "$s" result t1 a1 ok --at $((T0 + 900)) || fail "result"
  if act "$s" accept t1 a1 --at $((T0 + 950)) 2>/dev/null; then fail "unbound acceptance must refuse"; fi
  out=$(act "$s" show t1 --now $((T0 + 1000)))
  assert_contains "$out" "resulted" "a result alone cannot certify acceptance"
  if act "$s" accept t1 a1 --at "$T0" 2>/dev/null; then fail "acceptance without a native receipt must be refused"; fi
  pass "the documented follow-through loop clears incidents only through start, result and acceptance"
}

# Inaccessible evidence is unknown: the witness is a withdrawn claim that a
# receipt was absent when a permission-denied read had been hidden.
test_inaccessible_evidence_is_unknown() {
  local s root out
  s=$(fresh_state evidence)
  root="$TMP_ROOT/evidence/store"
  mkdir -p "$root/open" "$root/locked"
  : > "$root/open/receipt"
  : > "$root/locked/receipt"
  assert_equals "present" "$(bash "$ACTION" probe "$root/open/receipt")" "readable receipt is present"
  assert_equals "absent" "$(bash "$ACTION" probe "$root/open/missing")" "a searched directory without the entry is absent"
  chmod 000 "$root/locked"
  out=$(bash "$ACTION" probe "$root/locked/receipt")
  if [ -r "$root/locked/receipt" ]; then
    chmod 755 "$root/locked"
    pass "skip: runner can read through a mode 000 directory"
    return 0
  fi
  assert_contains "$out" "unknown reason=permission-denied" "a permission-denied read is unknown, not absent"
  assert_contains "$out" "fallback=" "unknown names a read-only fallback route"
  assert_not_contains "$out" "absent" "unknown is never reported as absence"
  admit_authorized "$s" a1 || { chmod 755 "$root/locked"; fail "admit"; }
  if act "$s" accept t1 a1 --evidence "$root/locked/receipt" 2>/dev/null; then
    chmod 755 "$root/locked"
    fail "inaccessible evidence must not be accepted as success"
  fi
  if act "$s" accept t1 a1 --evidence "$root/open/missing" 2>/dev/null; then
    chmod 755 "$root/locked"
    fail "absent evidence must not be accepted as success"
  fi
  if act "$s" accept t1 a1 --evidence "$root/open/receipt" 2>/dev/null; then
    chmod 755 "$root/locked"
    fail "readability alone cannot certify acceptance"
  fi
  chmod 755 "$root/locked"
  pass "inaccessible evidence is unknown with a fallback and never counts as absence or success"
}

native_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin"
  fm_git_worktree "$dir/project" "$dir/wt" action-test
  fm_write_meta "$dir/home/state/t1.meta" window=sess:fm-t1 endpoint_task_id=t1 \
    kind=ship harness=claude "worktree=$dir/wt" "project=$dir/project" spawn_gen=run-1
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    for arg in "$@"; do
      if [ "$arg" = /exit ] && [ -n "${FM_TEST_COMMIT_WT:-}" ]; then
        git -C "$FM_TEST_COMMIT_WT" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m "worker committed during exit" || exit 1
        printf zsh > "$FM_TEST_COMMAND_FILE"
      fi
    done ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in *pane_current_command*) if [ -n "${FM_TEST_COMMAND_FILE:-}" ]; then cat "$FM_TEST_COMMAND_FILE"; else printf 'zsh\n'; fi; exit 0 ;; *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s' "$dir"
}

send_native() {
  local dir=$1; shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_SEND_SETTLE=0 \
    bash "$ROOT/bin/fm-send.sh" t1 "$@" > "$dir/send.out" 2> "$dir/send.err"
}

poll_native() {
  local dir=$1 action_state=${2:-$1/home/state}
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1/bin/fm-watch.sh"
    date() { printf "2000000000\n"; }
    wake() { printf "%s\n" "$1"; }
    action_followthrough_check t1 "$2"
  ' _ "$ROOT" "$action_state"
}

test_native_intake_and_poll() {
  local dir s out rec count
  dir=$(native_case native-intake)
  s="$dir/home/state"
  send_native "$dir" "prepare the image" || fail "real send admission"
  rec="$s/t1.inbox/001.msg"
  out=$(poll_native "$dir") || fail "watcher action poll"
  assert_contains "$out" "unacked-unstarted" "real send exposes ready-but-unstarted"
  count=$(wc -l < "$s/.wake-queue")
  assert_equals "" "$(poll_native "$dir")" "a restarted poll deduplicates the incident"
  assert_equals "$count" "$(wc -l < "$s/.wake-queue")" "dedup survives a fresh watcher process"
  mv "$rec" "$s/t1.inbox/handled/"
  out=$(poll_native "$dir") || fail "handled poll"
  assert_contains "$out" "acked-unexecuted" "handled real steer still requires execution"
  : > "$s/.wake-queue"
  assert_equals "" "$(poll_native "$dir")" "draining a wake does not repeat its incident"
  act "$s" hold t1 steer-001 --kind safe-boundary --until 2000000100 --reason "finish the current independent operation" || fail "native hold"
  assert_equals "" "$(poll_native "$dir")" "a legitimate hold suppresses the actual poll"
  act "$s" start t1 steer-001 || fail "execution start"
  assert_equals "" "$(poll_native "$dir")" "a healthy long run stays quiet through the actual poll"
  send_native "$dir" "another authorized step" || fail "second send"
  out=$(act "$s" incidents t1 --now "$(date +%s)")
  assert_equals "" "$out" "admission inside its start window is quiet"
  mkdir -p "$s/parent-route"
  cp "$s/t1.meta" "$s/parent-route/t1.meta"
  rec=$(bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write_idempotent "$2" t1 "remote step"' _ "$ROOT" "$s/parent-route") || fail "remote inbox admission"
  out=$(poll_native "$dir" "$s/parent-route") || fail "parent-route action poll"
  assert_contains "$out" "unacked-unstarted" "remote parent-route ledger reaches existing watcher queue"
  mv "$rec" "$s/parent-route/t1.inbox/handled/"
  out=$(poll_native "$dir" "$s/parent-route") || fail "parent-route handled poll"
  assert_contains "$out" "acked-unexecuted" "remote acknowledgement still requires execution"
  assert_equals "" "$(poll_native "$dir" "$s/parent-route")" "remote incident dedup survives watcher restart"
  pass "real send and watcher poll enforce follow-through with durable dedup and wait controls"
}

test_native_acceptance_identity() {
  local dir s path good out field bad
  dir=$(native_case native-evidence)
  s="$dir/home/state"
  send_native "$dir" exit || fail "native exit steer"
  mv "$s/t1.inbox/001.msg" "$s/t1.inbox/handled/"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ACTION_ID=steer-001 FM_ACTION_ATTEMPT=001.msg \
    bash "$ROOT/bin/fm-control.sh" t1 exit > "$dir/control.out" 2> "$dir/control.err" || fail "native control receipt"
  path="$s/t1.action-receipts/steer-001"
  [ -f "$path" ] || fail "native producer did not publish a receipt"
  good=$(cat "$path")
  if act "$s" accept t1 steer-001 2>/dev/null; then fail "accept without evidence"; fi
  if act "$s" accept t1 steer-001 --evidence "$dir/missing" 2>/dev/null; then fail "missing evidence accepted"; fi
  printf '%s\n' "$good" > "$dir/arbitrary"
  if act "$s" accept t1 steer-001 --evidence "$dir/arbitrary" 2>/dev/null; then fail "arbitrary receipt path accepted"; fi
  for field in 2 3 4 5 6 7 8; do
    bad=wrong
    [ "$field" != 7 ] || bad=failed
    [ "$field" != 8 ] || bad=1
    printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' -v field="$field" -v bad="$bad" '{$field=bad; print}' > "$path"
    if act "$s" accept t1 steer-001 --evidence "$path" 2>/dev/null; then fail "invalid native receipt field $field accepted"; fi
  done
  printf '%s\n' "$good" > "$path"
  chmod 000 "$path"
  if [ ! -r "$path" ] && act "$s" accept t1 steer-001 --evidence "$path" 2>/dev/null; then
    chmod 600 "$path"; fail "unreadable receipt accepted"
  fi
  chmod 600 "$path"
  act "$s" accept t1 steer-001 --evidence "$path" || fail "current exact successful native evidence refused"
  out=$(act "$s" show t1)
  assert_contains "$out" "accepted" "exact native operation is accepted"
  printf 'spawn_gen=run-2\n' > "$dir/changed-meta"
  awk -F= '$1!="spawn_gen"' "$s/t1.meta" >> "$dir/changed-meta"
  mv "$dir/changed-meta" "$s/t1.meta"
  if act "$s" accept t1 steer-001 --evidence "$path" 2>/dev/null; then fail "older incarnation receipt accepted"; fi
  dir=$(native_case failed-native-evidence)
  s="$dir/home/state"
  send_native "$dir" interrupt || fail "native interrupt steer"
  if PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ACTION_ID=steer-001 FM_ACTION_ATTEMPT=001.msg \
    bash "$ROOT/bin/fm-control.sh" t1 interrupt > "$dir/control.out" 2> "$dir/control.err"; then
    fail "interrupting a stopped agent must refuse"
  fi
  if act "$s" accept t1 steer-001 --evidence "$s/t1.action-receipts/steer-001" 2>/dev/null; then
    fail "failed native operation must not certify acceptance"
  fi
  pass "native control receipts require exact current identity and successful evidence"
}

test_failed_gate_attempt_stays_pending() {
  local s class outcome
  for class in human-decision external-gate; do
    s=$(fresh_state "failed-$class")
    act "$s" admit t1 --id gate --class "$class" --owner owner --operation "answer?" --ready-with none --due $((T0+10)) --at "$T0" || fail "gate admission"
    for outcome in failed refused ok; do
      act "$s" result t1 gate "$outcome" --reason "query unavailable" --at $((T0+5)) || fail "gate attempt"
      assert_equals "gate:gate-overdue" "$(incident_kinds "$s" $((T0+20)))" "$class $outcome must not answer a gate"
    done
    act "$s" result t1 gate answered --at $((T0+21)) || fail "gate answer"
    assert_equals "" "$(incident_kinds "$s" $((T0+22)))" "explicit answer resolves $class"
  done
  pass "both gate classes stay pending until explicitly answered"
}

test_missing_relative_evidence_terminates() {
  local dir out name
  dir="$TMP_ROOT/relative"; mkdir -p "$dir"
  for name in receipt.json missing/receipt.json; do
    out=$(cd "$dir" && bash "$ACTION" probe "$name") || fail "relative probe failed"
    assert_equals absent "$out" "missing relative ancestry terminates"
    admit_authorized "$dir/state" "a-${name//\//-}" || fail "relative acceptance admission"
    if (cd "$dir" && act "$dir/state" accept t1 "a-${name//\//-}" --evidence "$name" 2>/dev/null); then fail "relative missing evidence accepted"; fi
  done
  pass "relative probes and acceptance terminate on missing paths"
}

test_internal_nudge_is_not_an_action() {
  local dir s out
  dir=$(native_case nudge)
  s="$dir/home/state"
  awk '$0=="kind=ship" {print "kind=secondmate"; next} {print}' "$s/t1.meta" > "$dir/nudge.meta"
  mv "$dir/nudge.meta" "$s/t1.meta"
  send_native "$dir" --fire-and-forget 0123456789abcdef "drain the notifications" || fail "real nudge send"
  mv "$s/t1.inbox/001.msg" "$s/t1.inbox/handled/"
  assert_equals "" "$(poll_native "$dir")" "handled internal nudge never produces an action incident"
  [ ! -f "$s/t1.actions" ] || fail "internal nudge was admitted"
  send_native "$dir" "prepare independent work" || fail "real ordinary steer"
  mv "$s/t1.inbox/002.msg" "$s/t1.inbox/handled/"
  out=$(poll_native "$dir") || fail "real steer poll"
  assert_contains "$out" "acked-unexecuted" "ordinary acknowledged steer remains enforced"
  pass "handled fire-and-forget nudges are excluded while real steers remain enforced"
}

test_control_result_keeps_admitted_head() {
  local dir s head out
  dir=$(native_case commit-during-control)
  s="$dir/home/state"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  send_native "$dir" exit || fail "exit admission"
  printf claude > "$dir/command"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ACTION_ID=steer-001 FM_ACTION_ATTEMPT=001.msg \
    FM_TEST_COMMIT_WT="$dir/wt" FM_TEST_COMMAND_FILE="$dir/command" \
    bash "$ROOT/bin/fm-control.sh" t1 exit > "$dir/control.out" 2> "$dir/control.err" || fail "exit must survive a worker commit"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" != "$head" ] || fail "fixture worker did not commit during exit"
  assert_equals "$head" "$(awk -F'\t' '{print $4}' "$s/t1.action-receipts/steer-001")" "result preserves admitted head"
  out=$(act "$s" show t1)
  assert_contains "$out" "resulted" "native result remains recorded after worker commit"
  if act "$s" accept t1 steer-001 --evidence "$s/t1.action-receipts/steer-001" 2>/dev/null; then fail "changed-head evidence must remain unknown"; fi
  pass "native control completion survives worker commits while acceptance checks freshness"
}

test_validation_returns_are_consumed() {
  local s command id out
  s=$(fresh_state validation-return)
  for command in respond run; do
    id="validation-$command"
    act "$s" admit t1 --id "$id" --class authorized --owner worker --operation "no-mistakes axi $command --wait" \
      --source "task-owner:validation:$command" --at "$T0" || fail "validation call admission"
    act "$s" start t1 "$id" --at $((T0+1)) || fail "call start"
    assert_equals "" "$(incident_kinds "$s" $((T0+10000)))" "running background drive is not interrupted"
    act "$s" result t1 "$id" ok --at $((T0+10000)) || fail "returned call"
    assert_equals "" "$(incident_kinds "$s" $((T0+10299)))" "returned call inside consumption bound"
    act "$s" ack t1 "$id" --at $((T0+10001)) || fail "ack"
    out=$(incident_kinds "$s" $((T0+10301)))
    assert_contains "$out" "$id:result-unconsumed" "returned $command cannot stay unconsumed"
    act "$s" consume t1 "$id" --reason "read and reported the returned gate" --at $((T0+10302)) || fail "consume return"
    assert_equals "" "$(incident_kinds "$s" $((T0+20000)))" "consumption closes returned-call incident"
  done
  pass "respond and background drive returns require consumption within the finite bound"
}

test_ready_but_unstarted
test_handled_but_unexecuted
test_start_and_refusal_satisfy_the_bound
test_holds_are_finite
test_gate_never_freezes_independent_work
test_no_blanket_grant_and_counted_grant
test_fold_is_read_only
test_runbook_loop
test_inaccessible_evidence_is_unknown

test_failed_gate_attempt_stays_pending
test_missing_relative_evidence_terminates
test_native_intake_and_poll
test_native_acceptance_identity

test_internal_nudge_is_not_an_action
test_control_result_keeps_admitted_head
test_validation_returns_are_consumed
