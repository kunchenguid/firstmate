#!/usr/bin/env bash
# Behavior tests for the committed-ready validation continuation owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-delivery-continuation-lib.sh
. "$ROOT/bin/fm-delivery-continuation-lib.sh"

CONTINUE="$ROOT/bin/fm-delivery-continue.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-continue)

make_fixture() {
  local dir=$1 home wt head
  home="$dir/home"
  wt="$home/projects/ship"
  mkdir -p "$home/state" "$home/data/ship" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  fm_git_init_commit "$wt"
  git -C "$wt" config user.name 'Firstmate Test'
  git -C "$wt" config user.email 'firstmate-test@example.invalid'
  git -C "$wt" checkout -qb fm/ship
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$home/state/ship.meta" "window=fm:fm-ship" "worktree=$wt" "project=sample" "harness=codex" "kind=ship" "mode=no-mistakes" "spawn_gen=g1"
  printf 'done: committed %s [spawn-gen=g1] implementation committed and focused checks passed\n' "$head" > "$home/state/ship.status"
  cat > "$home/data/ship/brief.md" <<'EOF'
Delivery contract: mode=no-mistakes
Delivery receipt contract: committed-head-v1
Status producer contract: serialized-status-v1
When you believe it is complete, append `done: committed $(git rev-parse HEAD) [spawn-gen=$(sed -n 's/^spawn_gen=//p' state/ship.meta | tail -1)] {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship - Ship task (repo: sample) (kind: ship)

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

make_send_stub() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -eu
task=$1; shift
message=$*
[ "${FM_SEND_EXPECTED_SPAWN_GEN:-}" = g1 ] || exit 11
[ -n "${FM_SEND_EXPECTED_WORKTREE_HEAD:-}" ] || exit 12
. "${FM_TEST_ROOT:?}/bin/fm-task-inbox-lib.sh"
. "${FM_TEST_ROOT:?}/bin/fm-classify-lib.sh"
if [ "${FM_TEST_APPEND_BLOCKER_BEFORE_SEND:-0}" = 1 ]; then
  printf 'blocked: blocker appeared at publication\n' >> "${FM_STATE_OVERRIDE:?}/$task.status"
fi
[ "$(status_observed_signature "${FM_STATE_OVERRIDE:?}/$task.status")" = "${FM_SEND_EXPECTED_STATUS_SIGNATURE:-}" ] || exit 13
fm_task_inbox_write_idempotent "${FM_STATE_OVERRIDE:?}" "$task" "$message" >/dev/null
SH
  chmod +x "$path"
}

make_state_stub() {
  local path=$1 state=$2
  printf '#!/usr/bin/env bash\nprintf '\''run-attribution: %%s\\n'\'' %q\n' "$state" > "$path"
  chmod +x "$path"
}

run_continue() {
  local home=$1 send=$2 state=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_TEST_ROOT="$ROOT" \
    FM_DELIVERY_SEND_BIN="$send" FM_DELIVERY_CREW_STATE_BIN="$state" "$CONTINUE" ship
}

test_exactly_once_delivery_and_replay() {
  local dir home send state first second third count due record
  dir="$TMP_ROOT/exactly-once"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  printf 'resolved [key=settled]: decision already answered\n' >> "$home/state/ship.status"
  first=$(run_continue "$home" "$send" "$state") || fail "initial continuation failed"
  make_state_stub "$state" unavailable
  second=$(run_continue "$home" "$send" "$state") || fail "replay continuation failed"
  due=$(FM_TASK_INBOX_GRACE_SECS=0 fm_task_inbox_due_action "$home/state" ship)
  record=$(find "$home/state/ship.inbox" -maxdepth 1 -name '*.msg' -print -quit)
  mkdir -p "$home/state/ship.inbox/handled"
  mv "$record" "$home/state/ship.inbox/handled/"
  third=$(run_continue "$home" "$send" "$state") || fail "handled replay continuation failed"
  count=$(find "$home/state/ship.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = 'result=sent task=ship' ] || fail "initial result wrong: $first"
  [ "$second" = 'result=already-delivered task=ship' ] || fail "replay result wrong: $second"
  [ "$third" = 'result=already-delivered task=ship' ] || fail "handled replay result wrong: $third"
  [ "$count" = 1 ] || fail "replay created $count delivery records"
  [[ "$due" == ring* ]] || fail "continuation record was excluded from acknowledgement retries: $due"
  [ ! -e "$home/state/.lease-ship" ] || fail "continuation stranded its lease"
  pass "committed-ready delivery is durable exactly once and replay-safe"
}

test_refusals_preserve_stop() {
  local dir home send state out
  dir="$TMP_ROOT/refusals"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  { printf 'blocked: waiting while docs mention [key=route] in prose\n'; cat "$home/state/ship.status"; } > "$home/state/ship.status.next"
  mv "$home/state/ship.status.next" "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "blocked result execution failed"
  [[ "$out" == *'reason=open-decision-or-blocker'* ]] || fail "open blocker was not refused: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "blocked task received validation delivery"
  pass "an open canonical blocker remains stopped"
}

test_active_run_and_unavailable_attribution_refuse() {
  local dir home send state out
  dir="$TMP_ROOT/active-and-mismatch"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" active
  out=$(run_continue "$home" "$send" "$state") || fail "active run execution failed"
  [[ "$out" == 'result=already-active task=ship' ]] || fail "active run was not recognized: $out"
  make_state_stub "$state" unavailable
  out=$(run_continue "$home" "$send" "$state") || fail "unavailable attribution execution failed"
  [ "$out" = 'result=retry task=ship reason=validation-attribution-unavailable' ] \
    || fail "unavailable run query did not remain retryable: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "unavailable run attribution received validation delivery"
  pass "active validation stops delivery and unavailable attribution remains retryable"
}

test_current_brief_requires_canonical_receipt() {
  local dir home send state out head
  dir="$TMP_ROOT/current-receipt"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  cat > "$home/data/ship/brief.md" <<'EOF'
Delivery contract: mode=no-mistakes
Delivery receipt contract: committed-head-v1
Status producer contract: serialized-status-v1
When you believe it is complete, append `done: committed $(git rev-parse HEAD) [spawn-gen=$(sed -n 's/^spawn_gen=//p' state/ship.meta | tail -1)] {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
  printf 'done: validation complete\n' > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "noncanonical current receipt execution failed"
  [ "$out" = 'result=refused task=ship reason=missing-committed-receipt' ] \
    || fail "current brief accepted a noncanonical receipt: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "current noncanonical receipt created an inbox delivery"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s [spawn-gen=g1] validation complete\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "canonical current receipt execution failed"
  [ "$out" = 'result=sent task=ship' ] || fail "current canonical receipt did not deliver: $out"
  pass "current briefs require canonical committed-head receipts"
}

test_promoted_contract_recovers_durable_continuation() {
  local dir home send state out wt
  dir="$TMP_ROOT/promoted-contract"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  wt="$home/projects/ship"
  fm_write_meta "$home/state/ship.meta" "window=fm:fm-ship" "worktree=$wt" "project=sample" "harness=codex" "kind=scout" "spawn_gen=g1"
  cat > "$home/data/ship/brief.md" <<'EOF'
This is a SCOUT task: the deliverable is a written report, not a PR.
When the report is complete, append `done: {one-line conclusion}` to the status file and stop.
EOF
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-promote.sh" ship --mode no-mistakes --yolo off >/dev/null 2>&1 \
    || fail "promoted no-mistakes fixture could not publish its ship contract"
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  printf '%s\n' "$$" > "$home/state/.lock"
  : > "$home/state/.wake-queue"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$CONTINUE" FM_DELIVERY_SEND_BIN="$send" \
    FM_DELIVERY_CREW_STATE_BIN="$state" FM_TEST_ROOT="$ROOT" \
    "$ROOT/bin/fm-delivery-preflight.sh") || fail "promoted durable preflight failed"
  [ "$out" = 'result=sent task=ship' ] \
    || fail "promoted authoritative contract did not continue committed work: $out"
  [ "$(find "$home/state/ship.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "promoted committed work did not receive exactly one durable continuation"
  pass "promoted no-mistakes contracts recover durable continuation"
}

test_inbox_failure_remains_retryable() {
  local dir home send state out
  dir="$TMP_ROOT/inbox-retry"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_state_stub "$state" absent
  printf '#!/usr/bin/env bash\nexit 1\n' > "$send"
  chmod +x "$send"
  out=$(run_continue "$home" "$send" "$state") || fail "inbox failure execution failed"
  [ "$out" = 'result=retry task=ship reason=inbox-delivery-failed' ] \
    || fail "inbox delivery failure did not remain retryable: $out"
  pass "inbox delivery failures remain retry obligations"
}

test_unserialized_canonical_producer_refuses_visibly_without_stranding_status() {
  local dir home send state out
  dir="$TMP_ROOT/unserialized-producer"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  sed '/^Status producer contract: serialized-status-v1$/d' "$home/data/ship/brief.md" \
    > "$home/data/ship/brief.next"
  mv "$home/data/ship/brief.next" "$home/data/ship/brief.md"
  out=$(run_continue "$home" "$send" "$state") || fail "unserialized producer execution failed"
  [ "$out" = 'result=refused task=ship reason=unverifiable-status-producer' ] \
    || fail "unserialized producer did not stop visibly: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "unserialized producer received validation delivery"
  "$ROOT/bin/fm-status-append.sh" "$home/state/ship.status" \
    'blocked [key=late-stop]: worker can still report the blocker' \
    || fail "producer refusal stranded the status publication lock"
  grep -Fqx 'blocked [key=late-stop]: worker can still report the blocker' "$home/state/ship.status" \
    || fail "producer refusal lost the worker blocker"
  pass "unserialized canonical producers stop visibly without blocking status"
}

test_strict_run_attribution_distinguishes_absence_from_query_failure() {
  local dir home fakebin out
  dir="$TMP_ROOT/strict-attribution"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit "${FM_FAKE_NM_EXIT:-0}"
SH
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FAKE_NM_EXIT=1 \
    "$ROOT/bin/fm-crew-state.sh" --run-attribution ship)
  [ "$out" = 'run-attribution: unavailable' ] || fail "failed run query was not unavailable: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FAKE_NM_EXIT=0 \
    "$ROOT/bin/fm-crew-state.sh" --run-attribution ship)
  [ "$out" = 'run-attribution: absent' ] || fail "successful empty run inventory was not proven absent: $out"
  pass "strict run attribution separates proven absence from query unavailability"
}

test_identity_and_committed_head_requirements() {
  local dir home send state out head
  dir="$TMP_ROOT/identity-and-head"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  sed '/^spawn_gen=/d' "$home/state/ship.meta" > "$home/state/ship.meta.next"
  mv "$home/state/ship.meta.next" "$home/state/ship.meta"
  out=$(run_continue "$home" "$send" "$state") || fail "missing-incarnation execution failed"
  [[ "$out" == *'reason=missing-task-incarnation'* ]] || fail "missing incarnation was not refused: $out"
  printf 'spawn_gen=g1\n' >> "$home/state/ship.meta"
  printf 'dirty\n' > "$home/projects/ship/uncommitted.txt"
  out=$(run_continue "$home" "$send" "$state") || fail "dirty committed receipt execution failed"
  [[ "$out" == *'reason=uncommitted-worktree'* ]] || fail "committed receipt did not require a clean worktree: $out"
  rm "$home/projects/ship/uncommitted.txt"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s [spawn-gen=g1] canonical receipt\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "canonical receipt execution failed"
  [ "$out" = 'result=sent task=ship' ] || fail "canonical committed receipt did not deliver: $out"
  pass "continuation requires an incarnation and a clean canonical committed head"
}

test_replacement_incarnation_rejects_prior_receipt() {
  local dir home send state out
  dir="$TMP_ROOT/replacement-incarnation"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  sed 's/^spawn_gen=g1$/spawn_gen=g2/' "$home/state/ship.meta" > "$home/state/ship.meta.next"
  mv "$home/state/ship.meta.next" "$home/state/ship.meta"
  out=$(run_continue "$home" "$send" "$state") || fail "replacement-incarnation execution failed"
  [ "$out" = 'result=refused task=ship reason=committed-receipt-incarnation-mismatch' ] \
    || fail "prior incarnation receipt reached its replacement worker: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "replacement worker received prior incarnation validation"
  pass "committed receipts cannot authorize replacement incarnations"
}

test_head_advance_during_attribution_refuses_stale_delivery() {
  local dir home send state out before after
  dir="$TMP_ROOT/head-advance-during-attribution"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"
  before=$(git -C "$home/projects/ship" rev-parse HEAD)
  cat > "$state" <<'SH'
#!/usr/bin/env bash
set -eu
git -C "${FM_ADVANCE_WORKTREE:?}" commit -q --allow-empty -m advance-during-attribution
printf 'run-attribution: absent\n'
SH
  chmod +x "$state"
  out=$(FM_ADVANCE_WORKTREE="$home/projects/ship" run_continue "$home" "$send" "$state") \
    || fail "head-advance execution failed"
  after=$(git -C "$home/projects/ship" rev-parse HEAD)
  [ "$after" != "$before" ] || fail "the attribution fixture did not advance the worktree"
  [ "$out" = 'result=refused task=ship reason=committed-head-mismatch' ] \
    || fail "a head advanced during attribution reached stale delivery: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "a stale exact-head instruction was enqueued"
  [ ! -e "$home/state/.lease-ship" ] || fail "the refused head race stranded its lease"
  pass "a head advance during run attribution cannot enqueue stale validation authority"
}

test_decision_change_at_publication_refuses_stale_delivery() {
  local dir home send state out
  dir="$TMP_ROOT/decision-change-at-publication"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  out=$(FM_TEST_APPEND_BLOCKER_BEFORE_SEND=1 run_continue "$home" "$send" "$state") \
    || fail "decision-change execution failed"
  [ "$out" = 'result=retry task=ship reason=inbox-delivery-failed' ] \
    || fail "a blocker added at publication did not stop delivery: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "a stale decision snapshot enqueued validation"
  pass "decision state is revalidated at durable inbox publication"
}

test_historical_receipt_requires_exact_head_provenance() {
  local dir home send state out head delivery message
  dir="$TMP_ROOT/historical-head-provenance"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  cat > "$home/data/ship/brief.md" <<'EOF'
Delivery contract: mode=no-mistakes
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
  printf 'done: implementation committed and focused checks passed\n' > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "unbound historical receipt execution failed"
  [ "$out" = 'result=refused task=ship reason=unverifiable-historical-committed-head' ] \
    || fail "historical receipt borrowed the current head: $out"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  delivery=$(fm_delivery_continuation_id ship "$head" g1)
  message=$(fm_delivery_continuation_message ship "$head" g1 "$delivery")
  fm_task_inbox_write_idempotent "$home/state" ship "$message" >/dev/null
  out=$(run_continue "$home" "$send" "$state") || fail "historical exact-record replay failed"
  [ "$out" = 'result=already-delivered task=ship' ] \
    || fail "historical replay did not converge on exact durable head evidence: $out"
  git -C "$home/projects/ship" commit -q --allow-empty -m advance
  out=$(run_continue "$home" "$send" "$state") || fail "historical advanced-head execution failed"
  [ "$out" = 'result=refused task=ship reason=continuation-head-mismatch' ] \
    || fail "historical receipt authorized a later clean head: $out"
  pass "historical receipts require durable exact-head provenance"
}

test_terminal_receipt_and_existing_lease_retry() {
  local dir home send state out head
  dir="$TMP_ROOT/terminal-and-lease"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "terminal receipt execution failed"
  [[ "$out" == *'reason=attributable-validation-terminal-receipt'* ]] || fail "terminal PR receipt was treated as committed-ready: $out"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s [spawn-gen=g1] implementation committed and focused checks passed\nfailed: validation prerequisites unavailable\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "terminal failure execution failed"
  [ "$out" = 'result=refused task=ship reason=terminal-task-failure' ] \
    || fail "later terminal failure was ignored after committed readiness: $out"
  printf 'done: committed %s [spawn-gen=g1] implementation committed and focused checks passed\n' "$head" > "$home/state/ship.status"
  printf '%s\n' "$$" > "$home/state/.lock"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim ship >/dev/null || fail "fixture main lease claim failed"
  out=$(PI_CODING_AGENT=true run_continue "$home" "$send" "$state") || fail "borrowed lease execution failed"
  [[ "$out" == 'result=retry task=ship reason=supervision-owner-active' ]] || fail "borrowed same-actor lease was not retained as retry: $out"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lease.sh" check ship >/dev/null \
    || fail "continuation released the pre-existing lease"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lease.sh" release ship >/dev/null
  pass "terminal receipts and failures stop while existing custody remains retryable"
}

test_killed_delivery_operation_does_not_strand_session_lease() {
  local dir home send state marker pid operation_pid helper_pid out
  dir="$TMP_ROOT/killed-delivery-operation"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; marker="$dir/operation.pid"
  make_send_stub "$send"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${FM_OPERATION_MARKER:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$state"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_ROOT="$ROOT" FM_OPERATION_MARKER="$marker" FM_DELIVERY_SEND_BIN="$send" \
    FM_DELIVERY_CREW_STATE_BIN="$state" "$CONTINUE" ship > "$dir/first.out" 2> "$dir/first.err" &
  pid=$!
  for _ in $(seq 1 100); do
    [ -s "$marker" ] && [ -e "$home/state/.lease-ship" ] && break
    sleep 0.01
  done
  operation_pid=$(cut -f4 "$home/state/.lease-ship" 2>/dev/null)
  operation_pid=${operation_pid%-*}
  operation_pid=${operation_pid##*-}
  helper_pid=$(cat "$marker" 2>/dev/null)
  case "$operation_pid:$helper_pid" in *[!0-9:]*|:|*:) fail "delivery fixture did not expose both operation pids" ;; esac
  kill -9 "$operation_pid" 2>/dev/null || fail "could not kill the delivery operation"
  kill -9 "$helper_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -e "$home/state/.lease-ship" ] || fail "killed delivery operation did not leave the crash-window lease"
  make_state_stub "$state" absent
  out=$(PI_CODING_AGENT=true run_continue "$home" "$send" "$state") || fail "delivery replay after killed owner failed"
  [ "$out" = 'result=sent task=ship' ] || fail "dead delivery operation stranded the session lease: $out"
  [ ! -e "$home/state/.lease-ship" ] || fail "replay left the recovered delivery lease"
  pass "a killed delivery operation cannot strand its live Pi session lease"
}

write_fake_delivery_proc() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (delivery) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0fm-delivery-continue.sh\0ship\0' > "$proc_root/$pid/cmdline"
}

test_reused_delivery_pid_does_not_preserve_lease() {
  local dir home proc_root owner
  dir="$TMP_ROOT/reused-delivery-pid"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  proc_root="$dir/proc"
  printf '%s\n' "$$" > "$home/state/.lock"
  write_fake_delivery_proc "$proc_root" "$$" 111
  owner=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_lease_delivery_owner reused "$2"' _ "$ROOT/bin/fm-lease-lib.sh" "$$") \
    || fail "could not create delivery process identity owner"
  PI_CODING_AGENT=true FM_PROC_ROOT_OVERRIDE="$proc_root" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_LEASE_HOLDER_PID="$$" FM_LEASE_OWNER="$owner" "$ROOT/bin/fm-lease.sh" claim-new reused >/dev/null \
    || fail "could not claim delivery identity lease"
  write_fake_delivery_proc "$proc_root" "$$" 222
  PI_CODING_AGENT=true FM_PROC_ROOT_OVERRIDE="$proc_root" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_LEASE_HOLDER_PID="$$" FM_LEASE_OWNER=pi-main-replay "$ROOT/bin/fm-lease.sh" claim-new reused \
    || fail "reused delivery pid stranded the lease"
  [ "$(cut -f4 "$home/state/.lease-reused")" = pi-main-replay ] \
    || fail "new process incarnation did not own the reclaimed delivery lease"
  PI_CODING_AGENT=true FM_PROC_ROOT_OVERRIDE="$proc_root" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_LEASE_OWNER=pi-main-replay "$ROOT/bin/fm-lease.sh" release reused >/dev/null
  pass "delivery leases bind PID and process start identity"
}

test_pi_empty_drain_recovers_unqueued_durable_candidate() {
  local dir home stub log out
  dir="$TMP_ROOT/pi-empty-durable-preflight"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  printf 'resolved [key=settled]: decision already answered\n' >> "$home/state/ship.status"
  stub="$dir/continue"; log="$dir/delivery.log"
  printf '%s\n' "$$" > "$home/state/.lock"
  : > "$home/state/.wake-queue"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_PREFLIGHT_LOG:?}"
printf 'result=sent task=%s\n' "$1"
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh") || fail "empty Pi drain durable preflight failed"
  assert_contains "$out" "Deterministic delivery continuation preflight:" \
    "empty Pi drain omitted its durable continuation result"
  assert_contains "$out" "result=sent task=ship" \
    "empty Pi drain did not recover the unqueued committed-ready task"
  [ "$(cat "$log")" = ship ] || fail "empty Pi drain did not invoke exactly one durable candidate"
  [ ! -s "$home/state/.wake-queue" ] || fail "durable inventory manufactured a wake row"
  pass "Pi startup intake recovers committed-ready state without a wake row"
}

