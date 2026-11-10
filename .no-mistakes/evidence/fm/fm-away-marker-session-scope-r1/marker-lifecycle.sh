#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M71C3BT7531H11V7JNQG8V64
LAB=$(mktemp -d "$PWD/.lab.XXXXXX")
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX_TMPDIR="$PWD/.t"
mkdir -p "$TMUX_TMPDIR"
cleanup() {
  set +e
  if [ -n "${TMUX:-}" ]; then "$ROOT/bin/fm-afk-launch.sh" stop; fi
  TMUX_TMPDIR="$ROOT/.t" tmux -L fm-lab kill-server 2>/dev/null
  rm -rf "$LAB" "$ROOT/.t"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
# Execute real lifecycle/daemon with a synthetic codex primary identity, not a
# substitute daemon, watcher, pane reader, or delivery implementation.
export FM_TEST_SEAM=1 FM_TEST_HARNESS=codex
export FM_HOUSEKEEPING_TICK=1 FM_HEARTBEAT_SCAN_SECS=300 FM_WEDGE_ALARM_CHANNEL=off
export FM_ESCALATE_BATCH_SECS=3600 FM_MAX_DEFER_SECS=0
TMUX_TMPDIR="$ROOT/.t" tmux -L fm-lab new-session -d -x 120 -y 36 -s primary -c "$ROOT" 'exec /bin/bash --noprofile --norc'
export TMUX=$(TMUX_TMPDIR="$ROOT/.t" tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
export FM_SUPERVISOR_TARGET=$(tmux display-message -p -t primary '#{pane_id}') FM_SUPERVISOR_BACKEND=tmux
ST=$LAB/state
launch() { "$ROOT/bin/fm-afk-launch.sh" "$@"; }
families=(stale reported-stale dialog paused pause-until-due)
seed() {
  for task in done-worker wait-worker; do
    for family in "${families[@]}"; do
      printf '%s\n' "$(( $(date +%s) - 172801 ))" > "$ST/.subsuper-$family-$task"
    done
  done
}
show() {
  python3 - "$ST" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
for f in sorted(p.iterdir()):
 if f.is_file() and (f.name.startswith('.subsuper-') or f.name in ('.wake-queue','.afk','done-worker.status','done-worker.meta')):
  print(f.name+': '+repr(f.read_text()))
PY
}
no_markers() {
  for family in "${families[@]}"; do
    for f in "$ST/.subsuper-$family-"*; do [ ! -e "$f" ] || { echo "UNEXPECTED $f"; return 1; }; done
  done
}
durable() {
  [ "$(cat "$ST/.subsuper-seen-status-sentinel")" = 'classification-position' ]
  [ "$(cat "$ST/.wake-queue")" = '' ]
  [ -s "$ST/done-worker.status" ] && [ -s "$ST/done-worker.meta" ]
}
printf 'classification-position\n' > "$ST/.subsuper-seen-status-sentinel"
: > "$ST/.wake-queue"
printf 'done [at=%s]: PR https://example.test/o/r/pull/1 checks green\n' "$(date +%s)" > "$ST/done-worker.status"
printf 'window=primary:0\nbackend=tmux\nharness=codex\n' > "$ST/done-worker.meta"

echo '=== SCENARIO 1: return without a running daemon clears ten session markers ==='
seed
show
launch enter --words 'Supervise the disposable lab only'
launch stop
no_markers; durable; [ ! -e "$ST/.afk" ]; [ ! -e "$ST/.afk-contract" ]
show
echo 'RESULT: no-daemon return cleared all five families for both workers; durable state kept; posture archived'

echo '=== SCENARIO 2: crash leftovers cleared before a real daemon first housekeeping ==='
seed
# Match audit failure shape for the actual idle done worker, without its report/pause companions.
rm -f "$ST/.subsuper-reported-stale-done-worker" "$ST/.subsuper-dialog-done-worker" "$ST/.subsuper-paused-done-worker" "$ST/.subsuper-pause-until-due-done-worker"
printf '%s\n' "$(date +%s)" > "$ST/.subsuper-last-scan"
show
launch enter --words 'Supervise the disposable lab only'
launch start
sleep 6
[ -f "$ST/.supervise-daemon.pid" ]
pid=$(cat "$ST/.supervise-daemon.pid")
kill -0 "$pid"
no_markers; durable
[ -e "$ST/.subsuper-last-housekeep" ]
if grep -q 'possible wedge' "$ST/.subsuper-escalations" 2>/dev/null; then echo 'UNEXPECTED OLD WEDGE'; exit 1; fi
show
cp "$ST/.subsuper.log" "$E/daemon.log" 2>/dev/null || true
echo "RESULT: real daemon pid=$pid alive; housekeeping ran; old 172801-second clock absent and no false wedge buffered"

echo '=== SCENARIO 3: refresh preserves current session markers byte-for-byte ==='
seed
python3 - "$ST" "$E/refresh-before.json" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]); names=('stale','reported-stale','dialog','paused','pause-until-due')
json.dump({f.name:f.read_text() for n in names for f in p.glob('.subsuper-'+n+'-*')},open(sys.argv[2],'w'),sort_keys=True)
PY
# Stop the daemon temporarily so housekeeping cannot legitimately consume synthetic markers.
kill -STOP "$pid"
launch start
python3 - "$ST" "$E/refresh-before.json" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]); expected=json.load(open(sys.argv[2]))
assert len(expected)==10
for name,value in expected.items(): assert (p/name).read_text()==value,name
print('All ten current-session marker contents unchanged by refresh')
PY
show
kill -CONT "$pid"
# Freeze housekeeping's cadence so the shutdown scenario has all seeded markers.
export FM_HOUSEKEEPING_TICK=3600
launch stop
no_markers; durable
[ ! -e "$ST/.afk" ]
if kill -0 "$pid" 2>/dev/null; then echo 'daemon still alive'; exit 1; fi
show
echo 'RESULT: refresh retained all five families; return with a real daemon stopped it and cleared all families'

