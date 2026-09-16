#!/usr/bin/env bash
# Behavior tests for deterministic /next ranking and card rendering.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEXT="$ROOT/bin/fm-next.sh"
TMP_ROOT=$(fm_test_tmproot fm-next)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fixture="$TMP_ROOT/all-tiers.json"
cat > "$fixture" <<'JSON'
{
  "schema":"fm-fleet-snapshot.v1",
  "generated":"2026-09-16T12:00:00Z",
  "backlog":{"records":[
    {"structured":true,"id":"active-call","title":"Choose active route","state":"in_flight","kind":"ship","priority":"4","captain_actionable":true,"hold_reason":"Choose route A or B","hold_set":"2026-09-10T00:00:00Z","unresolved_blocker_ids":[],"body_excerpt":"A preserves compatibility; B removes the old endpoint.","repo":"alpha"},
    {"structured":true,"id":"delivery","title":"Finished delivery","state":"in_flight","kind":"ship","priority":"0","captain_actionable":false,"since":"2026-09-11","unresolved_blocker_ids":[],"repo":"alpha"},
    {"structured":true,"id":"blocked-call","title":"Clear blocked launch","state":"queued","kind":"ship","priority":"0","captain_actionable":true,"hold_reason":"Approve the production window","hold_set":"2026-09-09T00:00:00Z","unresolved_blocker_ids":[],"repo":"alpha"},
    {"structured":true,"id":"queued-choice","title":"Choose expensive migration","state":"queued","kind":"captain","priority":"0","captain_actionable":false,"hold_reason":null,"since":"2026-09-08","unresolved_blocker_ids":[],"repo":"alpha"},
    {"structured":true,"id":"closure","title":"Completed audit","state":"done","kind":"scout","priority":"0","captain_actionable":false,"reported":"2026-09-07","completion":{"verb":"reported","date":"2026-09-07"},"report_path":"data/closure/report.md","links":[],"unresolved_blocker_ids":[],"body_excerpt":"Audit accepted; retain the report.","repo":"alpha"}
  ]},
  "tasks":[
    {"id":"active-call","project":"alpha","mode":"no-mistakes","yolo":"off","current_state":{"state":"parked","detail":"Waiting for route choice"},"hints":{"open_decisions":[{"key":"route","verb":"needs-decision","summary":"Choose route A or B"}],"last_event_text":"working: old event"},"pr":{"url":null}},
    {"id":"delivery","project":"alpha","mode":"no-mistakes","yolo":"off","current_state":{"state":"done","detail":"checks green: PR ready for review"},"hints":{"open_decisions":[],"last_event_text":"working: stale"},"pr":{"url":"https://github.com/example/alpha/pull/7"}}
  ],
  "secondmate_current":{"records":[]}
}
JSON

run_json() { "$NEXT" --snapshot "$1" --json; }

mutate() { # <input> <output> <jq filter>
  jq "$3" "$1" > "$2"
}

test_each_ranking_tier() {
  local out two three four five
  out=$(run_json "$fixture")
  printf '%s' "$out" | jq -e '.selection.ref == "active-call" and .selection.tier == 1 and .selection.kind == "active_intervention"' >/dev/null \
    || fail "active captain intervention did not outrank every lower tier: $out"

  two="$TMP_ROOT/tier-two.json"
  mutate "$fixture" "$two" '.backlog.records |= map(select(.id != "active-call")) | .tasks |= map(select(.id != "active-call"))'
  out=$(run_json "$two")
  printf '%s' "$out" | jq -e '.selection.ref == "delivery" and .selection.tier == 2 and .selection.artifact == "https://github.com/example/alpha/pull/7"' >/dev/null \
    || fail "finished delivery did not rank second: $out"

  three="$TMP_ROOT/tier-three.json"
  mutate "$two" "$three" '.tasks |= map(if .id == "delivery" then .yolo = "on" else . end)'
  out=$(run_json "$three")
  printf '%s' "$out" | jq -e '.selection.ref == "blocked-call" and .selection.tier == 3' >/dev/null \
    || fail "blocked captain action did not rank third or autonomous landing was not excluded: $out"

  four="$TMP_ROOT/tier-four.json"
  mutate "$three" "$four" '.backlog.records |= map(if .id == "blocked-call" then .captain_actionable = false else . end)'
  out=$(run_json "$four")
  printf '%s' "$out" | jq -e '.selection.ref == "queued-choice" and .selection.tier == 4 and .selection.kind == "queued_judgment"' >/dev/null \
    || fail "queued judgment did not rank fourth: $out"

  five="$TMP_ROOT/tier-five.json"
  mutate "$four" "$five" '.backlog.records |= map(select(.id == "closure")) | .tasks = []'
  out=$(run_json "$five")
  printf '%s' "$out" | jq -e '.selection.ref == "closure" and .selection.tier == 5 and .selection.kind == "closure"' >/dev/null \
    || fail "Done closure did not remain a last-resort fallback: $out"
  pass "every ranking tier is ordered and closure is fallback-only"
}

