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
write_task ship-wide   ship no-mistakes fm:9
write_task ship-readfail ship no-mistakes fm:11
write_task ship-captured ship no-mistakes fm:12
write_task ship-ansi     ship no-mistakes fm:13
# A project can register its own ship-branch prefix, so this task's branch is
# not fm/<id>. bin/fm-spawn.sh records the branch it actually built and
# bin/fm-fleet-snapshot.sh publishes it; run attribution is keyed on it.
write_task ship-prefixed ship no-mistakes fm:14
printf 'branch=release/ship-prefixed\n' >> "$HOME_DIR/state/ship-prefixed.meta"
# Deliberately NOT created: the run is read in the task's own copy or not at
# all, and the project root is a different copy answering for a different
# repository.
fm_write_meta "$HOME_DIR/state/ship-nocopy.meta" \
  "window=fm:15" "endpoint_task_id=ship-nocopy" \
  "worktree=$TMP_ROOT/wt/ship-nocopy-absent" \
  "project=$PROJECT" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
write_task scout-one   scout local-only fm:10
# No window at all, which is how the fleet document reports a task it could not
# observe as well as one that never had an endpoint.
fm_write_meta "$HOME_DIR/state/no-endpoint.meta" \
  "endpoint_task_id=no-endpoint" "worktree=$TMP_ROOT/wt/no-endpoint" \
  "project=$PROJECT" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
mkdir -p "$TMP_ROOT/wt/no-endpoint"
write_task gone-one    ship no-mistakes fm:99

# --- the pipeline runs the fake CLI reports ---------------------------------
#
# The overview table is what bin/fm-nm-run-lib.sh parses to attribute a run to a
# branch. `ship-run` deliberately carries TWO runs, so the selection rule - the
# newest row for the branch wins - is exercised rather than assumed.
cat > "$TMP_ROOT/overview.txt" <<'TOON'
current_branch: main
runs_on_current_branch: 0
count: 9 of 9 total
runs[9]{id,branch,status,head,pr}:
  "01FLOWRUNAAAAAAAAAAAAAAAA1",fm/ship-run,running,"bb73f233","https://github.com/example/project/pull/25"
  "01FLOWRUNAAAAAAAAAAAAAAAA2",fm/ship-run,failed,"a1b2c3d4",""
  "01FLOWRUNAAAAAAAAAAAAAAAA3",fm/ship-badrun,running,"c0ffee11",""
  "01FLOWRUNAAAAAAAAAAAAAAAA4",fm/ship-odd,running,"d00d1234",""
  "01FLOWRUNAAAAAAAAAAAAAAAA5",fm/ship-merged,completed,"feedbeef",""
  "01FLOWRUNAAAAAAAAAAAAAAAA6",fm/ship-wide,running,"ab12cd34",""
  "01FLOWRUNAAAAAAAAAAAAAAAA7",fm/ship-captured,failed,"9b76c588",""
  "01FLOWRUNAAAAAAAAAAAAAAAA8",fm/ship-ansi,running,"11aa22bb",""
  "01FLOWRUNAAAAAAAAAAAAAAAA9",release/ship-prefixed,running,"33cc44dd",""
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
cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA9.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA9"
  branch: release/ship-prefixed
  status: running
  head: 33cc44dd
  steps[1]{step,status,findings,duration_ms}:
    review,running,0,0
TOON

cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA4.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA4"
  branch: fm/ship-odd
  status: running
  head: d00d1234
  steps[1]{step,status,findings}:
    review,running,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,2w3d,"no news","",1
TOON

cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA5.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA5"
  branch: fm/ship-merged
  status: completed
  head: feedbeef
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,completed,0,20
outcome: completed
error: "step review failed: agent fix: exit status 1"
TOON

# The tool has inserted a column mid-block between versions: `round_active_for`
# arrives fourth in active_steps on newer builds, and `attempt` is a plausible
# future addition to steps. A parser that indexed by position rather than by the
# header's own column names would relabel every column after the new one and
# still emit a well-formed row.
cat > "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA6.txt" <<'TOON'
run:
  id: "01FLOWRUNAAAAAAAAAAAAAAAA6"
  branch: fm/ship-wide
  status: running
  head: ab12cd34
  pr: "https://github.com/example/project/pull/999"
  steps[4]{step,status,detail,attempt,findings,duration_ms}:
    "intent",completed,,1,0,44
    review,running,"failed, then fixed",2,3,0
    test,completed,"two, commas, here",1,5,176257
    lint,completed,"he said \"go, then stop\"",1,7,999
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,running,2m30s,30s,"9s ago: log: still going","4242",second
TOON

