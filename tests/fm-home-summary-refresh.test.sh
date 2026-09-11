#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-refresh)
HOME_DIR="$TMP_ROOT/mate-home"
CADENCE_HOME="$TMP_ROOT/cadence-home"
PARENT_HOME="$TMP_ROOT/parent-home"
LARGE_HOME="$TMP_ROOT/large-home"
STATELESS_HOME="$TMP_ROOT/stateless-home"
LARGE_CHILD_HOME="$TMP_ROOT/large-child-home"
LARGE_PARENT_HOME="$TMP_ROOT/large-parent-home"
DECISIONS_HOME="$TMP_ROOT/decisions-home"
OVERSIZED_HOME="$TMP_ROOT/oversized-home"
MIRROR_CHILD_HOME="$TMP_ROOT/mirror-child-home"
MIRROR_PARENT_HOME="$TMP_ROOT/mirror-parent-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
LOCK_HOLDER_PID=

cleanup() {
  local pid
  case "$SLOW_WORKER_PGID" in
    ''|*[!0-9]*) ;;
    *) kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 || true ;;
  esac
  for pid in "$WATCH_PID" "$SLOW_WRITER_PID" "$SLOW_NM_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NM_MARKER:-}" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_MARKER"
  sleep "${FM_TEST_NM_SLEEP:-30}"
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" \
  "$HOME_DIR/projects/task" "$HOME_DIR/bin"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