test_pi_empty_drain_requeues_unqueued_retry() {
  local dir home stub out rows
  dir="$TMP_ROOT/pi-empty-durable-retry"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  printf '%s\n' "$$" > "$home/state/.lock"
  : > "$home/state/.wake-queue"
  stub="$dir/continue"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf 'result=retry task=%s reason=validation-attribution-unavailable\n' "$1"
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" "$ROOT/bin/fm-wake-drain.sh" \
    2> "$dir/first.err") || fail "empty Pi retry drain failed: $(cat "$dir/first.err")"
  printf '%s\n' "$out" | grep -q '^result=retry task=ship reason=validation-attribution-unavailable$' \
    || fail "empty Pi drain hid the durable-only retry: $out"
  rows=$(awk -F '\t' '$3 == "signal" && $4 == "ship.status" { count++ } END { print count + 0 }' \
    "$home/state/.wake-queue")
  [ "$rows" -eq 1 ] || fail "empty Pi retry did not create exactly one durable task wake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" "$ROOT/bin/fm-wake-drain.sh" \
    2> "$dir/second.err") || fail "replayed Pi retry drain failed: $(cat "$dir/second.err")"
  rows=$(awk -F '\t' '$3 == "signal" && $4 == "ship.status" { count++ } END { print count + 0 }' \
    "$home/state/.wake-queue")
  [ "$rows" -eq 1 ] || fail "replayed Pi retry duplicated its durable task wake"
  pass "Pi empty drains persist durable-only continuation retries"
}

