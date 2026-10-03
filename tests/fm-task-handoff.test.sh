#!/usr/bin/env bash
# Behavioral coverage for the lease-safe cross-task handoff public interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-handoff)
HANDOFF="$ROOT/bin/fm-task-handoff.sh"
LEASE="$ROOT/bin/fm-lease.sh"

make_fake_backend() {  # <case-dir>
  local dir=$1 fakebin="$1/fakebin" command
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'status --json') echo '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  'agent --help') printf 'Commands:\n  prompt  Submit a prompt to an agent\n' ;;
  'pane get') jq -n --arg p "$3" '{result:{pane:{pane_id:$p}}}' ;;
  'pane process-info') jq -n --arg p "${4:-}" '{result:{type:"pane_process_info",process_info:{pane_id:$p,shell_pid:101,foreground_processes:[{pid:102,name:"pi",argv0:"pi"}]}}}' ;;
  'agent get') jq -n --arg pane "$3" '{result:{agent:{agent:"pi",pane_id:$pane,agent_status:"idle"}}}' ;;
  'agent prompt')
    if [ "${FM_FAKE_PROMPT_TIMEOUT:-0}" = 1 ]; then echo 'timeout waiting for response' >&2; exit 1; fi
    printf '%s\n' "$*" >> "${FM_TEST_SEND_LOG:-/dev/null}"
    jq -n --arg pane "$3" '{result:{type:"agent_prompted",pane_id:$pane}}'
    ;;
  'pane read') printf '╭────╮\n│    │\n╰────╯\n' ;;
  'pane send-text') printf '%s\n' "$*" >> "${FM_TEST_SEND_LOG:-/dev/null}" ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$fakebin/herdr"
  for command in tmux zellij orca cmux; do
    printf '#!/bin/sh\nexit 97\n' > "$fakebin/$command"
    chmod +x "$fakebin/$command"
  done
  printf '%s\n' "$fakebin"
}

