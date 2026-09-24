#!/usr/bin/env bash
# Behavior tests for bin/fm-flow-snapshot.sh, the read-only per-agent pipeline
# snapshot. Every fixture is synthetic: the fake `no-mistakes`, `gh` and `tmux`
# below are the only outside readers the collector has, so the whole document is
# determined by files this script writes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-flow-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HOME_DIR=$TMP_ROOT/home
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PROJECT=$TMP_ROOT/project
TOON_DIR=$TMP_ROOT/toon
ROLLUP_DIR=$TMP_ROOT/rollup

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" \
  "$PROJECT" "$TOON_DIR" "$ROLLUP_DIR"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

# The same portable mtime read the collector uses, so the expected building
# elapsed is computed from the fixture rather than guessed.
meta_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

write_task() {  # <id> <kind> <mode> <window> [pr-url]
  local id=$1 kind=$2 mode=$3 window=$4 pr=${5:-}
  mkdir -p "$TMP_ROOT/wt/$id"
  if [ -n "$pr" ]; then
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=$window" "endpoint_task_id=$id" "worktree=$TMP_ROOT/wt/$id" \
      "project=$PROJECT" "harness=claude" "kind=$kind" "mode=$mode" "yolo=off" \
      "model=opus-5" "effort=high" "pr=$pr"
  else
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=$window" "endpoint_task_id=$id" "worktree=$TMP_ROOT/wt/$id" \
      "project=$PROJECT" "harness=claude" "kind=$kind" "mode=$mode" "yolo=off" \
      "model=opus-5" "effort=high"
  fi
}

write_task ship-run    ship no-mistakes fm:1 https://github.com/example/project/pull/25
write_task ship-norun  ship no-mistakes fm:2
write_task ship-direct ship direct-PR   fm:3 https://github.com/example/project/pull/26
write_task ship-merged ship no-mistakes fm:4 https://github.com/example/project/pull/27
write_task ship-closed ship no-mistakes fm:5 https://github.com/example/project/pull/28
write_task ship-gitlab ship no-mistakes fm:6 https://gitlab.example.com/group/project/-/merge_requests/7
write_task ship-badrun ship no-mistakes fm:7
write_task ship-odd    ship no-mistakes fm:8
write_task scout-one   scout local-only fm:9
write_task gone-one    ship no-mistakes fm:99

# --- the pipeline runs the fake CLI reports ---------------------------------
#
# The overview table is what bin/fm-nm-run-lib.sh parses to attribute a run to a
# branch. `ship-run` deliberately carries TWO runs, so the selection rule - the
# newest row for the branch wins - is exercised rather than assumed.
cat > "$TMP_ROOT/overview.txt" <<'TOON'
current_branch: main
runs_on_current_branch: 0
count: 5 of 5 total
runs[5]{id,branch,status,head,pr}:
  "01FLOWRUNAAAAAAAAAAAAAAAA1",fm/ship-run,running,"bb73f233","https://github.com/example/project/pull/25"
  "01FLOWRUNAAAAAAAAAAAAAAAA2",fm/ship-run,failed,"a1b2c3d4",""
  "01FLOWRUNAAAAAAAAAAAAAAAA3",fm/ship-badrun,running,"c0ffee11",""
  "01FLOWRUNAAAAAAAAAAAAAAAA4",fm/ship-odd,running,"d00d1234",""
  "01FLOWRUNAAAAAAAAAAAAAAAA5",fm/ship-merged,completed,"feedbeef",""
TOON

cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA1.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA1"
  branch: fm/ship-run
  status: running
  head: bb73f233
  pr: "https://github.com/example/project/pull/25"
  findings: 2 info
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,22
    rebase,completed,0,981
    review,completed,2,176257
    test,completed,1,249567
    document,completed,0,149799
    lint,completed,0,1127597
    push,completed,0,2411
    pr,completed,0,36162
    ci,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,1h2m3s,"37s ago: log: waiting, then polling","",starting
TOON

# An `active_for` carrying a unit the parser does not know must yield null
# rather than a partial sum, which would understate the elapsed materially.
cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA4.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA4"
  branch: fm/ship-odd
  status: running
  head: d00d1234
  steps[1]{step,status,findings,duration_ms}:
    review,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,2w3d,"no news","",1
TOON

cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA5.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA5"
  branch: fm/ship-merged
  status: completed
  head: feedbeef
  error: "step review failed: agent fix: exit status 1"
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,completed,0,20
TOON

cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
# The version banner goes to stderr on every call, including the ones that
# work, which is why the collector keeps the two streams separate.
printf 'A new version of no-mistakes is available\n' >&2
run=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--run" ] && run=\$a
  prev=\$a
done
case "\${1:-}" in
  --version|version) echo "no-mistakes version v1.75.3"; exit 0 ;;
esac
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ] && [ -z "\$run" ]; then
  cat "$TMP_ROOT/overview.txt"
  exit 0
fi
if [ -n "\$run" ]; then
  if [ -f "$TOON_DIR/\$run.txt" ]; then
    cat "$TOON_DIR/\$run.txt"
    exit 0
  fi
  echo "error: repo not initialized"
  exit 1
fi
exit 0
SH

# --- the check rollups the fake gh serves -----------------------------------
#
# PR 25 carries five entries for four checks: the older "Lint" attempt is
# superseded by the newer one and must be counted nowhere, leaving exactly one
# check in each of the four classes.
cat > "$ROLLUP_DIR/25.json" <<'JSON'
{"headRefOid":"bb73f233","state":"OPEN","statusCheckRollup":[
{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","startedAt":"2026-09-24T06:05:00Z"},
{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","startedAt":"2026-09-24T06:10:00Z"},
{"__typename":"CheckRun","name":"Behavior tests","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI","startedAt":"2026-09-24T06:10:00Z"},
{"__typename":"CheckRun","name":"Docs","status":"IN_PROGRESS","conclusion":"","workflowName":"CI","startedAt":"2026-09-24T06:11:00Z"},
{"__typename":"CheckRun","name":"Optional guard","status":"COMPLETED","conclusion":"SKIPPED","workflowName":"CI","startedAt":"2026-09-24T06:10:00Z"}
]}
JSON

cat > "$ROLLUP_DIR/26.json" <<'JSON'
{"headRefOid":"bb73f233","state":"OPEN","statusCheckRollup":[
{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","startedAt":"2026-09-24T06:10:00Z"},
{"__typename":"StatusContext","context":"legacy/commit-status","state":"SUCCESS","createdAt":"2026-09-24T06:10:00Z"}
]}
JSON

cat > "$ROLLUP_DIR/27.json" <<'JSON'
{"headRefOid":"feedbeef","state":"MERGED","statusCheckRollup":[
{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI","startedAt":"2026-09-24T06:10:00Z"}
]}
JSON

cat > "$ROLLUP_DIR/28.json" <<'JSON'
{"headRefOid":"deadbeef","state":"CLOSED","statusCheckRollup":[]}
JSON

cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
# gh pr view <number> --repo <owner>/<repo> --json statusCheckRollup,headRefOid,state
num=\${3:-}
[ "\${1:-}" = pr ] || exit 1
[ "\${2:-}" = view ] || exit 1
[ -f "$ROLLUP_DIR/\$num.json" ] || exit 1
cat "$ROLLUP_DIR/\$num.json"
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-t" ] && target=$arg
  prev=$arg
done
# gone-one's fm:99 is deliberately absent from the session: its recorded
# endpoint no longer resolves, which is what moves it out of the drawn set.
case "$target" in
  fm:99) exit 1 ;;
esac
case "${1:-}" in
  list-windows)
    printf 'fm:1 fm-ship-run\nfm:2 fm-ship-norun\nfm:3 fm-ship-direct\nfm:4 fm-ship-merged\n'
    printf 'fm:5 fm-ship-closed\nfm:6 fm-ship-gitlab\nfm:7 fm-ship-badrun\nfm:8 fm-ship-odd\n'
    printf 'fm:9 fm-scout-one\n'
    ;;
  list-panes)
    printf '%s\n' "${target##*:}"
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  has-session) exit 0 ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH

chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/gh" "$FAKEBIN/tmux"

BUILT_AT=$(meta_mtime "$HOME_DIR/state/ship-norun.meta")
NOW_EPOCH=$((BUILT_AT + 3600))

snapshot() {  # <flags...>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FLOW_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" \
    FM_FLOW_SNAPSHOT_NOW=2026-09-24T07:00:00Z \
    "$SNAPSHOT" "$@"
}

DOC=$(snapshot --json) || fail "the snapshot refused to emit over the fixture home"
printf '%s' "$DOC" | jq -e . >/dev/null 2>&1 || fail "the snapshot did not emit valid JSON"

agent() {  # <id> <jq-filter>
  printf '%s' "$DOC" | jq -r --arg id "$1" "[.agents[] | select(.id == \$id)][0] | $2"
}

