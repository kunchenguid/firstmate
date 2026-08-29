#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and unchanged snapshot path.
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

# Publication-only boundary: poison the ledger with a structurally complete but
# semantically false state, then prove the current parent snapshot still computes
# the home summary from the owning home instead of consuming this file.
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
  and .secondmate_current.records[0].current.state == "externally_held"
  and any(.secondmate_current.records[0].holds[]; .id == "ledger-task")
' "$TMP_ROOT/parent-snapshot.json" >/dev/null \
  || fail "fleet snapshot consumed the poisoned publication instead of recomputing its established path"
pass "fleet snapshot remains a non-consumer of the ledger"

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
grep -F 'refresh exceeded its 1-second deadline' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "publication lock timeout was not logged"
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
