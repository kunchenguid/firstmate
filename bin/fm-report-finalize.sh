#!/usr/bin/env bash
# Capture a task report or ship delivery receipt into the canonical private
# archive under data/reports/<project>/, record report_archive= in task meta,
# and regenerate the per-project INDEX.md.
#
# Scouts require the working report at data/<id>/report.md and a completed
# unresolved-decision inventory. Ship tasks accept an optional working report
# or synthesize a short structured delivery receipt from task meta and status.
#
# Idempotent: repeating finalize for the same bytes succeeds; conflicting
# archive content refuses safely.
#
# Usage: fm-report-finalize.sh <task-id>
#
# The normative contract is owned by docs/task-report-archive.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-report-lib.sh
. "$SCRIPT_DIR/fm-report-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-report-finalize: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  usage >&2
  exit 2
fi

ID=$1
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"

[ -f "$META" ] && [ ! -L "$META" ] || fail "task metadata is absent: $META"

KIND=$(fm_report_meta_value "$META" kind)
[ -n "$KIND" ] || KIND=ship
PROJECT=$(fm_report_meta_value "$META" project)
[ -n "$PROJECT" ] || fail "task $ID has no project= in metadata; cannot choose an archive owner"

SLUG=$(basename "$PROJECT")
fm_report_slug_valid "$SLUG" || fail "project slug is not archive-safe: $SLUG"

WORKING=$(fm_report_working_path "$DATA" "$ID")
ARCHIVE_REL=$(fm_report_archive_rel "$SLUG" "$ID")
ARCHIVE_ABS=$(fm_report_archive_abs "$DATA" "$SLUG" "$ID")

existing_archive=$(fm_report_meta_value "$META" report_archive)
already_finalized=$(fm_report_meta_value "$META" report_finalized)
if [ -n "$existing_archive" ] && [ "$existing_archive" != "$ARCHIVE_REL" ]; then
  fail "task $ID already finalized to a different archive path: $existing_archive"
fi

if [ "$already_finalized" = 1 ] && [ -f "$ARCHIVE_ABS" ]; then
  fm_report_regenerate_index "$DATA" "$SLUG" \
    || fail "could not regenerate index for project $SLUG"
  printf 'finalized: %s\n' "$ARCHIVE_REL"
  exit 0
fi

if [ "$KIND" = scout ]; then
  if [ ! -f "$WORKING" ]; then
    fail "scout task $ID has no working report at $WORKING"
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-decision-hold.sh" verify "$ID" >/dev/null; then
    fail "scout task $ID has not passed the unresolved-decision completion gate"
  fi
fi

if [ "$KIND" = secondmate ]; then
  fail "secondmate homes are not finalized through fm-report-finalize.sh"
fi

SOURCE_TMP=
SOURCE_TMP_IS_TEMP=0
cleanup() {
  if [ "$SOURCE_TMP_IS_TEMP" = 1 ] && [ -n "$SOURCE_TMP" ]; then
    rm -f "$SOURCE_TMP"
  fi
}
trap cleanup EXIT HUP INT TERM

if [ -f "$WORKING" ]; then
  SOURCE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-report-source.XXXXXX") || exit 1
  SOURCE_TMP_IS_TEMP=1
  cp -f "$WORKING" "$SOURCE_TMP" || fail "could not read working report at $WORKING"
elif [ "$KIND" = ship ]; then
  SOURCE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-report-source.XXXXXX") || exit 1
  SOURCE_TMP_IS_TEMP=1
  fm_report_write_ship_receipt "$SOURCE_TMP" "$ID" "$META" "$STATUS" \
    || fail "could not synthesize ship delivery receipt for $ID"
else
  fail "task $ID has no working report at $WORKING"
fi

if [ -f "$ARCHIVE_ABS" ]; then
  existing_hash=$(fm_report_sha256_file "$ARCHIVE_ABS") \
    || fail "existing archive at $ARCHIVE_ABS is unreadable"
  source_hash=$(fm_report_sha256_file "$SOURCE_TMP") \
    || fail "source report for $ID is unreadable"
  if [ "$existing_hash" != "$source_hash" ]; then
    fail "archive at $ARCHIVE_ABS already exists with different content"
  fi
else
  fm_report_atomic_write "$ARCHIVE_ABS" "$SOURCE_TMP" \
    || fail "could not write archive at $ARCHIVE_ABS"
fi

fm_report_record_meta "$META" "$ARCHIVE_REL" \
  || fail "could not record report_archive= for $ID"

fm_report_regenerate_index "$DATA" "$SLUG" \
  || fail "could not regenerate index for project $SLUG"

printf 'finalized: %s\n' "$ARCHIVE_REL"
