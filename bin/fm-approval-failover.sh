#!/usr/bin/env bash
# Firstmate-invoked managed-approval failover for a recorded local worker.
# Usage: FM_HOME=<owning-home> fm-approval-failover.sh apply <task-id>
# Firstmate must first observe a defeated bypass: a Codex command-approval
# prompt under its bypass launch, or a Claude policy refusal of a bypass session.
# Obtain the captain's explicit approval before running apply; observing the
# failure alone does not authorize a lasting permission change or relaunch.
# This command does not detect, poll, capture a screen, or answer an approval.
# It saves approve-for-me (Codex) or auto (Claude) only when the owning home's
# mode file is absent, then uses fm-control interrupt/relaunch to preserve and
# resume the assigned work. Both fallbacks use a model reviewer.
# Explicit settings, including invalid files, directories and dangling links,
# are never overwritten. Publication uses an exact-destination atomic link;
# a concurrent setting wins. Remote endpoints, non-bypass launches and T3 Code
# tasks, which already run at T3's full-access mode, refuse.
# The existing task lease guard protects configuration publication. Release its
# command lock before invoking child lifecycle commands, which guard themselves.
# A lifecycle failure leaves the setting saved and reports incomplete recovery.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  --help|-h)
    printf '%s\n' 'Usage: FM_HOME=<owning-home> fm-approval-failover.sh apply <task-id>' \
      "Run only after observing a defeated bypass and obtaining the captain's explicit approval." \
      'Saves the runtime fallback once and relaunches through fm-control.'
    exit 0
    ;;
  apply) [ "$#" -eq 2 ] || { echo 'error: apply requires one task id' >&2; exit 2; } ;;
  *) echo 'error: expected apply <task-id>; see --help' >&2; exit 2 ;;
esac
ID=$2
: "${FM_HOME:?FM_HOME must explicitly name the owning home}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_task_id_creation_valid "$ID" || { echo 'error: invalid task id' >&2; exit 2; }
TMP=
trap 'rm -f "$TMP"; fm_lease_guard_release' EXIT
fm_lease_guard "$ID" 'managed approval failover'
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no regular task record for $ID" >&2; exit 1; }
HARNESS=$(fm_backend_meta_exact_value "$META" harness) || exit 1
MODE=$(fm_meta_get "$META" approval_mode)
if [ -n "$MODE" ] && [ "$MODE" != bypass ]; then
  echo 'error: the recorded launch did not use bypass; nothing changed' >&2
  exit 1
fi
[ -z "$(fm_meta_get "$META" remote_host)" ] || {
  echo 'error: invoke failover in the remote worker owning home' >&2
  exit 1
}
case "$HARNESS" in
  codex) SETTING=codex-approval-mode; FALLBACK=approve-for-me ;;
  claude) SETTING=claude-permission-mode; FALLBACK=auto ;;
  *) echo 'error: managed approval failover supports only Codex and Claude' >&2; exit 1 ;;
esac
[ "$(fm_backend_of_meta "$META")" != t3code ] || {
  echo "error: backend=t3code already runs $HARNESS at T3's full-access runtime mode and cannot honor config/$SETTING=$FALLBACK; approve the pending request in T3 Code itself or choose another backend; nothing changed" >&2
  exit 1
}
[ ! -e "$CONFIG/$SETTING" ] && [ ! -L "$CONFIG/$SETTING" ] || {
  echo "error: config/$SETTING already exists; nothing overwritten" >&2
  exit 1
}
mkdir -p "$CONFIG"
TMP=$(mktemp "$CONFIG/.approval-failover.XXXXXX")
printf '%s\n' "$FALLBACK" > "$TMP"
# Perl's link calls link(2) at this exact path: unlike ln, it cannot place a
# link inside a concurrently created directory or a symlink to a directory.
if ! perl -e 'link($ARGV[0], $ARGV[1]) or die "$!\n"' "$TMP" "$CONFIG/$SETTING"; then
  echo "error: could not publish config/$SETTING; nothing overwritten" >&2
  exit 1
fi
rm -f -- "$TMP"
TMP=
printf 'saved config/%s=%s; approvals use a model reviewer\n' "$SETTING" "$FALLBACK"
fm_lease_guard_release
# Cancel the pending approval/refused turn so guarded relaunch can exit the
# composer without accepting the blocked command or typing into its dialog.
if ! "$SCRIPT_DIR/fm-control.sh" "$ID" interrupt \
  || ! "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "Managed bypass failed; config/$SETTING now selects $FALLBACK. Preserve all work and continue the assigned task."; then
  echo 'error: fallback saved, but worker recovery failed; preserve work and reconcile through fm-control' >&2
  exit 1
fi
printf 'managed approval failover: %s relaunched with config/%s=%s\n' "$ID" "$SETTING" "$FALLBACK"
