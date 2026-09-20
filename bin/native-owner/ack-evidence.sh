#!/usr/bin/env bash
# Usage: FM_HOME=<home> ack-evidence.sh capture-json|legacy-token|preflight-token|verify-token|verify-legacy|acknowledge-token
# Required environment: FM_HOME; token modes read their evidence from standard input.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
export FM_STATE_OVERRIDE="$FM_HOME/state"
cd "$ROOT"
. bin/fm-wake-lib.sh

read_token() {
  local token
  token=$(cat)
  [ -n "$token" ] || exit 2
  printf '%s' "$token"
}

case "${1:-}" in
  capture-json)
    fm_wake_ack_evidence_capture
    printf '{"seq":"%s","generation":"%s","notes":[' \
      "$FM_WAKE_ACK_EVIDENCE_CUTOFF" "$FM_WAKE_ACK_EVIDENCE_GENERATION"
    separator=
    while IFS=$'\t' read -r id digest; do
      [ -n "$id" ] || continue
      printf '%s"%s"' "$separator" "$id"
      separator=,
    done < "$FM_WAKE_ACK_EVIDENCE_NOTES"
    printf '],"ownerEvidence":"%s"}\n' "$FM_WAKE_ACK_EVIDENCE_TOKEN"
    fm_wake_ack_evidence_clear
    ;;
  legacy-token)
    fm_wake_ack_evidence_legacy_token
    ;;
  preflight-token)
    token=$(read_token)
    fm_wake_ack_evidence_precondition "$token"
    fm_wake_ack_evidence_clear
    ;;
  verify-token)
    token=$(read_token)
    fm_wake_ack_evidence_completed "$token"
    ;;
  verify-legacy)
    token=$(fm_wake_ack_evidence_legacy_token)
    fm_wake_ack_evidence_completed "$token"
    ;;
  acknowledge-token)
    token=$(read_token)
    fm_wake_ack_evidence_acknowledge "$token"
    ;;
  *)
    printf 'usage: ack-evidence.sh capture-json|legacy-token|preflight-token|verify-token|verify-legacy|acknowledge-token\n' >&2
    exit 2
    ;;
esac
