#!/usr/bin/env bash
# Push declared inheritable local config to live secondmate homes.
# Usage: fm-config-push.sh [--help]
#
# Config-only convergence for mid-session changes such as config/crew-dispatch.json
# edits. This discovers live secondmate homes from state/*.meta, backfills
# home= from data/secondmates.md for older meta records, and reuses the same
# propagate_inheritable_config machinery as bootstrap, but deliberately does not
# fast-forward tracked files and does not nudge running secondmates.
# Warnings-only skips exit 0; real propagation errors exit non-zero.
set -u

usage() {
  cat <<'EOF'
Usage: fm-config-push.sh [--help]

Push the primary firstmate home's declared inheritable local config into each
live secondmate home's config/ directory.

This is config-only:
  - does not fast-forward tracked files
  - does not nudge secondmates
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero only for real propagation errors

Live homes come from state/*.meta records with kind=secondmate.
data/secondmates.md is only a fallback for missing home= fields in older or
incomplete meta records.

Environment overrides follow the rest of firstmate:
  FM_HOME            active firstmate home
  FM_ROOT_OVERRIDE  firstmate repo root
  FM_STATE_OVERRIDE state dir
  FM_CONFIG_OVERRIDE config dir
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: fm-config-push.sh [--help]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"
SECONDMATES_MD="$DATA/secondmates.md"

"$SCRIPT_DIR/fm-guard.sh" || true

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

print_item_report() {
  local report=$1 item status reason
  while IFS=$'\t' read -r item status reason; do
    [ -n "$item" ] || continue
    if [ -n "$reason" ]; then
      printf '  %s: %s - %s\n' "$item" "$status" "$reason"
    else
      printf '  %s: %s\n' "$item" "$status"
    fi
  done < "$report"
}

records=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-records.XXXXXX" 2>/dev/null) || exit 1
reports=""
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local report_file
  rm -f "$records"
  for report_file in $reports; do
    rm -f "$report_file"
  done
}
trap cleanup EXIT

live_secondmate_meta_records "$STATE" "$SECONDMATES_MD" > "$records"
if [ ! -s "$records" ]; then
  echo "config-push: no live secondmate homes found"
  exit 0
fi

echo "config-push: $CONFIG -> live secondmate homes"

seen_homes=""
errors=0
while IFS='|' read -r id home _window meta; do
  [ -n "$id" ] || continue
  if [ -z "$home" ]; then
    printf 'secondmate %s: skipped - no home= in %s and no registry home\n' "$id" "$meta"
    continue
  fi
  if ! validate_secondmate_home "$id" "$home"; then
    printf 'secondmate %s (%s): skipped - unsafe home: %s\n' "$id" "$home" "$VALIDATION_ERROR"
    continue
  fi
  home_real="$VALIDATED_HOME"
  case " $seen_homes " in
    *" $home_real "*)
      printf 'secondmate %s (%s): skipped - already processed for another live meta\n' "$id" "$home_real"
      continue
      ;;
  esac
  seen_homes="$seen_homes $home_real"

  printf 'secondmate %s (%s):\n' "$id" "$home_real"
  dirty=$(dirty_status "$home_real" yes || true)
  if [ -n "$dirty" ]; then
    echo "  home: dirty working tree - config-only push continuing"
  fi

  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-report.XXXXXX" 2>/dev/null) || {
    echo "  home: error - could not create report file"
    errors=1
    continue
  }
  reports="$reports $report"
  if FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$CONFIG" "$home_real/config"; then
    print_item_report "$report"
  else
    errors=1
    print_item_report "$report"
  fi
done < "$records"

[ "$errors" -eq 0 ] || exit 1
exit 0