test_non_pi_empty_drain_initializes_missing_queue() {
  local dir home out
  dir="$TMP_ROOT/non-pi-empty-drain"; mkdir -p "$dir"
  home="$dir/home"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-wake-drain.sh") || fail "non-Pi empty drain failed"
  [ -z "$out" ] || fail "non-Pi empty drain was not silent: $out"
  [ -f "$home/state/.wake-queue" ] && [ ! -s "$home/state/.wake-queue" ] \
    || fail "non-Pi empty drain did not initialize its durable queue"
  pass "non-Pi empty drains initialize their durable queue"
}

test_transferred_captain_hold_stops_delivery() {
  local dir home send state out
  dir="$TMP_ROOT/captain-held-decision"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  printf 'needs-decision [key=route]: choose the delivery route\n' >> "$home/state/ship.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" hold ship-route \
      --title "Choose the delivery route" --reason "captain route decision pending" \
      --repo sample --origin ship >/dev/null \
    || fail "could not create the captain-held delivery decision"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" complete ship ship-route >/dev/null \
    || fail "could not transfer the delivery decision to its durable hold"
  out=$(run_continue "$home" "$send" "$state") || fail "captain-held continuation execution failed"
  [ "$out" = 'result=refused task=ship reason=open-decision-or-blocker' ] \
    || fail "captain-held decision did not stop validation delivery: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "captain-held task received validation delivery"
  pass "transferred captain holds remain validation blockers"
}

