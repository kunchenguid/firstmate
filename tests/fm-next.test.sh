#!/usr/bin/env bash
# Behavior tests for deterministic /next ranking and evidence-bound action cards.
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

run_json() { FM_DATA_OVERRIDE="$LIFECYCLE_DATA" "$NEXT" --snapshot "$1" --json; }
run_card() { FM_DATA_OVERRIDE="$LIFECYCLE_DATA" "$NEXT" --snapshot "$1"; }

base_snapshot() {
  jq -n '{schema:"fm-fleet-snapshot.v1",generated:"2026-09-16T12:00:00Z",backlog:{records:[]},tasks:[],secondmate_current:{records:[]}}'
}

test_ranking_and_genuine_alternatives() {
  local input out card
  input="$TMP_ROOT/ranking.json"
  base_snapshot | jq '.backlog.records = [
    {structured:true,id:"restart",title:"Choose active route",state:"in_flight",kind:"ship",priority:"3",captain_actionable:true,hold_reason:"Choose route A or B",hold_set:"2026-09-10",unresolved_blocker_ids:[]},
    {structured:true,id:"review",title:"Verify launcher",state:"done",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,completion:{verb:"done",date:"2026-09-11"},unresolved_blocker_ids:[],captain_intent:"Verify the launcher behavior."},
    {structured:true,id:"release",title:"Approve release window",state:"queued",kind:"ship",priority:"0",captain_actionable:true,hold_reason:"Approve Tuesday release",hold_set:"2026-09-09",unresolved_blocker_ids:[]},
    {structured:true,id:"dependent",title:"Publish release",state:"queued",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["release"]}
  ]' > "$input"
  out=$(run_json "$input")
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-next.v3"
    and .selection.ref == "restart"
    and .selection.class == "restart"
    and .selection.action == "Choose route A or B"
    and (.selection.why | contains("restarts work already under way"))
    and (.selection.why | contains("outranks 2 other action(s)"))
    and (.alternatives | length) == 2
    and .alternatives[0].ref == "review"
    and .alternatives[1].ref == "release"
    and .ranking.order[0] == "captain_value_class"
  ' >/dev/null || fail "ranking or alternatives were not deterministic: $out"
  card=$(run_card "$input")
  assert_contains "$card" "OTHER WORTHWHILE ACTIONS" "ranked alternatives were omitted"
  assert_contains "$card" "1. review - Inspect the candidate result for Verify launcher" "first alternative is not the next ranked action"
  assert_contains "$card" "2. release - Approve or decline Tuesday release" "second alternative is not the next ranked action"
  pass "fleet-wide ranking selects one action and at most two genuine alternatives"
}

test_priority_and_dependency_ties() {
  local input out
  input="$TMP_ROOT/ties.json"
  base_snapshot | jq '.backlog.records = [
    {structured:true,id:"priority-first",title:"Priority first",state:"queued",kind:"ship",priority:"0",captain_actionable:true,hold_reason:"Choose the rollout",hold_set:"2026-09-15",unresolved_blocker_ids:[]},
    {structured:true,id:"many-deps",title:"Many dependencies",state:"queued",kind:"ship",priority:"1",captain_actionable:true,hold_reason:"Choose the API",hold_set:"2026-09-01",unresolved_blocker_ids:[]},
    {structured:true,id:"dep-a",title:"A",state:"queued",kind:"ship",priority:null,captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["many-deps"]},
    {structured:true,id:"dep-b",title:"B",state:"queued",kind:"ship",priority:null,captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["many-deps"]}
  ]' > "$input"
  out=$(run_json "$input")
  printf '%s\n' "$out" | jq -e '.selection.ref == "many-deps" and .selection.downstream_released == 2' >/dev/null \
    || fail "dependency-release value class did not outrank an ordinary decision: $out"
  assert_contains "$(printf '%s\n' "$out" | jq -r '.selection.why')" "unlocks 2 dependent task(s)" "ranking explanation omitted the concrete unlock"

  jq '(.backlog.records[] | select(.id == "priority-first").unresolved_blocker_ids) = []
      | .backlog.records += [{structured:true,id:"priority-dep",title:"P",state:"queued",kind:"ship",unresolved_blocker_ids:["priority-first"]}]' "$input" > "$TMP_ROOT/ties-equal.json"
  out=$(run_json "$TMP_ROOT/ties-equal.json")
  printf '%s\n' "$out" | jq -e '.selection.ref == "priority-first"' >/dev/null \
    || fail "explicit priority did not break an equal value-class tie: $out"
  pass "value class, priority, and dependency release deterministically explain rank"
}

