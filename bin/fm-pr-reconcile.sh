#!/usr/bin/env bash
# Reconcile one task during the watcher's normal slow PR poll, without a
# supervisor turn. Usage: fm-pr-reconcile.sh <task-id>
# Recover a ready status URL missing from metadata, and refresh changed GitHub
# heads through fm-pr-check.sh itself. Unqueued GitHub PRs with yolo on retry
# fm-pr-merge.sh --queue-sweep (green only, exact-head review coverage, ordinary
# authority/hold/away guards). Existing queue arms keep their bounded ejection
# policy; this sweep never re-arms one behind that policy's back.
# One plain refusal per PR/head is emitted until it changes or clears.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
[ "$#" -eq 1 ] && fm_pr_task_id_valid "$1" || exit 2
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
value() { fm_dod_meta_value "$META" "$1"; }
[ "$(value kind)" != secondmate ] || exit 0
URL=$(value pr)
# Recovery must not launder a refused or tampered poll into a new trusted
# registration. A task with no poll artifacts can be enrolled; any existing
# generation must first pass the same authentication as the normal PR poll.
if [ -e "$STATE/$ID.check.sh" ] || [ -L "$STATE/$ID.check.sh" ] \
  || [ -e "$STATE/$ID.pr-poll" ] || [ -L "$STATE/$ID.pr-poll" ] \
  || [ -e "$STATE/$ID.pr-poll-registration" ] || [ -L "$STATE/$ID.pr-poll-registration" ]; then
  fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || exit 0
fi
if [ -z "$URL" ]; then
  STATUS="$STATE/$ID.status"
  [ -f "$STATUS" ] && [ ! -L "$STATUS" ] || exit 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = done ] || continue
    URL=$(fm_dod_pr_url_from_done_note "$(status_line_note "$line")" || true)
  done < "$STATUS"
fi
[ -n "$URL" ] && fm_pr_url_parse "$URL" || exit 0
[ "$FM_PR_PROVIDER" = github ] || exit 0
URL=$FM_PR_URL
export GH_HOST=$FM_PR_HOST
command -v jq >/dev/null 2>&1 || exit 0
MARKER="$STATE/$ID.pr-reconcile"
report() {
  local reason=$1 signature tmp
  signature="$URL $HEAD $reason"
  fm_pr_regular_destination_or_absent "$MARKER" || return 1
  [ ! -f "$MARKER" ] || [ "$(< "$MARKER")" != "$signature" ] || return 0
  tmp=$(mktemp "$STATE/.pr-reconcile.XXXXXX") || return 1
  printf '%s\n' "$signature" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$MARKER"
  printf 'PR recovery: %s: %s\n' "$URL" "$reason"
}
HEAD=unknown
if ! LIVE=$(gh pr view "$URL" --json state,headRefOid,isInMergeQueue 2>/dev/null) \
  || ! HEAD=$(printf '%s' "$LIVE" | jq -er '.headRefOid') \
  || ! fm_pr_head_valid "$HEAD"; then
  report 'live PR state could not be read'
  exit 0
fi
[ "$(printf '%s' "$LIVE" | jq -r '.state')" = OPEN ] || exit 0
STOP="$STATE/$ID.queue-stop"
if [ -f "$STOP" ] && [ ! -L "$STOP" ] \
  && [ "$(< "$STOP")" = "$(printf '%s\n%s' "$URL" "$HEAD")" ]; then
  exit 0
fi
if [ "$(value pr)" != "$URL" ] || [ "$(value pr_head)" != "$HEAD" ]; then
  if ! OUTPUT=$("$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" 2>&1); then
    report "$(printf '%s\n' "$OUTPUT" | tail -1)"
    exit 0
  fi
  if printf '%s\n' "$OUTPUT" | grep -q '^error:'; then
    report "$(printf '%s\n' "$OUTPUT" | grep '^error:' | head -1)"
    exit 0
  fi
fi
[ "$(value yolo)" = on ] || exit 0
[ "$(printf '%s' "$LIVE" | jq -r '.isInMergeQueue')" = false ] || exit 0
# The arm sweep owns armed PRs and its one-requeue limit. Coverage retry
# intents, unlike arms, carry no authority and can safely use this path.
[ ! -e "$STATE/$ID.queue-arm" ] || exit 0
MODE=--queue-sweep
if fm_queue_pending_matches "$STATE/$ID.queue-pending" "$URL"; then
  MODE=--queue-at-green
fi
if ! OUTPUT=$("$SCRIPT_DIR/fm-pr-merge.sh" "$ID" "$URL" "$MODE" 2>&1); then
  report "$(printf '%s\n' "$OUTPUT" | tail -1)"
else
  fm_pr_regular_destination_or_absent "$MARKER" && rm -f -- "$MARKER"
fi
