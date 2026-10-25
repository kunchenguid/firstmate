#!/usr/bin/env bash
# Run the post-step-B fork journey with the add-on installed, then verify the
# optional hooks remain a no-op when it is absent.
# FM_TEST_FORK names a read-only Firstmate checkout.
set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${FM_TEST_FORK:?set FM_TEST_FORK to a Firstmate checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork" "$d/addons"
cp -a "$addons/." "$d/addons/"
cp -a "$FM_TEST_FORK/bin" "$FM_TEST_FORK/tests" "$d/fork/"
# Step B moved the journey into this add-on; restore its test without changing
# the post-step-B fork sources.
cp "$addons/wait-timers/tests/fm-wait-timers.test.sh" "$d/fork/tests/"

# Present: the unmodified fork journey over the add-on library.
(cd "$d/fork" && env -u FM_TASK_ID FM_WAIT_TIMERS_MAIN_ESCALATION_ONLY=1 FM_HOME="$d/fork" FM_ADDONS_DIR="$d/addons" bash tests/fm-wait-timers.test.sh) > "$d/present.out" 2>&1 \
  || { echo "FAIL: wait-timer journey with the add-on present" >&2; tail -20 "$d/present.out" >&2; exit 1; }

# Absent: a Main-owned overdue episode cannot enqueue its check wake without
# the optional timer hook. Use the same durable episode shape as the real journey.
( set -e
  FM_HOME="$d/fork" FM_ADDONS_DIR="$d/none"
  mkdir -p "$d/fork/state"
  printf 'blocked [key=wait]: external condition\\n' > "$d/fork/state/fixture.status"
  lib="${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh"
  task=fixture
  # shellcheck source=/dev/null
  [ ! -r "$lib" ] || . "$lib"
  if declare -F fm_wait_timers_tick >/dev/null; then fm_wait_timers_tick; fi
  if [ -n "$task" ] && declare -F fm_wait_timer_push_delivered >/dev/null; then fm_wait_timer_push_delivered "$task" window; fi
  ! declare -F fm_wait_timers_tick >/dev/null
  ! declare -F fm_wait_timer_push_delivered >/dev/null
  [ ! -e "$d/fork/state/.waiting-timers/fixture" ] ) \
  || { echo "FAIL: absent add-on must not escalate the wait" >&2; exit 1; }
echo "ok: Main-owned escalation with add-on; absent add-on does not escalate"