test_blocker_credential_and_approval_actions() {
  local kind reason expected input out
  while IFS='|' read -r kind reason expected; do
    input="$TMP_ROOT/action-$kind.json"
    base_snapshot | jq --arg reason "$reason" '.backlog.records = [
      {structured:true,id:"needs-action",title:"Production access",state:"in_flight",kind:"ship",priority:"0",captain_actionable:true,hold_reason:$reason,hold_set:"2026-09-10",unresolved_blocker_ids:[]}
    ]' > "$input"
    out=$(run_json "$input")
    assert_contains "$(printf '%s\n' "$out" | jq -r '.selection.action')" "$expected" "$kind action was not translated into concrete captain work"
    printf '%s\n' "$out" | jq -e '.selection.checks | length >= 2' >/dev/null \
      || fail "$kind action omitted concrete checks: $out"
    assert_not_contains "$(printf '%s\n' "$out" | jq -r '.card')" "Next lifecycle action" "$kind card exposed workflow jargon"
  done <<'EOF'
decision|Choose blue or green deployment|Choose blue or green deployment
credential|GitHub login is required|Provide the credential or login needed
approval|Approve the production window|Approve or decline
EOF
  pass "decisions, credentials, and approvals become concrete captain actions"
}

test_t5_golden_review_card() {
  local input out card header
  input="$TMP_ROOT/t5.json"
  base_snapshot | jq '.backlog.records = [{
      structured:true,id:"launcher-review",title:"Firstmate launcher",state:"done",kind:"ship",priority:"0",
      captain_actionable:false,hold_reason:null,completion:{verb:"done",date:"2026-09-16"},unresolved_blocker_ids:[],
      captain_intent:"Add a root-level Firstmate launcher and make the README instructions match its real behavior.",
      completion_evidence:{summary:"The root-level launcher and README update are complete at revision abcdef1234567890",artifactType:"local branch",artifacts:[]},
      review_plan:{source:"data/launcher-review/brief.md",
        review:{action:"Run the root-level Firstmate launcher and verify its documented behavior",context:"The launcher and README are complete.",
          checks:["From the repository root, run the Firstmate launcher.","Confirm it starts Firstmate in the intended repository context.","Verify the README instructions match what the launcher actually does."],
          success:"The launcher starts Firstmate in the intended context and the README matches reality.",
          failure:"The launcher starts in the wrong context or the README differs from observed behavior.",
          continue:"Repeat only the inconclusive check and record what remains unknown.",
          fix:"Name the first launcher or README mismatch as one concrete correction."},
        delivery:{action:null,context:null,checks:[],success:null,failure:null,continue:null,fix:null},
        monitoring:{action:null,context:null,checks:[],success:null,failure:null,continue:null,fix:null}}
    }]
    | .tasks = [{id:"launcher-review",project:"firstmate",mode:"local-only",yolo:"off",current_state:{state:"done",detail:"ready in branch fm/launcher-review"},hints:{open_decisions:[]},pr:{url:null}}]' > "$input"
  out=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"launcher-review","ref":"t5","name":"firstmate-launcher"}]' run_json "$input")
  card=$(printf '%s\n' "$out" | jq -r '.card')
  header=$(printf '%s\n' "$card" | head -1)
  [ "$header" = "NEXT — Run the root-level Firstmate launcher and verify its documented behavior" ] \
    || fail "t5 header is not a specific human action: $header"
  assert_contains "$card" "TASK t5 - firstmate-launcher" "t5 card omitted its meaningful task identity"
  assert_contains "$card" "1. From the repository root, run the Firstmate launcher." "t5 did not say where to run the launcher"
  assert_contains "$card" "2. Confirm it starts Firstmate in the intended repository context." "t5 did not check launch context"
  assert_contains "$card" "3. Verify the README instructions match what the launcher actually does." "t5 did not compare README with reality"
  assert_contains "$card" "SUCCESS: The launcher starts Firstmate in the intended context and the README matches reality." "t5 success outcome is not observable"
  assert_contains "$card" "FIX: Name the first launcher or README mismatch as one concrete correction." "t5 fix outcome is not concrete"
  assert_not_contains "$card" "abcdef1234567890" "card exposed a raw revision hash"
  assert_not_contains "$card" "local-only" "card exposed a delivery-mode label"
  assert_not_contains "$card" "Review the candidate artifact" "card retained the vague review instruction"
  assert_not_contains "$(printf '%s\n' "$card" | awk '/^POSSIBLE OUTCOMES/{exit} {print}')" "concrete correction" "a correction leaked into the selected action instead of outcomes"
  pass "t5 golden card asks for the launcher, context, and README checks with separate outcomes"
}

