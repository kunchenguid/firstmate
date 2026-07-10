#!/usr/bin/env bash
# Update a live task's human-readable herdr tab label.
# Usage: fm-label.sh <id|fm-id> <phase-text>
# Herdr labels are rendered as "<project>: <phase-text>" and recorded in meta.
# Non-herdr backends are intentionally a successful no-op with an explanatory message.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

META_LOCK=
META_SNAPSHOT=
META_TMP=
fm_label_cleanup() {
  [ -z "$META_TMP" ] || rm -f "$META_TMP"
  [ -z "$META_SNAPSHOT" ] || rm -f "$META_SNAPSHOT"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
}
trap fm_label_cleanup EXIT

[ "$#" -eq 2 ] || { echo "usage: fm-label.sh <id|fm-id> <phase-text>" >&2; exit 2; }
RAW_ID=$1
PHASE=$2
[ -n "$PHASE" ] || { echo "error: phase text must not be empty" >&2; exit 2; }
case "$PHASE" in
  *$'\n'*|*$'\r'*) echo "error: phase text cannot contain a newline" >&2; exit 2 ;;
esac

META=$(fm_backend_meta_for_selector "$RAW_ID" "$STATE" 2>/dev/null || true)
[ -n "$META" ] || { echo "error: no metadata for $RAW_ID in $STATE" >&2; exit 1; }
TASK_ID=${META##*/}
TASK_ID=${TASK_ID%.meta}
META_LOCK="$STATE/.$TASK_ID.meta.lock"
fm_lock_acquire_wait "$META_LOCK"
if ! LOCKED_META=$(fm_backend_meta_for_selector "$RAW_ID" "$STATE" 2>/dev/null); then
  echo "error: could not re-read metadata for $RAW_ID in $STATE" >&2
  exit 1
fi
[ "$LOCKED_META" = "$META" ] || { echo "error: metadata for $RAW_ID changed while waiting for its update lock" >&2; exit 1; }
META_SNAPSHOT=$(mktemp "$STATE/.$TASK_ID.meta.snapshot.XXXXXX")
if ! cp -p "$META" "$META_SNAPSHOT"; then
  echo "error: could not read metadata from $META" >&2
  exit 1
fi
KIND=$(fm_meta_get "$META_SNAPSHOT" kind)
[ "$KIND" != secondmate ] || { echo "error: live labels are supported only for crewmates and scouts, not secondmates" >&2; exit 1; }
TARGET=$(fm_backend_target_of_meta "$META_SNAPSHOT")
[ -n "$TARGET" ] || { echo "error: no backend endpoint recorded in $META" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META_SNAPSHOT")

case "$BACKEND" in
  herdr)
    fm_backend_source herdr
    PROJECT=$(fm_meta_get "$META_SNAPSHOT" project)
    PROJECT_LABEL=${PROJECT##*/}
    [ -n "$PROJECT_LABEL" ] || PROJECT_LABEL=project
    NEW_LABEL="$PROJECT_LABEL: $PHASE"
    fm_backend_herdr_rename_task "$TARGET" "$NEW_LABEL" || {
      echo "error: could not rename herdr tab for $TASK_ID" >&2
      exit 1
    }
    META_TMP=$(mktemp "$STATE/.$TASK_ID.meta.update.XXXXXX")
    if ! { sed '/^label=/d' "$META_SNAPSHOT" && printf 'label=%s\n' "$NEW_LABEL"; } > "$META_TMP"; then
      echo "error: herdr tab renamed but could not update $META" >&2
      exit 1
    fi
    if [ ! -f "$META" ] || ! cmp -s "$META_SNAPSHOT" "$META"; then
      echo "error: herdr tab renamed but metadata changed or disappeared before updating $META" >&2
      exit 1
    fi
    mv -f "$META_TMP" "$META"
    META_TMP=
    printf 'fm-label: %s -> %s\n' "$TASK_ID" "$NEW_LABEL"
    ;;
  *)
    printf 'fm-label: backend=%s does not support live labels; no-op for %s\n' "$BACKEND" "$TASK_ID"
    ;;
esac