# The repository's own captured output from this emitter, served unchanged. The
# hand-written fixtures above encode what the shape is believed to be; this one
# is what it actually was, which is how the `error` key was found to sit at
# column 0 rather than inside the run block.
cp "$ROOT/tests/captures/no-mistakes-v1.70.1/failed.toon" \
  "$TOON_DIR/01FLOWRUNAAAAAAAAAAAAAAAA7.txt"

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
  # The overview is read in the task's own copy of the repository, so the
  # working directory is what lets this fake fail for one task only.
  case "\$PWD" in
    */ship-readfail) echo "error: repo not initialized" >&2; exit 1 ;;
  esac
  cat "$TMP_ROOT/overview.txt"
  exit 0
fi
if [ -n "\$run" ]; then
  if [ -f "$TOON_DIR/\$run.txt" ]; then
    cat "$TOON_DIR/\$run.txt"
    exit 0
  fi
  # Colourised, on stderr, with nothing on stdout: the shape that makes the
  # collector fall back to stderr for the failed read's own words.
  if [ "\$run" = 01FLOWRUNAAAAAAAAAAAAAAAA8 ]; then
    printf '\033[31merror: the daemon said no\033[0m\n' >&2
    exit 1
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

# Every invocation is recorded, so a flag that claims the snapshot is local can
# be checked against what was actually called rather than against its own help.
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$TMP_ROOT/gh-calls.log"
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
    printf 'fm:9 fm-ship-wide\nfm:10 fm-scout-one\nfm:11 fm-ship-readfail\n'
    printf 'fm:12 fm-ship-captured\nfm:13 fm-ship-ansi\nfm:14 fm-ship-prefixed\n'
    printf 'fm:15 fm-ship-nocopy\n'
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

DOC=$(snapshot) || fail "the snapshot refused to emit over the fixture home"
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
assert_equals "no endpoint liveness recorded for this task" \
  "$(printf '%s' "$DOC" | jq -r '[.omitted[] | select(.id == "no-endpoint")][0].reason')" \
  "a task the fleet read could not observe is not reported as never having had an endpoint"
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
assert_equals "true" "$(agent scout-one '.state.ok')" \
  "a scout carries the state the fleet document published"
assert_equals "$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null \
  | jq -r '[.tasks[] | select(.id == "scout-one")][0].current_state.state')" \
  "$(agent scout-one '.state.value')" \
  "and it is that document's own value, not a second reading that could disagree"
assert_equals "not_checked" "$(agent scout-one '.agent_alive')" \
  "the fleet document's endpoint liveness is passed through, never re-probed here"
assert_equals "not_checked" "$(agent ship-run '.agent_alive')" \
  "including for a pipeline agent"
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

# --- read against the repository's own capture of this emitter ---------------

assert_equals "true" "$(agent ship-captured '.collection.ok')" \
  "the captured output of a real run collects cleanly"
assert_contains "$(agent ship-captured '.run.error')" "step push failed: push to fork" \
  "the error text is read although it sits at column 0 rather than inside the run block"
assert_equals "9b76c588" "$(agent ship-captured '.run.head')" \
  "and the head is read from inside the run block in the same pass"
assert_equals "failed" \
  "$(agent ship-captured '[.steps[] | select(.step == "push")][0].status')" \
  "its step statuses come through"
assert_equals "6980" \
  "$(agent ship-captured '[.steps[] | select(.step == "push")][0].duration_ms')" \
  "and their durations"

# --- the run is read in the task's own copy, or not at all ------------------

assert_equals "false" "$(agent ship-nocopy '.collection.ok')" \
  "a task whose own copy of the repository is gone reports its run as unestablished"
assert_contains "$(agent ship-nocopy '.collection.reason')" "no copy of the repository" \
  "and says so, rather than reading a different copy and answering from it"

# --- the pull request link has one source -----------------------------------

assert_equals "null" "$(agent ship-wide '.pr.url')" \
  "a link on the run itself is not adopted as the task's, which the fleet document owns"
assert_equals "null" "$(agent ship-wide '.pr.number')" \
  "so no PR number is attached to a task the rest of firstmate has none for"

# --- a project that registered its own ship-branch prefix -------------------

assert_equals "release/ship-prefixed" "$(agent ship-prefixed '.branch')" \
  "the task's branch is read from the fleet document, not rebuilt from its id"
assert_equals "01FLOWRUNAAAAAAAAAAAAAAAA9" "$(agent ship-prefixed '.run.id')" \
  "so its run is attributed, which keying on fm/<id> would have missed entirely"
assert_equals "true" "$(agent ship-prefixed '.collection.ok')" \
  "and the row does not report a busy task as having no pipeline run"

# --- a failed read whose diagnosis is colourised ----------------------------

assert_equals "false" "$(agent ship-ansi '.collection.ok')" \
  "a run read that fails collects as a failure"