test_missing_evidence_requests_one_inspection() {
  local input out
  input="$TMP_ROOT/missing-evidence.json"
  base_snapshot | jq '.backlog.records = [{
    structured:true,id:"thin-result",title:"Thin result",state:"done",kind:"scout",priority:"0",captain_actionable:false,
    hold_reason:null,report_path:"data/thin-result/report.md",captain_intent:"Determine whether retries preserve request ordering.",unresolved_blocker_ids:[]
  }]' > "$input"
  out=$(run_json "$input")
  printf '%s\n' "$out" | jq -e '
    .selection.action == "Inspect the report for Thin result"
    and (.selection.checks | length) == 1
    and (.selection.checks[0] | contains("Open data/thin-result/report.md and answer one question"))
    and (.selection.checks[0] | contains("retries preserve request ordering"))
  ' >/dev/null || fail "missing evidence caused an invented checklist instead of one inspection: $out"
  pass "missing review evidence yields one concrete inspection and the question it answers"
}

test_delivery_decision_and_monitoring_checks() {
  local delivery_input monitoring_input out
  delivery_input="$TMP_ROOT/delivery.json"
  base_snapshot | jq '.backlog.records = [{
      structured:true,id:"delivery",title:"Ship accepted change",state:"done",kind:"ship",priority:"0",captain_actionable:false,unresolved_blocker_ids:[],pr_url:"https://example.test/pull/7",
      review_plan:{source:"data/delivery/brief.md",review:null,
        delivery:{action:"Approve or decline landing the accepted pull request",context:"Review passed.",checks:["Open https://example.test/pull/7 and confirm it is the accepted change.","Confirm the release window is still valid."],success:"Landing is explicitly approved.",failure:"Landing is declined with one concrete reason.",continue:null,fix:"Name the correction required before landing."},monitoring:null}
    }]
    | .tasks = [{id:"delivery",mode:"no-mistakes",yolo:"off",current_state:{state:"done",detail:"accepted"},hints:{},pr:{url:"https://example.test/pull/7"}}]' > "$delivery_input"
  out=$(run_json "$delivery_input")
  printf '%s\n' "$out" | jq -e '
    .selection.kind == "delivery"
    and .selection.action == "Approve or decline landing the accepted pull request"
    and .selection.checks[0] == "Open https://example.test/pull/7 and confirm it is the accepted change."
    and .selection.outcomes[0].label == "DELIVER"
    and .selection.outcomes[1].label == "FIX"
  ' >/dev/null || fail "delivery decision was rendered as workflow state: $out"

  monitoring_input="$TMP_ROOT/monitoring.json"
  base_snapshot | jq '.backlog.records = [{
      structured:true,id:"monitor",title:"Observe production release",state:"done",kind:"ship",priority:"0",captain_actionable:false,unresolved_blocker_ids:[],
      review_plan:{source:"data/monitor/brief.md",review:null,delivery:null,
        monitoring:{action:"Check the production release for request errors",context:"The release is live.",checks:["Open the production dashboard and inspect request errors for 30 minutes.","Compare the error rate with the pre-release baseline."],success:"The error rate stays at or below baseline for 30 minutes.",failure:"The error rate rises above baseline.",continue:"Continue for the rest of the 30-minute window.",fix:"Report the elevated error rate and begin the recorded rollback."}}
    }]' > "$monitoring_input"
  out=$(run_json "$monitoring_input")
  printf '%s\n' "$out" | jq -e '
    .selection.kind == "monitoring"
    and .selection.action == "Check the production release for request errors"
    and (.selection.checks | length) == 2
    and .selection.outcomes[0].label == "HEALTHY"
    and .selection.outcomes[1].label == "CONTINUE"
    and .selection.outcomes[2].label == "FIX"
  ' >/dev/null || fail "monitoring checks were not evidence-bound: $out"
  pass "delivery and monitoring cards ask for concrete decisions and checks"
}