# --- the document itself ----------------------------------------------------

assert_equals "fm-flow-snapshot.v1" "$(printf '%s' "$DOC" | jq -r '.schema')" \
  "the schema id names this wire format"

# --- liveness is the only membership test -----------------------------------

assert_equals "" "$(agent gone-one '.id // ""')" \
  "a task whose recorded window no longer resolves is not drawn"
assert_equals "gone-one" \
  "$(printf '%s' "$DOC" | jq -r '[.omitted[] | select(.id == "gone-one")][0].id // ""')" \
  "that task is named in omitted rather than dropped silently"
assert_equals "recorded window no longer exists" \
  "$(printf '%s' "$DOC" | jq -r '[.omitted[] | select(.id == "gone-one")][0].reason')" \
  "omitted says why the task is not drawn"
assert_equals "true" \
  "$(printf '%s' "$DOC" | jq -r '[.agents[].pipeline] == ([.agents[].pipeline] | sort | reverse)')" \
  "pipeline agents are emitted first, so the wire order is the draw order"

# --- a worker with no pipeline carries a state and no steps -----------------

assert_equals "false" "$(agent scout-one '.pipeline')" \
  "a scout is marked as running no pipeline"
assert_equals "0" "$(agent scout-one '.steps | length')" \
  "a scout carries no steps, rather than nine permanently empty ones"
assert_equals "false" "$(agent scout-one '.run.present')" \
  "a scout carries no run"
assert_equals "true" "$(agent scout-one '.state | has("ok")')" \
  "a scout carries the state read through the fleet's own owner of it"
assert_equals "this worker opens no PR" "$(agent scout-one '.ci.collection.reason')" \
  "a scout's checks are named as absent rather than reported as zero"

# --- run selection ----------------------------------------------------------

assert_equals "01FLOWRUNAAAAAAAAAAAAAAAA1" "$(agent ship-run '.run.id')" \
  "the newest run on the branch is the one attributed to the task"
assert_equals "running" "$(agent ship-run '.run.status')" \
  "the run's status comes from the same selection"
assert_equals "bb73f233" "$(agent ship-run '.run.head')" \
  "the run's head is read from its own status output"
assert_equals "true" "$(agent ship-run '.collection.ok')" \
  "a resolved run collects cleanly"
assert_equals "step review failed: agent fix: exit status 1" \
  "$(agent ship-merged '.run.error')" \
  "the run's error text is carried through verbatim"

assert_equals "false" "$(agent ship-norun '.run.present')" \
  "a branch with no run carries none"
assert_equals "true" "$(agent ship-norun '.collection.ok')" \
  "having no run yet is an ordinary state, not a collection failure"
assert_equals "no pipeline run for this branch" "$(agent ship-norun '.collection.reason')" \
  "and it says so in its own words"

# --- step and duration passthrough ------------------------------------------

assert_equals "building intent rebase review test document lint push pr ci" \
  "$(agent ship-run '[.steps[].step] | join(" ")')" \
  "the nine pipeline steps arrive in order behind the worker's own building step"
assert_equals "1127597" "$(agent ship-run '[.steps[] | select(.step == "lint")][0].duration_ms')" \
  "a finished step's duration is passed through unchanged"
assert_equals "2" "$(agent ship-run '[.steps[] | select(.step == "review")][0].findings')" \
  "a step's finding count is passed through unchanged"

# --- the building phase -----------------------------------------------------

assert_equals "completed" "$(agent ship-run '.steps[0].status')" \
  "once a run exists the building phase is over"
assert_equals "null" "$(agent ship-run '.steps[0].duration_ms')" \
  "its duration is blank rather than zero, because nothing records when the run began"
assert_equals "running" "$(agent ship-norun '.steps[0].status')" \
  "a task with no run yet is still building"
assert_equals "3600000" \
  "$(agent ship-norun '[.active_steps[] | select(.step == "building")][0].active_ms')" \
  "its elapsed is measured from the task record"

# --- active steps -----------------------------------------------------------

assert_equals "3723000" \
  "$(agent ship-run '[.active_steps[] | select(.step == "ci")][0].active_ms')" \
  "a running step's humanised elapsed is parsed back to milliseconds"
assert_equals "37s ago: log: waiting, then polling" \
  "$(agent ship-run '[.active_steps[] | select(.step == "ci")][0].last_activity')" \
  "a quoted field keeps the commas inside it"