assert_contains "$(agent ship-ansi '.collection.reason')" "error: the daemon said no" \
  "the command's own words are read from stderr when stdout is empty"
assert_not_contains "$(agent ship-ansi '.collection.reason')" "[31m" \
  "with its colour escapes stripped rather than carried onto the wire"
assert_not_contains "$(agent ship-ansi '.collection.reason')" "u001b" \
  "and none left encoded in the JSON either"

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

# --- a numeric column the header never declared -----------------------------
#
# Zero is a measured value here, a step that took no time or found nothing, so
# reporting it for a column that was never emitted states a measurement that was
# never made.
assert_equals "null" \
  "$(agent ship-odd '[.steps[] | select(.step == "review")][0].duration_ms')" \
  "a duration the block header did not declare is unknown, not a measured zero"
assert_equals "0" \
  "$(agent ship-odd '[.steps[] | select(.step == "review")][0].findings')" \
  "while a column that IS declared keeps its own measured zero"

# --- a block whose columns moved ---------------------------------------------

assert_equals "150000" \
  "$(agent ship-wide '[.active_steps[] | select(.step == "review")][0].active_ms')" \
  "a block carrying an extra column still reads its elapsed from the right one"
assert_equals "9s ago: log: still going" \
  "$(agent ship-wide '[.active_steps[] | select(.step == "review")][0].last_activity')" \
  "and every column after the new one keeps its own name's value"
assert_equals "4242" \
  "$(agent ship-wide '[.active_steps[] | select(.step == "review")][0].agent_pid')" \
  "the process id is not the column that used to sit at its index"
assert_equals "second" \
  "$(agent ship-wide '[.active_steps[] | select(.step == "review")][0].round')" \
  "nor is the round"
assert_equals "44" \
  "$(agent ship-wide '[.steps[] | select(.step == "intent")][0].duration_ms')" \
  "a step block carrying an extra column reads its duration by name too"
assert_equals "3" \
  "$(agent ship-wide '[.steps[] | select(.step == "review")][0].findings')" \
  "and its finding count by name"
# A plain comma split shifts every later column, so the name map indexes
# correctly into a wrongly split row and reads confident wrong numbers.
assert_equals "176257" \
  "$(agent ship-wide '[.steps[] | select(.step == "test")][0].duration_ms')" \
  "a quoted comma inside a steps field does not shift the columns after it"
assert_equals "5" \
  "$(agent ship-wide '[.steps[] | select(.step == "test")][0].findings')" \
  "nor the finding count that sits between them"
# This emitter quotes a leading cell elsewhere, and a row gate keyed on the
# first CHARACTER dropped such a row and closed the block with it, so every row
# after it went too.
assert_equals "completed" \
  "$(agent ship-wide '[.steps[] | select(.step == "intent")][0].status')" \
  "a row whose leading cell is quoted is still read"
assert_equals "4" "$(agent ship-wide '[.steps[] | select(.step != "building")] | length')" \
  "and it does not take the rest of its block with it"
# This emitter escapes a quote inside a quoted cell, so a splitter that toggles
# on every quote closes the field early and shifts every later column.
assert_equals "999" \
  "$(agent ship-wide '[.steps[] | select(.step == "lint")][0].duration_ms')" \
  "an escaped quote inside a quoted cell does not close it early"
assert_equals "7" \
  "$(agent ship-wide '[.steps[] | select(.step == "lint")][0].findings')" \
  "nor shift the column before it"

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

assert_equals "no pull request recorded for this task" \
  "$(agent ship-norun '.ci.collection.reason')" \
  "a task with no PR has nothing to read checks for, which is not a suppressed read"
assert_equals "0" "$(agent ship-norun '.ci.total')" "and no check count is invented for it"

# --- a link this view cannot read checks for --------------------------------

assert_equals "false" "$(agent ship-gitlab '.ci.collection.ok')" \
  "a merge request's checks are not claimed to have been read"
assert_equals "checks are read for GitHub pull requests only" \
  "$(agent ship-gitlab '.ci.collection.reason')" \
  "and the limit is named rather than left blank"
assert_equals "0" "$(agent ship-gitlab '.ci.total')" \
  "no check count is invented for it"

# --- a failed run LIST read is not an empty pipeline ------------------------

assert_equals "false" "$(agent ship-readfail '.collection.ok')" \
  "a run list that could not be read collects as a failure"
assert_contains "$(agent ship-readfail '.collection.reason')" "could not be read" \
  "and says the READ failed, rather than claiming the pipeline holds no runs"
assert_not_contains "$(agent ship-readfail '.collection.reason')" "listed no runs" \
  "which is a claim about the pipeline's contents that a failed read cannot support"

