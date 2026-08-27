#!/usr/bin/env bash
# Behavior tests for the project dashboard aggregation and read-only board.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-project-dashboard-snapshot.sh"
BOARD="$ROOT/bin/fm-project-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  cat > "$home/data/projects.md" <<'EOF'
# Projects
- alpha [no-mistakes] - Alpha product (added 2020-01-01)
- bravo [direct-PR] - Bravo product (added 2020-01-01)
- beta [no-mistakes] - Beta product (added 2020-01-01)
- gamma [local-only] - Gamma product (added 2020-01-01)
- delta [no-mistakes +yolo] - Delta product (added 2020-01-01)
- epsilon [direct-PR]
- zeta
EOF
  printf '%s\n' "$home"
}

write_fleet_fixture() {  # <home>
  local home=$1 id
  for id in alpha-work alpha-call bravo-work beta-wait delta-mate; do
    : > "$home/state/$id.meta"
    : > "$home/state/$id.status"
  done
  jq -n --arg home "$home" '
    def paths($id): {
      meta:{path:($home + "/state/" + $id + ".meta"),present:true},
      status_log:{path:($home + "/state/" + $id + ".status"),present:true},
      worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}
    };
    def task($id;$repo;$state;$detail): {
      id:$id,kind:"ship",project:$repo,paths:paths($id),secondmate_projects:[],
      current_state:{state:$state,source:"fixture",detail:$detail},
      hints:{open_decisions:[]},pr:{url:null},backlog:{id:$id,repo:$repo,title:$id}
    };
    {
      schema:"fm-fleet-snapshot.v1",generated:"2026-08-26T00:00:00Z",fm_home:$home,
      backlog:{present:true,records:[
        {structured:true,id:"alpha-work",repo:"alpha",title:"Build alpha",state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]},
        {structured:true,id:"alpha-call",repo:"alpha",title:"Choose alpha route",state:"queued",since:"2020-01-01",captain_actionable:true,hold_reason:"Choose release route",unresolved_blocker_ids:[]},
        {structured:true,id:"alpha-landed",repo:"alpha",title:"Alpha shipped",state:"done",hold_kind:null,pr_url:"https://github.com/example/alpha/pull/7",completion:{date:"2026-08-20"}},
        {structured:true,id:"bravo-work",repo:"bravo",title:"Build bravo",state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]},
        {structured:true,id:"beta-wait",repo:"beta",title:"Wait for vendor",state:"queued",since:"2020-01-01",captain_actionable:false,hold_reason:"Vendor release pending",unresolved_blocker_ids:["vendor"]}
      ]},
      tasks:[
        task("alpha-work";"alpha";"working";"Implementing cards"),
        (task("alpha-call";"alpha";"parked";"Captain choice")
          | .hints.open_decisions=[{key:"route",verb:"needs-decision",summary:"Choose alpha route"}]),
        task("bravo-work";"bravo";"working";"Shipping bravo"),
        task("beta-wait";"beta";"paused";"Vendor release pending"),
        {id:"delta-mate",kind:"secondmate",project:"delta",paths:paths("delta-mate"),
         secondmate_projects:["delta"],current_state:{state:"working",source:"fixture",detail:""},
         hints:{open_decisions:[]},pr:{url:null},backlog:null}
      ],
      secondmate_current:{records:[{
        id:"delta-mate",home:($home + "/secondmates/delta"),remote:false,
        current:{state:"active_child_work",reason:null},
        active_children:[{id:"delta-child",title:"Delta rollout",repo:"delta",state:"working",doing:"Roll out Delta"}],
        decisions_open:[],holds:[],queued:[],
        landed:[{id:"delta-landed",title:"Delta landed",repo:"delta",completion:{date:"2026-08-21"},pr_url:"https://github.com/example/delta/pull/4",report_path:null}],
        counts:{active_children:1,decisions_open:0,holds:0,queued:0,landed:1,endpoints:1},
        endpoints:[],omitted:[]
      }]}
    }
  ' > "$home/fleet.json"
  cat > "$home/fake-fleet-snapshot" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FLEET_CALL_LOG"
cat "$FLEET_FIXTURE"
SH
  chmod +x "$home/fake-fleet-snapshot"
}

run_snapshot() {  # <home> <now-epoch> [args...]
  local home=$1 now_epoch=$2
  shift 2
  FLEET_FIXTURE="$home/fleet.json" FLEET_CALL_LOG="$home/fleet-calls.log" \
    FM_HOME="$home" FM_PROJECT_DASHBOARD_FLEET_SNAPSHOT="$home/fake-fleet-snapshot" \
    FM_PROJECT_DASHBOARD_NOW=2026-08-26T00:00:00Z FM_PROJECT_DASHBOARD_NOW_EPOCH="$now_epoch" \
    "$SNAPSHOT" --json "$@"
}

