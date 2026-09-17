#!/usr/bin/env bash
# Behavior tests for deterministic /next choice, preparation packets, and terse handoffs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEXT="$ROOT/bin/fm-next.sh"
TMP_ROOT=$(fm_test_tmproot fm-next)
LIFECYCLE_DATA="$TMP_ROOT/lifecycle-data"
mkdir -p "$LIFECYCLE_DATA/task-lifecycle"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

write_lifecycle() {  # <id> <stage> <route> <delivery-complete|null> <monitoring-complete|null>
  local id=$1 stage=$2 route=$3 delivery=$4 monitoring=$5
  jq -n --arg id "$id" --arg stage "$stage" --arg route "$route" \
    --arg delivery "$delivery" --arg monitoring "$monitoring" '
    {version:1,id:$id,stage:$stage,updatedAt:"2026-09-16T12:00:00Z",
     review:{startedAt:"2026-09-15T10:00:00Z",completedAt:"2026-09-15T11:00:00Z"},
     acceptance:{actor:"reviewer",at:"2026-09-15T11:00:00Z",evidence:"recorded checks passed",limitations:"none declared",route:$route},
     delivery:(if $route == "close" then null else {startedAt:"2026-09-15T12:00:00Z",completedAt:(if $delivery == "null" then null else $delivery end),evidence:(if $delivery == "null" then null else "delivered" end)} end),
     monitoring:(if $stage == "monitoring" then {startedAt:"2026-09-15T13:00:00Z",completedAt:(if $monitoring == "null" then null else $monitoring end),evidence:(if $monitoring == "null" then null else "healthy" end)} else null end),
     correction:null}' > "$LIFECYCLE_DATA/task-lifecycle/$id.json"
}

write_lifecycle closure accepted close null null
write_lifecycle delivery accepted deliver null null
write_lifecycle monitor monitoring deliver-monitor 2026-09-15T12:30:00Z null

run_json() {  # <snapshot> [mode]
  local snapshot=$1
  shift
  FM_DATA_OVERRIDE="$LIFECYCLE_DATA" "$NEXT" --snapshot "$snapshot" --json "$@"
}

run_card() {  # <snapshot> [mode]
  local snapshot=$1
  shift
  FM_DATA_OVERRIDE="$LIFECYCLE_DATA" "$NEXT" --snapshot "$snapshot" "$@"
}

base_snapshot() {
  jq -n '{schema:"fm-fleet-snapshot.v1",generated:"2026-09-16T12:00:00Z",backlog:{records:[]},tasks:[],secondmate_current:{records:[]}}'
}

assert_five_second_card() {  # <card> <label>
  local card=$1 label=$2 nonempty context sentences
  nonempty=$(printf '%s\n' "$card" | awk 'NF {n++} END {print n + 0}')
  [ "$nonempty" -le 5 ] || fail "$label has more than five non-empty lines: $card"
  context=$(printf '%s\n' "$card" | awk 'NF {n++; if (n == 3) print}')
  [ "${#context}" -le 320 ] || fail "$label context is not five-second readable"
  sentences=$(printf '%s\n' "$context" | awk '{print gsub(/[.!?]+([[:space:]]|$)/, "&")}')
  [ "$sentences" -le 2 ] || fail "$label context exceeds two short sentences"
  assert_not_contains "$card" "WHY THIS" "$label exposed selection diagnostics"
  assert_not_contains "$card" "POSSIBLE OUTCOMES" "$label exposed outcome taxonomy"
  assert_not_contains "$card" "OTHER WORTHWHILE ACTIONS" "$label exposed alternatives"
  assert_not_contains "$card" "DO THIS" "$label added an empty workflow heading"
  assert_not_contains "$card" "DONE WHEN" "$label added lifecycle framing"
  assert_not_contains "$card" "Next lifecycle action" "$label exposed lifecycle language"
}