test_origin_captain_hold_stops_delivery_without_decision_keys() {
  local dir home send state out
  dir="$TMP_ROOT/origin-captain-hold"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" hold ship --reason "captain owns validation timing" >/dev/null \
    || fail "could not hold the origin delivery task"
  out=$(run_continue "$home" "$send" "$state") || fail "origin-held continuation execution failed"
  [ "$out" = 'result=refused task=ship reason=open-decision-or-blocker' ] \
    || fail "origin captain hold did not stop validation delivery: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "origin-held task received validation delivery"
  pass "origin captain holds block delivery without transferred decision keys"
}

test_linked_captain_hold_stops_before_inventory_completion() {
  local dir home send state out
  dir="$TMP_ROOT/linked-captain-hold"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" hold ship-route \
      --title "Choose the delivery route" --reason "captain route decision pending" \
      --repo sample --origin ship >/dev/null \
    || fail "could not create the linked captain-held task"
  out=$(run_continue "$home" "$send" "$state") || fail "linked-hold continuation execution failed"
  [ "$out" = 'result=refused task=ship reason=open-decision-or-blocker' ] \
    || fail "linked captain hold did not stop validation before inventory completion: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "linked captain-held task received validation delivery"
  pass "linked captain holds block delivery before inventory completion"
}

