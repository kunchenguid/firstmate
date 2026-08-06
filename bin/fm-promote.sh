#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}
fm_pr_task_id_valid "$ID" || { echo "error: invalid task ID" >&2; exit 1; }
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP=
ORIGINAL_META=
PROMOTION_COMMITTED=0
VALIDATION_CHECK_ABSENT=0
VALIDATION_TRUST_ABSENT=0
PROMOTION_META_HASH=
CHECK_SLOT_HELD=0
MIGRATION_BOUNDARY_HELD=0
PROMOTION_VALIDATION_CHILD_PID=
PROMOTION_VALIDATION_SLOT_OWNER_PID=
promotion_slot_release() {
  local failed=0
  if [ "$CHECK_SLOT_HELD" -eq 1 ]; then
    fm_custom_check_slot_release || failed=1
    CHECK_SLOT_HELD=0
  fi
  if [ "$MIGRATION_BOUNDARY_HELD" -eq 1 ]; then
    fm_custom_check_migration_release || failed=1
    MIGRATION_BOUNDARY_HELD=0
  fi
  return "$failed"
}
promotion_slot_acquire() {
  if ! fm_custom_check_migration_acquire "$STATE" 100; then
    return 1
  fi
  MIGRATION_BOUNDARY_HELD=1
  if ! fm_custom_check_slot_acquire "$STATE" "$ID" 100; then
    fm_custom_check_migration_release || true
    MIGRATION_BOUNDARY_HELD=0
    return 1
  fi
  CHECK_SLOT_HELD=1
}
promotion_candidate_current() {
  [ -n "$PROMOTION_META_HASH" ] || return 1
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || return 1
  [ "$(fm_pr_sha256 "$META")" = "$PROMOTION_META_HASH" ]
}
promotion_validation_handoff_stop() {
  [ -n "$PROMOTION_VALIDATION_CHILD_PID" ] || return 0
  kill -TERM "$PROMOTION_VALIDATION_CHILD_PID" 2>/dev/null || true
  wait "$PROMOTION_VALIDATION_CHILD_PID" 2>/dev/null || true
  PROMOTION_VALIDATION_CHILD_PID=
}
promote_cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  promotion_validation_handoff_stop || true
  if [ "$PROMOTION_COMMITTED" -ne 1 ] && [ -n "$ORIGINAL_META" ]; then
    [ "$CHECK_SLOT_HELD" -eq 1 ] || promotion_slot_acquire || true
    if [ "$CHECK_SLOT_HELD" -eq 1 ] && promotion_candidate_current; then
      if [ "$MODE" = no-mistakes ] \
        && fm_validation_check_registered "$STATE" "$ID" \
          "$FM_ROOT/bin/fm-nm-run-lib.sh" "$FM_ROOT/bin/fm-validation-poll.sh"; then
        PROMOTION_COMMITTED=1
      else
        [ "$VALIDATION_CHECK_ABSENT" -ne 1 ] || rm -f -- "$STATE/$ID.check.sh"
        [ "$VALIDATION_TRUST_ABSENT" -ne 1 ] || rm -f -- "$STATE/$ID.check-trust"
        mv -f -- "$ORIGINAL_META" "$META" || true
        ORIGINAL_META=
      fi
    fi
  fi
  promotion_slot_release || true
  [ -z "$ORIGINAL_META" ] || rm -f -- "$ORIGINAL_META"
}
trap promote_cleanup EXIT
trap 'exit 1' HUP INT TERM
if ! promotion_slot_acquire; then
  echo "error: task check publication is busy" >&2
  exit 1
fi
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
if grep -q '^pr=' "$META"; then
  echo "error: task check is reserved for PR merge polling" >&2
  exit 1
fi
ORIGINAL_META=$(mktemp "$STATE/.fm-promote-original.XXXXXX")
cp "$META" "$ORIGINAL_META"
TMP=$(mktemp "$STATE/.fm-promote-meta.XXXXXX")
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
if [ "$MODE" = no-mistakes ]; then
  [ -e "$STATE/$ID.check.sh" ] || [ -L "$STATE/$ID.check.sh" ] || VALIDATION_CHECK_ABSENT=1
  [ -e "$STATE/$ID.check-trust" ] || [ -L "$STATE/$ID.check-trust" ] || VALIDATION_TRUST_ABSENT=1
fi
PROMOTION_META_HASH=$(fm_pr_sha256 "$TMP") || exit 1
mv -f -- "$TMP" "$META"
TMP=

if [ "$MODE" = no-mistakes ]; then
  PROMOTION_VALIDATION_SLOT_OWNER_PID=${BASHPID:-$$}
  FM_VALIDATION_SLOT_OWNER_PID="$PROMOTION_VALIDATION_SLOT_OWNER_PID" FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$FM_ROOT/bin/fm-validation-check.sh" --slot-held "$ID" &
  PROMOTION_VALIDATION_CHILD_PID=$!
  if ! wait "$PROMOTION_VALIDATION_CHILD_PID"; then
    PROMOTION_VALIDATION_CHILD_PID=
    echo "error: could not arm validation check for $ID" >&2
    exit 1
  fi
  PROMOTION_VALIDATION_CHILD_PID=
fi
PROMOTION_COMMITTED=1
promotion_slot_release || exit 1
rm -f -- "$ORIGINAL_META"
ORIGINAL_META=
trap - EXIT HUP INT TERM

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
