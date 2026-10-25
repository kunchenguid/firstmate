#!/usr/bin/env bash
# Integration proof of the lead-wake seam. FM_TEST_FORK names a read-only Firstmate
# checkout; its bin/ and tests/ are copied privately and only the proposed step-B replacements
# are applied to the copy (tests/stage-step-b.py). The real watcher then runs the fork's lead-wake cases (tests/fm-lead-wake.test.sh):
# add-on present = the fork's lead-wake behavior, add-on absent = Kun's (no wake, no error).
# Needs tasks-axi, bash, python3.
set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${FM_TEST_FORK:?set FM_TEST_FORK to a Firstmate checkout}"
command -v tasks-axi >/dev/null || { echo "not ok - tasks-axi is required"; exit 1; }
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user XDG_CONFIG_HOME=$d/xdg-config XDG_DATA_HOME=$d/xdg-data TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork" "$d/fakebin" "$d/empty"
cp -a "$FM_TEST_FORK/bin" "$FM_TEST_FORK/tests" "$d/fork/"
python3 "$addons/lead-wake/tests/stage-step-b.py" "$d/fork/bin"
cp "$addons/lead-wake/tests/fm-lead-wake.test.sh" "$d/fork/tests/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/fakebin/tmux"
printf '#!/usr/bin/env bash\necho "state: unknown · source: none · fake default"\n' > "$d/fakebin/fm-crew-state.sh"
chmod +x "$d/fakebin/"*

fail() { echo "not ok - $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
tasks() { FM_HOME=$home "$d/fork/bin/fm-tasks-axi.sh" "$@" >/dev/null || fail "fixture: tasks $*"; }
newhome() {  # <name>
  home=$d/$1; state=$home/state
  mkdir -p "$state" "$home/config" "$home/data"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'lead-1\n' > "$home/.fm-secondmate-home"
}
# watch <addons-dir> <out> [wait-seconds]: run the real watcher; it exits on a wake.
watch() {
  local pid i=0 limit=${3:-100}
  rm -f "$state/.last-ready-work-check" "$state/.heartbeat-streak" "$state/.last-heartbeat"
  PATH="$d/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ADDONS_DIR="$1" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    bash "$d/fork/bin/fm-watch.sh" > "$2" 2>"$2.err" &
  pid=$!
  while [ "$i" -lt "$limit" ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1; fi
  wait "$pid" 2>/dev/null || true
}

# Present: the fork's lead-wake cases on the staged watcher. Absent: Kun's ring text.
FM_ADDONS_DIR=$addons bash "$d/fork/tests/fm-lead-wake.test.sh" || fail "fork lead-wake cases with the add-on present"
FM_ADDONS_DIR=$d/empty RING_TEXT="Drain pending rows in this home's wake queue, then resume idle supervision." \
  bash "$d/fork/tests/fm-lead-wake.test.sh" ring || fail "absent add-on: Kun's drain ring"

# Absent add-on: Kun behavior - no ready-work wake, no error.
newhome absent
tasks add alpha-one "first ready item"
watch "$d/empty" "$d/o5" 30 || true
! grep -q 'ready work waiting' "$d/o5" || fail "absent add-on still woke the lead: $(cat "$d/o5")"
[ ! -s "$d/o5.err" ] || fail "absent add-on wrote stderr: $(cat "$d/o5.err")"
[ ! -e "$state/.ready-work-surfaced" ] || fail "absent add-on recorded a ready-work surfacing"
ok "absent: no ready-work wake and no error (Kun behavior)"

# lane-target inheritance hook.
inherit() { FM_HOME=$home FM_ADDONS_DIR=$1 bash -c '. "$1/fm-config-inherit-lib.sh"; printf "%s\n" "$FM_INHERITABLE_CONFIG"' _ "$d/fork/bin"; }
case " $(inherit "$addons") " in *" lane-target "*) ok "present: lane-target is inheritable" ;; *) fail "lane-target not inheritable" ;; esac
case " $(inherit "$d/empty") " in *" lane-target "*) fail "absent add-on still inherits lane-target" ;; *) ok "absent: Kun's inheritable list" ;; esac
