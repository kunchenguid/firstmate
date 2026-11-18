#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# Step display: while config/step-display is on (bin/fm-step-lib.sh owns the
# switch), the Under Way table has a Step column, `--steps <task-id>` prints one
# task's checklist, and `--watch` redraws either view.
# The Step cell shows the review step when the task's current state comes from a
# no-mistakes run (source run-step); otherwise it shows the worker's own step
# record as a bar, n/m, the step name, and the time on that step; otherwise it
# says "step not reported". It never guesses a step from pane text.
# A row is marked "needs you" when the snapshot reports a pending decision or
# the run's gate waits on a human decision.
# While the display is off the table is byte for byte the table without the
# Step column, and `--steps` and `--watch` only report that the display is off.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-step-lib.sh
. "$SCRIPT_DIR/fm-step-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"  # FM_GATE_HUMAN_DECISION: the human-decision component

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json]
       fm-fleet-view.sh [--steps <task-id>] [--watch [--interval <seconds>] [--rounds <n>]]
                        [--snapshot <file>]

Render a human fleet view from fm-fleet-snapshot.sh.
Use --json to print the underlying snapshot.

Step display (config/step-display, on unless the file holds off):
  --steps <task-id>     print one task's step checklist instead of the table
  --watch               redraw the view until interrupted; the screen is cleared
                        only when standard output is a terminal
  --interval <seconds>  time between redraws in --watch (default 5)
  --rounds <n>          stop --watch after n draws (default 0, no limit)
  --snapshot <file>     render a saved fm-fleet-snapshot.sh --json output instead
                        of taking a new snapshot
EOF
}

die_usage() {
  printf 'fm-fleet-view: %s\n' "$1" >&2
  usage >&2
  exit 2
}

need_value() {  # <option> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 needs a value"
}

STEPS_ID=
WATCH=0
INTERVAL=5
ROUNDS=0
SNAPSHOT_FILE=
[ "${1:-}" = --json ] && [ $# -eq 1 ] && { "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $?; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --steps) need_value "$1" $#; STEPS_ID=$2; shift 2 ;;
    --watch) WATCH=1; shift ;;
    --interval) need_value "$1" $#; INTERVAL=$2; shift 2 ;;
    --rounds) need_value "$1" $#; ROUNDS=$2; shift 2 ;;
    --snapshot) need_value "$1" $#; SNAPSHOT_FILE=$2; shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*|0) die_usage "--interval must be a positive whole number of seconds" ;; esac
case "$ROUNDS" in ''|*[!0-9]*) die_usage "--rounds must be a whole number" ;; esac
[ -z "$SNAPSHOT_FILE" ] || [ -r "$SNAPSHOT_FILE" ] || die_usage "cannot read snapshot file: $SNAPSHOT_FILE"

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

STEP_DISPLAY=$(fm_step_display_mode "$CONFIG")
if [ "$STEP_DISPLAY" = off ] && { [ -n "$STEPS_ID" ] || [ "$WATCH" = 1 ]; }; then
  printf 'The step display is off (%s/step-display holds off).\n' "$CONFIG"
  printf 'Write on to that file, or remove it, to turn the display on.\n'
  exit 0
fi

take_snapshot() {
  if [ -n "$SNAPSHOT_FILE" ]; then
    cat -- "$SNAPSHOT_FILE"
  else
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
  fi
}

