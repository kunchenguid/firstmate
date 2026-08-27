#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# It also prints the provider-headroom gauge, because this view is the one
# AGENTS.md section 8 has firstmate read at every heartbeat, and that is where
# queued work gets dispatched. A limit reached mid-flight kills every worker on
# that account inside the same minute, so the gauge belongs next to the
# dispatch decision rather than in a command someone has to think of running.
# bin/fm-usage-wall.sh owns the reading, including every unmeasurable case.
#
# The read is bounded here as well as inside that command, because this view is
# rendered on the heartbeat path and its total cost has to be a constant.
# FM_FLEET_VIEW_HEADROOM_TIMEOUT is that constant, and a bound hit prints the
# same unknown line as any other unreadable gauge - never a healthy one, and
# never a silently omitted section.
#
# The inner reading budget is defaulted strictly BELOW this outer bound. An
# inner bound at or above the outer one is a false-unmeasurable generator: the
# outer kill lands first, so a gauge that was about to answer is reported as one
# that could not be read, in the surface built to prevent exactly that. An
# operator who sets FM_USAGE_WALL_QUOTA_TIMEOUT explicitly still wins.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

HEADROOM_TIMEOUT=${FM_FLEET_VIEW_HEADROOM_TIMEOUT:-30}
case "$HEADROOM_TIMEOUT" in ''|*[!0-9]*|0) HEADROOM_TIMEOUT=30 ;; esac

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json]

Render a human fleet view from fm-fleet-snapshot.sh.
Use --json to print the underlying snapshot.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?
HEADROOM_INNER=$((HEADROOM_TIMEOUT * 3 / 4))
[ "$HEADROOM_INNER" -ge 1 ] || HEADROOM_INNER=1
HEADROOM=$(FM_USAGE_WALL_QUOTA_TIMEOUT=${FM_USAGE_WALL_QUOTA_TIMEOUT:-$HEADROOM_INNER} \
  fm_run_timed "$HEADROOM_TIMEOUT" "$SCRIPT_DIR/fm-usage-wall.sh" headroom 2>/dev/null) \
  || HEADROOM="HEADROOM: (all providers) unknown reason=the headroom read did not complete within ${HEADROOM_TIMEOUT}s"

printf '%s\n' "$SNAPSHOT" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t):
    if $t.kind == "secondmate" then "\(endpoint_exists($t)) / \($t.endpoint.agent_alive)"
    else endpoint_exists($t) end;
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.home.present then $t.paths.home.path
    elif $t.paths.home.path != null then $t.paths.home.path + " (absent)"
    elif $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t):
    if $t.kind == "secondmate" then "\($t.actions.send) - \($t.actions.watch)"
    else $t.actions.watch end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";

  "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued") | backlog_row(.))
   end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done") | backlog_row(.))
   end),
  "",
  "## Secondmates",
  .secondmate_guidance.note
'

printf '\n## Headroom\n\n%s\n' "$HEADROOM"