test_choose_is_deterministic_and_diagnostics_are_opt_in() {
  local input normal why debug why_card
  input="$TMP_ROOT/ranking.json"
  base_snapshot | jq '.backlog.records = [
    {structured:true,id:"restart",title:"Choose active route",state:"in_flight",kind:"ship",priority:"3",captain_actionable:true,hold_reason:"Choose route A or B",hold_set:"2026-09-10",unresolved_blocker_ids:[]},
    {structured:true,id:"review",title:"Verify launcher",state:"done",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,completion:{verb:"done",date:"2026-09-11"},unresolved_blocker_ids:[],captain_intent:"Verify the launcher behavior."},
    {structured:true,id:"release",title:"Approve release window",state:"queued",kind:"ship",priority:"0",captain_actionable:true,hold_reason:"Approve Tuesday release",hold_set:"2026-09-09",unresolved_blocker_ids:[]},
    {structured:true,id:"dependent",title:"Publish release",state:"queued",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["release"]}
  ]' > "$input"

  normal=$(run_json "$input")
  printf '%s\n' "$normal" | jq -e '
    .schema == "fm-next.v4"
    and .mode == "normal"
    and .selection.canonicalId == "restart"
    and .selection.actionTitle == "Choose route A or B"
    and .selection.preparation.schema == "fm-next-prepare.v1"
    and (has("diagnostics") | not)
    and (has("explanation") | not)
  ' >/dev/null || fail "normal selection leaked or lost diagnostics: $normal"
  assert_five_second_card "$(printf '%s\n' "$normal" | jq -r '.card')" "ranked normal handoff"

  why=$(run_json "$input" --why)
  printf '%s\n' "$why" | jq -e '
    .selection.canonicalId == "restart"
    and (.explanation.summary | contains("restarts work already under way"))
    and (.explanation.summary | contains("ranked ahead of 2 other eligible action(s)"))
    and [.explanation.alternatives[].ref] == ["review","release"]
    and (has("diagnostics") | not)
  ' >/dev/null || fail "--why changed selection or omitted its concise explanation: $why"
  why_card=$(run_card "$input" --why)
  assert_contains "$why_card" "Why this" "--why omitted its explicit explanation"
  assert_contains "$why_card" "Considered next: review · Verify launcher; release · Approve release window" "--why omitted bounded alternatives"

  debug=$(run_card "$input" --debug)
  printf '%s\n' "$debug" | jq -e '
    .mode == "debug"
    and .selection.canonicalId == "restart"
    and .diagnostics.ranking.eligible == 3
    and .diagnostics.ranking.order[0] == "captain_value_class"
    and [.diagnostics.candidates[].canonicalId] == ["restart","review","release"]
    and .diagnostics.candidates[0].lifecycle.status == "needs-you"
    and .diagnostics.candidates[1].lifecycle.status == "done"
    and (.selection | has("preparation") | not)
  ' >/dev/null || fail "--debug was not structured ranking/candidate/lifecycle output: $debug"
  pass "CHOOSE stays deterministic while normal, --why, and --debug separate presentation from diagnostics"
}

