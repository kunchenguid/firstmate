#!/usr/bin/env bash
# Fixture for tests/fm-crew-panel.test.sh: one home with a worker in each state
# the crew panel draws. crew_panel_fixture <dir> writes the home under <dir>/home,
# a fake no-mistakes under <dir>/fakebin, and the snapshot at <dir>/snapshot.json.
# The time is fixed at CREW_PANEL_NOW (2026-11-18 15:08 UTC).
set -u

CREW_PANEL_NOW=1795014480

# shellcheck source=bin/fm-step-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-step-lib.sh"

crew_panel_fixture() {  # <dir>
  local dir=$1 home state now=$CREW_PANEL_NOW id
  home="$dir/home"
  state="$home/state"
  mkdir -p "$state" "$home/data" "$dir/fakebin" "$dir/wt"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# Fake no-mistakes: `axi status` prints the run saved in the worktree.
[ "${1:-} ${2:-}" = "axi status" ] && [ -f .nm-axi-status ] && { cat .nm-axi-status; exit 0; }
exit 1
SH
  chmod +x "$dir/fakebin/no-mistakes"

  # fm-step.sh stamps each record line with `date +%s`; a fake date sets the time.
  mkdir -p "$dir/fakedate"
  cat > "$dir/fakedate/date" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = +%s ] && [ -n "${CREW_PANEL_EPOCH:-}" ] && { printf '%s\n' "$CREW_PANEL_EPOCH"; exit 0; }
exec /bin/date "$@"
SH
  chmod +x "$dir/fakedate/date"
  step() {  # <id> <seconds-ago> <fm-step args...>
    local sid=$1 ago=$2
    shift 2
    CREW_PANEL_EPOCH=$((now - ago)) PATH="$dir/fakedate:$PATH" \
      "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-step.sh" --record "$state/$sid.step" "$@"
  }
  status() {  # <id> <seconds-ago> <state> <text>
    printf '%s [at=%s]: %s\n' "$3" "$((now - $2))" "$4" >> "$state/$1.status"
  }
  steer() {  # <id> <seconds-ago> <text>
    mkdir -p "$state/$1.inbox/handled"
    printf 'schema=fm-task-inbox.v1\nat=%s\n--\n%s\n' \
      "$(date -u -r "$((now - $2))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - $2))" +%Y-%m-%dT%H:%M:%SZ)" \
      "$3" > "$state/$1.inbox/handled/$((now - $2))-x.msg"
  }

  # working: a five-step plan, on step 3.
  id=arc-5673-toolbar-spacing
  step $id 1500 --plan 'Read the toolbar code' 'Find the spacing rule' 'Write the spacing fix' 'Run the tests' 'Write the PR text'
  step $id 1500 1 5 'Read the toolbar code'
  step $id 1100 2 5 'Find the spacing rule'
  step $id 360 3 5 'Write the spacing fix'
  status $id 1500 working 'started the plan'
  # working, no step reported.
  status arc-5677-editor-toolbar 900 working 'reading the editor toolbar'
  # needs you.
  id=arc-tokens-wave2
  step $id 2400 --plan 'Map the tokens' 'Rename the tokens' 'Update the docs'
  step $id 2400 1 3 'Map the tokens'
  step $id 1200 2 3 'Rename the tokens'
  status $id 2400 working 'started the plan'
  status $id 720 needs-decision '[key=tokens] Rename the tokens in place, or keep the old names as aliases for one release?'
  steer $id 3000 'Start with the color tokens.'
  # checking: the plan is done and the review runs.
  id=arc-5595-styles
  step $id 5400 --plan 'Read the styles' 'Write the fix' 'Run the tests'
  step $id 5400 1 3 'Read the styles'
  step $id 4200 2 3 'Write the fix'
  step $id 2400 3 3 'Run the tests'
  mkdir -p "$dir/wt/$id"
  cat > "$dir/wt/$id/.nm-axi-status" <<'TOON'