assert_equals "null" \
  "$(agent ship-odd '[.active_steps[] | select(.step == "review")][0].active_ms')" \
  "an elapsed carrying an unknown unit is reported as unknown, not partially summed"

# --- GitHub check classes ---------------------------------------------------

assert_equals "true" "$(agent ship-run '.ci.collection.ok')" \
  "the check rollup was read"
assert_equals "4" "$(agent ship-run '.ci.total')" \
  "a superseded earlier attempt of a check is counted nowhere"
assert_equals "1" "$(agent ship-run '.ci.passed')" "one check passed"
assert_equals "1" "$(agent ship-run '.ci.failed')" "one check failed"
assert_equals "1" "$(agent ship-run '.ci.pending')" "one check has not finished"
assert_equals "1" "$(agent ship-run '.ci.skipped')" \
  "a deliberately-not-run check is its own class, never folded into passing"
assert_equals "SUCCESS" \
  "$(agent ship-run '[.ci.checks[] | select(.name == "Lint")][0].conclusion')" \
  "the latest attempt of a check is the one kept"
assert_equals "bb73f233" "$(agent ship-run '.ci.head')" \
  "the commit these checks describe is carried beside them"

assert_equals "2" "$(agent ship-direct '.ci.total')" \
  "a commit status is counted alongside check runs rather than dropped"
assert_equals "2" "$(agent ship-direct '.ci.passed')" \
  "a successful commit status counts as passing"

# --- the pull request's own lifecycle ---------------------------------------

assert_equals "OPEN" "$(agent ship-run '.ci.pr_state')" "an open PR reports itself open"
assert_equals "MERGED" "$(agent ship-merged '.ci.pr_state')" "a merged PR reports itself merged"
assert_equals "CLOSED" "$(agent ship-closed '.ci.pr_state')" "a closed PR reports itself closed"
assert_equals "25" "$(agent ship-run '.pr.number')" \
  "the PR number comes from the same parser the check read used"

# --- a link this view cannot read checks for --------------------------------

assert_equals "false" "$(agent ship-gitlab '.ci.collection.ok')" \
  "a merge request's checks are not claimed to have been read"
assert_equals "checks are read for GitHub pull requests only" \
  "$(agent ship-gitlab '.ci.collection.reason')" \
  "and the limit is named rather than left blank"
assert_equals "0" "$(agent ship-gitlab '.ci.total')" \
  "no check count is invented for it"

# --- a failed run read reports the command's own words ----------------------

assert_equals "false" "$(agent ship-badrun '.collection.ok')" \
  "a run whose status could not be read collects as a failure"
assert_contains "$(agent ship-badrun '.collection.reason')" "error: repo not initialized" \
  "the reason carries the command's own diagnosis, not just an exit code"
assert_equals "0" "$(agent ship-badrun '.steps | length')" \
  "no step is reported inside a frame that says nothing about this task is known"

# --- --no-ci ----------------------------------------------------------------

DOC=$(snapshot --json --no-ci) || fail "--no-ci refused to emit"
assert_equals "skipped" "$(agent ship-run '.ci.collection.reason')" \
  "--no-ci names the GitHub read as skipped rather than failed"
assert_equals "0" "$(agent ship-run '.ci.total')" "--no-ci reads no checks"
assert_equals "01FLOWRUNAAAAAAAAAAAAAAAA1" "$(agent ship-run '.run.id')" \
  "--no-ci still resolves the pipeline run, which is a local read"

# --- --task -----------------------------------------------------------------

DOC=$(snapshot --json --task ship-run) || fail "--task refused to emit"
assert_equals "1" "$(printf '%s' "$DOC" | jq -r '.agents | length')" \
  "--task restricts the snapshot to the one task"
assert_equals "ship-run" "$(printf '%s' "$DOC" | jq -r '.agents[0].id')" \
  "--task keeps the task it was given"

# --- usage ------------------------------------------------------------------

snapshot --not-a-flag >/dev/null 2>&1
expect_code 2 $? "the collector refuses an unknown flag"

snapshot --task >/dev/null 2>&1
expect_code 2 $? "--task refuses to run with no id"

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_FLOW_SNAPSHOT_FLEET_JSON="$TMP_ROOT/does-not-exist.json" \
  "$SNAPSHOT" --json >/dev/null 2>&1
expect_code 1 $? "an unreadable fleet document refuses rather than emitting an empty fleet"

pass "fm-flow-snapshot: pipeline steps, check classes and crew state over a synthetic fleet"