test_t5_prepared_handoff_golden() {
  local input out card expected long_intent
  input="$TMP_ROOT/t5.json"
  long_intent='Add a root-level Firstmate launcher and make the README instructions match its real behavior, including every original implementation requirement and every possible review outcome.'
  base_snapshot | jq --arg intent "$long_intent" '.backlog.records = [{
      structured:true,id:"launcher-review",title:"Firstmate launcher",state:"done",kind:"ship",priority:"0",
      captain_actionable:false,hold_reason:null,completion:{verb:"done",date:"2026-09-16"},unresolved_blocker_ids:[],
      captain_intent:$intent,firstmate_spec:"Preserve every internal lifecycle detail that normal output must not repeat.",
      completion_evidence:{summary:"The launcher implementation, executable tests, and README agree at revision abcdef1234567890",artifactType:"local branch",artifacts:["fm","tests/fm-launcher.test.sh","README.md"]},
      repository_state:{git:{branch:"fm/fm-firstmate-local-startup",trackedChanges:false}},
      review_plan:{source:"data/launcher-review/brief.md",
        review:{action:"Test the new fm launcher",context:"I already inspected the launcher implementation, executable tests, and README; they agree on the expected Firstmate extensions/context and argument forwarding.",
          checks:["From the Firstmate repository root, run `./fm --mode text`; confirm it opens with the expected Firstmate extensions and repository context."],
          success:"The launcher opens correctly.",failure:"The launcher fails or opens the wrong context.",continue:null,fix:null},
        delivery:null,monitoring:null}
    }]
    | .tasks = [{id:"launcher-review",project:"/srv/firstmate",mode:"local-only",yolo:"off",
        paths:{worktree:{path:"/srv/firstmate-task",present:true},report:{path:null,present:false}},
        current_state:{state:"done",detail:"ready in branch fm/fm-firstmate-local-startup"},hints:{open_decisions:[]},pr:{url:null}}]' > "$input"
  out=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"launcher-review","ref":"t5","name":"root-level-fm"}]' run_json "$input")
  card=$(printf '%s\n' "$out" | jq -r '.card')
  expected=$(cat <<'EOF'
Test the new fm launcher
t5 · root-level-fm

I already inspected the launcher implementation, executable tests, and README; they agree on the expected Firstmate extensions/context and argument forwarding.

From the Firstmate repository root, run `./fm --mode text`; confirm it opens with the expected Firstmate extensions and repository context.

Reply `works`, or send the observed failure.
EOF
)
  [ "$card" = "$expected" ] || fail "t5 normal handoff changed from the hard golden:$'\n'$card"
  printf '%s\n' "$out" | jq -e '
    .selection.preparation.intent.captainIntent != null
    and .selection.preparation.plan.action == "Test the new fm launcher"
    and .selection.preparation.lifecycle.status == "done"
    and .selection.preparation.artifacts.locations == ["README.md","fm","tests/fm-launcher.test.sh"]
    and .selection.preparation.repository.projectPath == "/srv/firstmate"
    and .selection.preparation.repository.worktreePath == "/srv/firstmate-task"
    and .selection.preparation.repository.git.trackedChanges == false
    and (.selection.preparation.existingResult.summary | contains("implementation, executable tests, and README agree"))
  ' >/dev/null || fail "t5 preparation packet omitted intent, plan, lifecycle, artifacts, repository, or result: $out"
  assert_five_second_card "$card" "t5 golden handoff"
  assert_not_contains "$card" "$long_intent" "t5 repeated the raw specification"
  assert_not_contains "$card" "abcdef1234567890" "t5 exposed a raw revision"
  assert_not_contains "$card" "selected delivery path" "t5 exposed delivery mechanics"
  assert_not_contains "$card" "/task t5" "t5 sent the captain to another task record"
  assert_not_contains "$card" "accept" "t5 led with a possible outcome"
  assert_not_contains "$card" "rank" "t5 exposed ranking"
  pass "t5 is a prepared five-second launcher check, not a task-record summary"
}

test_decision_and_credential_handoffs() {
  local decision credential card
  decision="$TMP_ROOT/decision.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"color",title:"Production color",state:"in_flight",kind:"ship",priority:"0",
    captain_actionable:true,hold_reason:"Choose `blue` or `green` for production",hold_set:"2026-09-10",unresolved_blocker_ids:[],
    completion_evidence:{summary:"I compared compatibility and rollback cost; I recommend `blue` because it preserves the current clients.",artifactType:"decision evidence",artifacts:[]}
  }]' > "$decision"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"color","ref":"t2","name":"production-color"}]' run_card "$decision")
  assert_contains "$card" "Choose \`blue\` or \`green\` for production" "decision was not reduced to the exact choice"
  assert_contains "$card" "I recommend \`blue\`" "decision omitted Firstmate's recommendation"
  assert_contains "$card" "t2 · production-color" "decision omitted meaningful identity"
  assert_five_second_card "$card" "decision handoff"

  credential="$TMP_ROOT/credential.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"login",title:"GitHub publishing",state:"in_flight",kind:"ship",priority:"0",
    captain_actionable:true,hold_reason:"GitHub login is required in the publishing terminal",hold_set:"2026-09-10",unresolved_blocker_ids:[]
  }]' > "$credential"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"login","ref":"t3","name":"github-publishing"}]' run_card "$credential")
  assert_contains "$card" "Complete the login for github-publishing" "credential title was vague"
  assert_contains "$card" "GitHub login is required in the publishing terminal" "credential omitted its exact location"
  assert_contains "$card" "Do not paste a secret into chat" "credential handoff did not protect the secret"
  assert_contains "$card" "Reply \`ready\` when access works" "credential handoff lacked one simple response"
  assert_five_second_card "$card" "credential handoff"
  pass "decisions and credentials reduce to one concrete captain action"
}

