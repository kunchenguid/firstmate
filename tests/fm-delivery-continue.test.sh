#!/usr/bin/env bash
# Behavior tests for the committed-ready validation continuation owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

CONTINUE="$ROOT/bin/fm-delivery-continue.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-continue)

make_fixture() {
  local dir=$1 home wt
  home="$dir/home"
  wt="$home/projects/ship"
  mkdir -p "$home/state" "$home/data/ship" "$home/projects"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -qb fm/ship
  fm_write_meta "$home/state/ship.meta" "window=fm:fm-ship" "worktree=$wt" "project=sample" "harness=codex" "kind=ship" "mode=no-mistakes" "spawn_gen=g1"
  printf 'done: implementation committed and focused checks passed\n' > "$home/state/ship.status"
  printf 'Delivery contract: mode=no-mistakes\nFirstmate will then instruct you to run /no-mistakes to validate and ship a PR.\n' > "$home/data/ship/brief.md"
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
. "${FM_TEST_ROOT:?}/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "${FM_STATE_OVERRIDE:?}" "$task" "$message" >/dev/null
SH
  chmod +x "$path"
}

make_state_stub() {
  local path=$1 state=$2
  printf '#!/usr/bin/env bash\nprintf %s\\n %q\n' "'state: $state · source: none · unverified endpoint'" > "$path"
  chmod +x "$path"
}

run_continue() {
  local home=$1 send=$2 state=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_TEST_ROOT="$ROOT" \
    FM_DELIVERY_SEND_BIN="$send" FM_DELIVERY_CREW_STATE_BIN="$state" "$CONTINUE" ship
}

test_exactly_once_delivery_and_replay() {
  local dir home send state first second count due
  dir="$TMP_ROOT/exactly-once"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" unknown
  first=$(run_continue "$home" "$send" "$state") || fail "initial continuation failed"
  second=$(run_continue "$home" "$send" "$state") || fail "replay continuation failed"
  count=$(find "$home/state/ship.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = 'result=sent task=ship' ] || fail "initial result wrong: $first"
  [ "$second" = 'result=already-delivered task=ship' ] || fail "replay result wrong: $second"
  [ "$count" = 1 ] || fail "replay created $count delivery records"
  due=$(FM_TASK_INBOX_GRACE_SECS=0 fm_task_inbox_due_action "$home/state" ship)
  [[ "$due" == ring* ]] || fail "continuation record was excluded from acknowledgement retries: $due"
  [ ! -e "$home/state/.lease-ship" ] || fail "continuation stranded its lease"
  pass "committed-ready delivery is durable exactly once and replay-safe"
}

test_refusals_preserve_stop() {
  local dir home send state out
  dir="$TMP_ROOT/refusals"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" unknown
  { printf 'blocked [key=real]: waiting for authority\n'; cat "$home/state/ship.status"; } > "$home/state/ship.status.next"
  mv "$home/state/ship.status.next" "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "blocked result execution failed"
  [[ "$out" == *'reason=open-decision-or-blocker'* ]] || fail "open blocker was not refused: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "blocked task received validation delivery"
  pass "an open canonical blocker remains stopped"
}

test_active_run_and_head_mismatch_refuse() {
  local dir home send state out
  dir="$TMP_ROOT/active-and-mismatch"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" working
  # This state stub is deliberately unverified, so it cannot hide delivery.
  out=$(run_continue "$home" "$send" "$state") || fail "unknown busy execution failed"
  [[ "$out" == 'result=sent task=ship' ]] || fail "unverified busy source hid continuation: $out"
  rm -rf "$home/state/ship.inbox"
  make_state_stub "$state" working
  sed -i.bak 's/source: none/source: run-step/' "$state"; rm -f "$state.bak"
  out=$(run_continue "$home" "$send" "$state") || fail "active run execution failed"
  [[ "$out" == 'result=already-active task=ship' ]] || fail "active run was not recognized: $out"
  pass "unverified busy does not mask delivery while an attributed run does"
}

test_identity_and_committed_head_requirements() {
  local dir home send state out head
  dir="$TMP_ROOT/identity-and-head"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" unknown
  sed '/^spawn_gen=/d' "$home/state/ship.meta" > "$home/state/ship.meta.next"
  mv "$home/state/ship.meta.next" "$home/state/ship.meta"
  out=$(run_continue "$home" "$send" "$state") || fail "missing-incarnation execution failed"
  [[ "$out" == *'reason=missing-task-incarnation'* ]] || fail "missing incarnation was not refused: $out"
  printf 'spawn_gen=g1\n' >> "$home/state/ship.meta"
  printf 'dirty\n' > "$home/projects/ship/uncommitted.txt"
  out=$(run_continue "$home" "$send" "$state") || fail "dirty legacy receipt execution failed"
  [[ "$out" == *'reason=uncommitted-worktree'* ]] || fail "legacy receipt did not independently require a clean committed head: $out"
  rm "$home/projects/ship/uncommitted.txt"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s canonical receipt\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "canonical receipt execution failed"
  [ "$out" = 'result=sent task=ship' ] || fail "canonical committed receipt did not deliver: $out"
  pass "continuation requires an incarnation and proves both legacy and canonical committed heads"
}

test_fleet_and_bearings_project_pending_continuation() {
  local dir home send state fakebin snapshot bearings
  dir="$TMP_ROOT/fleet-projection"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" unknown
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
  pass "fleet and Bearings project the pending continuation and unverified worker activity"
}

test_exactly_once_delivery_and_replay
test_refusals_preserve_stop
test_active_run_and_head_mismatch_refuse
test_identity_and_committed_head_requirements
test_fleet_and_bearings_project_pending_continuation
echo "all fm-delivery-continue tests passed"