test_aggregation_status_precedence_and_secondmate_join() {
  local home epoch out
  home=$(make_home aggregation)
  write_fleet_fixture "$home"
  epoch=$(stat -f '%m' "$home/state/beta-wait.status" 2>/dev/null || stat -c '%Y' "$home/state/beta-wait.status")
  out=$(run_snapshot "$home" "$epoch") || fail "dashboard snapshot failed"
  printf '%s' "$out" | jq -e '
    .schema == "fm-project-dashboard.v1"
      and (.projects | map(.name)) == ["alpha","bravo","beta","gamma","delta","epsilon","zeta"]
      and .summary.total == 7
      and (.projects[] | select(.name == "epsilon")
        | .description == "" and .mode == "direct-PR" and .added == null and .status == "idle_queued")
      and (.projects[] | select(.name == "zeta")
        | .description == "" and .mode == "no-mistakes" and .yolo == false)
      and (.projects[] | select(.name == "alpha")
        | .status == "needs_attention"
          and .counts.active == 1
          and .counts.decisions == 2
          and (.landed | any(.id == "alpha-landed"))
          and (.prs | any(.url == "https://github.com/example/alpha/pull/7")))
      and (.projects[] | select(.name == "bravo") | .status == "active")
      and (.projects[] | select(.name == "beta") | .status == "waiting")
      and (.projects[] | select(.name == "gamma") | .status == "idle_queued" and .queued == [])
      and (.projects[] | select(.name == "delta")
        | .status == "active"
          and .secondmates == [{id:"delta-mate",home:(.secondmates[0].home),remote:false,state:"active_child_work",unavailable:false}]
          and (.active_work | any(.id == "delta-child" and .owner == "delta-mate"))
          and (.landed | any(.id == "delta-landed" and .owner == "delta-mate")))
  ' >/dev/null || fail "project aggregation, precedence, or secondmate join was wrong: $out"
  [ "$(cat "$home/fleet-calls.log")" = "--json" ] \
    || fail "dashboard did not use the canonical fleet snapshot interface"
  pass "aggregation left-joins every project and preserves status precedence and secondmate state"
}

test_stale_risk_is_strictly_older_than_eight_days() {
  local home activity exact later out
  home=$(make_home stale)
  write_fleet_fixture "$home"
  activity=$(stat -f '%m' "$home/state/beta-wait.status" 2>/dev/null || stat -c '%Y' "$home/state/beta-wait.status")
  exact=$((activity + 8 * 86400))
  later=$((exact + 1))
  out=$(run_snapshot "$home" "$exact") || fail "exact-threshold snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "beta") | .status == "waiting" and .stale_risk == false)
      and (.projects[] | select(.name == "alpha") | .stale_risk == false)
      and (.projects[] | select(.name == "bravo") | .stale_risk == false)
  ' >/dev/null || fail "stale overlay fired at or overrode an excluded status at the exact threshold: $out"
  out=$(run_snapshot "$home" "$later") || fail "post-threshold snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "beta") | .status == "waiting" and .stale_risk == true)
      and (.projects[] | select(.name == "gamma") | .stale_risk == true)
  ' >/dev/null || fail "stale overlay did not fire after eight days: $out"
  pass "stale risk is an overlay only after eight full days"
}