test_visual_delivery_and_monitoring_handoffs() {
  local visual delivery monitoring card
  visual="$TMP_ROOT/visual.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"visual",title:"Settings layout",state:"done",kind:"ship",priority:"0",unresolved_blocker_ids:[],
    completion_evidence:{summary:"The responsive layout checks pass.",artifactType:"visual review",artifacts:["http://127.0.0.1:4173/settings"]},
    review_plan:{review:{action:"Check the settings layout at phone width",context:"I ran the layout tests and opened the prepared review surface; only the visual judgment remains.",checks:["Open http://127.0.0.1:4173/settings and check that the Save button stays visible at 390 px."],success:null,failure:null,continue:null,fix:null},delivery:null,monitoring:null}
  }]' > "$visual"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"visual","ref":"t4","name":"settings-layout"}]' run_card "$visual")
  assert_contains "$card" "http://127.0.0.1:4173/settings" "visual handoff omitted its exact access point"
  assert_contains "$card" "390 px" "visual handoff omitted the prepared physical check"
  assert_contains "$card" "Reply \`looks good\`" "visual handoff lacked its simple response"
  assert_five_second_card "$card" "visual handoff"

  delivery="$TMP_ROOT/delivery.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"delivery",title:"Ship accepted change",state:"done",kind:"ship",priority:"0",unresolved_blocker_ids:[],pr_url:"https://example.test/pull/7",
    completion_evidence:{summary:"Review passed and the pull request is green.",artifactType:"pull request",artifacts:["https://example.test/pull/7"]},
    review_plan:{review:null,delivery:{action:"Approve landing the accepted pull request",context:"I checked the accepted result and current green checks; only landing approval remains.",checks:["Approve or decline https://example.test/pull/7."],success:null,failure:null,continue:null,fix:null},monitoring:null}
  }]
  | .tasks = [{id:"delivery",mode:"no-mistakes",yolo:"off",current_state:{state:"done",detail:"accepted"},hints:{},pr:{url:"https://example.test/pull/7"}}]' > "$delivery"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"delivery","ref":"t6","name":"accepted-pr"}]' run_card "$delivery")
  assert_contains "$card" "https://example.test/pull/7" "delivery approval omitted the exact result"
  assert_contains "$card" "Reply \`approve\` or \`decline: <reason>\`" "delivery approval lacked one explicit response"
  assert_five_second_card "$card" "delivery handoff"

  monitoring="$TMP_ROOT/monitoring.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"monitor",title:"Observe production release",state:"done",kind:"ship",priority:"0",unresolved_blocker_ids:[],
    review_plan:{review:null,delivery:null,monitoring:{action:"Check production request errors",context:"I checked deployment completion and the baseline; only the live 30-minute reading remains.",checks:["At https://status.example.test/errors, confirm the error rate stays below 1% through 12:30 UTC."],success:null,failure:null,continue:null,fix:null}}
  }]' > "$monitoring"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"monitor","ref":"t7","name":"request-errors"}]' run_card "$monitoring")
  assert_contains "$card" "https://status.example.test/errors" "monitoring omitted the exact check location"
  assert_contains "$card" "below 1% through 12:30 UTC" "monitoring omitted the observable condition"
  assert_contains "$card" "Reply \`healthy\`" "monitoring lacked one simple response"
  assert_five_second_card "$card" "monitoring handoff"
  pass "visual review, delivery approval, and monitoring expose only their prepared final action"
}

