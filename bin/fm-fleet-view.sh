#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# Under Way is ordered by the snapshot's card rank, so the row that most needs
# attention is first, and History renders the durable outcome manifests that
# outlive teardown. docs/fleet-data-contracts.md owns both contracts.
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
  def card_of($t):
    if $t.card == null then "-" else "\($t.card.column) / \($t.card.action)" end;
  def pr_state_of($t):
    if $t.pr.url == null then "-" else "\($t.pr.status.state) / \($t.pr.status.checks)" end;
  def task_row($t):
    "| \($t.id) | \(card_of($t)) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(pr_state_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def history_row($r):
    "| \($r.task_id) | \(dash($r.title)) | \($r.outcome.state) | \(dash($r.timestamps.completed)) | \(dash($r.pr.url // $r.report.path)) |";
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
  "Supervision: watcher \(if .supervision.watcher.stale then "stale" else "fresh" end)" +
    "\(if .supervision.watcher.age_seconds == null then "" else " (\(.supervision.watcher.age_seconds)s)" end)" +
    "\(if .supervision.afk.active then ", away mode on" else "" end)",
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Card | Current | Kind | Repo/Project | Backend | Endpoint | PR | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks | sort_by([.card.rank, .id])[] | task_row(.))
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
  "## History",
  (if (.history.records | length) == 0 then
    "No completed tasks in durable history."
   else
    "| ID | Title | Outcome | Completed | Artifact |",
    "| --- | --- | --- | --- | --- |",
    (.history.records[] | history_row(.))
   end),
  (if (.history.malformed | length) == 0 then empty
   else "", "Unreadable history records: \([.history.malformed[] | "\(.id) (\(.reason))"] | join(", "))"
   end),
  (if .history.truncated then "", "Showing \(.history.shown) of \(.history.total) completed tasks." else empty end),
  "",
  "## Secondmates",
  .secondmate_guidance.note
'
