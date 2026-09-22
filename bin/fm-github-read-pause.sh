#!/usr/bin/env bash
# Durably suppress Firstmate's automatic GitHub readers without deleting the
# records needed to resume them later.
#
# Usage:
#   fm-github-read-pause.sh pause
#
# pause atomically publishes state/.github-read-pause before retiring the
# contribution observer and every registered GitHub merge-poll check through
# fm-check-unregister.sh. It preserves task metadata, contribution records,
# PR-poll data, PR-poll registrations, and every other resumable sidecar.
# Repeating pause is idempotent. Startup, contribution registration, and
# fm-pr-check.sh serialize on the same marker lock, so none can re-arm a reader
# across this operation. Any malformed marker remains a pause and is reported
# for repair rather than interpreted as permission to read GitHub.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-github-read-pause-lib.sh
. "$SCRIPT_DIR/fm-github-read-pause-lib.sh"

usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; }
fail() { printf 'fm-github-read-pause: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
MODE=$1
MARKER=$(fm_github_read_pause_marker "$STATE")
LOCK="$STATE/.github-read-pause.lock"

case "$MODE" in
  pause) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
fm_lock_acquire_wait "$LOCK" || fail 'pause lock unavailable'
LOCK_HELD=1
cleanup() {
  [ "${LOCK_HELD:-0}" -eq 0 ] || fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if fm_github_read_pause_active "$STATE"; then
  fm_github_read_pause_valid "$STATE" || fail "invalid pause marker at $MARKER"
else
  device=$(fm_pr_file_device "$STATE") || fail 'state directory unavailable'
  fm_pr_regular_destination_on_device_or_absent "$MARKER" "$device" \
    || fail 'pause marker path is unsafe'
  staged=$(umask 077; mktemp "$STATE/.github-read-pause.XXXXXX") \
    || fail 'could not stage pause marker'
  if ! printf 'fm-github-read-pause-v1\n' > "$staged" \
    || ! chmod 0600 "$staged" \
    || ! fm_pr_private_file_valid "$staged" 600 "$device" \
    || ! mv -f -- "$staged" "$MARKER"; then
    rm -f -- "$staged" 2>/dev/null || true
    fail 'could not publish pause marker'
  fi
fi

failed=0
if [ -e "$STATE/contributions.check.sh" ] || [ -L "$STATE/contributions.check.sh" ] \
  || [ -e "$STATE/contributions.check-trust" ] || [ -L "$STATE/contributions.check-trust" ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-check-unregister.sh" contributions >/dev/null || failed=1
fi

for sidecar in "$STATE"/*.pr-poll; do
  [ -e "$sidecar" ] || [ -L "$sidecar" ] || continue
  id=${sidecar##*/}
  id=${id%.pr-poll}
  if ! fm_pr_task_id_valid "$id" || ! fm_pr_poll_data_parse "$sidecar"; then
    if [ -e "$STATE/$id.check.sh" ] || [ -L "$STATE/$id.check.sh" ]; then
      printf 'fm-github-read-pause: cannot classify active merge poll %s; marker remains active\n' "$id" >&2
      failed=1
    fi
    continue
  fi
  [ "$FM_PR_DATA_PROVIDER" = github ] || continue
  if [ -e "$STATE/$id.check.sh" ] || [ -L "$STATE/$id.check.sh" ] \
    || [ -e "$STATE/$id.check-trust" ] || [ -L "$STATE/$id.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-check-unregister.sh" "$id" >/dev/null || failed=1
  fi
done

[ "$failed" -eq 0 ] || fail 'one or more GitHub readers could not be retired; marker remains active'
fm_lock_release "$LOCK" || fail 'pause lock could not be released'
LOCK_HELD=0
printf 'paused: GitHub readers retired; durable records preserved\n'