make_home() {  # <case-dir> <task>...
  local dir=$1 home="$1/home" task
  shift
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  for task in "$@"; do
    {
      printf 'window=fixture:w1:p-%s\n' "$task"
      printf 'endpoint_task_id=%s\n' "$task"
      printf 'harness=pi\n'
      printf 'kind=ship\n'
      printf 'backend=herdr\n'
      printf 'spawn_gen=test-%s\n' "$task"
    } > "$home/state/$task.meta"
  done
  printf '%s\n' "$home"
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_conflict_preserves_then_delivers_exactly_once() {
  local dir home fakebin id body out rc count record actual
  dir="$TMP_ROOT/conflict"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=legacy-full-missing-counts-backend
  body=$'Implement the authorized unknown-not-zero correction.\nKeep the accepted contract exact.\n'

  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "branch fixture lease failed"
  rc=0
  out=$(PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "$body" 2>&1) || rc=$?
  [ "$rc" -eq 6 ] || fail "ownership-conflict handoff exited $rc, not 6: $out"
  assert_contains "$out" "not started" "ownership conflict did not deny a false start"
  assert_contains "$out" "leased to the branch supervision actor" "ownership conflict lost its concrete blocker"
  [ ! -d "$home/state/target.inbox" ] || {
    count=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
    [ "$count" -eq 0 ] || fail "conflicting actor sent around the active owner"
  }
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "durable refused handoff was not inspectable"
  assert_contains "$out" "state=retryable-refusal" "conflict did not persist a retryable refusal"
  assert_contains "$out" "target=target" "durable handoff lost its intended recipient"
  assert_contains "$out" "Implement the authorized unknown-not-zero correction." "durable handoff lost its body"

  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    FM_TEST_SEND_LOG="$dir/send.log" "$LEASE" release target --actor branch \
    || fail "owner release failed"
  record=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' -print)
  [ -f "$record" ] || fail "ownership settlement did not deliver the handoff"
  actual=$(inbox_body "$record"; printf '\001')
  actual=${actual%?}
  [ "$actual" = "$body" ] || fail "delivered handoff body was not byte-exact"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "delivered handoff was not inspectable"
  assert_contains "$out" "state=delivered" "ownership settlement did not persist delivery"

  mkdir -p "$home/state/target.inbox/handled"
  mv "$record" "$home/state/target.inbox/handled/${record##*/}"

  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" retry "$id" >/dev/null || fail "delivered handoff retry failed"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "$body" >/dev/null || fail "original sender retry failed"
  count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "ownership settlement or duplicate retries delivered $count copies"
  pass "task-handoff: ownership conflict preserves the exact body and settlement delivers it once"
}

test_restart_sweep_recovers_pending_handoff() {
  local dir home fakebin id rc count
  dir="$TMP_ROOT/restart"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=restart-recovery
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "restart fixture lease failed"
  rc=0
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "recover after branch replacement" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || fail "restart fixture did not stop at the ownership conflict"

  rm "$home/state/.lease-target"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$LEASE" sweep || fail "restart recovery sweep failed"
  count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "restart sweep did not recover exactly one handoff"
  assert_contains "$(FM_HOME="$home" "$HANDOFF" inspect "$id")" "state=delivered" \
    "restart recovery did not publish delivery"
  pass "task-handoff: restart recovery delivers without conversation memory after the lease is gone"
}

test_pending_handoff_rejects_replacement_executor() {
  local dir home fakebin id rc out
  dir="$TMP_ROOT/replacement-generation"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=replacement-generation
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "replacement-generation lease failed"
  rc=0
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "instruction for the original executor" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || fail "replacement-generation fixture did not stop at the ownership conflict"
  assert_contains "$(FM_HOME="$home" "$HANDOFF" inspect "$id")" \
    'target_generation=test-target' "pending handoff did not capture the original executor generation"

  sed -i 's/^spawn_gen=.*/spawn_gen=replacement-target/' "$home/state/target.meta"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    "$LEASE" release target --actor branch >/dev/null || fail "replacement-generation owner release failed"
  [ ! -d "$home/state/target.inbox" ] || fail "pending handoff reached a replacement executor"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "replacement rejection was not inspectable"
  assert_contains "$out" 'state=rejected' "replacement executor mismatch did not become a durable refusal"
  assert_contains "$out" 'changed executor generation' "replacement refusal lost its identity blocker"
  assert_contains "$out" 'instruction for the original executor' "replacement refusal lost the retained instruction"
  pass "task-handoff: retained instructions stay bound to the captured executor generation"
}

test_pending_handoff_rejects_target_archived_before_retry() {
  local dir home fakebin id rc out
  dir="$TMP_ROOT/archive-before-retry"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=archive-before-retry
  mkdir -p "$home/data"
  printf 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n' >"$home/.tasks.toml"
  printf '%s\n' '## In flight' '- [ ] target - Target task (kind: ship)' '' \
    '## Queued' '' '## Done' >"$home/data/backlog.md"
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "archive-before-retry lease failed"
  rc=0
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "retain this exact rejected body" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || fail "archive-before-retry fixture did not stop at the owner conflict"
  tasks-axi "done" target --file "$home/data/backlog.md" >/dev/null \
    || fail "archive-before-retry target could not become terminal"

  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    "$LEASE" release target --actor branch >/dev/null || fail "terminal target owner release failed"
  [ ! -d "$home/state/target.inbox" ] || fail "pending handoff resumed a terminal target"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "terminal handoff rejection was not inspectable"
  assert_contains "$out" 'state=rejected' "terminal retry did not persist a rejection"
  assert_contains "$out" 'is explicitly terminal' "terminal retry lost its disposition blocker"
  assert_contains "$out" 'retain this exact rejected body' "terminal retry lost the handoff body"
  pass "task-handoff: archival between retention and retry rejects without losing the request"
}

test_sweep_without_handoffs_is_a_noop() {
  local dir home
  dir="$TMP_ROOT/empty-sweep"
  home=$(make_home "$dir" target)
  FM_HOME="$home" "$LEASE" sweep || fail "empty handoff sweep failed"
  [ ! -e "$home/state/task-handoffs" ] \
    || fail "ordinary lease sweep materialized an empty handoff ledger"
  pass "task-handoff: a home without handoffs stays untouched by lease sweep"
}

test_local_runtime_backend_matrix_uses_one_durable_plane() {
  local dir home fakebin backend endpoint id record count rc out
  for backend in tmux herdr zellij orca cmux; do
    dir="$TMP_ROOT/backend-$backend"
    fakebin=$(make_fake_backend "$dir")
    home=$(make_home "$dir" source target)
    endpoint="test-$backend-endpoint"
    {
      printf 'endpoint_task_id=target\n'
      printf 'harness=pi\n'
      printf 'kind=ship\n'
      printf 'backend=%s\n' "$backend"
      if [ "$backend" = orca ]; then
        printf 'terminal=%s\n' "$endpoint"
      else
        printf 'window=%s\n' "$endpoint"
      fi
      printf 'spawn_gen=test-target\n'
    } > "$home/state/target.meta"
    id="backend-$backend"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" send source target --id "$id" \
      "deliver independently of the $backend doorbell" 2>&1) || rc=$?
    if [ "$backend" != herdr ]; then
      [ "$rc" = 7 ] || fail "retired $backend handoff did not refuse: $out"
      out=$(FM_HOME="$home" "$HANDOFF" inspect "$id")
      assert_contains "$out" 'state=rejected' 'retired handoff rejection was not durable'
      assert_contains "$out" "deliver independently of the $backend doorbell" 'retired handoff lost body'
      [ ! -d "$home/state/target.inbox" ] || fail 'retired target received an instruction'
      continue
    fi
    [ "$rc" = 0 ] || fail "Herdr handoff failed: $out"
    record=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' -print)
    [ -f "$record" ] || fail "$backend delivery did not create an inbox record"
    assert_contains "$(inbox_body "$record")" "deliver independently of the $backend doorbell" \
      "$backend delivery changed the instruction"
    count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || fail "$backend delivery created $count inbox records"
  done
  pass "task-handoff: Herdr delivers durably; retired backends reject without losing the requested body"
}

test_uncertain_handoff_persists_recovery_before_suppression() {
  local dir home fakebin id out rc record
  dir="$TMP_ROOT/uncertain-marker-failure"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  mkdir -p "$home/state/target.inbox/.escalated"
  id=uncertain-marker-failure
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PROMPT_TIMEOUT=1 FM_HOME="$home" \
    "$HANDOFF" send source target --id "$id" "retain the uncertain handoff" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "uncertain handoff exited $rc: $out"
  record="$home/state/target.inbox/001.msg"
  [ -f "$record" ] || fail "the uncertain handoff lost its inbox record"
  grep -F "$record" "$home/state/.wake-queue" >/dev/null \
    || fail "handoff marker failure occurred before the uncertainty wake was durable"
  assert_contains "$out" 'uncertainty wake was queued' \
    "handoff marker failure did not report the durable recovery path"

  dir="$TMP_ROOT/uncertain-wake-failure"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  mkdir "$home/state/.wake-queue"
  id=uncertain-wake-failure
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PROMPT_TIMEOUT=1 FM_HOME="$home" \
    "$HANDOFF" send source target --id "$id" "retain after handoff wake failure" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "handoff wake persistence failure exited $rc: $out"
  record="$home/state/target.inbox/001.msg"
  [ -f "$record" ] || fail "handoff wake persistence failure lost its inbox record"
  [ ! -e "$home/state/target.inbox/.escalated" ] \
    || fail "handoff wake persistence failure suppressed recovery before a wake existed"
  assert_contains "$out" 'uncertainty wake could not be queued' \
    "handoff wake persistence failure was not reported"
  pass "task-handoff uncertainty keeps recovery durable before suppressing replay"
}

test_terminal_refusal_is_durable() {
  local dir home fakebin id out rc
  dir="$TMP_ROOT/rejected"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source)
  id=retired-target
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" send source retired --id "$id" \
    "do not lose this rejected instruction" 2>&1) || rc=$?
  [ "$rc" -eq 7 ] || fail "missing target exited $rc, not terminal refusal 7: $out"
  assert_contains "$out" "no safe live metadata record" "terminal refusal lost its concrete blocker"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "terminal refusal was not inspectable"
  assert_contains "$out" "state=rejected" "terminal refusal state was not durable"
  assert_contains "$out" "target=retired" "terminal refusal lost its intended recipient"
  assert_contains "$out" "do not lose this rejected instruction" "terminal refusal discarded the body"
  rc=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" retry "$id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 7 ] || fail "terminally refused handoff became retryable"
  pass "task-handoff: a terminal target refusal keeps the exact body and concrete blocker"
}

