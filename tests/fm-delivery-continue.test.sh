#!/usr/bin/env bash
# Behavior tests for the committed-ready validation continuation owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTINUE="$ROOT/bin/fm-delivery-continue.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-continue)

make_fixture() {
  local dir=$1 home wt head
  home="$dir/home"
  wt="$home/projects/ship"
  mkdir -p "$home/state" "$home/data/ship" "$home/projects"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -qb fm/ship
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$home/state/ship.meta" "window=fm:fm-ship" "worktree=$wt" "project=sample" "harness=codex" "kind=ship" "mode=no-mistakes" "spawn_gen=g1"
  printf 'done: committed %s focused checks passed\n' "$head" > "$home/state/ship.status"
  printf 'Delivery contract: mode=no-mistakes\nFirstmate will then instruct you to run /no-mistakes to validate and ship a PR.\n' > "$home/data/ship/brief.md"
  printf '%s\n' "$home"
}

make_send_stub() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -eu
task=$1; shift
[ "$1" = --fire-and-forget ]; shift 2
message=$*
. "${FM_TEST_ROOT:?}/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "${FM_STATE_OVERRIDE:?}" "$task" "$message" fire-and-forget >/dev/null
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
  local dir home send state first second count
  dir="$TMP_ROOT/exactly-once"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" unknown
  first=$(run_continue "$home" "$send" "$state") || fail "initial continuation failed"
  second=$(run_continue "$home" "$send" "$state") || fail "replay continuation failed"
  count=$(find "$home/state/ship.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = 'result=sent task=ship' ] || fail "initial result wrong: $first"
  [ "$second" = 'result=already-delivered task=ship' ] || fail "replay result wrong: $second"
  [ "$count" = 1 ] || fail "replay created $count delivery records"
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

test_exactly_once_delivery_and_replay
test_refusals_preserve_stop
test_active_run_and_head_mismatch_refuse
echo "all fm-delivery-continue tests passed"
