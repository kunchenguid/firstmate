#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

printf '%s\n' "$SNAPSHOT" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t): endpoint_exists($t);
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t): dash($t.actions.watch);
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";
  def under_way($t):
    ($t.retained_record != true)
      and ((($t.record_disposition == "active")
              and ($t.backlog.state == "in_flight" or $t.current_state.state == "working"))
           or (($t.record_disposition == "unknown")
              and (($t.hints.open_decisions // []) | length) > 0));
  def integrity_record($t):
    (under_way($t) | not)
      and ($t.retained_record != true)
      and (($t.record_disposition == "unknown")
        or ($t.record_disposition == "ambiguous")
        or ($t.record_disposition == "active")
        or ((($t.record_disposition == "done")
             or ($t.record_disposition == "archive_done")
             or ($t.record_disposition == "queued")
             or ($t.record_disposition == "parked"))
            and $t.current_state.state == "working"));
  def integrity_row($t):
    "| \($t.id) | \($t.record_disposition) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) |";

  "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "## Under Way",
  (if ([.tasks[] | select(under_way(.))] | length) == 0 then
    (if (.tasks | length) == 0 then "No live task metadata found."
     else "No tasks currently classified as under way." end)
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | select(under_way(.)) | task_row(.))
   end),
  "",
  "## Retained execution records",
  "Closed backlog items; endpoint and local-copy cleanup are not confirmed by closure.",
  (if ([.tasks[] | select(.retained_record == true)] | length) == 0 then
    "No retained closed records."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | select(.retained_record == true) | task_row(.))
   end),
  "",
  "## Task record integrity",
  "Unclassified or contradictory execution records; visible for reconciliation, not presented as active work.",
  (if ([.tasks[] | select(integrity_record(.))] | length) == 0 then
    "No task-record integrity findings."
   else
    "| ID | Disposition | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | select(integrity_record(.)) | integrity_row(.))
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
   end)
'
