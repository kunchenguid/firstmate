#!/usr/bin/env bash
# Behavior tests for deterministic /next ranking and card rendering.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEXT="$ROOT/bin/fm-next.sh"
TMP_ROOT=$(fm_test_tmproot fm-next)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
LIFECYCLE_DATA="$TMP_ROOT/lifecycle-data"
mkdir -p "$LIFECYCLE_DATA/task-lifecycle"
cat > "$LIFECYCLE_DATA/task-lifecycle/closure.json" <<'JSON'
{"version":1,"id":"closure","stage":"accepted","updatedAt":"2026-09-15T00:00:00Z","review":{"startedAt":"2026-09-14T00:00:00Z","completedAt":"2026-09-15T00:00:00Z"},"acceptance":{"actor":"reviewer","at":"2026-09-15T00:00:00Z","evidence":"report approved","limitations":"none declared","route":"close"},"delivery":null,"monitoring":null,"correction":null}
JSON

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

run_json() { FM_DATA_OVERRIDE="$LIFECYCLE_DATA" "$NEXT" --snapshot "$1" --json; }

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
  printf '%s' "$out" | jq -e '.selection.ref == "blocked-call" and .selection.tier == 2 and .selection.kind == "blocked_captain_action"' >/dev/null \
    || fail "inactive concrete captain action did not rank second: $out"

  three="$TMP_ROOT/tier-three.json"
  mutate "$two" "$three" '.backlog.records |= map(if .id == "blocked-call" then .captain_actionable = false else . end)'
  out=$(run_json "$three")
  printf '%s' "$out" | jq -e '.selection.ref == "queued-choice" and .selection.tier == 3 and .selection.kind == "queued_judgment"' >/dev/null \
    || fail "queued judgment did not rank third: $out"

  four="$TMP_ROOT/tier-four.json"
  mutate "$three" "$four" '.backlog.records |= map(select(.id != "queued-choice"))'
  out=$(run_json "$four")
  printf '%s' "$out" | jq -e '.selection.ref == "delivery" and .selection.tier == 4 and .selection.kind == "review" and .selection.status == "done"' >/dev/null \
    || fail "unreviewed candidate did not rank as forward review work: $out"

  five="$TMP_ROOT/tier-five.json"
  mutate "$four" "$five" '.backlog.records |= map(select(.id == "closure")) | .tasks = []'
  out=$(run_json "$five")
  printf '%s' "$out" | jq -e '.selection.ref == "closure" and .selection.tier == 5 and .selection.kind == "closure" and .selection.route == "close"' >/dev/null \
    || fail "accepted close route did not remain a last-resort fallback: $out"
  pass "captain actions, lifecycle progress, and closure use deterministic tiers"
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

test_done_requires_review_and_stale_events_are_excluded() {
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
  printf '%s' "$out" | jq -e '
    .selection.ref == "auto-land"
    and .selection.kind == "review"
    and .selection.status == "done"
    and .selection.close_ready == false
    and .ranking.autonomous_forward_present == true
    and .ranking.closure_eligible == 0
  ' >/dev/null || fail "worker completion inferred acceptance or stale events became captain actions: $out"
  pass "worker completion remains forward review work and stale events do not create acceptance"
}

test_closure_context_and_stable_card() {
  local input out card
  input="$TMP_ROOT/tier-five.json"
  out=$(run_json "$input")
  printf '%s' "$out" | jq -e '
    .selection.closure_context.accepted_scope_ended == true
    and .selection.closure_context.acceptance.actor == "reviewer"
    and .selection.closure_context.route == "close"
    and (.selection.closure_context.open_defect_or_authorized_follow_up | contains("Durable task notes remain available"))
    and .selection.closure_context.durable_outcome == "data/closure/report.md"
    and (.selection.closure_context.knowledge_retained | contains("data/closure/report.md"))
    and (.selection.recommendation | contains("Close this task"))
    and (.selection.alternatives | contains("follow-up"))
    and .selection.actions == ["/task closure","/close closure","/history closure"]
  ' >/dev/null || fail "closure context, recommendation, alternatives, or commands are incomplete: $out"
  card=$(FM_DATA_OVERRIDE="$LIFECYCLE_DATA" $NEXT --snapshot "$input")
  [ "$card" = "$(printf '%s' "$out" | jq -r '.card')" ] \
    || fail "plain output must return the JSON card verbatim"
  assert_contains "$card" "What completed: data/closure/report.md" "closure card lacks durable outcome"
  assert_contains "$card" "Acceptance: reviewer" "closure card lacks acceptance evidence"
  assert_contains "$card" "Route: close" "closure card lacks selected route"
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
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW=2026-09-15T10:00:00Z \
    "$ROOT/bin/fm-task-lifecycle.sh" review-start done-one >/dev/null || fail "live closure review did not start"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW=2026-09-15T10:01:00Z \
    "$ROOT/bin/fm-task-lifecycle.sh" accept done-one --actor reviewer --evidence "report accepted" --route close >/dev/null \
    || fail "live closure was not accepted"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$NEXT" --json) \
    || fail "live closure composition failed"
  printf '%s' "$out" | jq -e '
    .selection.kind == "closure"
      and .selection.task_detail.schema == "fm-task-detail.v2"
      and .selection.task_detail.acceptance.actor == "reviewer"
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
test_done_requires_review_and_stale_events_are_excluded
test_closure_context_and_stable_card
test_callsign_ref_and_name
test_live_closure_composes_detail_and_closure_owners
test_secondmate_canonical_ref

echo "fm-next tests passed"