test_selected_project_payload_is_validated() {
  local home epoch out rc error
  home=$(make_home selected)
  write_fleet_fixture "$home"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch" --select delta) || fail "selected-project snapshot failed"
  printf '%s' "$out" | jq -e '.selected_project == "delta" and (.projects | any(.name == "delta"))' >/dev/null \
    || fail "selected project was not preserved in the payload"
  set +e
  error=$(run_snapshot "$home" "$epoch" --select missing 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unregistered selected project was accepted"
  assert_contains "$error" "not registered" "selected-project refusal did not explain the error"
  pass "selected project data is explicit and registry-validated"
}

test_bounded_secondmate_state_keeps_registered_ownership_visible() {
  local home epoch out
  home=$(make_home bounded-secondmate)
  write_fleet_fixture "$home"
  jq '.secondmate_current.records = []' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "bounded-secondmate snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "delta")
    | .status == "needs_attention"
      and .secondmates == [{id:"delta-mate",home:null,remote:false,state:"unknown",unavailable:true}]
      and .next_step == "Secondmate state unavailable from the bounded fleet snapshot"
  ' >/dev/null || fail "bounded secondmate state silently dropped registered project ownership: $out"
  pass "bounded secondmate state keeps ownership visible as explicit attention"
}

test_distinct_unkeyed_decisions_are_all_surfaced() {
  local home epoch out
  home=$(make_home unkeyed-decisions)
  write_fleet_fixture "$home"
  jq '
    .backlog.records += [{structured:true,id:"bravo-choice",repo:"bravo",title:"Bravo choice",
      state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks |= map(
        if .id == "bravo-work" then
          .hints.open_decisions = [{key:"default",verb:"needs-decision",summary:"pick a rollout window"}]
        else . end)
    | .tasks += [(.tasks[] | select(.id == "bravo-work")
        | .id = "bravo-choice" | .backlog.id = "bravo-choice" | .backlog.title = "Bravo choice"
        | .paths.meta.path = (.paths.meta.path | sub("bravo-work"; "bravo-choice"))
        | .paths.status_log.path = (.paths.status_log.path | sub("bravo-work"; "bravo-choice"))
        | .hints.open_decisions = [{key:"default",verb:"needs-decision",summary:"approve the vendor contract"}])]
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unkeyed-decision snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "bravo")
    | .status == "needs_attention"
      and .counts.decisions == 2
      and (.decisions | map(.summary) | sort) == ["approve the vendor contract","pick a rollout window"]
  ' >/dev/null || fail "distinct unkeyed captain decisions collapsed into one: $out"
  pass "distinct captain decisions sharing the default key stay visible"
}

test_attention_next_step_is_an_action_not_a_bare_title() {
  local home epoch out
  home=$(make_home attention-next-step)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(
      if .id == "bravo-work" then .current_state = {state:"failed",source:"fixture",detail:"gate rejected the push"}
      elif .id == "beta-wait" then .current_state = {state:"done",source:"fixture",detail:""} | .pr.url = "https://github.com/example/beta/pull/3"
      else . end)
    | .backlog.records |= map(if .id == "beta-wait" then .state = "in_flight" else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "attention next-step snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "bravo")
      | .status == "needs_attention" and .next_step == "failed: gate rejected the push")
      and (.projects[] | select(.name == "beta")
        | .status == "needs_attention" and .next_step == "PR awaiting review: beta-wait")
  ' >/dev/null || fail "attention next step was a bare task title: $out"
  pass "failure and review-PR next steps read as actions"
}

test_unattributable_secondmate_state_is_disclosed() {
  local home epoch out
  home=$(make_home unattributable)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta","gamma"] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta","gamma"]
          | .active_children = [{id:"loose-child",title:"Unlabelled rollout",repo:null,state:"working",doing:"Working"}]
          | .landed = []
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unattributable-state snapshot failed"
  printf '%s' "$out" | jq -e '
    .summary.unattributed == 2
      and ([.projects[] | select(.name == "delta" or .name == "gamma")]
           | all(.status == "needs_attention"
                 and .active_work == []
                 and .counts.unattributed == 1
                 and (.unattributed[0] | .id == "loose-child" and .kind == "active_work" and .owner == "delta-mate")
                 and (.next_step | startswith("Secondmate work is not attributable to one project"))))
  ' >/dev/null || fail "unattributable secondmate work was silently dropped: $out"
  pass "secondmate work that no project can claim is disclosed, not dropped"
}

test_registered_secondmate_without_a_task_still_owns_its_projects() {
  local home epoch out
  home=$(make_home registry-only-secondmate)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(select(.id != "delta-mate"))
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta"]
          | .decisions_open = [{id:"delta-call",key:"default",verb:"needs-decision",
              summary:"Approve the delta rollout",reason:null,repo:"delta"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "registry-only secondmate snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "delta")
    | .status == "needs_attention"
      and (.secondmates | map(.id)) == ["delta-mate"]
      and .counts.decisions == 1
      and .next_step == "Approve the delta rollout"
  ' >/dev/null || fail "a registered secondmate with no parent task lost its project state: $out"
  pass "registered secondmate ownership survives a missing parent task"
}

test_live_secondmate_owner_activity_defeats_stale_risk() {
  local home activity exact later out
  home=$(make_home secondmate-activity)
  write_fleet_fixture "$home"
  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .current = {state:"externally_held",reason:null}
        | .active_children = []
        | .landed = []
        | .holds = [{id:"delta-hold",title:"Delta hold",repo:"delta",reason:"Waiting on vendor"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  activity=$(stat -f '%m' "$home/state/delta-mate.status" 2>/dev/null || stat -c '%Y' "$home/state/delta-mate.status")
  exact=$((activity + 8 * 86400))
  later=$((exact + 1))
  out=$(run_snapshot "$home" "$exact") || fail "secondmate-activity snapshot failed"
  printf '%s' "$out" | jq -e --argjson activity "$activity" '
    .projects[] | select(.name == "delta")
    | .status == "waiting" and .stale_risk == false
      and .last_activity.age_seconds == 8 * 86400
      and .last_activity.at == ($activity | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ' >/dev/null || fail "owning secondmate activity was ignored by the stale overlay: $out"
  out=$(run_snapshot "$home" "$later") || fail "aged secondmate-activity snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "delta") | .status == "waiting" and .stale_risk == true
  ' >/dev/null || fail "stale overlay never fires for a secondmate-owned project: $out"
  pass "an owning secondmate's own activity counts toward the stale overlay"
}

test_non_https_pr_link_discloses_itself_without_failing_the_board() {
  local home epoch payload out board
  home=$(make_home http-pr)
  write_fleet_fixture "$home"
  jq '.backlog.records |= map(if .id == "alpha-landed" then .pr_url = "http://git.internal/example/alpha/pull/7" else . end)'     "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  payload="$home/dashboard.json"
  run_snapshot "$home" "$epoch" > "$payload" || fail "non-https PR link failed the aggregation"
  jq -e '
    .projects[] | select(.name == "alpha") | .prs
    | any(.url == "http://git.internal/example/alpha/pull/7" and .linkable == false)
  ' "$payload" >/dev/null || fail "non-https PR link was dropped instead of disclosed: $(cat "$payload")"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s
' "$*" >> "$LAVISH_CALL_LOG"
SH
  chmod +x "$home/fakebin/lavish-axi"
  board="$home/.lavish/project-dashboard.html"
  out=$(PATH="$home/fakebin:$PATH" LAVISH_CALL_LOG="$home/lavish.log" FM_HOME="$home" "$BOARD" build "$payload")     || fail "one non-https PR link took the whole board down: $out"
  assert_contains "$out" "board: $board" "board was not published despite a valid payload"
  pass "a non-https PR link is disclosed instead of failing every project"
}

extract_payload() {  # <board>
  sed -n '/<script id="project-dashboard-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

test_board_build_is_stable_read_only_and_selection_preserving() {
  local home source_home epoch payload board out before after
  source_home=$(make_home board-source)
  write_fleet_fixture "$source_home"
  epoch=$(date +%s)
  payload="$source_home/dashboard.json"
  run_snapshot "$source_home" "$epoch" --select delta > "$payload" || fail "board payload snapshot failed"

  home=$(make_home board)
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAVISH_CALL_LOG"
SH
  chmod +x "$home/fakebin/lavish-axi"
  board="$home/.lavish/project-dashboard.html"
  before=$(find "$home/state" -mindepth 1 -print | sort)
  out=$(PATH="$home/fakebin:$PATH" LAVISH_CALL_LOG="$home/lavish.log" FM_HOME="$home" "$BOARD" build "$payload") \
    || fail "valid dashboard payload did not build"
  after=$(find "$home/state" -mindepth 1 -print | sort)
  [ "$before" = "$after" ] || fail "read-only board build changed fleet state"
  assert_contains "$out" "board: $board" "build did not report the stable board path"
  assert_contains "$out" "served: $board" "build did not report Lavish serving"
  [ "$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" path)" = "$board" ] \
    || fail "dashboard path was not stable and home-scoped"
  [ "$(cat "$home/lavish.log")" = "$board" ] || fail "dashboard was not served through Lavish"
  extract_payload "$board" | jq -e '
    .selected_project == "delta"
      and (.projects[] | select(.name == "delta") | .active_work[0].id == "delta-child")
  ' >/dev/null || fail "built board lost selected project data"
  assert_absent "$home/state/procevent" "read-only dashboard registered a process-event source"
  pass "board build is stable, read-only, and selection-preserving"
}

test_aggregation_status_precedence_and_secondmate_join
test_distinct_unkeyed_decisions_are_all_surfaced
test_attention_next_step_is_an_action_not_a_bare_title
test_unattributable_secondmate_state_is_disclosed
test_registered_secondmate_without_a_task_still_owns_its_projects
test_live_secondmate_owner_activity_defeats_stale_risk
test_non_https_pr_link_discloses_itself_without_failing_the_board
test_stale_risk_is_strictly_older_than_eight_days
test_selected_project_payload_is_validated
test_bounded_secondmate_state_keeps_registered_ownership_visible
test_board_build_is_stable_read_only_and_selection_preserving
