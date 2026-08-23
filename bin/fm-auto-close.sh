#!/usr/bin/env bash
# Stop and clean up one ordinary worker after its terminal outcome is confirmed.
#
# Usage: fm-auto-close.sh maybe <task-id>
#        fm-auto-close.sh finish <task-id>
#
# `maybe` accepts only an unchanged done/failed status whose authoritative
# fm-crew-state result matches, with no open decision and no secondmate record.
# It exits the agent through fm-control, records the exact spawn/status identity,
# then calls `finish`.
# `finish` retries cleanup from that receipt. fm-teardown revalidates the receipt
# under its lifecycle locks and remains the owner of landed-work safety.
# Ordinary dirty work is preserved. The sole exception is residual dirt after
# the recorded PR is proved merged; fm-teardown's --auto-terminal path owns that
# narrow discard proof.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is required" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CREW_STATE_BIN="${FM_AUTO_CLOSE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
CONTROL_BIN="${FM_AUTO_CLOSE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
TEARDOWN_BIN="${FM_AUTO_CLOSE_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"

# shellcheck source=bin/fm-auto-close-lib.sh
. "$SCRIPT_DIR/fm-auto-close-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

mode=${1:-}
id=${2:-}
if [ "$#" -ne 2 ] || ! fm_auto_close_token_valid "$id"; then
  printf 'usage: fm-auto-close.sh maybe|finish <task-id>\n' >&2
  exit 2
fi
meta="$STATE/$id.meta"
status="$STATE/$id.status"
receipt=$(fm_auto_close_receipt_path "$STATE" "$id")

meta_value() { fm_meta_get "$meta" "$1"; }

finish() {
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$TEARDOWN_BIN" "$id" --auto-terminal
}

maybe() {
  local kind incarnation signature line terminal current current_signature
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  kind=$(meta_value kind)
  [ "$kind" != secondmate ] || return 0
  [ -z "$(status_open_decisions "$status")" ] || return 0
  line=$(last_status_line "$status")
  terminal=$(status_line_verb "$line")
  case "$terminal" in done|failed) ;; *) return 0 ;; esac
  signature=$(fm_wake_signal_sig "$status") || return 0
  current=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || return 0
  case "$current" in "state: $terminal "*) ;; *) return 0 ;; esac
  current_signature=$(fm_wake_signal_sig "$status") || return 0
  [ "$current_signature" = "$signature" ] || return 0
  incarnation=$(meta_value spawn_gen)
  fm_auto_close_token_valid "$incarnation" || return 0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CONTROL_BIN" "$id" exit >/dev/null || return 1
  current_signature=$(fm_wake_signal_sig "$status") || return 1
  [ "$current_signature" = "$signature" ] || return 0
  [ "$(meta_value spawn_gen)" = "$incarnation" ] || return 0
  fm_auto_close_receipt_write "$STATE" "$id" "$incarnation" "$terminal" "$signature" || return 1
  finish
}

case "$mode" in
  maybe) maybe ;;
  finish) finish ;;
  *) printf 'usage: fm-auto-close.sh maybe|finish <task-id>\n' >&2; exit 2 ;;
esac
