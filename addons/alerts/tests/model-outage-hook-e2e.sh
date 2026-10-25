#!/usr/bin/env bash
# Model-outage observer reached through the step-B loader and guarded tick, over
# fixture lanes: present -> grouped wake, absent -> kun behavior (no function, no
# wake, exit 0 under set -e). FM_TEST_FORK names a read-only Firstmate checkout;
# the watcher itself is never run.
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
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$FM_TEST_FORK/bin" "$d/fork/bin"
rm -f "$d/fork/bin/fm-model-outage-lib.sh"   # step B deletes the fork-only copy
# The observer reads the backend and busy verdict through sibling libraries run
# in a bounded subshell; fake only those two, as the fork's own fixtures do.
cat > "$d/fork/bin/fm-backend.sh" <<'FAKE'
fm_backend_agent_state() { printf alive; }
fm_backend_visible_capture_supported() { return 0; }
fm_backend_visible_capture() { printf 'Upstream request failed: region denied\n'; }
FAKE
cat > "$d/fork/bin/fm-busy-lib.sh" <<'FAKE'
fm_busy_classify_semantic() { printf 'idle opencode-plugin\n'; }
FAKE

# shellcheck disable=SC2317,SC2329,SC2030 # the watcher helpers are called by the sourced library
# run <addons-dir> <wake-file>: the exact step-B watcher lines over two idle lanes
# that fail with the same provider error.
run() {
  local ad=$1 wakes=$2 state
  state=$d/state-$(basename "$wakes")
  mkdir -p "$state" "$d/live"
  (
    set -e
    export FM_HOME=$d/fork SCRIPT_DIR=$d/fork/bin STATE=$state FM_ADDONS_DIR=$ad
    # shellcheck source=/dev/null
    [ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/alerts/bin/fm-model-outage-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/alerts/bin/fm-model-outage-lib.sh"
    fm_busy_token_valid() { return 0; }
    fm_backend_visible_capture_supported() { return 0; }
    fm_busy_current_gen() { cat "$1/$2.busy-gen"; }
    fm_meta_get() { printf opencode; }
    fm_backend_target_of_meta() { printf 'fake:%s' "${1##*/}"; }
    fm_backend_of_meta() { printf fake; }
    hash_pane() { md5sum | cut -c1-12; }
    fm_wake_append() { printf '%s\n' "$3" >> "$wakes"; }
    wake() { :; }
    triage_log() { printf '%s\n' "$*" >> "$d/triage.log"; }
    for id in alpha bravo; do : > "$state/$id.meta"; printf 'g1\n' > "$state/$id.busy-gen"; done
    if declare -F fm_model_outage_tick >/dev/null; then fm_model_outage_tick || triage_log "model-error observation failed"; fi
  )
}

run "$addons" "$d/present.wakes"
grep -q 'check: model outage affected=\[alpha,bravo\]: Upstream request failed: region denied' "$d/present.wakes" \
  || { echo "FAIL: present add-on must raise one grouped outage wake" >&2; cat "$d/present.wakes" >&2 || true; exit 1; }
[ "$(wc -l < "$d/present.wakes")" -eq 1 ] || { echo "FAIL: exactly one wake expected" >&2; exit 1; }

run "$d/no-addons" "$d/absent.wakes"
[ ! -e "$d/absent.wakes" ] || { echo "FAIL: absent add-on must raise no wake" >&2; exit 1; }
[ ! -e "$d/triage.log" ] || { echo "FAIL: absent add-on must log nothing" >&2; cat "$d/triage.log" >&2; exit 1; }
# Push-transition hook: cursor and open-captain-call tasks suppress, others do not.
# shellcheck disable=SC2031,SC2317,SC2329 # the sourced hook calls the stubs
(
  export FM_HOME=$d/fork SCRIPT_DIR=$d/fork/bin STATE=$d/state-push
  mkdir -p "$STATE"
  # shellcheck source=/dev/null
  . "$addons/alerts/bin/fm-model-outage-lib.sh"
  ! fm_alerts_push_suppress cursor-task || { echo "FAIL: hook suppressed without watcher helpers" >&2; exit 1; }
  fm_meta_get() { case $1 in *cursor-task.meta) printf cursor ;; *) printf claude ;; esac; }
  task_captain_call_open() { [ "$1" = call-task ]; }
  fm_alerts_push_suppress cursor-task || { echo "FAIL: cursor task must suppress" >&2; exit 1; }
  fm_alerts_push_suppress call-task || { echo "FAIL: open captain call must suppress" >&2; exit 1; }
  ! fm_alerts_push_suppress plain-task || { echo "FAIL: ordinary task must not suppress" >&2; exit 1; }
)
echo "ok: alerts observer present -> grouped wake; absent -> kun behavior"
