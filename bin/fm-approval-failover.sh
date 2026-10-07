#!/usr/bin/env bash
# Managed-approval failover for a recorded local worker.
# Usage: fm-approval-failover.sh classify codex|claude < visible-screen
#        FM_HOME=<home> fm-approval-failover.sh probe <task-id>
#        FM_HOME=<home> fm-approval-failover.sh apply <task-id>
# classify is pure; probe reads only the recorded endpoint's visible viewport.
# apply repeats probe, then atomically creates the runtime's home config only
# if absent, reports the switch, interrupts the refused turn, and relaunches
# through fm-control. It never answers an approval or edits vendor settings.
# Only an unconfigured, canonical bypass launch recorded by fm-spawn is eligible.
# Unknown legacy metadata, remote endpoints, explicit settings (including broken
# symlinks), unrelated errors and unreadable screens are not evidence.
# Codex requires its approval question AND the selected approval option; Claude
# requires a policy-blocked-connection refusal AND HTTP 403 in the same viewport.
# A failed lifecycle action leaves the durable fallback in place and reports
# failure; it never repeats the bypass attempt or claims recovery succeeded.
# Recovery-grade lifecycle operations are supported only by tmux and herdr.
# The watcher emits the probe result for firstmate, which runs apply under its
# normal recovery authority; the watcher itself never changes permission policy.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

classify() {
  local harness=$1 screen
  screen=$(perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g')
  case "$harness" in
    codex)
      printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*Would you like to run the following command\?' || return 1
      printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*[›>❯][[:space:]]*1\.[[:space:]]*Yes, proceed' || return 1
      printf 'codex-approval-prompt\n'
      ;;
    claude)
      printf '%s\n' "$screen" | grep -Fq 'A Formal policy has blocked the connection for your user to this resource' || return 1
      printf '%s\n' "$screen" | grep -Eq '(HTTP|API Error:|status)[[:space:]:]*403' || return 1
      printf 'claude-policy-403\n'
      ;;
    *) return 1 ;;
  esac
}
case "${1:-}" in
  --help|-h) head -n 21 "$0"; exit 0 ;;
  classify) [ "$#" -eq 2 ] || exit 2; classify "$2"; exit $? ;;
  probe|apply) [ "$#" -eq 2 ] || exit 2 ;;
  *) echo 'error: expected classify <harness>, probe <task-id>, or apply <task-id>' >&2; exit 2 ;;
esac
VERB=$1 ID=$2
: "${FM_HOME:?FM_HOME must explicitly name the owning home}"
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 2 ;; esac
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 1
BINDING=$(cksum < "$META")
[ -n "$(fm_meta_get "$META" spawn_gen)" ] || exit 1
HARNESS=$(fm_meta_get "$META" harness)
[ "$(fm_meta_get "$META" approval_mode)" = bypass ] || exit 1
[ "$(fm_meta_get "$META" approval_configured)" = 0 ] || exit 1
[ -z "$(fm_meta_get "$META" remote_host)" ] || exit 1
case "$HARNESS" in
  codex) SETTING=codex-approval-mode; FALLBACK=approve-for-me ;;
  claude) SETTING=claude-permission-mode; FALLBACK=auto ;;
  *) exit 1 ;;
esac
# Do not use test -e alone: a dangling symlink is an explicit setting too.
[ ! -e "$CONFIG/$SETTING" ] && [ ! -L "$CONFIG/$SETTING" ] || exit 1
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND TARGET=$FM_BACKEND_VALIDATED_TARGET
SCREEN=$(fm_backend_visible_capture "$BACKEND" "$TARGET" "fm-$ID") || exit 1
EVIDENCE=$(printf '%s\n' "$SCREEN" | classify "$HARNESS") || exit 1
[ "$(cksum < "$META")" = "$BINDING" ] || {
  echo 'error: launch record changed during capture; refusing stale evidence' >&2
  exit 1
}
if [ "$VERB" = probe ]; then
  printf 'managed-approval %s evidence=%s; load stuck-crewmate-recovery\n' "$ID" "$EVIDENCE"
  exit 0
fi
case "$BACKEND" in
  tmux|herdr) ;;
  *) echo "error: $BACKEND cannot verify lifecycle recovery; permission setting unchanged" >&2; exit 1 ;;
esac
# Publish complete bytes with link(2)'s no-replacement semantics. A concurrent
# explicit setting wins, even when empty or a symlink; no partial file is seen.
mkdir -p "$CONFIG"
TMP=$(mktemp "$CONFIG/.approval-failover.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$FALLBACK" > "$TMP"
if ! ln "$TMP" "$CONFIG/$SETTING" 2>/dev/null; then
  echo "error: config/$SETTING appeared during failover; nothing overwritten" >&2
  exit 1
fi
stamp=$(date +%s)
printf 'working [at=%s]: managed approval failover selected %s=%s after %s\n' "$stamp" "$SETTING" "$FALLBACK" "$EVIDENCE" >> "$STATE/$ID.status"
if ! "$SCRIPT_DIR/fm-control.sh" "$ID" interrupt || ! "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "Managed approval failover: $EVIDENCE; config/$SETTING now selects $FALLBACK. Preserve all work and continue the assigned task."; then
  stamp=$(date +%s)
  printf 'blocked [at=%s]: managed approval fallback persisted, but worker recovery failed; preserve work and use fm-control to reconcile\n' "$stamp" >> "$STATE/$ID.status"
  exit 1
fi
printf 'managed approval failover: %s uses config/%s=%s; worker relaunched\n' "$ID" "$SETTING" "$FALLBACK"
