#!/usr/bin/env bash
# Integration: real fork watcher/guard journeys, relocated sampler, then absent add-on.
# Usage: bash host-memory/tests/fm-host-memory.test.sh <read-only-fork-checkout>
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: fm-host-memory.test.sh <fork-checkout>' >&2; exit 2; }
addons=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
# Independent clone, never a shared worktree and never an edit to the supplied fork.
git clone -q --no-hardlinks "$1" "$d/fork"
mkdir -p "$d/home" "$d/tmp" "$d/config" "$d/data" "$d/run"
export HOME="$d/home" TMPDIR="$d/tmp" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" XDG_RUNTIME_DIR="$d/run"
export FM_TEST_SKIP_ORPHAN_REAP=1 FM_ADDONS_DIR="$addons" FM_BACKEND=tmux TMUX=''
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_TEST_LIB_SOURCED
cd "$d/fork"
echo '=== current fork with add-on checkout available (no hook installed yet) ==='
bash tests/fm-jev-mem-guard.test.sh
# Apply prospective sampler seams ONLY in our scratch clone; tests assert behavior, not source bytes.
python3 - "$addons" <<'PY'
import pathlib
import sys

p = pathlib.Path('bin/fm-watch.sh')
s = p.read_text()
s = s.replace('. "$SCRIPT_DIR/fm-host-memory-sampler.sh"',
    'if [ -f "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/host-memory/bin/fm-host-memory-lib.sh" ]; then . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/host-memory/bin/fm-host-memory-lib.sh"; fi')
s = s.replace('[ "$owns_lock" -ne 1 ] || fm_memory_sampler_stop',
    'if declare -F fm_memory_sampler_stop >/dev/null && [ "$owns_lock" -eq 1 ]; then fm_memory_sampler_stop; fi')
for verb in ('start', 'restart'):
    line = f'fm_memory_sampler_ensure || triage_log "host memory sampler failed to {verb}"'
    s = s.replace(line, f'if declare -F fm_memory_sampler_ensure >/dev/null; then {line}; fi')
p.write_text(s)
# Older fork tests source the old public path to drive tick publication failures.
# Keep that entrypoint in the scratch clone, but run the add-on implementation.
pathlib.Path('bin/fm-host-memory-sampler.sh').write_text(
    '. "${FM_ADDONS_DIR}/host-memory/bin/fm-host-memory-lib.sh"\n')
PY
echo '=== relocated add-on sampler through optional watcher seam ==='
bash tests/fm-jev-mem-guard.test.sh
export FM_ADDON_TEST_ROOT="$addons" FM_ADDON_ABSENT_ROOT="$d/absent-addons"
echo '=== ordinary watcher check with present and absent add-on ==='
bash -s <<'SH'
set -u
# shellcheck source=/dev/null
. "$PWD/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-addon-absent)
for mode in present absent; do
  if [ "$mode" = present ]; then export FM_ADDONS_DIR="$FM_ADDON_TEST_ROOT"; else export FM_ADDONS_DIR="$FM_ADDON_ABSENT_ROOT"; fi
  case=$(make_case "Umer-$mode")
  mkdir -p "$case/proc/pressure"
  printf 'MemAvailable: 41943040 kB\n' > "$case/proc/meminfo"
  printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$case/proc/pressure/memory"
  cat > "$case/state/ordinary.check.sh" <<'CHECK'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/.host-memory-sampler.pid" ]; then
  read -r pid _ < "$FM_HOME/state/.host-memory-sampler.pid"
  ps -ww -p "$pid" -o args= > "$FM_HOME/sampler-command"
fi
echo 'Umer check completed'
CHECK
  chmod 700 "$case/state/ordinary.check.sh"
  FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" "$ROOT/bin/fm-check-register.sh" ordinary >/dev/null || fail 'custom check registration failed'
  rc=0
  env PATH="$case/fakebin:$PATH" FM_HOME="$case" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/no-cgroup" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 timeout 20 "$ROOT/bin/fm-watch.sh" > "$case/out" 2> "$case/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$mode add-on watcher exited $rc: $(<"$case/err")"
  assert_contains "$(<"$case/out")" 'Umer check completed' "$mode add-on keeps ordinary watcher behavior"
  if [ "$mode" = present ]; then
    assert_contains "$(<"$case/sampler-command")" "$FM_ADDON_TEST_ROOT/host-memory/bin/fm-host-memory-sampler.sh run" 'the running sampler comes from the add-on'
    [ -s "$case/state/host-memory.tsv" ] || fail 'relocated sampler did not record a sample'
  else
    for f in "$case/state"/*host-memory* "$case/state"/.*host-memory*; do
      [ ! -e "$f" ] || fail "absent add-on created sampler state: $f"
    done
  fi
  [ ! -s "$case/err" ] || fail "$mode add-on emitted an error: $(<"$case/err")"
  pass "$mode add-on: ordinary check succeeds with correct sampler presence"
done
SH
echo 'PASS current fork, relocated lifecycle and absent add-on integration'