echo '=== SCENARIO 4: failed launch restores clocks and delivery artifacts ==='
seed
printf 'pending lab escalation\n' > "$ST/.subsuper-escalations"
printf 'prior flag\n' > "$ST/.afk"
launch enter --words 'Supervise the disposable lab only'
python3 - "$ST" "$E/rollback-before.json" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]);json.dump({f.name:f.read_text() for f in p.iterdir() if f.is_file() and (f.name.startswith('.subsuper-') or f.name=='.afk')},open(sys.argv[2],'w'),sort_keys=True)
PY
set +e
FM_SUPERVISOR_BACKEND=zellij launch start
rc=$?
set -e
[ "$rc" -ne 0 ]
python3 - "$ST" "$E/rollback-before.json" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]);expected=json.load(open(sys.argv[2]))
for name,value in expected.items(): assert (p/name).read_text()==value,name
print('Failed unsupported-backend launch restored every saved marker, delivery buffer, and away flag byte-for-byte')
PY
show
echo "RESULT: launch refused with exit=$rc and restored pre-launch episode state"
launch stop

echo '=== SCENARIO 5: fresh native preparation clears prior episode state ==='
seed
launch enter --words 'Supervise the disposable lab only'
launch start-native
no_markers; durable
[ "$(cat "$ST/.afk-daemon-terminal")" = "$(printf 'none\t-\tnative')" ]
show
echo 'RESULT: native preparation removed prior clocks and report/pause/dialog markers, kept durable worker state'
launch stop
no_markers; durable
# Retain exact product log, wherever this version owns it.
for f in "$ST"/*.log "$ST"/.*log; do
  [ ! -f "$f" ] || cp "$f" "$E/$(basename "$f")"
done
echo 'ALL SCENARIOS COMPLETED'
