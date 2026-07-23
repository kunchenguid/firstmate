#!/usr/bin/env bash
# Push declared inherited local material to live secondmate homes.
# Usage: fm-config-push.sh [--help]
#
# Mid-session convergence for inherited local material such as
# config/crew-dispatch.json edits or data/captain-shared.md updates. This
# discovers live secondmate homes from state/*.meta, backfills
# home= from data/secondmates.md for older meta records, and reuses the same
# propagation machinery as bootstrap, but deliberately does not
# fast-forward tracked files.
# After a successful per-home propagation that changes any allowlisted config/*
# item, writes a generation-specific literal-content reread instruction and
# sends its pointer to that live secondmate via fm-config-inherit-lib.sh
# (fm_config_send_reread_nudge).
# Unchanged config and data/captain-shared.md-only updates send no reread
# message unless a previous send failure is pending for that home.
# Warnings-only skips exit 0; real propagation or reread-send errors exit non-zero.
set -u

usage() {
  cat <<'EOF'
Usage: fm-config-push.sh [--help]

Push the primary firstmate home's declared inherited local material into each
live secondmate home.

This is local-material-only:
  - does not fast-forward tracked files
  - after successful config/* changes, writes a generation-specific
    literal-content reread instruction and sends its pointer to that live secondmate
    (no message when config is unchanged unless a previous send failure is pending)
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero for real propagation errors or reread-send failures

Live homes come from state/*.meta records with kind=secondmate.
data/secondmates.md is only a fallback for missing home= fields in older or
incomplete meta records.

Environment overrides follow the rest of firstmate:
  FM_HOME            active firstmate home
  FM_ROOT_OVERRIDE  firstmate repo root
  FM_STATE_OVERRIDE state dir
  FM_DATA_OVERRIDE  data dir
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
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATES_MD="$DATA/secondmates.md"

"$SCRIPT_DIR/fm-guard.sh" || true

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
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

echo "config-push: $FM_HOME -> live secondmate homes"

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
    echo "  home: dirty working tree - local-material push continuing"
  fi

  mkdir -p "$home_real/state" || {
    echo "  config-reread: error - could not create state directory"
    errors=1
    continue
  }
  home_lock=$(fm_config_inherit_lock_path "$home_real") || {
    echo "  config-reread: error - could not resolve per-home lock"
    errors=1
    continue
  }
  fm_lock_acquire_wait "$home_lock" || {
    echo "  config-reread: error - could not acquire per-home lock"
    errors=1
    continue
  }
  if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
    fm_config_reread_retry_pending "$id" "$home_real" || true
    if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      echo "  config-reread: error - retry instruction queue is full"
      errors=1
      fm_lock_release "$home_lock" || true
      continue
    fi
  fi

  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-report.XXXXXX" 2>/dev/null) || {
    echo "  home: error - could not create report file"
    errors=1
    fm_lock_release "$home_lock" || true
    continue
  }
  reports="$reports $report"
  if FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
    :
  else
    errors=1
  fi
  print_item_report "$report"
  reread_pending=0
  if fm_config_reread_has_pending "$home_real" || fm_config_reread_has_staged "$FM_HOME" "$id"; then
    reread_pending=1
  fi
  if reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$STATE" \
    fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
    if [ -n "$(fm_config_reread_changed_items "$report")" ] || [ "$reread_pending" -eq 1 ]; then
      printf '  config-reread: sent\n'
    fi
    [ -z "$reread_out" ] || printf '%s\n' "$reread_out"
  else
    errors=1
    if [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    else
      printf '  config-reread: send failed\n'
    fi
  fi
  fm_lock_release "$home_lock" || true
done < "$records"

[ "$errors" -eq 0 ] || exit 1
exit 0