test_closure_fallback_and_no_action_fleet() {
  local closure_input autonomous_input auto_delivery_input empty_input out card
  rm -f "$LIFECYCLE_DATA/task-lifecycle/delivery.json" "$LIFECYCLE_DATA/task-lifecycle/monitor.json"
  closure_input="$TMP_ROOT/closure.json"
  base_snapshot | jq '.backlog.records = [{structured:true,id:"closure",title:"Completed audit",state:"done",kind:"scout",priority:"0",captain_actionable:false,report_path:"data/closure/report.md",unresolved_blocker_ids:[]}]' > "$closure_input"
  out=$(run_json "$closure_input")
  printf '%s\n' "$out" | jq -e '
    .selection.kind == "closure"
    and .selection.action == "Close Completed audit"
    and .selection.checks == ["Run /task closure and confirm the recorded scope is complete.","Run /close closure."]
    and .selection.outcomes[0].label == "CLOSE"
  ' >/dev/null || fail "closure was not a last-resort concrete action: $out"
  card=$(run_card "$closure_input")
  [ "$card" = "$(printf '%s\n' "$out" | jq -r '.card')" ] || fail "plain card diverged from JSON card"

  autonomous_input="$TMP_ROOT/autonomous.json"
  jq '.backlog.records += [{structured:true,id:"ordinary-ready",title:"Ready autonomous work",state:"queued",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[]}]' "$closure_input" > "$autonomous_input"
  out=$(run_json "$autonomous_input")
  printf '%s\n' "$out" | jq -e '.selection == null and .ranking.autonomous_forward_present == true' >/dev/null \
    || fail "closure displaced autonomous forward work: $out"

  write_lifecycle auto-delivery accepted deliver null null
  auto_delivery_input="$TMP_ROOT/auto-delivery.json"
  base_snapshot | jq '.backlog.records = [{structured:true,id:"auto-delivery",title:"Automatic delivery",state:"done",kind:"ship",priority:"0",captain_actionable:false,unresolved_blocker_ids:[],review_plan:{source:"data/auto-delivery/brief.md",review:{action:"Review it",checks:["Check it"]},delivery:{action:null,context:null,checks:[],success:null,failure:null,continue:null,fix:null},monitoring:null}}]
    | .tasks = [{id:"auto-delivery",mode:"no-mistakes",yolo:"on",current_state:{state:"done",detail:"accepted"},hints:{},pr:{url:"https://example.test/pull/8"}}]' > "$auto_delivery_input"
  out=$(run_json "$auto_delivery_input")
  printf '%s\n' "$out" | jq -e '.selection == null and .ranking.forward_eligible == 0 and .ranking.autonomous_forward_present == true' >/dev/null \
    || fail "autonomous delivery became captain work because another review phase had guidance: $out"
  rm -f "$LIFECYCLE_DATA/task-lifecycle/auto-delivery.json"

  empty_input="$TMP_ROOT/empty.json"
  base_snapshot > "$empty_input"
  out=$(run_json "$empty_input")
  printf '%s\n' "$out" | jq -e '.selection == null and .card == "Fleet needs no captain action."' >/dev/null \
    || fail "empty fleet invented captain work: $out"
  [ "$(run_card "$empty_input")" = "Fleet needs no captain action." ] || fail "plain no-action response changed"
  pass "closure is last resort and autonomous or empty fleets invent no captain action"
}

test_cards_omit_workflow_engine_phrasing() {
  local input card phrase
  input="$TMP_ROOT/t5.json"
  card=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"launcher-review","ref":"t5","name":"firstmate-launcher"}]' run_card "$input")
  while IFS= read -r phrase; do
    assert_not_contains "$card" "$phrase" "card contains prohibited workflow-engine phrasing"
  done <<'EOF'
Next lifecycle action
Review the candidate artifact
Recommendation:
Consequence:
Alternatives:
delivery mode
standing_landing_authority
close_ready
EOF
  assert_contains "$card" "DO THIS" "card omitted the action checklist"
  assert_contains "$card" "DONE WHEN" "card omitted observable completion"
  assert_contains "$card" "WHY THIS" "card omitted ranking rationale"
  assert_contains "$card" "POSSIBLE OUTCOMES" "card omitted separated outcomes"
  pass "cards use chief-of-staff sections without workflow-engine phrasing"
}

test_ranking_and_genuine_alternatives
test_priority_and_dependency_ties
test_blocker_credential_and_approval_actions
test_t5_golden_review_card
test_missing_evidence_requests_one_inspection
test_delivery_decision_and_monitoring_checks
test_closure_fallback_and_no_action_fleet
test_cards_omit_workflow_engine_phrasing

echo "fm-next tests passed"