# Shared jq definitions for the step cells and the checklist.
# shellcheck disable=SC2016  # jq program text, not shell expansion.
STEP_JQ_DEFS='
  def repeat_text($s; $k): if $k <= 0 then "" else $s * $k end;
  def human_age($s):
    if $s == null then "?"
    elif $s < 60 then "\($s)s"
    elif $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
    else "\($s / 86400 | floor)d" end;
  def bar($n; $m): ($n * 10 / $m | floor) as $f | "[" + repeat_text("█"; $f) + repeat_text("░"; 10 - $f) + "]";
  def detail_parts($t): ($t.current_state.detail // "") | split(" · ");
  def in_review($t): $t.current_state.source == "run-step";
  def review_text($t): "in review: " + (detail_parts($t)[0] | if . == "" then $t.current_state.state else . end);
  def needs_you($t):
    ($t.hints.pending_decision == true) or (detail_parts($t) | any(. == $human_decision));
  def step_text($t):
    if in_review($t) then review_text($t)
    elif $t.step == null then "step not reported"
    elif $t.step.current == null then
      (if $t.step.plan == null then "step not reported"
       else "\(bar(0; ($t.step.plan | length))) 0/\($t.step.plan | length) plan recorded, not started" end)
    else $t.step.current as $c
      | "\(bar($c.n; $c.m)) \($c.n)/\($c.m) \($c.name) (\(human_age($c.age_seconds)))"
    end;
  def step_cell($t): (if needs_you($t) then "⚑ needs you · " else "" end) + step_text($t);
'

render_table() {
  jq -r --arg step_display "$STEP_DISPLAY" --arg human_decision "$FM_GATE_HUMAN_DECISION" "$STEP_JQ_DEFS"'
  def steps_on: $step_display == "on";
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
  def step_column($t): if steps_on then " \(step_cell($t)) |" else "" end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) |\(step_column($t)) \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
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
    "| ID | Current |\(if steps_on then " Step |" else "" end) Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- |\(if steps_on then " --- |" else "" end) --- | --- | --- | --- | --- | --- | --- |",
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
}

# The checklist for one task: build steps from its step record, then the review
# step from its current state, then the last status note. A missing task is an
# error; a missing record says "step not reported".
render_steps() {
  jq -r --arg id "$STEPS_ID" --arg human_decision "$FM_GATE_HUMAN_DECISION" "$STEP_JQ_DEFS"'
  ([.tasks[]? | select(.id == $id)] | first) as $t
  # A step name counts only from the current plan size, so a re-plan never
  # labels a step with a name from an older plan. A recorded full plan of that
  # size names the steps that have not started yet.
  | ($t.step.plan // null) as $plan
  | def name_of($i):
      ([$t.step.history[]? | select(.n == $i and .m == $t.step.current.m) | .name] | last)
      // (if $plan != null and ($plan | length) == $t.step.current.m then $plan[$i - 1].name else null end);
    def build_lines:
      if $t.step == null then "  step not reported"
      elif $t.step.current == null then
        (if $plan == null then "  step not reported"
         else $plan[] as $p | "  [ ] \($p.n)/\($plan | length) \($p.name)" end)
      else $t.step.current as $c
        | range(1; $c.m + 1) as $i
        | name_of($i) as $name
        | if $i < $c.n or ($i == $c.n and in_review($t)) then
            "  [x] \($i)/\($c.m) \($name // "(no name recorded)")"
          elif $i == $c.n then
            "  [>] \($i)/\($c.m) \($c.name) (\(human_age($c.age_seconds)))"
          else
            "  [ ] \($i)/\($c.m) \($name // "not started")"
          end
      end;
    "# Steps: \($id)",
    "",
    "Current: \($t.current_state.state) / \($t.current_state.source)",
    (if needs_you($t) then "⚑ needs you: a decision waits on a human" else empty end),
    "",
    "Build plan:",
    build_lines,
    "",
    "Review:",
    (if in_review($t) then "  \(review_text($t))" else "  no review run recorded" end),
    "",
    "Last note: \(if ($t.hints.last_event_text // "") == "" then "-" else $t.hints.last_event_text end)"
  '
}

render_once() {
  local snapshot
  snapshot=$(take_snapshot) || return $?
  if [ -n "$STEPS_ID" ]; then
    printf '%s\n' "$snapshot" | jq -e --arg id "$STEPS_ID" 'any(.tasks[]?; .id == $id)' >/dev/null || {
      printf 'fm-fleet-view: no live task named %s\n' "$STEPS_ID" >&2
      return 1
    }
    printf '%s\n' "$snapshot" | render_steps
  else
    printf '%s\n' "$snapshot" | render_table
  fi
}

if [ "$WATCH" = 0 ]; then
  render_once
  exit $?
fi

round=0
while :; do
  round=$((round + 1))
  [ -t 1 ] && printf '\033[H\033[2J'
  render_once || exit $?
  [ -t 1 ] && printf '\nRedraws every %ss. Press Ctrl-C to stop.\n' "$INTERVAL"
  if [ "$ROUNDS" -gt 0 ] && [ "$round" -ge "$ROUNDS" ]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