test_same_task_send_and_reminder_contract_stay_ordinary() {
  local dir home fakebin record handoff_record action
  dir="$TMP_ROOT/same-task"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" same)
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim same --actor main || fail "same-task lease failed"
  touch "$home/state/.last-watcher-beat"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SUPERVISION_ACTOR=main \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" same "ordinary same-task steer" >/dev/null 2>&1 \
    || fail "ordinary same-task fm-send failed"
  record=$(find "$home/state/same.inbox" -maxdepth 1 -name '*.msg' -print)
  [ -f "$record" ] || fail "ordinary same-task steer did not create its inbox record"
  handoff_record=$(bash -c '. "$1"; fm_task_inbox_handoff_id "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$record" 2>/dev/null || true)
  [ -z "$handoff_record" ] || fail "ordinary same-task steer was rewritten as a cross-task handoff"
  touch -t 202001010000 "$record"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" same' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") || fail "reminder ladder check failed"
  case "$action" in "ring $record") ;; *) fail "ordinary unacknowledged reminder changed: $action" ;; esac
  pass "task-handoff: ordinary same-task steering and its unacknowledged reminder remain unchanged"
}

test_conflict_preserves_then_delivers_exactly_once
test_restart_sweep_recovers_pending_handoff
test_pending_handoff_rejects_replacement_executor
test_pending_handoff_rejects_target_archived_before_retry
test_sweep_without_handoffs_is_a_noop
test_local_runtime_backend_matrix_uses_one_durable_plane
test_uncertain_handoff_persists_recovery_before_suppression
test_terminal_refusal_is_durable
test_same_task_send_and_reminder_contract_stay_ordinary
printf 'All task-handoff tests passed.\n'