test_priority_dependency_and_ties() {
  local input out
  input="$TMP_ROOT/order.json"
  jq -n '{
    schema:"fm-fleet-snapshot.v1",generated:"2026-09-16T12:00:00Z",
    backlog:{records:[
      {structured:true,id:"priority-first",title:"Priority first",state:"queued",kind:"ship",priority:"0",captain_actionable:true,hold_reason:"choose",hold_set:"2026-09-15",unresolved_blocker_ids:[]},
      {structured:true,id:"many-deps",title:"Many dependencies",state:"queued",kind:"ship",priority:"1",captain_actionable:true,hold_reason:"choose",hold_set:"2026-09-01",unresolved_blocker_ids:[]},
      {structured:true,id:"dep-a",title:"A",state:"queued",kind:"ship",priority:null,captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["many-deps"]},
      {structured:true,id:"dep-b",title:"B",state:"queued",kind:"ship",priority:null,captain_actionable:false,hold_reason:null,unresolved_blocker_ids:["many-deps"]}
    ]},tasks:[],secondmate_current:{records:[]}}
  ' > "$input"
  out=$(run_json "$input")
  printf '%s' "$out" | jq -e '.selection.ref == "priority-first"' >/dev/null \
    || fail "explicit priority must outrank dependency impact: $out"

  jq '(.backlog.records[] | select(.id == "many-deps").priority) = "0"' "$input" > "$TMP_ROOT/deps.json"
  out=$(run_json "$TMP_ROOT/deps.json")
  printf '%s' "$out" | jq -e '.selection.ref == "many-deps" and .selection.downstream_released == 2' >/dev/null \
    || fail "dependency release count did not break equal-priority tie: $out"

  jq '(.backlog.records[] | select(.id == "many-deps").id) = "z-last"
      | .backlog.records |= map(select(.id == "priority-first" or .id == "z-last"))
      | (.backlog.records[] | select(.id == "z-last").priority) = "0"
      | (.backlog.records[] | select(.id == "z-last").hold_set) = "2026-09-01"' "$input" > "$TMP_ROOT/oldest.json"
  out=$(run_json "$TMP_ROOT/oldest.json")
  printf '%s' "$out" | jq -e '.selection.ref == "z-last"' >/dev/null \
    || fail "oldest actionable wait did not break otherwise equal tie: $out"

  jq '(.backlog.records[] | select(.id == "priority-first").hold_set) = "2026-09-01"
      | (.backlog.records[] | select(.id == "many-deps").id) = "a-first"
      | .backlog.records |= map(select(.id == "priority-first" or .id == "a-first"))
      | (.backlog.records[] | select(.id == "a-first").priority) = "0"' "$input" > "$TMP_ROOT/id-tie.json"
  out=$(run_json "$TMP_ROOT/id-tie.json")
  printf '%s' "$out" | jq -e '.selection.ref == "a-first"' >/dev/null \
    || fail "canonical reference did not break complete tie deterministically: $out"
  pass "priority, dependency impact, oldest wait, and canonical reference order ties"
}

test_autonomous_actions_and_stale_events_are_excluded() {
  local input out
  input="$TMP_ROOT/autonomous.json"
  jq -n '{
    schema:"fm-fleet-snapshot.v1",generated:"2026-09-16T12:00:00Z",
    backlog:{records:[
      {structured:true,id:"ordinary-ready",title:"Ready",state:"queued",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[]},
      {structured:true,id:"recover-me",title:"Recover",state:"in_flight",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[]},
      {structured:true,id:"auto-land",title:"Auto land",state:"in_flight",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[]},
      {structured:true,id:"close-later",title:"Close later",state:"done",kind:"ship",priority:"0",captain_actionable:false,hold_reason:null,unresolved_blocker_ids:[],completion:{verb:"done",date:"2026-09-01"}}
    ]},
    tasks:[
      {id:"recover-me",mode:"no-mistakes",yolo:"off",current_state:{state:"failed",detail:"worker stopped"},hints:{open_decisions:[],last_event_text:"needs-decision: stale old text"},pr:{url:null}},
      {id:"auto-land",mode:"no-mistakes",yolo:"on",current_state:{state:"done",detail:"checks green"},hints:{open_decisions:[],last_event_text:"needs-decision: stale old text"},pr:{url:"https://github.com/example/repo/pull/8"}}
    ],secondmate_current:{records:[]}}
  ' > "$input"
  out=$(run_json "$input")
  printf '%s' "$out" | jq -e '.selection == null and .card == "Fleet needs no captain action." and .ranking.autonomous_forward_present == true and .ranking.closure_eligible == 1' >/dev/null \
    || fail "routine dispatch, recovery, autonomous landing, or stale events became captain work: $out"
  pass "autonomous work is excluded and stale status events never override current state"
}