test_closure_preflight_and_missing_evidence() {
  local closure missing card out
  rm -f "$LIFECYCLE_DATA/task-lifecycle/delivery.json" "$LIFECYCLE_DATA/task-lifecycle/monitor.json"
  closure="$TMP_ROOT/closure.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"closure",title:"Completed audit",state:"done",kind:"scout",priority:"0",unresolved_blocker_ids:[],report_path:"data/closure/report.md",
    closure_review:{result:"The audit report is retained at data/closed-tasks/closure/report.md",retained:["data/closed-tasks/closure/report.md"],follow_ups:[],cleanup:"Cleanup is safe"}
  }]' > "$closure"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"closure","ref":"t8","name":"completed-audit"}]' run_card "$closure")
  assert_contains "$card" "Authorize closing completed-audit" "closure title did not ask for the remaining authorization"
  assert_contains "$card" "preflighted retention and cleanup" "closure omitted its completed preflight"
  assert_contains "$card" "Cleanup is safe" "closure omitted cleanup safety"
  assert_contains "$card" "Reply \`close\` to authorize cleanup" "closure asked for more than authorization"
  assert_not_contains "$card" "Run /close" "closure delegated its own preflight to another command"
  assert_five_second_card "$card" "closure handoff"

  missing="$TMP_ROOT/missing.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"thin-result",title:"Thin result",state:"done",kind:"scout",priority:"0",unresolved_blocker_ids:[],
    captain_intent:"Determine whether retries preserve request ordering."
  }]' > "$missing"
  out=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"thin-result","ref":"t9","name":"retry-order"}]' run_json "$missing")
  card=$(printf '%s\n' "$out" | jq -r '.card')
  printf '%s\n' "$out" | jq -e '
    .selection.preparation.missingEvidence == ["task-specific review plan","readable result location"]
  ' >/dev/null || fail "missing evidence was not explicit in the preparation packet: $out"
  assert_contains "$card" "Locate the result for retry-order" "missing evidence invented a review"
  assert_contains "$card" "Send the result location or result needed to check" "missing evidence did not ask for the smallest useful input"
  assert_contains "$card" "retries preserve request ordering" "missing evidence lost the precise uncertainty"
  assert_not_contains "$card" "open the recorded result" "missing evidence used the prohibited vague instruction"
  assert_five_second_card "$card" "missing-evidence handoff"
  pass "closure is preflighted and absent evidence produces one precise request"
}

test_obsolete_preparation_reranks_once() {
  local before after first second card
  before="$TMP_ROOT/obsolete-before.json"
  after="$TMP_ROOT/obsolete-after.json"
  base_snapshot | jq '.backlog.records = [
    {structured:true,id:"obsolete",title:"Old decision",state:"in_flight",kind:"ship",priority:"0",captain_actionable:true,hold_reason:"Choose the retired endpoint",hold_set:"2026-09-01",unresolved_blocker_ids:[]},
    {structured:true,id:"fresh",title:"Fresh review",state:"done",kind:"ship",priority:"1",unresolved_blocker_ids:[],completion_evidence:{summary:"The fresh result is ready.",artifactType:"report",artifacts:["data/fresh/report.md"]},review_plan:{review:{action:"Check the fresh retry result",context:"I inspected the report; only the timeout behavior remains.",checks:["Run `make retry-smoke` and confirm it exits 0."],success:null,failure:null,continue:null,fix:null},delivery:null,monitoring:null}}
  ]' > "$before"
  jq '(.backlog.records[] | select(.id == "obsolete")) |= (.state="queued" | .captain_actionable=false | .hold_reason=null)' "$before" > "$after"

  first=$(run_json "$before")
  second=$(run_json "$after")
  printf '%s\n' "$first" | jq -e '.selection.canonicalId == "obsolete"' >/dev/null \
    || fail "fixture did not initially select the action preparation made obsolete"
  printf '%s\n' "$second" | jq -e '.selection.canonicalId == "fresh"' >/dev/null \
    || fail "one fresh deterministic rerun did not select the next eligible action"
  card=$(printf '%s\n' "$second" | jq -r '.card')
  assert_not_contains "$card" "retired endpoint" "fresh rerun handed off stale work"
  assert_contains "$card" "\`make retry-smoke\`" "fresh rerun omitted the newly selected action"
  assert_five_second_card "$card" "obsolete-action rerank"
  pass "an action proven obsolete during preparation is replaced by one fresh deterministic selection"
}

test_live_preparation_reads_result_and_repository_state() {
  local home fakebin project worktree out busy_gen
  home="$TMP_ROOT/live-home"
  fakebin="$home/fakebin"
  project="$home/projects/sample"
  worktree="$home/projects/prepared-copy"
  mkdir -p "$home/data/prepared" "$home/state" "$home/config" "$home/projects" "$fakebin"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n' ;;
  list-windows) printf 'fm-prepared\n' ;;
