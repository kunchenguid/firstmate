#!/usr/bin/env bash
# Deterministic /task detail tests for current, Done, blocked, missing-date,
# closed, ambiguous, and retired-reference lookup behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TASK="$ROOT/bin/fm-task.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-detail)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n' ;;
  list-windows)
    printf 'fm-active-task\nfm-ready-task\n'
    ;;
esac
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] active-task - Implement understandable task details (repo: firstmate) (kind: ship) (since 2026-09-10)
  - Preserve the useful durable context without copying generated instructions.
- [ ] ready-task - Finish local task card (repo: firstmate) (kind: ship) (since 2026-09-11)
## Queued
- [ ] blocker-task - Supply required dependency (repo: firstmate) (kind: ship) (since 2026-09-09)
- [ ] blocked-task - Wait for required dependency (repo: firstmate) (kind: ship) blocked-by: blocker-task
- [ ] missing-date-task - Keep unknown dates honest (repo: firstmate) (kind: scout)
## Done
- [x] done-task - Completed task awaiting acknowledgement (repo: firstmate) (kind: ship) (done 2026-09-12)
  Delivered to local main with the requested behavior.
EOF

for id in active-task ready-task; do
  mkdir -p "$HOME_DIR/projects/$id" "$HOME_DIR/data/tasks/$id"
  cat > "$HOME_DIR/state/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$HOME_DIR/projects/$id
project=$HOME_DIR/projects/firstmate
harness=claude
kind=ship
mode=local-only
yolo=off
spawn_gen=s100.$id
started_at=2026-09-10T09:30:00Z
EOF
  busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$id" idle --gen "$busy_gen" \
    --source claude-hook --event stop
done
cat >> "$HOME_DIR/state/active-task.meta" <<'EOF'
pr=https://example.test/pull/44
EOF
cat > "$HOME_DIR/data/tasks/active-task/brief.md" <<'EOF'
# Task

## Captain's intent
Show enough useful task detail to decide whether to close the work.
Keep purpose concise.

## Firstmate spec
This generated implementation section must not be copied into Purpose.

## Captain review plan
Review Action: Exercise the detailed task card
Review Context: The detail view is implemented.
Review Check: Open the task by its short reference.
Review Check: Confirm the purpose excludes implementation-only instructions.
Review Success: The task detail is useful and concise.
Review Failure: The purpose leaks implementation-only instructions.
Review Fix: Remove the leaked implementation text.
EOF
printf 'working: assembling the deterministic task card\n' > "$HOME_DIR/state/active-task.status"
printf 'done: ready in branch fm/ready-task\n' > "$HOME_DIR/state/ready-task.status"

active=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json active-task) \
  || fail "active task detail lookup failed"
printf '%s\n' "$active" | jq -e '
  .schema == "fm-task-detail.v2"
  and (keys | sort) == ["acceptance","artifacts","attention","closeReady","completionEvidence","dates","delivery","details","followUps","id","kind","lifecycle","name","nextAction","outcome","project","purpose","ref","requirements","retainedKnowledge","reviewPlan","route","schema","source","status"]
  and .source == "current"
  and .ref == "t1"
  and .name == "understandable-task-details"
  and .id == "active-task"
  and .project == "firstmate"
  and .kind == "ship"
  and .status == "working"
  and .dates.created == "2026-09-10"
  and .dates.started == "2026-09-10T09:30:00Z"
  and .dates.finished == null
  and .purpose == "Show enough useful task detail to decide whether to close the work. Keep purpose concise."
  and (.purpose | contains("generated implementation") | not)
  and (.details | contains("useful durable context"))
  and .outcome == "assembling the deterministic task card"
  and .requirements.captainIntent == "Show enough useful task detail to decide whether to close the work. Keep purpose concise."
  and .requirements.firstmateSpec == "This generated implementation section must not be copied into Purpose."
  and .reviewPlan.source == "data/tasks/active-task/brief.md"
  and .reviewPlan.review.action == "Exercise the detailed task card"
  and .reviewPlan.review.checks == ["Open the task by its short reference.","Confirm the purpose excludes implementation-only instructions."]
  and .reviewPlan.review.success == "The task detail is useful and concise."
  and .reviewPlan.review.failure == "The purpose leaks implementation-only instructions."
  and .reviewPlan.review.fix == "Remove the leaked implementation text."
  and .completionEvidence.summary == "assembling the deterministic task card"
  and .completionEvidence.artifactType == "pull request"
  and (.artifacts | index("https://example.test/pull/44") != null)
  and .nextAction == "Continue the current work"
' >/dev/null || fail "active detail omitted composed current records: $active"
card=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" t1) \
  || fail "active short-reference card failed"
assert_contains "$card" "Task t1: understandable-task-details" "card heading changed"
assert_contains "$card" "Canonical ID: active-task" "card omitted canonical identity"
assert_contains "$card" "Started: 2026-09-10T09:30:00Z" "card omitted authoritative start date"
assert_contains "$card" "Next action: Continue the current work" "card omitted active next action"
pass "active task detail composes purpose, dates, state, metadata, and artifacts"

ready=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json ready-task) \
  || fail "ready task detail lookup failed"