# --- a failed run read reports the command's own words ----------------------

assert_equals "false" "$(agent ship-badrun '.collection.ok')" \
  "a run whose status could not be read collects as a failure"
assert_contains "$(agent ship-badrun '.collection.reason')" "error: repo not initialized" \
  "the reason carries the command's own diagnosis, not just an exit code"
assert_equals "0" "$(agent ship-badrun '.steps | length')" \
  "no step is reported inside a frame that says nothing about this task is known"

# --- --no-ci ----------------------------------------------------------------

assert_present "$TMP_ROOT/gh-calls.log" \
  "an ordinary run does reach GitHub, so the next assertion is not vacuous"
rm -f "$TMP_ROOT/gh-calls.log"

DOC=$(snapshot --no-ci) || fail "--no-ci refused to emit"
assert_absent "$TMP_ROOT/gh-calls.log" \
  "--no-ci makes no GitHub call at all, including through the fleet read it does not own"
assert_equals "skipped" "$(agent ship-run '.ci.collection.reason')" \
  "--no-ci names the GitHub read as skipped rather than failed"
assert_equals "0" "$(agent ship-run '.ci.total')" "--no-ci reads no checks"
assert_equals "01FLOWRUNAAAAAAAAAAAAAAAA1" "$(agent ship-run '.run.id')" \
  "--no-ci still resolves the pipeline run, which is a local read"

# --- --task -----------------------------------------------------------------

DOC=$(snapshot --task ship-run) || fail "--task refused to emit"
assert_equals "1" "$(printf '%s' "$DOC" | jq -r '.agents | length')" \
  "--task restricts the snapshot to the one task"
assert_equals "ship-run" "$(printf '%s' "$DOC" | jq -r '.agents[0].id')" \
  "--task keeps the task it was given"

# --- usage ------------------------------------------------------------------

# --help is printed by slicing this script's own header, so the slice and the
# header drift apart silently: the help simply stops mid-sentence. Assert the
# whole contract arrives, including its last line.
HELP=$(snapshot --help) || fail "--help refused to run"
for documented in --no-ci --task \
  FM_FLOW_SNAPSHOT_NM_TIMEOUT FM_FLOW_SNAPSHOT_GH_TIMEOUT \
  FM_FLOW_SNAPSHOT_NOW_EPOCH FM_FLOW_SNAPSHOT_NOW; do
  assert_contains "$HELP" "$documented" "--help documents $documented"
done
assert_contains "$HELP" "fm-flow-snapshot.sh - read-only per-agent pipeline snapshot." \
  "--help starts at the first header line"
assert_equals "one wedged worker must not blank the whole view." \
  "$(printf '%s\n' "$HELP" | sed -e '/^$/d' -e '$!d')" \
  "--help reaches its last line rather than stopping mid-sentence"
for gone in FM_FLOW_SNAPSHOT_STATE_TIMEOUT FM_FLOW_SNAPSHOT_FLEET_JSON; do
  assert_not_contains "$HELP" "$gone" "--help does not document $gone, which this command no longer has"
done

snapshot --not-a-flag >/dev/null 2>&1
expect_code 2 $? "the collector refuses an unknown flag"

# --json was a no-op alias for the default behavior and is gone, so it is now an
# unknown flag like any other rather than a silently accepted one.
snapshot --json >/dev/null 2>&1
expect_code 2 $? "--json is no longer accepted"

snapshot --task >/dev/null 2>&1
expect_code 2 $? "--task refuses to run with no id"

# A fleet read that FAILS must refuse, because an empty document would read as
# an empty fleet, which is a different and far more dangerous claim. An absent
# home is not that case: it is a real, empty fleet. A task record the fleet read
# cannot take a copy of is, and it is the cheapest genuine trigger.
if [ "$(id -u)" != 0 ]; then
  FAIL_HOME=$TMP_ROOT/unreadable-home
  mkdir -p "$FAIL_HOME/state" "$FAIL_HOME/data"
  printf '# Backlog\n' > "$FAIL_HOME/data/backlog.md"
  fm_write_meta "$FAIL_HOME/state/unreadable.meta" \
    "window=fm:1" "worktree=$TMP_ROOT/wt/ship-run" "project=$PROJECT" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  chmod 000 "$FAIL_HOME/state/unreadable.meta"
  PATH="$FAKEBIN:$PATH" FM_HOME="$FAIL_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$SNAPSHOT" >/dev/null 2>&1
  expect_code 1 $? "a fleet read that fails refuses rather than emitting an empty fleet"
  chmod 644 "$FAIL_HOME/state/unreadable.meta"
fi

pass "fm-flow-snapshot: pipeline steps, check classes and crew state over a synthetic fleet"