run:
  id: r-5595
  branch: fm/arc-5595-styles
  status: running
  pr: ""
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,1200
  rebase,completed,0,800
  review,completed,2,90000
  test,running,0,
  document,pending,0,
  lint,pending,0,
  push,pending,0,
  pr,pending,0,
  ci,pending,0,
active_steps[1]{step,active_for,last_activity,agent_pid,round}:
  test,4m12s,10s,123,1
TOON
  # verifying: the PR is green and the verifier runs.
  id=arc-5601-role-access
  step $id 9000 --plan 'Read the role checks' 'Write the access fix' 'Run the tests'
  step $id 9000 1 3 'Read the role checks'
  step $id 7000 2 3 'Write the access fix'
  step $id 5000 3 3 'Run the tests'
  status $id 900 "done" 'PR https://github.com/acme/arc/pull/5601 checks green'
  # stopped review: the worker reported done, then stopped its review run at the CI wait.
  id=arc-5700-stopped-review
  step $id 15000 --plan 'Read the code' 'Write the fix'
  step $id 15000 1 2 'Read the code'
  step $id 14000 2 2 'Write the fix'
  status $id 13000 "done" 'PR https://github.com/acme/arc/pull/5700'
  id=arc-5601-role-access-verify
  step $id 840 --plan 'Start the app' 'Sign in as each role' 'Check each page' 'Write the report'
  step $id 840 1 4 'Start the app'
  step $id 600 2 4 'Sign in as each role'
  step $id 240 3 4 'Check each page'
  step $id 500 --scenario pass 'viewer cannot open admin'
  step $id 300 --scenario pass 'editor can save'
  step $id 100 --scenario run 'admin can delete'
  printf 'model=claude-opus-5-5\n' > "$state/$id.meta"
  # PR ready: the verifier passed.
  id=arc-memo-dedupe
  step $id 20000 --plan 'Read the memo code' 'Write the dedupe' 'Run the tests'
  step $id 20000 1 3 'Read the memo code'
  step $id 15000 2 3 'Write the dedupe'
  step $id 12000 3 3 'Run the tests'
  status $id 2000 "done" 'PR https://github.com/acme/arc/pull/5622 checks green'
  id=arc-memo-dedupe-verify
  step $id 1900 --plan 'Start the app' 'Check the memo list' 'Write the report'
  step $id 1900 1 3 'Start the app'
  step $id 1500 2 3 'Check the memo list'
  step $id 1200 3 3 'Write the report'
  step $id 1300 --scenario pass 'one memo per save'
  step $id 1250 --scenario pass 'undo keeps one memo'
  # report ready.
  status arc-history-errors 600 "done" 'report saved'
  # report ready, then a second round: the scout saved a report, then recorded a
  # new 8-step plan, is on step 2, and says round 2 started.
  id=arc-round2-scout
  step $id 6000 --plan 'Read the code' 'Find the cause' 'Write the report'
  step $id 6000 1 3 'Read the code'
  step $id 5000 2 3 'Find the cause'
  step $id 4000 3 3 'Write the report'
  status $id 3500 "done" 'report saved'
  status $id 1000 working 'round 2 validation started'
  step $id 1000 --plan 'Start the app' 'Open the page' 'Sign in' 'Check the list' 'Check the form' 'Check errors' 'Compare rounds' 'Write round 2'
  step $id 900 1 8 'Start the app'
  step $id 300 2 8 'Open the page'
  # no reply.
  id=arc-5083-history
  step $id 7200 --plan 'Read the history code' 'Write the fix'
  step $id 7200 1 2 'Read the history code'
  step $id 5400 2 2 'Write the fix'
  status $id 5400 working 'writing the fix'

  local tasks='[]'
  add() {  # <json built with jq -n from the named args>
    tasks=$(printf '%s' "$tasks" | jq --argjson t "$1" '. + [$t]')
  }
  task() {  # <id> <kind> <spawn-ago> <state> <source> <detail> <endpoint> [jq-extra]
    local sid=$1 stepj
    stepj=$(fm_step_record_json "$state/$sid.step" "$now")
    jq -n --arg id "$sid" --arg kind "$2" --argjson spawn "$((now - $3))" \
      --arg st "$4" --arg src "$5" --arg detail "$6" --argjson ep "$7" \
      --argjson step "$stepj" --arg state "$state" --arg wt "$dir/wt/$sid" \
      --argjson now "$now" --arg data "$home/data" '
      {id: $id, kind: $kind, mode: "no-mistakes", branch: ("fm/" + $id),
       project: "/x/projects/arc", spawn_gen: ("s\($spawn).1.1"), backend: "herdr",
       paths: {meta: {path: ($state + "/" + $id + ".meta")},
               status_log: {path: ($state + "/" + $id + ".status"), last_event: null},
               worktree: {path: $wt, present: true},
               report: {path: ($data + "/" + $id + "/report.md"), present: false}},
       current_state: {state: $st, source: $src, detail: $detail},
       endpoint: {target: ("personal:" + $id), exists: $ep},
       pr: {url: null}, step: $step,
       hints: {pending_decision: false, open_decisions: []},
       backlog: {title: null, repo: "arc", body_lines: []}}' | jq "${8:-.}"
  }
  add "$(task arc-5680-upload-limit ship 120 working pane '' true '.backlog.title = "Raise the upload limit"')"
  add "$(task arc-5673-toolbar-spacing ship 1600 working pane '' true '.backlog.title = "Fix the toolbar spacing" | .paths.status_log.last_event = {state: "working", age_seconds: 1500}')"
  add "$(task arc-5677-editor-toolbar ship 1000 working pane '' true '.backlog.title = "Editor toolbar order" | .paths.status_log.last_event = {state: "working", age_seconds: 900}')"
  add "$(task arc-tokens-wave2 ship 3100 working status-log '' true '.backlog.title = "Design tokens, wave 2" | .hints.pending_decision = true | .hints.open_decisions = [{key: "tokens", verb: "decide", summary: "Rename the tokens in place, or keep the old names as aliases for one release?"}]')"
  add "$(task arc-5595-styles ship 5500 working run-step 'validating (running)' true '.backlog.title = "Style cleanup"')"
  add "$(task arc-5700-stopped-review ship 15100 unknown run-step 'run cancelled: no verdict' true '.backlog.title = "Stopped review" | .pr.url = "https://github.com/acme/arc/pull/5700"')"
  add "$(task arc-5601-role-access ship 9100 "done" status-log 'checks green: PR ready for review' true '.backlog.title = "Role access fix" | .pr.url = "https://github.com/acme/arc/pull/5601" | .backlog.body_lines = ["verifier: auth"]')"
  add "$(task arc-5601-role-access-verify scout 850 working pane '' true '.mode = "local-only" | .branch = null')"
  add "$(task arc-memo-dedupe ship 20100 "done" status-log 'checks green: PR ready for review' true '.backlog.title = "Memo dedupe" | .pr.url = "https://github.com/acme/arc/pull/5622" | .backlog.body_lines = ["verifier: data"]')"
  add "$(task arc-memo-dedupe-verify scout 1950 "done" status-log '' true '.mode = "local-only" | .branch = null')"
  add "$(task arc-history-errors scout 4000 "done" status-log '' true '.backlog.title = "Why history errors" | .paths.report.present = true | .hints.open_decisions = [{key: "a", verb: "decide", summary: "Keep the old API?"}, {key: "b", verb: "decide", summary: "Drop the cache?"}]')"
  add "$(task arc-round2-scout scout 6100 working pane '' true '.backlog.title = "Round 2 check" | .paths.report.present = true | .paths.status_log.last_event = {state: "working", age_seconds: 1000}')"
  add "$(task arc-5083-history ship 7300 working pane '' false '.backlog.title = "History list fix" | .paths.status_log.last_event = {state: "working", age_seconds: 5400}')"
  jq -n --argjson tasks "$tasks" '{tasks: $tasks, backlog: {records: [
    {state: "queued", captain_actionable: false}, {state: "queued", captain_actionable: false},
    {state: "done", captain_actionable: false, completion: {date: "2026-11-18"}}]}}' > "$dir/snapshot.json"
}
