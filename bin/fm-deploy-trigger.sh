#!/usr/bin/env bash
# Decide and perform the automatic deploy that follows a confirmed merge.
#
# Called by bin/fm-merge-outcome-lib.sh's fm_merge_outcome_report, the one owner
# of the confirmed-merge path, so a merge this home performed and a merge its
# poll noticed both reach the same decision without an agent remembering to make
# it.
#
# Usage: fm-deploy-trigger.sh <home> <state> <task-id>
#
# Inert unless the task's project has a deploy policy at
# config/deploy-policy/<project>. A home with no policy for that project does
# nothing here and exits 0, so this changes nothing for every other project and
# every secondmate home.
#
# It deploys ONLY when everything merged and not yet live is auto-deployable. A
# range that touches a captain-reserved surface is never deployed here under any
# circumstances; it is reported and left for the captain.
#
# Whatever happens, at most one captain-facing line is queued, and the exit
# status is always 0: a deploy that failed is a deploy problem, never a reason
# to report that the merge itself was not recorded.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR=${1:-}
STATE_DIR=${2:-}
TASK_ID=${3:-}
[ -n "$HOME_DIR" ] && [ -n "$STATE_DIR" ] && [ -n "$TASK_ID" ] || exit 0

META="$STATE_DIR/$TASK_ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
PROJECT_PATH=$(sed -n 's/^project=//p' "$META" | head -1)
[ -n "$PROJECT_PATH" ] || exit 0
PROJECT=$(basename "$PROJECT_PATH")
[ -n "$PROJECT" ] || exit 0

POLICY="$HOME_DIR/config/deploy-policy/$PROJECT"
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || exit 0

# One captain-facing line, through the queue this home already uses.
queue() {
  (
    FM_HOME=$HOME_DIR
    FM_STATE_OVERRIDE=$STATE_DIR
    STATE=$STATE_DIR
    export FM_HOME FM_STATE_OVERRIDE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check "deploy-$PROJECT-$TASK_ID" "check: $1"
  ) >/dev/null 2>&1 || true
}

# Refresh this home's copy through the one guarded path that may touch a project
# clone, so the comparison is against what actually landed. A refresh that
# cannot run is not fatal: the status read below simply reports against the copy
# as it stands.
FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_SYNC_TIMEOUT:-120}" \
  "$SCRIPT_DIR/fm-fleet-sync.sh" "$PROJECT" >/dev/null 2>&1 || true

status_out=$(FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_STATUS_TIMEOUT:-120}" \
  "$SCRIPT_DIR/fm-deploy-status.sh" "$PROJECT" --porcelain 2>/dev/null) || {
  queue "could not check whether $PROJECT's live site is up to date; it needs a look"
  exit 0
}

field() { printf '%s\n' "$status_out" | sed -n "s/^$1=//p" | head -1; }

[ "$(field managed)" = yes ] || exit 0
auto=$(field auto_deployable)
pending=$(field pending_total)
captain_paths=$(field pending_captain_paths)
target=$(field target_sha)

if [ "${pending:-0}" = 0 ]; then
  exit 0
fi

if [ "$auto" != yes ]; then
  queue "$PROJECT has $pending merged change(s) waiting to go live, and $captain_paths of the files they touch are design surfaces you asked to approve first. Run /deploy to see them."
  exit 0
fi

if deploy_out=$(FM_HOME="$HOME_DIR" timeout "${FM_DEPLOY_TIMEOUT:-900}" \
  "$SCRIPT_DIR/fm-deploy.sh" "$PROJECT" "$target" 2>&1); then
  queue "$PROJECT's live site is now up to date with everything merged; nothing needed your permission."
else
  queue "$PROJECT's live site could not be updated automatically and needs a look: $(printf '%s' "$deploy_out" | tail -3 | tr '\n' ' ')"
fi
exit 0