printf '%s\n' "$ready" | jq -e '
  .status == "done"
  and .outcome == "ready in branch fm/ready-task; candidate ready for review"
  and .delivery == "Candidate local branch"
  and .acceptance == null
  and .nextAction == "Start review"
' >/dev/null || fail "Done task inferred acceptance or skipped review: $ready"
pass "completed local work remains a candidate until review records acceptance"

done=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json done-task) \
  || fail "Done task detail lookup failed"
printf '%s\n' "$done" | jq -e '
  .status == "done"
  and .dates.finished == "2026-09-12"
  and .outcome == "Candidate result ready; review has not started"
  and .acceptance == null
  and .closeReady == false
  and .nextAction == "Start review"
' >/dev/null || fail "Done task was not presented as an unreviewed candidate: $done"
pass "Done current work names review instead of inferring acceptance"

blocked=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json blocked-task) \
  || fail "blocked task detail lookup failed"
printf '%s\n' "$blocked" | jq -e '
  .status == "blocked"
  and .outcome == "Waiting on blocker-task"
  and .attention == "Blocked by: blocker-task"
  and .nextAction == "Firstmate must resolve the recorded problem"
' >/dev/null || fail "blocked task omitted its concrete blocker: $blocked"
pass "blocked task detail identifies the blocker and next action"

missing=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json missing-date-task) \
  || fail "missing-date task detail lookup failed"
printf '%s\n' "$missing" | jq -e '
  .dates.created == null and .dates.started == null and .dates.finished == null and .dates.delivered == null
' >/dev/null || fail "missing lifecycle dates were inferred: $missing"
missing_card=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" missing-date-task)
assert_contains "$missing_card" "Created: unknown" "card did not label a missing creation date honestly"
assert_contains "$missing_card" "Started: unknown" "card did not label a missing start date honestly"
assert_contains "$missing_card" "Finished: unknown" "card did not label a missing finish date honestly"
pass "missing lifecycle dates stay explicit and honest"

make_closure() {  # <id> <name> <result>
  local id=$1 name=$2 result=$3 dir
  dir="$HOME_DIR/data/closed-tasks/$id"
  mkdir -p "$dir"
  jq -n --arg id "$id" --arg name "$name" --arg result "$result" '
    {version:1, disposition:"closed", id:$id, ref:"t9", name:$name,
     project:"firstmate", kind:"ship",
     dates:{created:"2026-08-01",started:"2026-08-02T09:00:00Z",completed:"2026-08-03",closed:"2026-08-04T12:00:00Z"},
     closedEpoch:1785844800, result:$result,
     artifacts:["https://example.test/pull/9"],
     retainedKnowledge:[("data/closed-tasks/" + $id + "/brief.md"),"data/learnings.md"],
     followUps:["later-task"], archive:("data/closed-tasks/" + $id)}' > "$dir/closure.json"
  cat > "$dir/task.txt" <<EOF
task:
  id: $id
  title: Archived purpose title
  body: Remember the useful archived detail.
EOF
  cat > "$dir/brief.md" <<'EOF'
## Captain's intent
Preserve the archived purpose without reviving its old short reference.

## Firstmate spec
Do not copy this section.
EOF
}

make_closure closed-task archived-task-detail "Delivered the task detail command"
closed=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json closed-task) \
  || fail "closed canonical lookup failed"
printf '%s\n' "$closed" | jq -e '
  .schema == "fm-task-detail.v2"
  and .source == "closed"
  and .ref == "t9 (retired)"
  and .name == "archived-task-detail"
  and .status == "closed"
  and .dates.created == "2026-08-01"
  and .dates.started == "2026-08-02T09:00:00Z"
  and .dates.finished == "2026-08-03"
  and .dates.closed == "2026-08-04T12:00:00Z"
  and .purpose == "Preserve the archived purpose without reviving its old short reference."
  and .details == "Remember the useful archived detail."
  and .outcome == "Delivered the task detail command"
  and .acceptance == null
  and .route == null
  and (.artifacts | index("https://example.test/pull/9") != null)
  and (.retainedKnowledge | index("data/learnings.md") != null)
  and .followUps == ["later-task"]
  and .nextAction == "Continue recorded follow-up work"
' >/dev/null || fail "closed detail omitted archived result or links: $closed"
by_name=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$TASK" --json archived-task-detail) \
  || fail "closed human-name lookup failed"
[ "$(printf '%s\n' "$by_name" | jq -r .id)" = closed-task ] || fail "closed human name selected the wrong archive"
pass "closed lookup returns archived dates, result, knowledge, artifacts, and follow-ups"

make_closure other-closed shared-closed-name "One result"
make_closure third-closed shared-closed-name "Another result"
if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$TASK" shared-closed-name >"$TMP_ROOT/ambiguous.out" 2>&1; then
  fail "ambiguous closed name resolved"
fi
assert_grep "ambiguous closed-task name" "$TMP_ROOT/ambiguous.out" "ambiguity did not ask for a canonical id"
pass "ambiguous closed names are refused"

if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$TASK" t9 >"$TMP_ROOT/retired.out" 2>&1; then
  fail "retired short reference resolved from history"
fi
assert_grep "retired or unknown short reference 't9'" "$TMP_ROOT/retired.out" \
  "retired reference refusal was not explicit"
pass "retired short references remain intentionally unresolved"

echo "# all fm-task-detail tests passed"