test_closure_context_and_stable_card() {
  local input out card
  input="$TMP_ROOT/tier-five.json"
  out=$(run_json "$input")
  printf '%s' "$out" | jq -e '
    .selection.closure_context.accepted_scope_ended == true
    and (.selection.closure_context.open_defect_or_authorized_follow_up | contains("Durable task notes were checked"))
    and .selection.closure_context.durable_outcome == "data/closure/report.md"
    and (.selection.closure_context.knowledge_retained | contains("data/closure/report.md"))
    and (.selection.recommendation | contains("Close this task"))
    and (.selection.alternatives | contains("follow-up"))
    and .selection.actions == ["/task closure","/close closure","/history closure"]
  ' >/dev/null || fail "closure context, recommendation, alternatives, or commands are incomplete: $out"
  card=$($NEXT --snapshot "$input")
  [ "$card" = "$(printf '%s' "$out" | jq -r '.card')" ] \
    || fail "plain output must return the JSON card verbatim"
  assert_contains "$card" "What completed: data/closure/report.md" "closure card lacks durable outcome"
  assert_contains "$card" "Why it is not continuing:" "closure card lacks stop reason"
  assert_contains "$card" "Recommendation:" "card lacks recommendation"
  assert_contains "$card" "Alternatives:" "card lacks alternatives"
  assert_contains "$card" "Actions:" "card lacks exact actions"
  pass "completion context and stable card include every required decision field"
}

test_callsign_ref_and_name() {
  local out
  out=$(FM_NEXT_CALLSIGNS_JSON='[{"id":"active-call","ref":"t7","name":"active-route-choice"}]' run_json "$fixture")
  printf '%s' "$out" | jq -e '
    .selection.ref == "t7"
      and .selection.canonical_id == "active-call"
      and .selection.name == "active-route-choice"
      and .selection.actions[0] == "/task t7"
      and .ranking.order[-2:] == ["callsign","canonical_id"]
  ' >/dev/null || fail "callsign and human name were not composed into the selected card: $out"
  pass "selected cards use the central short reference and human name when available"
}

test_live_closure_composes_detail_and_closure_owners() {
  local home fakebin out
  home="$TMP_ROOT/live-closure"
  fakebin="$home/fakebin"
  mkdir -p "$home/data/done-one" "$home/state" "$home/config" "$home/projects" "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] follow-one - Authorized follow-up blocked-by: done-one blocked-by: missing-work (repo: sample) (kind: ship) (since 2026-09-15)

## Done
- [x] done-one - Finished report data/done-one/report.md (repo: sample) (kind: scout) (priority: 1) (reported 2026-09-14)
  Findings retained here.
EOF
  printf '# Findings\n' > "$home/data/done-one/report.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$NEXT" --json) \
    || fail "live closure composition failed"
  printf '%s' "$out" | jq -e '
    .selection.kind == "closure"
      and .selection.task_detail.schema == "fm-task-detail.v1"
      and .selection.closure_review.result == "Report completed at data/done-one/report.md"
      and .selection.closure_review.follow_ups == ["follow-one"]
      and (.selection.closure_review.retained | index("data/closed-tasks/done-one/report.md") != null)
      and (.selection.closure_context.open_defect_or_authorized_follow_up | contains("follow-one"))
      and (.selection.recommendation | contains("already-authorized follow-up"))
  ' >/dev/null || fail "live closure omitted task detail, outcome, retention, or follow-up context: $out"
  awk '/^## Queued/{print; skip=1; next} /^## Done/{skip=0} !skip{print}' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$NEXT" --json) \
    || fail "live closure without a follow-up failed"
  printf '%s' "$out" | jq -e '
    .selection.closure_review.follow_ups == []
      and (.selection.closure_context.open_defect_or_authorized_follow_up | contains("closure owner found no existing follow-up"))
      and (.selection.recommendation | contains("rather than inventing follow-up work"))
  ' >/dev/null || fail "absence of follow-up was claimed without the closure owner result: $out"
  pass "live closure composes task detail and the read-only closure owner"
}

test_secondmate_canonical_ref() {
  local input out
  input="$TMP_ROOT/secondmate.json"
  jq -n '{schema:"fm-fleet-snapshot.v1",generated:"2026-09-16T12:00:00Z",backlog:{records:[]},tasks:[],
    secondmate_current:{records:[{
      id:"domain",provenance:{selected:"structured-home"},
      active_children:[{id:"ship-a",state:"working"}],
      decisions_open:[{id:"ship-a",verb:"needs-decision",summary:"Choose the API"}],
      queued:[{id:"ship-a",title:"API delivery",priority:"1",since:"2026-09-01",repo:"api",kind:"ship",captain_actionable:true,hold_reason:"Choose the API",unresolved_blocker_ids:[]}],landed:[]
    }]}}
  ' > "$input"
  out=$(run_json "$input")
  printf '%s' "$out" | jq -e '.selection.ref == "domain/ship-a" and .selection.owner == "domain" and .selection.active == true' >/dev/null \
    || fail "secondmate action did not retain owner-qualified canonical reference: $out"
  pass "secondmate action uses an owner-qualified deterministic reference"
}

test_each_ranking_tier
test_priority_dependency_and_ties
test_autonomous_actions_and_stale_events_are_excluded
test_closure_context_and_stable_card
test_callsign_ref_and_name
test_live_closure_composes_detail_and_closure_owners
test_secondmate_canonical_ref

echo "fm-next tests passed"