test_durable_only_producer_refusal_is_visible_once_per_preflight() {
  local dir home stub log out count
  dir="$TMP_ROOT/durable-producer-refusal"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  : > "$home/state/.wake-queue"
  printf '%s\n' "$$" > "$home/state/.lock"
  stub="$dir/continue"; log="$dir/delivery.log"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_PREFLIGHT_LOG:?}"
printf 'result=refused task=%s reason=unverifiable-status-producer\n' "$1"
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-delivery-preflight.sh") || fail "durable producer refusal preflight failed"
  count=$(printf '%s\n' "$out" \
    | grep -c '^result=refused task=ship reason=unverifiable-status-producer$')
  [ "$count" -eq 1 ] || fail "durable producer refusal was hidden or duplicated: $out"
  [ "$(cat "$log")" = ship ] || fail "durable producer candidate was not deduplicated"
  pass "durable-only producer refusals remain visible and deduplicated"
}

test_fleet_and_bearings_project_pending_continuation() {
  local dir home send state fakebin snapshot bearings head active_snapshot active_bearings monitoring_bearings terminal_bearings
  dir="$TMP_ROOT/fleet-projection"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  run_continue "$home" "$send" "$state" >/dev/null || fail "projection continuation failed"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-ship\n' ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'working\nesc to interrupt\n' ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$snapshot" | jq -e '.tasks[] | select(.id == "ship") | .delivery_continuation.state == "pending" and .delivery_continuation.worker_unverified_busy == true' >/dev/null \
    || fail "fleet snapshot hid pending continuation or unverified busy source: $snapshot"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "validation_pending" and (.doing | contains("source unverified"))' >/dev/null \
    || fail "Bearings hid pending continuation or unverified busy source: $bearings"
  git -C "$home/projects/ship" commit -q --allow-empty -m validation-fix
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status')
    if [ "${FM_FAKE_RUN_MODE:-}" = active ]; then
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: running
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
    elif [ "${FM_FAKE_RUN_MODE:-}" = monitoring ]; then
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: running
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: "https://example.invalid/pull/1"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
    else
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: completed
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: "https://example.invalid/pull/1"
  findings: none
outcome: checks-passed
EOF
    fi
    ;;
  'axi logs') exit 0 ;;
  'runs --limit') exit 0 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  active_snapshot=$(FM_FAKE_RUN_MODE=active FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$active_snapshot" | jq -e '.tasks[] | select(.id == "ship") | .delivery_continuation.state == "pending" and .delivery_continuation.head != .delivery_continuation.current_head and .delivery_continuation.worker_run_attributed == true' >/dev/null \
    || fail "fleet snapshot treated attributed run head advancement as a conflict: $active_snapshot"
  active_bearings=$(FM_FAKE_RUN_MODE=active FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$active_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "working" and (.doing | contains("validating (running)")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings let pending delivery hide an attributed active run: $active_bearings"
  printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$home/state/ship.status"
  monitoring_bearings=$(FM_FAKE_RUN_MODE=monitoring FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$monitoring_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "done" and (.doing | contains("checks green")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings lost an attributed monitoring run reconciled through status: $monitoring_bearings"
  terminal_bearings=$(FM_FAKE_RUN_MODE=terminal FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$terminal_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "done" and (.doing | contains("checks green: PR ready for review")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings let pending delivery hide an attributed terminal run: $terminal_bearings"
  pass "fleet and Bearings preserve pending delivery behind authoritative run state"
}

test_advanced_head_surfaces_continuation_conflict() {
  local dir home send state out head snapshot bearings fakebin
  dir="$TMP_ROOT/head-conflict"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  run_continue "$home" "$send" "$state" >/dev/null || fail "initial head continuation failed"
  git -C "$home/projects/ship" commit -q --allow-empty -m advance
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s [spawn-gen=g1] advanced head\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "advanced head execution failed"
  [[ "$out" == *'reason=continuation-head-mismatch'* ]] || fail "old delivery was accepted for the advanced head: $out"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-ship\n' ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$snapshot" | jq -e '.tasks[] | select(.id == "ship") | .delivery_continuation.state == "head-mismatch" and .delivery_continuation.head != .delivery_continuation.current_head' >/dev/null \
    || fail "fleet snapshot hid the exact-head continuation conflict: $snapshot"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "validation_conflict"' >/dev/null \
    || fail "Bearings hid the exact-head continuation conflict: $bearings"
  pass "advanced committed heads refuse stale delivery and surface the conflict"
}

test_pi_drain_preflights_before_presenting_committed_ready_rows() {
  local dir home state stub log out err status first_label first_row
  dir="$TMP_ROOT/pi-drain-preflight"
  home="$dir/home"
  state="$home/state"
  stub="$dir/continue"
  log="$dir/delivery.log"
  mkdir -p "$state"
  printf '%s\n' "$$" > "$state/.lock"
  fm_write_meta "$state/ship.meta" "window=default:w1:p1" "project=sample"
  printf 'done: committed fixture\n' > "$state/ship.status"
  printf '1\t1\tsignal\tship.status\tsignal: ship.status\n' > "$state/.wake-queue"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
if [ "${FM_PREFLIGHT_RETRY:-0}" = 1 ]; then
  printf 'result=retry task=%s reason=validation-attribution-unavailable\n' "$1"
  exit 0
fi
if [ -e "${FM_PREFLIGHT_MARK:?}" ]; then
  printf 'result=already-delivered task=%s\n' "$1"
else
  printf '%s\n' "$1" > "$FM_PREFLIGHT_MARK"
  printf 'sent\n' >> "${FM_PREFLIGHT_LOG:?}"
  printf 'result=sent task=%s\n' "$1"
fi
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/first.err") || fail "Pi preflight drain failed: $(cat "$dir/first.err")"
  first_label=$(printf '%s\n' "$out" | grep -n '^Deterministic delivery continuation preflight:$' | cut -d: -f1)
  first_row=$(printf '%s\n' "$out" | grep -n "$(printf '\tsignal\tship.status\t')" | cut -d: -f1)
  [ -n "$first_label" ] && [ -n "$first_row" ] && [ "$first_label" -lt "$first_row" ] \
    || fail "Pi drain presented committed-ready work before deterministic continuation: $out"
  [ "$(cat "$log")" = sent ] || fail "Pi drain did not create exactly one continuation"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/replay.err") || fail "Pi replay drain failed: $(cat "$dir/replay.err")"
  printf '%s\n' "$out" | grep -q '^result=already-delivered task=ship$' \
    || fail "Pi replay did not converge on the durable continuation: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "Pi replay created a second continuation"

  rm -f "$dir/delivered"
  : > "$log"
  printf '1\t2\tcheck\tcaptain-request\tcheck: captain-request\n' >> "$state/.wake-queue"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 FM_PREFLIGHT_RETRY=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/retry.out" 2> "$dir/retry.err" || status=$?
  [ "$status" -eq 0 ] || fail "transient Pi preflight blocked an unrelated captain wake: $(cat "$dir/retry.err")"
  err=$(cat "$dir/retry.out")
  printf '%s\n' "$err" | grep -q '^result=retry task=ship reason=validation-attribution-unavailable$' \
    || fail "transient Pi preflight did not surface its retry obligation: $err"
  ! grep -q "$(printf '\tsignal\tship.status\t')" "$dir/retry.out" \
    || fail "transient Pi preflight exposed committed-ready work before settling"
  grep -q "$(printf '\tcheck\tcaptain-request\t')" "$dir/retry.out" \
    || fail "transient Pi preflight hid an unrelated captain request"
  grep -q "$(printf '\tsignal\tship.status\t')" "$state/.wake-queue" \
    || fail "transient Pi preflight consumed its durable wake"
  pass "Pi queue intake preflights committed-ready rows before presentation"
}

test_unmapped_stale_row_does_not_abort_preflight() {
  local dir home state out
  dir="$TMP_ROOT/unmapped-stale-row"
  home="$dir/home"
  state="$home/state"
  mkdir -p "$state"
  printf '%s\n' "$$" > "$state/.lock"
  printf '1\t1\tstale\tretired-pane\tstale: retired-pane\n1\t2\tcheck\tcaptain-request\tcheck: captain-request\n' \
    > "$state/.wake-queue"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/drain.err") \
    || fail "an unmapped stale row aborted Pi preflight: $(cat "$dir/drain.err")"
  printf '%s\n' "$out" | grep -q "$(printf '\tstale\tretired-pane\t')" \
    || fail "the unmapped stale row was not left for normal presentation"
  printf '%s\n' "$out" | grep -q "$(printf '\tcheck\tcaptain-request\t')" \
    || fail "the unmapped stale row hid a captain request"
  pass "unmapped stale rows remain presentable without continuation lookup"
}

test_exactly_once_delivery_and_replay
test_refusals_preserve_stop
test_active_run_and_unavailable_attribution_refuse
test_current_brief_requires_canonical_receipt
test_promoted_contract_recovers_durable_continuation
test_unserialized_canonical_producer_refuses_visibly_without_stranding_status
test_inbox_failure_remains_retryable
test_strict_run_attribution_distinguishes_absence_from_query_failure
test_identity_and_committed_head_requirements
test_replacement_incarnation_rejects_prior_receipt
test_head_advance_during_attribution_refuses_stale_delivery
test_decision_change_at_publication_refuses_stale_delivery
test_historical_receipt_requires_exact_head_provenance
test_terminal_receipt_and_existing_lease_retry
test_killed_delivery_operation_does_not_strand_session_lease
test_reused_delivery_pid_does_not_preserve_lease
test_pi_empty_drain_recovers_unqueued_durable_candidate
test_pi_empty_drain_requeues_unqueued_retry
test_non_pi_empty_drain_initializes_missing_queue
test_transferred_captain_hold_stops_delivery
test_origin_captain_hold_stops_delivery_without_decision_keys
test_linked_captain_hold_stops_before_inventory_completion
test_durable_only_producer_refusal_is_visible_once_per_preflight
test_fleet_and_bearings_project_pending_continuation
test_advanced_head_surfaces_continuation_conflict
test_pi_drain_preflights_before_presenting_committed_ready_rows
test_unmapped_stale_row_does_not_abort_preflight
echo "all fm-delivery-continue tests passed"