fm_git_init_commit "$HOME_DIR/projects/task"
git -C "$HOME_DIR/projects/task" checkout -q -b fm/ledger-task
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] ledger-task - Publish the home ledger (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$HOME_DIR/state/ledger-task.meta" \
  "window=fmtest:fm-ledger-task" \
  "worktree=$HOME_DIR/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.ledger123456"
busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" ledger-task)
"$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" ledger-task idle \
  --gen "$busy_gen" --source claude-hook --event stop

NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
NOW_TWO=2026-08-28T10:01:00Z
EPOCH_TWO=1787911260
NOW_THREE=2026-08-28T10:02:00Z
EPOCH_THREE=1787911320

run_writer() {  # <now> <epoch> [writer args...]
  local now=$1 epoch=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$now" FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    "$WRITER" "$@"
}

run_producer() {  # <now> <epoch>
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$1" FM_SNAPSHOT_NOW_EPOCH="$2" \
    "$SNAPSHOT" --secondmate-home-summary
}

wait_for_ledger_generation() {  # <generated> [tenths]
  local want=$1 attempts=${2:-150} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(jq -r '.generated // ""' "$HOME_DIR/state/home-summary.json" 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_writer "$NOW_ONE" "$EPOCH_ONE" || fail "initial home-summary publication failed"
jq -e --arg home "$HOME_DIR" --arg now "$NOW_ONE" --argjson epoch "$EPOCH_ONE" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and .generated == $now
  and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "initial ledger did not expose the extended producer schema"

PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$HOME_DIR/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$HOME_DIR/state/.last-watcher-beat" ] \
  || fail "the real watcher did not begin polling: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
printf 'blocked [key=fixture-dependency]: waiting for the fixture dependency\n' \
  >> "$HOME_DIR/state/ledger-task.status"
wait_for_ledger_generation "$NOW_TWO" \
  || fail "a status append did not refresh the ledger within the watcher cadence"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=

run_producer "$NOW_TWO" "$EPOCH_TWO" > "$TMP_ROOT/fresh-summary.json" \
  || fail "fresh secondmate-home-summary production failed"
jq -S 'del(.generated, .generated_epoch)' "$HOME_DIR/state/home-summary.json" \
  > "$TMP_ROOT/published-normalized.json"
jq -S 'del(.generated, .generated_epoch)' "$TMP_ROOT/fresh-summary.json" \
  > "$TMP_ROOT/fresh-normalized.json"
cmp -s "$TMP_ROOT/published-normalized.json" "$TMP_ROOT/fresh-normalized.json" \
  || fail "the status-triggered ledger differed from the real fresh producer"
pass "watcher-carried status append publishes the real home summary"

# A structured in-flight inventory above Linux MAX_ARG_STRLEN must remain
# publishable through both fleet snapshot modes and the real home-summary writer.
mkdir -p "$LARGE_HOME/state" "$LARGE_HOME/data" "$LARGE_HOME/config" \
  "$LARGE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$LARGE_HOME/AGENTS.md"
printf 'large\n' > "$LARGE_HOME/.fm-secondmate-home"
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 1200 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_HOME/data/backlog.md"
[ "$(wc -c < "$LARGE_HOME/data/backlog.md")" -gt 131072 ] \
  || fail "large in-flight fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-snapshot.json" \
  || fail "fleet snapshot json mode failed for a large backlog"
jq -e '.schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | length) == 1200
  and (.main_inventory.orphan_in_flight | length) == 1200' \
  "$TMP_ROOT/large-snapshot.json" >/dev/null \
  || fail "large fleet snapshot did not preserve the orphan inventory"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/large-summary.json" \
  || fail "secondmate home-summary mode failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$TMP_ROOT/large-summary.json" \
  >/dev/null || fail "large secondmate home-summary output was not valid"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' \
  "$LARGE_HOME/state/home-summary.json" >/dev/null \
  || fail "large secondmate home-summary was not published"
pass "large backlog snapshots and home-summary publication stay within exec limits"

mkdir -p "$STATELESS_HOME/data" "$STATELESS_HOME/config" \
  "$STATELESS_HOME/projects"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$STATELESS_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STATELESS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/stateless-snapshot.json" \
  || fail "fleet snapshot json mode failed without a state directory"
jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | length) == 0' \
  "$TMP_ROOT/stateless-snapshot.json" >/dev/null \
  || fail "stateless fleet snapshot output was not valid"
[ ! -e "$STATELESS_HOME/state" ] \
  || fail "fleet snapshot created operational state for transport files"
pass "fleet snapshot transport does not require or mutate operational state"

mkdir -p "$LARGE_CHILD_HOME/state" "$LARGE_CHILD_HOME/data" \
  "$LARGE_CHILD_HOME/config" "$LARGE_CHILD_HOME/projects" "$LARGE_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$LARGE_CHILD_HOME/AGENTS.md"
printf 'large-child\n' > "$LARGE_CHILD_HOME/.fm-secondmate-home"
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 600 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "large child home-summary publication failed"
large_child_bytes=$(wc -c < "$LARGE_CHILD_HOME/state/home-summary.json")
[ "$large_child_bytes" -gt 131072 ] && [ "$large_child_bytes" -le 262144 ] \
  || fail "large child ledger did not cross only the per-argument limit: $large_child_bytes"
mkdir -p "$LARGE_PARENT_HOME/state" "$LARGE_PARENT_HOME/data" \
  "$LARGE_PARENT_HOME/config" "$LARGE_PARENT_HOME/projects"
printf -- '- large-child - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$LARGE_CHILD_HOME" > "$LARGE_PARENT_HOME/data/secondmates.md"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$LARGE_PARENT_HOME/data/backlog.md"
fm_write_secondmate_meta "$LARGE_PARENT_HOME/state/large-child.meta" \
  "$LARGE_CHILD_HOME" "fmtest:fm-large-child" firstmate claude
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity"
pass "parent snapshot consumes large child ledgers without argument transport"

# A single long-lived task's whole-status-log open-decision fold has no size
# bound of its own: every still-open needs-decision/blocked note accumulates
# until resolved. That per-task payload rides through fm-fleet-snapshot.sh
# independently of the backlog-transport fix above, so it needs its own
# argv-safe proof: many distinct never-resolved decisions on one in-flight
# task, each long enough that the accumulated fold decisively exceeds Linux's
# 128 KiB MAX_ARG_STRLEN per-argument limit.
mkdir -p "$DECISIONS_HOME/state" "$DECISIONS_HOME/data" "$DECISIONS_HOME/config" \
  "$DECISIONS_HOME/projects"
printf '# Seeded Firstmate home\n' > "$DECISIONS_HOME/AGENTS.md"
printf 'decisions\n' > "$DECISIONS_HOME/.fm-secondmate-home"
cat > "$DECISIONS_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] held-task - Task with many long-held decisions (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$DECISIONS_HOME/state/held-task.meta" \
  "window=fmtest:fm-held-task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.held123456"
# Few distinct keys, each with a long note: status_open_decisions folds the
# open set with an O(n^2) per-key scan, so many short-lived keys would make
# this fixture pathologically slow without adding argv-transport coverage.
# The fold's cost tracks key COUNT; the argv limit tracks folded BYTE size, so
# few keys with long notes exercises the byte limit without that slowdown.
decisions_note=$(printf 'z%.0s' $(seq 1 2500))
i=1
while [ "$i" -le 60 ]; do
  printf 'needs-decision [key=decision-%s]: %s\n' "$i" "$decisions_note"
  i=$((i + 1))
done > "$DECISIONS_HOME/state/held-task.status"
[ "$(wc -c < "$DECISIONS_HOME/state/held-task.status")" -gt 131072 ] \
  || fail "large open-decisions fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DECISIONS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/decisions-summary.json" \
  2> "$TMP_ROOT/decisions-summary.err" \
  || fail "secondmate home-summary mode failed for many long held decisions: $(cat "$TMP_ROOT/decisions-summary.err")"
[ ! -s "$TMP_ROOT/decisions-summary.err" ] \
  || fail "secondmate home-summary mode reported an error for many long held decisions: $(cat "$TMP_ROOT/decisions-summary.err")"
jq -e '.schema == "fm-secondmate-home-summary.v1"
  and .counts.decisions_open == 60
  and .counts.endpoints == 1
  and (.endpoints | length) == 1
  and (.endpoints[0].id == "held-task")
  and (.decisions_open | length) == 20
  and (.omitted[] | select(.surface == "decisions_open") | .count) == 40' \
  "$TMP_ROOT/decisions-summary.json" >/dev/null \
  || fail "large open-decisions summary dropped or truncated the held task's decisions: $(cat "$TMP_ROOT/decisions-summary.json")"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DECISIONS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for many long held decisions"
jq -e '.schema == "fm-secondmate-home-summary.v1" and .counts.decisions_open == 60' \
  "$DECISIONS_HOME/state/home-summary.json" >/dev/null \
  || fail "large open-decisions home-summary was not published with its full decision count"
pass "many long held decisions on one task publish without exec argument transport"

# Nothing bounds a SINGLE status line: an agent appends notes directly and
# fm-procevent-remote-reply.sh mirrors a remote payload line with no size cap.
# One such line above Linux's 128 KiB MAX_ARG_STRLEN used to break every jq that
# carried it on argv - the crew-state read, the status-event composition, and the
# per-task row - and the row was dropped without any command reporting failure,
# which is what made the published summary read as an orphaned, unreadable home.
# Publish one, then require the full line back untruncated.
mkdir -p "$OVERSIZED_HOME/state" "$OVERSIZED_HOME/data" "$OVERSIZED_HOME/config" \
  "$OVERSIZED_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$OVERSIZED_HOME/AGENTS.md"
printf 'oversized\n' > "$OVERSIZED_HOME/.fm-secondmate-home"
fm_git_init_commit "$OVERSIZED_HOME/projects/task"
cat > "$OVERSIZED_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] big-line-task - Task holding one huge status line (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$OVERSIZED_HOME/state/big-line-task.meta" \
  "window=fmtest:fm-big-line-task" \
  "worktree=$OVERSIZED_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.bigline123456"
oversized_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$OVERSIZED_HOME/state" big-line-task)
"$ROOT/bin/fm-busy-event.sh" apply "$OVERSIZED_HOME/state" big-line-task idle \
  --gen "$oversized_gen" --source claude-hook --event stop
oversized_note=$(head -c 200000 /dev/zero | LC_ALL=C tr '\0' 'y')
printf 'needs-decision [key=oversized]: %s\n' "$oversized_note" \
  > "$OVERSIZED_HOME/state/big-line-task.status"
[ "$(wc -c < "$OVERSIZED_HOME/state/big-line-task.status")" -gt 131072 ] \
  || fail "oversized status-line fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$OVERSIZED_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/oversized-summary.json" \
  2> "$TMP_ROOT/oversized-summary.err" \
  || fail "secondmate home-summary mode failed for one oversized status line: $(cat "$TMP_ROOT/oversized-summary.err")"
[ ! -s "$TMP_ROOT/oversized-summary.err" ] \
  || fail "secondmate home-summary mode reported an error for one oversized status line: $(cat "$TMP_ROOT/oversized-summary.err")"
jq -e '.schema == "fm-secondmate-home-summary.v1"
  and .valid == true
  and .invalidity.kind == null
  and .counts.decisions_open == 1
  and .counts.endpoints == 1
  and (.decisions_open[0] | .id == "big-line-task" and .key == "oversized")' \
  "$TMP_ROOT/oversized-summary.json" >/dev/null \
  || fail "an oversized status line dropped the task from the home summary: $(jq -c '{valid,invalidity,counts}' "$TMP_ROOT/oversized-summary.json")"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$OVERSIZED_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/oversized-snapshot.json" \
  || fail "fleet snapshot json mode failed for one oversized status line"
jq -e --argjson bytes "${#oversized_note}" '(.tasks | length) == 1
  and (.tasks[0].id == "big-line-task")
  and (.tasks[0].current_state.state == "parked")
  and (.tasks[0].current_state.source == "status-log")
  and (.tasks[0].current_state.detail | length) == $bytes
  and (.tasks[0].hints.open_decisions | length) == 1
  and (.tasks[0].hints.open_decisions[0].summary | length) == $bytes
  and (.tasks[0].hints.last_event_text | length) > $bytes' \
  "$TMP_ROOT/oversized-snapshot.json" >/dev/null \
  || fail "the oversized status line was dropped or truncated in the fleet snapshot"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$OVERSIZED_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for one oversized status line"
jq -e '.valid == true and .counts.decisions_open == 1' \
  "$OVERSIZED_HOME/state/home-summary.json" >/dev/null \
  || fail "the oversized-status-line home summary was not published as readable"
pass "one oversized status line publishes a readable home summary untruncated"

# The same bytes reach a PARENT through the secondmate aggregation, which
# re-exports the mirrored line, its note, and the keyed decision fold. A local
# registered home covers the structured-home record and a remote route covers the
# mirrored parent-event fallback, while an ordinary task sorted AFTER the
# oversized one proves a per-task payload can no longer omit unrelated tasks.
mkdir -p "$MIRROR_CHILD_HOME/state" "$MIRROR_CHILD_HOME/data" \
  "$MIRROR_CHILD_HOME/config" "$MIRROR_CHILD_HOME/projects" "$MIRROR_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$MIRROR_CHILD_HOME/AGENTS.md"
printf 'ccc-mate\n' > "$MIRROR_CHILD_HOME/.fm-secondmate-home"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$MIRROR_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MIRROR_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "mirror child home-summary publication failed"
mkdir -p "$MIRROR_PARENT_HOME/state" "$MIRROR_PARENT_HOME/data" \
  "$MIRROR_PARENT_HOME/config" "$MIRROR_PARENT_HOME/projects/task" "$TMP_ROOT/mirrorbin"
printf '# Seeded Firstmate home\n' > "$MIRROR_PARENT_HOME/AGENTS.md"
fm_git_init_commit "$MIRROR_PARENT_HOME/projects/task"
cat > "$MIRROR_PARENT_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] aaa-big - Task holding one huge status line (repo: firstmate) (kind: ship) (since 2026-08-28)
- [ ] bbb-plain - Ordinary task sorted after it (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
{
  printf -- '- ccc-mate - local fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
    "$MIRROR_CHILD_HOME"
  printf -- '- ddd-remote - remote fixture domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: fixture work; projects: alpha; added 2026-08-28)\n'
} > "$MIRROR_PARENT_HOME/data/secondmates.md"
for mirror_id in aaa-big bbb-plain; do
  fm_write_meta "$MIRROR_PARENT_HOME/state/$mirror_id.meta" \
    "window=fmtest:fm-$mirror_id" \
    "worktree=$MIRROR_PARENT_HOME/projects/task" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=fm.$mirror_id.123456"
done
fm_write_secondmate_meta "$MIRROR_PARENT_HOME/state/ccc-mate.meta" \
  "$MIRROR_CHILD_HOME" "fmtest:fm-ccc-mate" firstmate claude
fm_write_meta "$MIRROR_PARENT_HOME/state/ddd-remote.meta" \
  "window=remote:ddd-remote" \
  "endpoint_task_id=ddd-remote" \
  "worktree=/remote/home/never-locally-present" \
  "harness=claude" \
  "kind=secondmate" \
  "mode=secondmate" \
  "home=/remote/home" \
  "remote_host=remote-mac" \
  "remote_root=/remote/root" \
  "remote_backend=herdr" \
  "remote_herdr_session=fm-remote" \
  "remote_target=fm-remote:w1:p1"
printf 'needs-decision [key=mirrored]: %s\n' "$oversized_note" \
  > "$MIRROR_PARENT_HOME/state/aaa-big.status"
printf 'working: ordinary short note\n' > "$MIRROR_PARENT_HOME/state/bbb-plain.status"
printf 'needs-decision [key=child-gate]: %s\n' "$oversized_note" \
  > "$MIRROR_PARENT_HOME/state/ccc-mate.status"
printf 'needs-decision [key=mirrored-remote]: %s\n' "$oversized_note" \
  > "$MIRROR_PARENT_HOME/state/ddd-remote.status"
cat > "$TMP_ROOT/mirrorbin/refusing-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
exit 255
SH
chmod +x "$TMP_ROOT/mirrorbin/refusing-ssh"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MIRROR_PARENT_HOME" \
  FM_SSH_BIN="$TMP_ROOT/mirrorbin/refusing-ssh" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/mirror-snapshot.json" \
  2> "$TMP_ROOT/mirror-snapshot.err" \
  || fail "parent fleet snapshot failed for mirrored oversized status lines: $(cat "$TMP_ROOT/mirror-snapshot.err")"
jq -e '[.tasks[].id] == ["aaa-big","bbb-plain","ccc-mate","ddd-remote"]' \
  "$TMP_ROOT/mirror-snapshot.json" >/dev/null \
  || fail "an oversized per-task payload omitted tasks from the parent snapshot: $(jq -c '[.tasks[].id]' "$TMP_ROOT/mirror-snapshot.json")"
jq -e --argjson bytes "${#oversized_note}" '.secondmate_current.records
  | (length == 2)
  and (.[0] | .id == "ccc-mate"
       and .provenance.summary_source == "local-ledger"
       and (.parent_event.raw | length) > $bytes
       and (.parent_event.note | length) == $bytes
       and (.parent_event.open_decisions | length) == 1
       and (.parent_event.open_decisions[0].key == "child-gate")
       and (.parent_event.reconciliation.decisions | length) == 1)
  and (.[1] | .id == "ddd-remote"
       and .provenance.selected == "parent-event-fallback"
       and (.parent_event.raw | length) > $bytes
       and (.parent_event.open_decisions | length) == 1)' \
  "$TMP_ROOT/mirror-snapshot.json" >/dev/null \
  || fail "the parent aggregation dropped a mirrored oversized status line: $(jq -c '[.secondmate_current.records[] | {id,sel:.provenance.selected,raw:(.parent_event.raw|length)}]' "$TMP_ROOT/mirror-snapshot.json")"
pass "mirrored oversized status lines survive the parent secondmate aggregation"

# The open-decision write-failure branch is the one path that still reaches exec
# arguments, so it must stay bounded: a fold small enough to fit one argument may
# ride argv, a larger fold must degrade to no open decisions, and NEITHER may drop
# the task or fail the snapshot. Inject a REAL write failure instead of asserting
# on source: give one task an id long enough that the transport filename
# "<id>.open-decisions.json" exceeds the filesystem's 255-byte name limit while the
# shorter observation filenames this loop writes first still fit, so exactly the
# open-decision write fails (ENAMETOOLONG) with the rest of the task intact.
WRITE_FAIL_ID=$(printf 'w%.0s' $(seq 1 236))
mkdir -p "$TMP_ROOT/namecheck"
if printf 'x' 2>/dev/null > "$TMP_ROOT/namecheck/$WRITE_FAIL_ID.crew-state-detail" \
  && ! printf 'x' 2>/dev/null > "$TMP_ROOT/namecheck/$WRITE_FAIL_ID.open-decisions.json"; then
  run_write_fail_snapshot() {  # <status-note> <out-json> <out-err>
    local note=$1 out=$2 err=$3 home="$TMP_ROOT/write-fail-home"
    rm -rf "$home"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
    printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
    {
      printf '%s\n' '## In flight'
      printf -- '- [ ] %s - Task whose decision transport cannot be written (repo: firstmate) (kind: ship) (since 2026-08-28)\n' \
        "$WRITE_FAIL_ID"
      printf '%s\n' '- [ ] zzz-sibling - Ordinary task sorted after it (repo: firstmate) (kind: ship) (since 2026-08-28)'
      printf '%s\n' '' '## Queued' '' '## Done'
    } > "$home/data/backlog.md"
    fm_write_meta "$home/state/$WRITE_FAIL_ID.meta" \
      "window=fmtest:fm-write-fail" "project=firstmate" "harness=claude" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=fm.writefail123456"
    fm_write_meta "$home/state/zzz-sibling.meta" \
      "window=fmtest:fm-zzz-sibling" "project=firstmate" "harness=claude" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=fm.sibling123456"
    printf 'needs-decision [key=transport]: %s\n' "$note" \
      > "$home/state/$WRITE_FAIL_ID.status"
    printf 'working: ordinary short note\n' > "$home/state/zzz-sibling.status"
    PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
      "$SNAPSHOT" --json > "$out" 2> "$err"
  }

  run_write_fail_snapshot 'pick a route' \
    "$TMP_ROOT/write-fail-small.json" "$TMP_ROOT/write-fail-small.err" \
    || fail "a failed open-decision write aborted the snapshot for a small fold: $(cat "$TMP_ROOT/write-fail-small.err")"
  jq -e --arg id "$WRITE_FAIL_ID" '[.tasks[].id] == [$id,"zzz-sibling"]
    and (.tasks[0].hints.open_decisions | length) == 1
    and (.tasks[0].hints.open_decisions[0].key == "transport")
    and (.tasks[0].hints.pending_decision == true)' \
    "$TMP_ROOT/write-fail-small.json" >/dev/null \
    || fail "a failed open-decision write lost a task or its small fold: $(jq -c '[.tasks[] | {id:(.id|length),d:(.hints.open_decisions|length)}]' "$TMP_ROOT/write-fail-small.json")"

  # The same failed write with a fold far above the per-argument limit must not
  # hand those bytes to exec: the row survives with no open decisions rather than
  # taking the whole task down with a failed jq.
  run_write_fail_snapshot "$oversized_note" \
    "$TMP_ROOT/write-fail-big.json" "$TMP_ROOT/write-fail-big.err" \
    || fail "a failed open-decision write aborted the snapshot for an oversized fold: $(cat "$TMP_ROOT/write-fail-big.err")"
  jq -e --arg id "$WRITE_FAIL_ID" --argjson bytes "${#oversized_note}" \
    '[.tasks[].id] == [$id,"zzz-sibling"]
    and (.tasks[0].hints.open_decisions | length) == 0
    and (.tasks[0].hints.last_event_text | length) > $bytes
    and (.tasks[1].current_state.state | length) > 0' \
    "$TMP_ROOT/write-fail-big.json" >/dev/null \
    || fail "an oversized fold on the write-failure path dropped a task or rode exec arguments: $(jq -c '[.tasks[] | {id:(.id|length),d:(.hints.open_decisions|length)}]' "$TMP_ROOT/write-fail-big.json")"
  pass "a failed open-decision write keeps every task row and never hands an oversized fold to exec"
else
  echo "skip: this filesystem's name limit cannot isolate an open-decision transport write failure"
fi

mkdir -p "$CADENCE_HOME/state" "$CADENCE_HOME/data" "$CADENCE_HOME/config" \
  "$CADENCE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$CADENCE_HOME/AGENTS.md"
printf 'cadence\n' > "$CADENCE_HOME/.fm-secondmate-home"
cat > "$CADENCE_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not seed the cadence ledger"
touch -t 203801010000 "$CADENCE_HOME/state/home-summary.json"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/cadence-watch.out" 2> "$TMP_ROOT/cadence-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$CADENCE_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$CADENCE_HOME/state/.last-watcher-beat" ] \
  || fail "the cadence watcher did not complete its initial cycle"
python3 - "$CADENCE_HOME/data/backlog.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("## Queued\n\n## Done", "## Queued\n- [ ] cadence-task - Publish without a status signal (repo: firstmate) (kind: ship)\n\n## Done"))
PY
i=0
while ! jq -e 'any(.queued[]; .id == "cadence-task")' \
  "$CADENCE_HOME/state/home-summary.json" >/dev/null 2>&1; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the cadence watcher exited before publishing the backlog-only change"
  [ "$i" -lt 80 ] \
    || fail "a backlog-only change did not refresh within the configured watcher cadence"
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "live watcher cadence bounds publication staleness without signals"

# Consumer boundary: first serialize behind any watcher-started publication,
# then replace the ledger with a structurally complete but semantically false
# state. The default parent snapshot must consume that publication rather than
# silently recomputing a different view of the owning home.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not settle the ledger before the consumer check"
jq '.state = "no_active_work" | .active_children = [] | .holds = []
    | .counts.active_children = 0 | .counts.holds = 0' \
  "$HOME_DIR/state/home-summary.json" > "$HOME_DIR/state/home-summary.poisoned"
mv -f "$HOME_DIR/state/home-summary.poisoned" "$HOME_DIR/state/home-summary.json"
mkdir -p "$PARENT_HOME/state" "$PARENT_HOME/data" "$PARENT_HOME/config" "$PARENT_HOME/projects"
printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$HOME_DIR" > "$PARENT_HOME/data/secondmates.md"
cat > "$PARENT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
fm_write_secondmate_meta "$PARENT_HOME/state/mate.meta" "$HOME_DIR" \
  "fmtest:fm-mate" firstmate claude
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$SNAPSHOT" --json > "$TMP_ROOT/parent-snapshot.json" \
  || fail "parent fleet snapshot failed"
jq -e '
  .secondmate_current.records[0].provenance.selected == "structured-home"
  and .secondmate_current.records[0].provenance.summary_source == "local-ledger"
  and .secondmate_current.records[0].current.state == "no_active_work"
  and (.secondmate_current.records[0].active_children | length) == 0
  and (.secondmate_current.records[0].holds | length) == 0
' "$TMP_ROOT/parent-snapshot.json" >/dev/null \
  || fail "fleet snapshot did not consume the published local ledger: $(jq -c '.secondmate_current.records[0]' "$TMP_ROOT/parent-snapshot.json")"
pass "fleet snapshot consumes the published local ledger by default"

# Restore the established ledger, then stop a real writer while its real producer
# is blocked in a current-state read. The prior ledger must remain byte-identical
# and valid because no partial producer output is ever published at its path.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not restore the real ledger"
printf 'working: replacement summary is being computed\n' \
  >> "$HOME_DIR/state/ledger-task.status"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/prior-ledger.json"
SLOW_MARKER="$TMP_ROOT/slow-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SLOW_MARKER" FM_TEST_NM_SLEEP=30 \
  "$WRITER" > "$TMP_ROOT/killed-writer.out" 2> "$TMP_ROOT/killed-writer.err" &
SLOW_WRITER_PID=$!
i=0
while [ ! -s "$SLOW_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$SLOW_WRITER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -s "$SLOW_MARKER" ] || fail "the real producer did not reach the controlled slow current-state read"
SLOW_NM_PID=$(cat "$SLOW_MARKER" 2>/dev/null || true)
writer_pgid=$(ps -o pgid= -p "$SLOW_WRITER_PID" 2>/dev/null | tr -d '[:space:]')
ancestor=$SLOW_NM_PID
child_pgid=
i=0
while [ "$i" -lt 20 ]; do
  ancestor_pgid=$(ps -o pgid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  parent=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  if [ "$parent" = "$SLOW_WRITER_PID" ]; then
    if [ "$ancestor_pgid" != "$writer_pgid" ]; then
      SLOW_WORKER_PGID=$ancestor_pgid
    else
      SLOW_WORKER_PGID=$child_pgid
    fi
    break
  fi
  child_pgid=$ancestor_pgid
  ancestor=$parent
  i=$((i + 1))
done
case "$SLOW_WORKER_PGID" in
  ''|*[!0-9]*) fail "the bounded writer did not expose its worker process group" ;;
esac
[ "$SLOW_WORKER_PGID" != "$writer_pgid" ] \
  || fail "the bounded worker did not have an isolated process group"
kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 \
  || fail "the bounded writer process group could not be terminated"
wait "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "killing the writer exposed invalid JSON at the ledger path"
cmp -s "$TMP_ROOT/prior-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "killing the writer replaced the prior complete ledger"

# Observe the ledger continuously through one successful replacement. Every read
# must parse, and the final document must be the newly computed complete summary.
READER_FAILURE="$TMP_ROOT/reader-failure"
SUCCESS_MARKER="$TMP_ROOT/success-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SUCCESS_MARKER" FM_TEST_NM_SLEEP=1 \
  "$WRITER" > "$TMP_ROOT/success-writer.out" 2> "$TMP_ROOT/success-writer.err" &
SLOW_WRITER_PID=$!
while kill -0 "$SLOW_WRITER_PID" 2>/dev/null; do
  if ! jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null 2>&1; then
    : > "$READER_FAILURE"
    break
  fi
done
if ! wait "$SLOW_WRITER_PID"; then
  SLOW_WRITER_PID=
  fail "successful atomic replacement failed: $(cat "$TMP_ROOT/success-writer.err" 2>/dev/null)"
fi
SLOW_WRITER_PID=
[ ! -e "$READER_FAILURE" ] || fail "a reader observed torn JSON during atomic replacement"
jq -e --arg now "$NOW_THREE" --argjson epoch "$EPOCH_THREE" '
  .generated == $now and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "the successful replacement did not publish the new complete document"
pass "writer kill and replacement preserve an atomic JSON ledger"

# Best-effort mode is the contract used by every lifecycle trigger. A failed
# producer records the failure and returns success without touching the ledger.
FAILBIN="$TMP_ROOT/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAILBIN/jq"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/before-best-effort.json"
PATH="$FAILBIN:$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "best-effort refresh propagated its producer failure"
cmp -s "$TMP_ROOT/before-best-effort.json" "$HOME_DIR/state/home-summary.json" \
  || fail "failed best-effort refresh changed the prior ledger"
grep -F 'summary producer failed' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "best-effort refresh did not log its failure"
pass "best-effort publication logs and continues"

LOCK_MARKER="$TMP_ROOT/lock-held"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$HOME_DIR" "$LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$LOCK_MARKER" ] || fail "could not hold the publication lock for timeout coverage"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "lock timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on its lock"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "repeated lock timeout changed the best-effort caller result"
[ "$(grep -c 'refresh exceeded its 1-second deadline' "$HOME_DIR/state/.home-summary-refresh.log" 2>/dev/null || true)" -ge 2 ] \
  || fail "repeated publication lock timeouts vanished from failure reporting"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "best-effort refresh bounds publication lock acquisition"

HANGBIN="$TMP_ROOT/hangbin"
REAL_JQ=$(command -v jq)
mkdir -p "$HANGBIN"
cat > "$HANGBIN/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*) sleep 30 ;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$HANGBIN/jq"
started=$(date +%s)
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort \
  || fail "validation timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on validation"
grep -F 'refresh exceeded its 1-second deadline' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "publication validation timeout was not logged"
pass "best-effort refresh bounds validation and publication"

MKBIN="$TMP_ROOT/mkdir-hangbin"
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$MKBIN"
cat > "$MKBIN/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_STALLED_STATE" ]; then
    sleep 30
  fi
done
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
chmod +x "$MKBIN/mkdir"
started=$(date +%s)
PATH="$MKBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" \
  FM_TEST_STALLED_STATE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort >/dev/null 2>"$TMP_ROOT/stalled-state.err" \
  || fail "state initialization timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 6 ] \
  || fail "best-effort refresh waited $elapsed seconds before bounded state initialization"
pass "best-effort refresh bounds state initialization"

SIGNALBIN="$TMP_ROOT/signalbin"
SIGNAL_MARKER="$TMP_ROOT/worker-signaled"
REAL_ENV=$(command -v env)
mkdir -p "$SIGNALBIN"
cat > "$SIGNALBIN/env" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_TEST_SIGNAL_MARKER" ]; then
  : > "$FM_TEST_SIGNAL_MARKER"
  exit 143
fi
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$SIGNALBIN/env"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$WRITER" --best-effort \
  || fail "worker termination changed the best-effort caller result"
grep -F 'refresh worker failed with exit 143' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "worker termination was not logged at the parent boundary"
pass "best-effort refresh logs worker termination"

rm -f "$SIGNAL_MARKER" "$HOME_DIR/state/.home-summary-refresh.log"
mkdir "$HOME_DIR/state/.home-summary-refresh.log"
if ! PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" WRITER="$WRITER" python3 - <<'PY'
import os
import subprocess
import time

read_fd, write_fd = os.pipe()
os.set_blocking(write_fd, False)
try:
    while True:
        os.write(write_fd, b"x" * 4096)
except BlockingIOError:
    pass
os.set_blocking(write_fd, True)
started = time.monotonic()
try:
    result = subprocess.run(
        [os.environ["WRITER"], "--best-effort"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=write_fd,
        env=os.environ,
        timeout=7,
    )
finally:
    os.close(write_fd)
    os.close(read_fd)
elapsed = time.monotonic() - started
if result.returncode != 0:
    raise SystemExit(f"blocked failure logger changed caller result: {result.returncode}")
if elapsed >= 6:
    raise SystemExit(f"blocked failure logger exceeded its bound: {elapsed:.2f}s")
PY
then
  fail "best-effort failure reporting was not fully bounded"
fi
pass "best-effort refresh bounds failure reporting fallback"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "an unavailable failure record blocked valid publication"
jq -e --arg now "$NOW_ONE" '.generated == $now' \
  "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "valid publication did not replace the ledger with an unavailable failure record"
rmdir "$HOME_DIR/state/.home-summary-refresh.log"
pass "valid publication ignores an unavailable failure record"

# --- publication cost, beacon isolation, and failure discoverability ---------
#
# The three regressions below all came from one live incident: in a real home
# whose tasks had accumulated ordinary status history, the producer needed
# minutes, so publication burned its whole deadline on every attempt, never
# published, starved the watcher's liveness beacon while it did, and said
# nothing about any of it because --best-effort is deliberately non-fatal.

# Publication cost must scale with what a home actually accumulates. Status
# history is append-only and unbounded, and the producer folds every task's
# whole stream, so an ordinary long-lived home is the real input - not the
# one-line log a freshly seeded fixture has. This home carries a status log of
# realistic width and depth and must still publish inside a deadline well under
# the default one.
COST_HOME="$TMP_ROOT/cost-home"
mkdir -p "$COST_HOME/state" "$COST_HOME/data" "$COST_HOME/config" \
  "$COST_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$COST_HOME/AGENTS.md"
printf 'cost\n' > "$COST_HOME/.fm-secondmate-home"
fm_git_init_commit "$COST_HOME/projects/task"
cat > "$COST_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] cost-task - Publish from an accumulated home (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$COST_HOME/state/cost-task.meta" \
  "window=fmtest:fm-cost-task" \
  "worktree=$COST_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.cost123456"
cost_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COST_HOME/state" cost-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COST_HOME/state" cost-task idle \
  --gen "$cost_busy_gen" --source claude-hook --event stop
python3 - "$COST_HOME/state/cost-task.status" <<'PY'
import sys
note = ("the crewmate ran validation and reported checks on the branch "
        "after review ") * 25
with open(sys.argv[1], "w") as handle:
    for i in range(300):
        handle.write(f"working: {note}({i})\n")
    handle.write("needs-decision [key=cost-gate]: which base to rebuild from\n")
PY
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COST_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" --best-effort \
  || fail "accumulated-home publication changed the best-effort caller result"
[ -f "$COST_HOME/state/home-summary.json" ] \
  || fail "an accumulated home did not publish within a 30-second deadline: $(cat "$COST_HOME/state/.home-summary-refresh.log" 2>/dev/null)"
jq -e --arg home "$COST_HOME" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and any(.decisions_open[]; .key == "cost-gate")
' "$COST_HOME/state/home-summary.json" >/dev/null \
  || fail "the accumulated home published a ledger missing its open decision"
pass "publication completes on a home carrying accumulated status history"

# One unreachable home must not extend publication without limit. A remote
# secondmate's current state is read over ssh, and ssh's own dead-peer detection
# deliberately never kills a slow-but-alive remote command, so nothing under the
# producer bounds that read on its own. Point the transport at a stub that never
# answers and require the producer to return anyway, reporting that home as
# unknown rather than waiting on it.
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/state" "$REMOTE_HOME/data" "$REMOTE_HOME/config" \
  "$REMOTE_HOME/projects" "$TMP_ROOT/sshbin"
printf '# Seeded Firstmate home\n' > "$REMOTE_HOME/AGENTS.md"
printf 'remote\n' > "$REMOTE_HOME/.fm-secondmate-home"
cat > "$REMOTE_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] rsm - Read remote current state (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
cat > "$REMOTE_HOME/data/secondmates.md" <<'EOF'
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
fm_write_meta "$REMOTE_HOME/state/rsm.meta" \
  "window=remote:rsm" \
  "endpoint_task_id=rsm" \
  "worktree=/remote/home/never-locally-present" \
  "harness=claude" \
  "kind=secondmate" \
  "mode=secondmate" \
  "home=/remote/home" \
  "remote_host=remote-mac" \
  "remote_root=/remote/root" \
  "remote_backend=herdr" \
  "remote_herdr_session=fm-remote" \
  "remote_target=fm-remote:w1:p1"
cat > "$TMP_ROOT/sshbin/stalled-ssh" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_SSH_CALLED"
cat > /dev/null
sleep 60
SH
chmod +x "$TMP_ROOT/sshbin/stalled-ssh"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REMOTE_HOME" \
  FM_SSH_BIN="$TMP_ROOT/sshbin/stalled-ssh" FM_TEST_SSH_CALLED="$TMP_ROOT/stalled-ssh.called" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/stalled-summary.json" \
  || fail "an unreachable remote home failed the whole producer"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 40 ] \
  || fail "the producer waited $elapsed seconds despite skipping remote endpoint state"
[ ! -e "$TMP_ROOT/stalled-ssh.called" ] \
  || fail "the producer issued a remote per-task state probe"
jq -e '
  .schema == "fm-secondmate-home-summary.v1"
  and .valid == false
  and .state == "unknown"
  and .invalidity.kind == "child_current_unavailable"
  and (.invalidity.ids == ["rsm"])
  and any(.endpoints[]; .id == "rsm" and .state == "unknown")
' "$TMP_ROOT/stalled-summary.json" >/dev/null \
  || fail "an unreachable remote task was not reported as unknown"
pass "producer skips remote per-task state probes"

# The watcher's beacon is what the rest of supervision reads as proof it is
# alive. Publication is side-band, so no matter how long it takes, the beacon
# must keep advancing. Hold the publication lock for the whole observation
# window, then require the beacon to keep ticking anyway.
BEAT_HOME="$TMP_ROOT/beat-home"
mkdir -p "$BEAT_HOME/state" "$BEAT_HOME/data" "$BEAT_HOME/config" \
  "$BEAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$BEAT_HOME/AGENTS.md"
printf 'beat\n' > "$BEAT_HOME/.fm-secondmate-home"
cat > "$BEAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
BEAT_LOCK_MARKER="$TMP_ROOT/beat-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 120
' _ "$ROOT" "$BEAT_HOME" "$BEAT_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$BEAT_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_LOCK_MARKER" ] || fail "could not stall publication for beacon coverage"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_HOME_SUMMARY_TIMEOUT=90 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/beat-watch.out" 2> "$TMP_ROOT/beat-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$BEAT_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_HOME/state/.last-watcher-beat" ] \
  || fail "the stalled-publication watcher never beat: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
beat_mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' "$1"; }
seen=0
last=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
i=0
while [ "$seen" -lt 3 ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the stalled-publication watcher exited: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
  sleep 0.1
  now=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
  if [ "$now" != "$last" ]; then
    seen=$((seen + 1))
    last=$now
  fi
  i=$((i + 1))
done
[ "$seen" -ge 3 ] \
  || fail "the beacon advanced only $seen time(s) in 20 seconds while publication was stalled"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "a stalled publication does not delay the watcher liveness beacon"

RESTART_HOME="$TMP_ROOT/restart-home"
mkdir -p "$RESTART_HOME/state" "$RESTART_HOME/data" "$RESTART_HOME/config" \
  "$RESTART_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$RESTART_HOME/AGENTS.md"
printf 'restart\n' > "$RESTART_HOME/.fm-secondmate-home"
fm_git_init_commit "$RESTART_HOME/projects/task"
cat > "$RESTART_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] restart-task - Preserve publication single flight (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$RESTART_HOME/state/restart-task.meta" \
  "window=fmtest:fm-restart-task" \
  "worktree=$RESTART_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.restart123456"
RESTART_LOCK_MARKER="$TMP_ROOT/restart-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$RESTART_HOME" "$RESTART_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$RESTART_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_LOCK_MARKER" ] || fail "could not hold the publication lock for restart coverage"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-one.out" 2> "$TMP_ROOT/restart-watch-one.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the first restart watcher did not begin polling"
printf 'needs-decision [key=restart-gate]: restart the watcher\n' \
  > "$RESTART_HOME/state/restart-task.status"
i=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
kill -0 "$WATCH_PID" 2>/dev/null \
  && fail "the first restart watcher did not surface its actionable signal"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
rm -f "$RESTART_HOME/state/.last-watcher-beat"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-two.out" 2> "$TMP_ROOT/restart-watch-two.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the replacement restart watcher did not begin polling"
sleep 4
[ ! -s "$RESTART_HOME/state/.home-summary-refresh.log" ] \
  || fail "watcher restart queued refreshes behind a live publication lock: $(cat "$RESTART_HOME/state/.home-summary-refresh.log")"
if ! kill -0 "$WATCH_PID" 2>/dev/null; then
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  rm -f "$RESTART_HOME/state/.last-watcher-beat"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/restart-watch-three.out" 2> "$TMP_ROOT/restart-watch-three.err" &
  WATCH_PID=$!
  i=0
  while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
    || fail "the recovery replacement watcher did not begin polling"
fi
kill -KILL "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort \
  || fail "stale-lock recovery changed the best-effort caller result"
i=0
while [ ! -e "$RESTART_HOME/state/home-summary.json" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/home-summary.json" ] \
  || fail "a dead publication lock wedged publication"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "publication remains single-flight across watcher restart"

# A publication that keeps failing is deliberately non-fatal to its caller, so
# the only way an operator learns about it is a session start saying so. Seed
# the home-local failure record a real failing home would have, and require the
# check a session start already runs to name it - then go quiet once the ledger
# is published again.
REPORT_HOME="$TMP_ROOT/report-home"
mkdir -p "$REPORT_HOME/state" "$REPORT_HOME/data" "$REPORT_HOME/config" \
  "$REPORT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$REPORT_HOME/AGENTS.md"
printf 'report\n' > "$REPORT_HOME/.fm-secondmate-home"
cat > "$REPORT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat > "$REPORT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] refresh exceeded its 60-second deadline
[2026-08-28T09:59:00Z] refresh exceeded its 60-second deadline
EOF
run_bootstrap_detect() {
  local threshold=${2:-2}
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_HOME_SUMMARY_FAILURE_REPORT="$threshold" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

COMPAT_HOME="$TMP_ROOT/compat-home"
mkdir -p "$COMPAT_HOME/state" "$COMPAT_HOME/data" "$COMPAT_HOME/config" \
  "$COMPAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$COMPAT_HOME/AGENTS.md"
printf 'compat\n' > "$COMPAT_HOME/.fm-secondmate-home"
cat > "$COMPAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "could not seed the compatibility ledger"
cat > "$COMPAT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] historical failure before publication
[2026-08-28T09:59:00Z] historical failure before publication
[2026-08-28T10:01:00Z] first failure after publication
EOF
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "historical failures satisfied the current publication threshold: $compat_out"
    ;;
esac
printf '[2026-08-28T10:02:00Z] second failure after publication\n' \
  >> "$COMPAT_HOME/state/.home-summary-refresh.log"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
printf '%s\n' "$compat_out" | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "current publication failures did not satisfy the report threshold: $compat_out"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not republish the compatibility ledger"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "republishing did not scope retained failure history: $compat_out"
    ;;
esac
pass "bootstrap scopes retained failures to the current publication"

# A timed-out attempt can finish recording after a newer ledger is published.
# Its record must retain the attempt's ordering rather than look like a failure
# of the newer publication and keep the session-start diagnostic active.
ORDER_HOME="$TMP_ROOT/order-home"
ORDER_DATE_BIN="$TMP_ROOT/order-date-bin"
mkdir -p "$ORDER_HOME/state" "$ORDER_HOME/data" "$ORDER_HOME/config" \
  "$ORDER_HOME/projects" "$ORDER_DATE_BIN"
printf '# Seeded Firstmate home\n' > "$ORDER_HOME/AGENTS.md"
printf 'order\n' > "$ORDER_HOME/.fm-secondmate-home"
cat > "$ORDER_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
REAL_DATE=$(command -v date)
cat > "$ORDER_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -u ] && [ "$2" = +%Y-%m-%dT%H:%M:%SZ ]; then
  python3 - "$FM_TEST_ORDER_START" "$FM_TEST_ORDER_EARLY" "$FM_TEST_ORDER_LATE" <<'PY'
import sys
import time

started = float(sys.argv[1])
print(sys.argv[2] if time.time() - started < 1 else sys.argv[3])
PY
  exit 0
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
chmod +x "$ORDER_DATE_BIN/date"
ORDER_LOCK_MARKER="$TMP_ROOT/order-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$ORDER_HOME" "$ORDER_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$ORDER_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$ORDER_LOCK_MARKER" ] || fail "could not hold the publication lock for ordering coverage"
order_started=$(python3 -c 'import time; print(time.time())')
PATH="$ORDER_DATE_BIN:$FAKEBIN:$PATH" FM_TEST_REAL_DATE="$REAL_DATE" \
  FM_TEST_ORDER_START="$order_started" FM_TEST_ORDER_EARLY="$NOW_ONE" \
  FM_TEST_ORDER_LATE="$NOW_THREE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ORDER_HOME" FM_HOME_SUMMARY_TIMEOUT=2 \
  "$WRITER" --best-effort \
  || fail "ordered timeout changed the best-effort caller result"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not publish after the ordered timeout"
order_out=$(run_bootstrap_detect "$ORDER_HOME" 1)
case "$order_out" in
  *HOME_SUMMARY:*)
    fail "a pre-publication attempt was reported after the newer ledger: $order_out"
    ;;
esac
pass "failure records preserve refresh attempt ordering"

report_out=$(run_bootstrap_detect "$REPORT_HOME")
printf '%s\n' "$report_out" \
  | grep -F 'HOME_SUMMARY: this home has never published state/home-summary.json' \
    >/dev/null \
  || fail "a home that never published its ledger was reported as silent: $report_out"
printf '%s\n' "$report_out" \
  | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "the publication report omitted the recorded failure count: $report_out"
printf '%s\n' "$report_out" \
  | grep -F 'refresh exceeded its 60-second deadline' >/dev/null \
  || fail "the publication report omitted the recorded reason: $report_out"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REPORT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not publish the ledger that clears the report"
report_out=$(run_bootstrap_detect "$REPORT_HOME")
case "$report_out" in
  *HOME_SUMMARY:*)
    fail "a published ledger still reported stale publication failures: $report_out"
    ;;
esac
pass "repeated publication failure is reported at session start until it clears"