esac
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/no-mistakes"

  git init -q -b main "$project"
  git -C "$project" config user.name fixture
  git -C "$project" config user.email fixture@example.test
  printf 'base\n' > "$project/sample.txt"
  git -C "$project" add sample.txt
  git -C "$project" commit -qm base
  git -C "$project" worktree add -q -b fm/prepared "$worktree"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] prepared - Prepared report data/prepared/report.md (repo: sample) (kind: scout) (reported 2026-09-16)
EOF
  cat > "$home/state/prepared.meta" <<EOF
window=firstmate:fm-prepared
endpoint_task_id=prepared
worktree=$worktree
project=$project
harness=claude
kind=scout
mode=local-only
yolo=off
spawn_gen=s100.prepared
started_at=2026-09-15T10:00:00Z
EOF
  cat > "$home/data/prepared/brief.md" <<'EOF'
## Captain's intent
Confirm the prepared report's finding.

## Firstmate spec
Keep the handoff narrow.

## Captain review plan
Review Action: Confirm the prepared report
Review Context: The report is ready for a focused check.
Review Check: Confirm the report says RESULT_FROM_REPORT.
EOF
  printf '# Result\nRESULT_FROM_REPORT\n' > "$home/data/prepared/report.md"
  printf 'done: report ready\n' > "$home/state/prepared.status"
  busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" prepared)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" prepared idle --gen "$busy_gen" \
    --source claude-hook --event stop

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$NEXT" --json) \
    || fail "live preparation packet failed"
  printf '%s\n' "$out" | jq -e --arg project "$project" --arg worktree "$worktree" '
    .selection.canonicalId == "prepared"
    and .selection.preparation.repository.projectPath == $project
    and .selection.preparation.repository.worktreePath == $worktree
    and .selection.preparation.repository.git.branch == "fm/prepared"
    and .selection.preparation.repository.git.trackedChanges == false
    and (.selection.preparation.existingResult.contentExcerpt | contains("RESULT_FROM_REPORT"))
    and (.selection.preparation.artifacts.locations | index("data/prepared/report.md") != null)
  ' >/dev/null || fail "live preparation omitted the bounded result or repository evidence: $out"
  assert_five_second_card "$(printf '%s\n' "$out" | jq -r '.card')" "live preparation handoff"
  pass "live PREPARE input includes a bounded existing result and current repository state"
}

test_no_action_and_option_validation() {
  local empty autonomous card out rc=0
  empty="$TMP_ROOT/empty.json"
  base_snapshot > "$empty"
  card=$(run_card "$empty")
  [ "$card" = "Nothing needs your attention right now." ] || fail "empty fleet invented work: $card"
  assert_five_second_card "$card" "empty fleet"

  autonomous="$TMP_ROOT/autonomous.json"
  base_snapshot | jq '.backlog.records = [{structured:true,id:"ordinary",title:"Ready autonomous work",state:"queued",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[]}]' > "$autonomous"
  out=$(run_json "$autonomous")
  printf '%s\n' "$out" | jq -e '.selection == null and .card == "Nothing needs your attention right now."' >/dev/null \
    || fail "autonomous work became a captain action: $out"
  assert_five_second_card "$(printf '%s\n' "$out" | jq -r '.card')" "autonomous fleet"

  run_card "$empty" --why --debug >"$TMP_ROOT/conflict.out" 2>"$TMP_ROOT/conflict.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "conflicting diagnostic modes did not fail with usage status"
  assert_contains "$(cat "$TMP_ROOT/conflict.err")" "mutually exclusive" "conflicting diagnostic modes lacked a precise error"
  pass "empty and autonomous fleets stay quiet and command modes parse strictly"
}

test_choose_is_deterministic_and_diagnostics_are_opt_in
test_t5_prepared_handoff_golden
test_decision_and_credential_handoffs
test_visual_delivery_and_monitoring_handoffs
test_closure_preflight_and_missing_evidence
test_obsolete_preparation_reranks_once
test_live_preparation_reads_result_and_repository_state
test_no_action_and_option_validation

echo "fm-next tests passed"
