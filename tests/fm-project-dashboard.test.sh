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
        id:"delta-mate",home:($home + "/secondmates/delta"),remote:false,projects:["delta"],
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
          and .counts.decisions == 1
          and (.decisions | map(.id)) == ["alpha-call"]
          and (.landed | any(.id == "alpha-landed"))
          and (.prs | any(.url == "https://github.com/example/alpha/pull/7")))
      and (.projects[] | select(.name == "bravo") | .status == "active")
      and (.projects[] | select(.name == "beta") | .status == "waiting")
      and (.projects[] | select(.name == "gamma") | .status == "idle_queued" and .queued == [])
      and (.projects[] | select(.name == "delta")
        | .status == "active"
          and .secondmates == [{id:"delta-mate",home:(.secondmates[0].home),remote:false,state:"active_child_work",unavailable:false,in_clone_list:true}]
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
      and .secondmates == [{id:"delta-mate",home:null,remote:false,state:"unknown",unavailable:true,in_clone_list:true}]
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
        | .status != "needs_attention"
          and .next_step == "Finished - beta-wait")
  ' >/dev/null || fail "attention next step was a bare task title: $out"
  pass "failure and finished-work next steps read as actions"
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
           | all(.status == "active"
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

test_blocked_status_fold_is_not_a_captain_decision() {
  local home epoch out
  home=$(make_home blocked-fold)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(
      if .id == "bravo-work" then
        .current_state = {state:"blocked",source:"fixture",detail:"waiting on vendor key"}
        | .hints.open_decisions = [{key:"default",verb:"blocked",summary:"waiting on vendor key"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "blocked-fold snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "bravo")
    | .status == "needs_attention"
      and .counts.decisions == 0
      and .decisions == []
      and (.failures | map(.id)) == ["bravo-work"]
      and .next_step == "blocked: waiting on vendor key"
  ' >/dev/null || fail "a blocked status-fold entry was counted as a captain decision: $out"
  pass "blocked work stays a failure and never becomes a captain decision"
}

test_backlog_order_survives_deduplication() {
  local home epoch out
  home=$(make_home backlog-order)
  write_fleet_fixture "$home"
  jq '
    .backlog.records = [
      {structured:true,id:"zz-top-priority",repo:"alpha",title:"Ship the exporter",state:"queued",
       since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]},
      {structured:true,id:"aa-later",repo:"alpha",title:"Tidy the docs",state:"queued",
       since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}
    ]
    | .tasks = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "backlog-order snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | (.queued | map(.id)) == ["zz-top-priority","aa-later"]
      and .next_step == "Ship the exporter"
  ' >/dev/null || fail "deduplication resorted the captain's backlog order: $out"
  pass "backlog order survives deduplication of queued work"
}

test_deferred_captain_hold_is_disclosed_not_escalated() {
  local home epoch out
  home=$(make_home deferred-hold)
  write_fleet_fixture "$home"
  jq '
    .backlog.records |= map(
      if .id == "alpha-call" then
        .title = "Old thing" | .hold_kind = "captain"
        | .hold_reason = "SUPERSEDED by alpha-new" | .deferred_marker = true
      else . end)
    | .tasks |= map(if .id == "alpha-call" then .hints.open_decisions = [] else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "deferred-hold snapshot failed"
  printf '%s' "$out" | jq -e '
    .summary.deferred_decisions == 1
      and (.projects[] | select(.name == "alpha")
        | .status == "active"
          and .counts.decisions == 0
          and .decisions == []
          and .counts.deferred_decisions == 1
          and (.deferred_decisions[0] | .id == "alpha-call" and .owner == "main"))
  ' >/dev/null || fail "a superseded captain hold still painted the card red: $out"
  pass "deferred captain holds are disclosed instead of demanding attention"
}

test_captain_hold_next_step_keeps_the_question() {
  local home epoch out
  home=$(make_home hold-question)
  write_fleet_fixture "$home"
  jq '
    .backlog.records |= map(
      if .id == "alpha-call" then
        .title = "Build the exporter" | .hold_reason = "choose between S3 and GCS"
      else . end)
    | .tasks |= map(if .id == "alpha-call" then .hints.open_decisions = [] else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "hold-question snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "needs_attention"
      and .next_step == "Build the exporter: choose between S3 and GCS"
  ' >/dev/null || fail "the captain hold next step dropped the question: $out"
  pass "a captain hold next step carries the question, not just the row title"
}

test_repo_labelled_secondmate_work_attributes_to_that_project() {
  local home epoch out
  home=$(make_home cross-repo)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta"] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta"]
          | .active_children = [{id:"cross-child",title:"Gamma rollout",repo:"gamma",
              state:"working",doing:"Working on gamma"}]
          | .landed = []
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "cross-repo snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "gamma")
      | .status == "active"
        and (.active_work | map(.id)) == ["cross-child"]
        and (.secondmates | map({id,in_clone_list})) == [{id:"delta-mate",in_clone_list:false}])
      and (.projects[] | select(.name == "delta")
        | .active_work == []
          and .counts.unattributed == 0
          and (.secondmates | map({id,in_clone_list})) == [{id:"delta-mate",in_clone_list:true}])
  ' >/dev/null || fail "repo-labelled secondmate work was dropped from every card: $out"
  pass "secondmate work naming a registered project lands on that project"
}

test_bounded_snapshot_drops_are_disclosed_board_wide() {
  local home epoch out
  home=$(make_home bounded-disclosure)
  write_fleet_fixture "$home"
  jq '
    .secondmate_current.truncated = 3
    | .secondmate_current.registry = {available:true,complete:false,records_truncated:true,
        input_truncated:false,reason:null}
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "bounded-disclosure snapshot failed"
  printf '%s' "$out" | jq -e '
    (.disclosures | length) == 2
      and (.disclosures | any(.surface == "registered secondmates omitted by the snapshot bound: 3"
                              and .reveal == "raise FM_SNAPSHOT_SECONDMATES"))
      and (.disclosures | any(.surface == "secondmate registry records omitted by the bounded read"))
  ' >/dev/null || fail "bounded snapshot drops were not disclosed: $out"
  out=$(run_snapshot "$home" "$epoch" --select delta) || fail "clean-disclosure snapshot failed"
  jq '.secondmate_current.truncated = 0 | .secondmate_current.registry = {available:true,complete:true,records_truncated:false,input_truncated:false,reason:null}'     "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "clean-disclosure snapshot failed"
  printf '%s' "$out" | jq -e '.disclosures == []' >/dev/null     || fail "a complete fleet read still reported a disclosure: $out"
  pass "bounded snapshot and registry drops surface as board-level disclosures"
}

test_finished_task_is_reported_verbatim_never_interpreted() {
  local home epoch out
  home=$(make_home merged-pr)
  write_fleet_fixture "$home"
  : > "$home/state/alpha-ship.meta"
  : > "$home/state/alpha-ship.status"
  jq --arg home "$home" '
    .backlog.records |= map(if .id == "alpha-call" then .captain_actionable = false else . end)
    | .tasks |= map(if .id == "alpha-call" then .hints.open_decisions = [] else . end)
    | .backlog.records += [{structured:true,id:"alpha-ship",repo:"alpha",title:"Ship alpha",
        state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks += [
        {id:"alpha-ship",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/alpha-ship.meta"),present:true},
                status_log:{path:($home + "/state/alpha-ship.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"done",source:"fixture",detail:"run passed: PR merged/closed"},
         hints:{open_decisions:[]},pr:{url:"https://github.com/example/alpha/pull/9"},
         backlog:{id:"alpha-ship",repo:"alpha",title:"Ship alpha"}}]
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "awaiting-teardown snapshot failed"
  printf '%s' "$out" | jq -e '
    .summary.finished == 1
      and (.projects[] | select(.name == "alpha")
        | .status == "active"
          and .counts.finished == 1
          and (.finished[0] | .id == "alpha-ship" and .owner == "main"
               and .url == "https://github.com/example/alpha/pull/9")
          and ([.decisions[],.failures[],.unreadable[]] | length) == 0
          and (.prs | any(.url == "https://github.com/example/alpha/pull/9"))
          and .finished[0].detail == "run passed: PR merged/closed"
          and (.next_step | test("teardown|awaiting review") | not))
  ' >/dev/null || fail "a finished task in the merge-to-teardown window was misread: $out"

  jq '
    .tasks |= map(select(.id != "alpha-work" and .id != "alpha-call"))
    | .backlog.records |= map(select(.id != "alpha-work" and .id != "alpha-call"))
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "quiet-project snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status != "needs_attention"
      and .next_step == "Finished - Ship alpha: run passed: PR merged/closed"
  ' >/dev/null || fail "finished work still painted the project red: $out"

  jq '
    .tasks |= map(if .id == "alpha-ship" then
        .current_state.detail = "checks green: PR ready for review (still monitoring for merge/close)"
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "checks-green snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .next_step == "Finished - Ship alpha: checks green: PR ready for review (still monitoring for merge/close)"
      and (.next_step | test("teardown|awaiting review") | not)
      and .finished[0].detail == "checks green: PR ready for review (still monitoring for merge/close)"
  ' >/dev/null || fail "a checks-green PR was told to tear down: $out"
  pass "a finished task repeats its crew detail verbatim and infers no lifecycle stage"
}

test_unreadable_task_state_is_disclosed_not_idle() {
  local home epoch out
  home=$(make_home unreadable-task)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(
        if .id == "bravo-work" then
          .current_state = {state:"unknown",source:"fixture",detail:"worktree gone (torn down?)"}
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unreadable-task snapshot failed"
  printf '%s' "$out" | jq -e '
    .summary.unreadable == 1
      and (.projects[] | select(.name == "bravo")
        | .status == "needs_attention"
          and .counts.unreadable == 1
          and (.unreadable[0] | .id == "bravo-work" and .owner == "main"
               and .reason == "worktree gone (torn down?)")
          and .next_step == "Task state could not be read: bravo-work - worktree gone (torn down?)")
  ' >/dev/null || fail "an unreadable task left the project reading idle: $out"
  pass "a task whose state cannot be read is disclosed, not reported as idle"
}

test_a_hold_never_hides_another_open_decision() {
  local home epoch out
  home=$(make_home hold-vs-folds)
  write_fleet_fixture "$home"
  jq '
    .backlog.records |= map(
      if .id == "alpha-work" then .captain_actionable = true | .hold_kind = "captain"
        | .hold_reason = "Approve the alpha budget"
      else . end)
    | .tasks |= map(
        if .id == "alpha-work" then
          .hints.open_decisions = [
            {key:"route",verb:"needs-decision",summary:"Choose alpha route"},
            {key:"budget",verb:"needs-decision",summary:"Approve the alpha budget"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "hold-vs-folds snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | ([.decisions[] | select(.id == "alpha-work") | .key] | sort) == ["alpha-work","route"]
      and ([.decisions[] | select(.id == "alpha-work") | .summary] | sort)
          == ["Approve the alpha budget","Choose alpha route"]
      and (.deferred_decisions | length) == 0
  ' >/dev/null || fail "a captain hold hid or duplicated an open decision on its task: $out"

  jq '
    .backlog.records |= map(if .id == "alpha-work" then
        .hold_reason = "SUPERSEDED by alpha-new" | .deferred_marker = true else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "deferred-hold-vs-folds snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "needs_attention"
      and ([.decisions[] | select(.id == "alpha-work") | .key] | sort) == ["budget","route"]
      and (.deferred_decisions | map(.id)) == ["alpha-work"]
  ' >/dev/null || fail "a deferred hold silently swallowed live open decisions: $out"
  pass "a captain hold never hides another open decision on the same task"
}

test_blank_detail_never_renders_a_blank_next_step() {
  local home epoch out
  home=$(make_home blank-detail)
  write_fleet_fixture "$home"
  jq '
    .backlog.records |= map(select(.repo != "beta"))
    | .tasks |= map(
        if .id == "beta-wait" then .current_state = {state:"paused",source:"fixture",detail:""}
        elif .id == "bravo-work" then .current_state = {state:"unknown",source:"fixture",detail:""}
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "blank-detail snapshot failed"
  printf '%s' "$out" | jq -e '
    ([.projects[] | select(.next_step == "" or (.next_step | endswith(" - ")))] | length) == 0
      and (.projects[] | select(.name == "beta")
        | .status == "waiting" and .next_step == "paused" and .waiting[0].reason == "paused")
      and (.projects[] | select(.name == "bravo")
        | .status == "needs_attention"
          and .next_step == "Task state could not be read: bravo-work"
          and .unreadable[0].reason == "Task state could not be read")
  ' >/dev/null || fail "a blank detail produced a blank next step: $out"
  pass "an empty detail never renders as a blank next step"
}

test_one_captain_hold_is_one_decision() {
  local home epoch out
  home=$(make_home single-decision)
  write_fleet_fixture "$home"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "single-decision snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .counts.decisions == 1
      and (.decisions | map(.id)) == ["alpha-call"]
      and .decisions[0].summary == "Choose release route"
  ' >/dev/null || fail "one captain hold was counted as two decisions: $out"
  pass "a hold recorded in both the backlog and the status fold is one decision"
}

test_per_home_bounded_drops_are_disclosed() {
  local home epoch out
  home=$(make_home per-home-omitted)
  write_fleet_fixture "$home"
  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .counts = {active_children:1,decisions_open:0,holds:0,queued:0,landed:15,endpoints:1}
        | .omitted = [{surface:"landed",count:5},{surface:"decisions_open",count:2}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "per-home omitted snapshot failed"
  printf '%s' "$out" | jq -e '
    (.disclosures | length) == 2
      and (.disclosures | any(
            .surface == "secondmate delta-mate landed omitted by the bounded home read: 5"
            and .reveal == "raise FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME"))
      and (.disclosures | any(
            .surface == "secondmate delta-mate decisions_open omitted by the bounded home read: 2"
            and .reveal == "raise FM_SNAPSHOT_SECONDMATE_DECISIONS"))
  ' >/dev/null || fail "a bounded per-home read was never disclosed: $out"

  jq '.secondmate_current.records |= map(if .id == "delta-mate" then .omitted = [] else . end)' \
    "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "complete per-home snapshot failed"
  printf '%s' "$out" | jq -e '.disclosures == []' >/dev/null \
    || fail "a complete home read still reported a drop: $out"
  pass "per-home bounded read drops reach the board disclosures"
}

test_one_hold_reason_absorbs_at_most_one_fold() {
  local home epoch out
  home=$(make_home generic-hold)
  write_fleet_fixture "$home"
  jq '
    .backlog.records |= map(
      if .id == "alpha-work" then .captain_actionable = true | .hold_kind = "captain"
        | .hold_reason = "Captain decision"
      else . end)
    | .tasks |= map(
        if .id == "alpha-work" then
          .hints.open_decisions = [
            {key:"route",verb:"needs-decision",summary:"Captain decision on the alpha route"},
            {key:"budget",verb:"needs-decision",summary:"Captain decision on the alpha budget"}]
        else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .decisions_open = [
            {id:"c1",key:"c1",verb:"captain-hold",summary:"Captain decision",reason:"Captain decision",
             repo:"delta",source:"backlog"},
            {id:"c1",key:"route",verb:"needs-decision",summary:"Captain decision on the delta route",
             reason:null,repo:"delta",source:"status"},
            {id:"c1",key:"budget",verb:"needs-decision",summary:"Captain decision on the delta budget",
             reason:null,repo:"delta",source:"status"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "generic-hold snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "alpha")
      | ([.decisions[] | select(.id == "alpha-work") | .key] | sort) == ["alpha-work","budget","route"])
      and (.projects[] | select(.name == "delta")
        | ([.decisions[] | select(.id == "c1") | .key] | sort) == ["budget","c1","route"])
  ' >/dev/null || fail "one generic hold reason erased several open decisions: $out"
  pass "a captain hold absorbs at most one fold and never an ambiguous match"
}

test_finished_non_https_pr_link_does_not_fail_the_board() {
  local home epoch payload board out
  home=$(make_home finished-http-pr)
  write_fleet_fixture "$home"
  : > "$home/state/alpha-ship.meta"
  : > "$home/state/alpha-ship.status"
  jq --arg home "$home" '
    .backlog.records += [{structured:true,id:"alpha-ship",repo:"alpha",title:"Ship alpha",
        state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks += [
        {id:"alpha-ship",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/alpha-ship.meta"),present:true},
                status_log:{path:($home + "/state/alpha-ship.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"done",source:"fixture",detail:"checks green: PR ready for review"},
         hints:{open_decisions:[]},pr:{url:"http://github.example/x/pull/1"},
         backlog:{id:"alpha-ship",repo:"alpha",title:"Ship alpha"}}]
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  payload="$home/dashboard.json"
  run_snapshot "$home" "$epoch" > "$payload" || fail "finished http PR snapshot failed"
  jq -e '
    .projects[] | select(.name == "alpha") | .finished[]
    | select(.id == "alpha-ship")
    | .url == "http://github.example/x/pull/1" and .linkable == false
  ' "$payload" >/dev/null || fail "a non-https finished PR link was dropped instead of disclosed: $(cat "$payload")"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/lavish-axi"
  board="$home/.lavish/project-dashboard.html"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" build "$payload") \
    || fail "one non-https finished PR link took the whole board down: $out"
  assert_contains "$out" "board: $board" "board was not published despite a valid payload"
  pass "a non-https PR link on finished work never fails the board"
}

test_unattributable_item_escalates_only_to_its_own_kind() {
  local home epoch out
  home=$(make_home unattributed-rank)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta","gamma"] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta","gamma"]
          | .current = {state:"no_active_work",reason:null}
          | .active_children = []
          | .landed = []
          | .queued = [{id:"q1",title:"Tidy docs later",repo:null}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unattributed-queued snapshot failed"
  printf '%s' "$out" | jq -e '
    [.projects[] | select(.name == "delta" or .name == "gamma")]
    | all(.status == "idle_queued"
          and .counts.unattributed == 1
          and (.unattributed[0].kind == "queued")
          and (.next_step | startswith("Secondmate work is not attributable") | not))
  ' >/dev/null || fail "an unattributable queued row repainted the card: $out"

  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .queued = []
        | .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",summary:"Approve the rollout",
            reason:null,repo:null,source:"status"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "unattributed-decision snapshot failed"
  printf '%s' "$out" | jq -e '
    [.projects[] | select(.name == "delta" or .name == "gamma")]
    | all(.status == "needs_attention"
          and (.unattributed[0].kind == "decision")
          and (.next_step | startswith("Secondmate work is not attributable to one project")))
  ' >/dev/null || fail "an unattributable decision failed to raise attention: $out"
  pass "an unattributable item escalates only to the status its own kind would produce"
}

test_secondmate_reaching_no_project_is_disclosed() {
  local home epoch out
  home=$(make_home orphan-mate)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = [] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = []
          | .current = {state:"captain_decision",reason:null}
          | .active_children = []
          | .landed = []
          | .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",
              summary:"Approve the orphan rollout",reason:null,repo:null,source:"status"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "orphan-mate snapshot failed"
  printf '%s' "$out" | jq -e '
    (.disclosures | any(
        (.surface | startswith("secondmate delta-mate has state that reaches no project card"))
        and (.reveal | startswith("record its projects in data/secondmates.md"))))
      and ([.projects[] | select(.secondmates | length > 0)] | length) == 0
  ' >/dev/null || fail "a secondmate reaching no project card vanished silently: $out"

  jq '.secondmate_current.records |= map(if .id == "delta-mate" then .projects = ["delta"] else . end)
      | .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta"] else . end)' \
    "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "attributable-mate snapshot failed"
  printf '%s' "$out" | jq -e '.disclosures == []' >/dev/null \
    || fail "an attributable secondmate still reported as unreachable: $out"
  pass "a secondmate whose state reaches no project card is disclosed board-wide"
}

test_state_reaching_no_card_is_disclosed_whatever_the_clone_list() {
  local home epoch out
  home=$(make_home unregistered-clone-list)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = [] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["gizmo"]
          | .current = {state:"captain_decision",reason:null}
          | .active_children = []
          | .landed = []
          | .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",
              summary:"Approve the gizmo rollout",reason:null,repo:null,source:"status"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unregistered clone-list snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(
      .surface == "secondmate delta-mate has state that reaches no project card: 1 item(s)")
  ' >/dev/null || fail "an unregistered clone list silently dropped an open decision: $out"

  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .active_children = [{id:"ac1",title:"Alpha child",repo:"alpha",state:"working",doing:"Working"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "visible-mate snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "alpha")
      | (.active_work | any(.id == "ac1")) and (.decisions | any(.id == "d1") | not))
      and (.disclosures | any(
            .surface == "secondmate delta-mate has state that reaches no project card: 1 item(s)"))
  ' >/dev/null || fail "a visible secondmate lost its open decision with no disclosure: $out"

  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",
          summary:"Approve the gizmo rollout",reason:null,repo:"gizmo",source:"status"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "unregistered-repo snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(
      .surface == "secondmate delta-mate has state that reaches no project card: 1 item(s)")
  ' >/dev/null || fail "an item labelled with an unregistered repo vanished silently: $out"
  pass "secondmate state that reaches no project card is always disclosed"
}

test_next_step_names_the_item_that_set_the_status() {
  local home epoch out
  home=$(make_home escalator-order)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta","gamma"] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta","gamma"]
          | .landed = []
          | .active_children = [{id:"ac1",title:"Some child work",repo:null,state:"working",doing:"Working"}]
          | .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",summary:"Approve rollout",
              reason:null,repo:null,source:"status"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "escalator-order snapshot failed"
  printf '%s' "$out" | jq -e '
    [.projects[] | select(.name == "delta" or .name == "gamma")]
    | all(.status == "needs_attention"
          and (.unattributed | map(.kind)) == ["active_work","decision"]
          and .next_step == "Secondmate work is not attributable to one project: Approve rollout")
  ' >/dev/null || fail "the next step named a lower-ranked escalator than the one that set the status: $out"
  pass "the next step names the unattributable item that set the status"
}

test_unattributable_deferred_and_blocked_rows_do_not_paint_cards_red() {
  local home epoch out
  home=$(make_home unattributable-rank-kind)
  write_fleet_fixture "$home"
  jq '
    .backlog.records = []
    | .tasks |= map(select(.kind == "secondmate") | .secondmate_projects = ["delta","gamma"])
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta","gamma"]
          | .current = {state:"no_active_work",reason:null}
          | .active_children = []
          | .landed = []
          | .holds = []
          | .queued = []
          | .decisions_open = [
              {id:"h1",key:"h1",verb:"captain-hold",summary:"Deferred rollout",
               reason:"revisit next quarter",repo:null,deferred_marker:true,source:"backlog"},
              {id:"b1",key:"b1",verb:"blocked",summary:"Blocked on vendor",repo:null,source:"status"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unattributable-kind snapshot failed"
  printf '%s' "$out" | jq -e '
    .summary.needs_attention == 0
      and ([.projects[] | select(.name == "delta" or .name == "gamma")]
           | all(.status == "idle_queued"
                 and .next_step == "No work queued"
                 and (.unattributed | map(.kind)) == ["deferred_decision"]))
  ' >/dev/null || fail "a deferred or blocked unattributable row painted the card red: $out"

  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .decisions_open = [{id:"d1",key:"d1",verb:"needs-decision",summary:"Approve rollout",
          reason:null,repo:null,source:"status"}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "live-decision control snapshot failed"
  printf '%s' "$out" | jq -e '
    [.projects[] | select(.name == "delta" or .name == "gamma")]
    | all(.status == "needs_attention" and (.unattributed | map(.kind)) == ["decision"])
  ' >/dev/null || fail "a live unattributable decision stopped raising attention: $out"
  pass "an unattributable deferred or blocked row is disclosed without painting the card red"
}

test_held_in_flight_backlog_row_reaches_the_card_without_task_metadata() {
  local home epoch out
  home=$(make_home held-in-flight)
  write_fleet_fixture "$home"
  jq '
    .tasks = []
    | .backlog.records = [
        {structured:true,id:"a-held",repo:"alpha",title:"Ship the exporter",state:"in_flight",
         current_role:"held",hold_reason:"Waiting on the vendor patch",hold_kind:"external",
         captain_actionable:false,unresolved_blocker_ids:[]}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "held in-flight snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "waiting"
      and (.waiting | map(.id)) == ["a-held"]
      and .next_step == "Waiting on the vendor patch"
  ' >/dev/null || fail "a held in-flight backlog row reached no card: $out"
  pass "a held in-flight backlog row reaches the card without live task metadata"
}

test_invalid_main_inventory_is_disclosed() {
  local home epoch out
  home=$(make_home main-inventory)
  write_fleet_fixture "$home"
  jq '
    .tasks = []
    | .backlog.records = [
        {structured:true,id:"a-orphan",repo:"alpha",title:"Orphan work",state:"in_flight",
         current_role:"worker",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .secondmate_current.records = []
    | .main_inventory = {valid:false,
        reason:"in-flight backlog item has no child metadata: a-orphan",
        orphan_in_flight:["a-orphan"],unstructured_current_count:0}
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "main-inventory snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(
      .surface == "main backlog inventory is invalid: in-flight backlog item has no child metadata: a-orphan"
      and .reveal == "inspect data/backlog.md In flight against state/*.meta")
  ' >/dev/null || fail "an invalid main backlog inventory was never disclosed: $out"

  jq '.main_inventory = {valid:true,reason:null,orphan_in_flight:[],unstructured_current_count:0}' \
    "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "valid-inventory snapshot failed"
  printf '%s' "$out" | jq -e '.disclosures == []' >/dev/null \
    || fail "a valid main inventory still reported a problem: $out"
  pass "an invalid main backlog inventory is disclosed board-wide"
}

test_stranded_count_counts_each_row_once() {
  local home epoch out
  home=$(make_home stranded-count)
  write_fleet_fixture "$home"
  jq '
    .tasks |= map(select(.kind != "secondmate"))
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = []
          | .active_children = []
          | .landed = []
          | .holds = []
          | .decisions_open = [{id:"q1",key:"q1",verb:"captain-hold",summary:"Pick a route",
              reason:"Pick a route",repo:null,source:"backlog"}]
          | .queued = [{id:"q1",title:"Pick a route",repo:null,captain_actionable:true,
              hold_reason:"Pick a route",hold_kind:"captain"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "stranded-count snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(
      .surface == "secondmate delta-mate has state that reaches no project card: 1 item(s)")
  ' >/dev/null || fail "one backlog row on two owner surfaces was counted twice: $out"
  pass "the stranded-item count counts each underlying row once"
}

test_repo_less_backlog_row_follows_its_task() {
  local home epoch out
  home=$(make_home repo-less-backlog)
  write_fleet_fixture "$home"
  : > "$home/state/t1.meta"
  : > "$home/state/t1.status"
  jq --arg home "$home" '
    .backlog.records = [
      {structured:true,id:"t1",repo:null,title:"Ship it",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/alpha/pull/1",completion:{date:"2026-08-20"}},
      {structured:true,id:"t2",repo:null,title:"Queued next",state:"queued",since:"2020-01-01",
       captain_actionable:false,hold_reason:"Waiting on review",unresolved_blocker_ids:[]}]
    | .tasks = [
        {id:"t1",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/t1.meta"),present:true},
                status_log:{path:($home + "/state/t1.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"done",source:"fixture",detail:"PR opened"},
         hints:{open_decisions:[]},pr:{url:"https://github.com/example/alpha/pull/1"},
         backlog:{id:"t1",repo:null,title:"Ship it"}},
        {id:"t2",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/t1.meta"),present:true},
                status_log:{path:($home + "/state/t1.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"paused",source:"fixture",detail:"Waiting on review"},
         hints:{open_decisions:[]},pr:{url:null},backlog:{id:"t2",repo:null,title:"Queued next"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "repo-less backlog snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures == []
      and (.projects[] | select(.name == "alpha")
        | (.landed | map(.id)) == ["t1"]
          and .counts.landed == 1
          and .finished == []
          and .counts.finished == 0
          and (.waiting | map(.id) | index("t2") != null)
          and .status == "waiting")
  ' >/dev/null || fail "a repo-less backlog row was dropped and its task mislabelled: $out"
  pass "a backlog row with no repo metadata follows its task to that project"
}

test_main_state_reaching_no_registered_project_is_disclosed() {
  local home epoch out
  home=$(make_home main-unregistered)
  write_fleet_fixture "$home"
  jq '
    .backlog.records = [
      {structured:true,id:"g1",repo:"gizmo",title:"Gizmo work",state:"queued",since:"2020-01-01",
       captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks = [(.tasks[] | select(.id == "alpha-work") | .project = "gizmo" | .backlog.repo = "gizmo")]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "unregistered-main snapshot failed"
  printf '%s' "$out" | jq -e '
    (.disclosures | any(
       .surface == "main backlog rows that reach no registered project: 1"
       and .reveal == "register the project in data/projects.md, or add (repo: <project>) to the row"))
      and (.disclosures | any(
       .surface == "main tasks that reach no registered project: 1"))
      and ([.projects[] | select(.status != "idle_queued")] | length) == 0
  ' >/dev/null || fail "main state outside every registered project vanished silently: $out"
  pass "main backlog rows and tasks that reach no registered project are disclosed"
}

test_secondmate_holds_truncation_is_disclosed() {
  local home epoch out
  home=$(make_home holds-truncation)
  write_fleet_fixture "$home"
  jq '
    .secondmate_current.records |= map(
      if .id == "delta-mate" then
        .holds = [range(0;20) as $i | {id:("h" + ($i|tostring)),title:("Hold " + ($i|tostring)),
          repo:"delta",reason:"Waiting on vendor"}]
        | .counts = {active_children:1,decisions_open:0,holds:25,queued:0,landed:1,endpoints:1}
        | .omitted = [{surface:"holds",count:5}]
      else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "holds-truncation snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(
      .surface == "secondmate delta-mate holds omitted by the bounded home read: 5"
      and .reveal == "raise FM_SNAPSHOT_SECONDMATE_QUEUED")
  ' >/dev/null || fail "a truncated secondmate holds list was not disclosed: $out"
  pass "a bounded secondmate holds read is disclosed with the bound that caused it"
}

test_home_summary_discloses_its_own_holds_truncation() {
  local home summary
  home="$TMP_ROOT/holds-producer"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  {
    printf '# Backlog\n\n## In flight\n\n## Queued\n'
    for i in $(seq 1 25); do
      printf -- '- [ ] q%02d - Held item %02d (repo: alpha) (kind: ship) (hold: waiting on vendor) (hold-kind: external)\n' "$i" "$i"
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  summary=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_SNAPSHOT_NOW=2026-08-26T00:00:00Z FM_SNAPSHOT_NOW_EPOCH=1787000000 \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) \
    || fail "secondmate home summary failed"
  printf '%s' "$summary" | jq -e '
    (.holds | length) == 20
      and .counts.holds == 25
      and (.omitted | any(.surface == "holds" and .count == 5))
  ' >/dev/null || fail "the home summary truncated holds without disclosing the drop: $summary"
  pass "the secondmate home summary discloses its own holds truncation"
}

test_torn_down_done_rows_do_not_raise_the_incomplete_banner() {
  local home epoch out
  home=$(make_home done-history)
  write_fleet_fixture "$home"
  : > "$home/state/a-now.meta"
  : > "$home/state/a-now.status"
  jq --arg home "$home" '
    .backlog.records = [
      {structured:true,id:"old1",repo:null,title:"Shipped last month",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/alpha/pull/9",completion:{date:"2026-08-20"}},
      {structured:true,id:"a-now",repo:"alpha",title:"Current work",state:"in_flight",
       since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks = [
        {id:"a-now",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/a-now.meta"),present:true},
                status_log:{path:($home + "/state/a-now.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"working",source:"fixture",detail:"Building"},
         hints:{open_decisions:[]},pr:{url:null},backlog:{id:"a-now",repo:"alpha",title:"Current work"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "done-history snapshot failed"
  printf '%s' "$out" | jq -e '.disclosures == []' >/dev/null \
    || fail "torn-down done history raised the fleet-incomplete banner: $out"

  jq '.backlog.records |= map(if .id == "old1" then .state = "queued" | .since = "2020-01-01"
        | .captain_actionable = false | .unresolved_blocker_ids = [] else . end)' \
    "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "open-row snapshot failed"
  printf '%s' "$out" | jq -e '
    .disclosures | any(.surface == "main backlog rows that reach no registered project: 1")
  ' >/dev/null || fail "an open unreachable backlog row stopped being disclosed: $out"
  pass "only open backlog rows a reader can act on raise the incomplete banner"
}

test_done_row_naming_an_unregistered_project_is_disclosed() {
  local home epoch out
  home=$(make_home done-unregistered)
  write_fleet_fixture "$home"
  : > "$home/state/a1.meta"
  : > "$home/state/a1.status"
  jq --arg home "$home" '
    .backlog.records = [
      {structured:true,id:"gz",repo:"gizmo",title:"Gizmo done",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/gizmo/pull/1",completion:{date:"2026-08-21"}},
      {structured:true,id:"old1",repo:null,title:"Shipped last month",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/alpha/pull/9",completion:{date:"2026-08-20"}},
      {structured:true,id:"a1",repo:"alpha",title:"Current work",state:"in_flight",
       since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks = [
        {id:"a1",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/a1.meta"),present:true},
                status_log:{path:($home + "/state/a1.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"working",source:"fixture",detail:"Building"},
         hints:{open_decisions:[]},pr:{url:null},backlog:{id:"a1",repo:"alpha",title:"Current work"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "done-unregistered snapshot failed"
  printf '%s' "$out" | jq -e '
    (.disclosures | length) == 1
      and (.disclosures[0].surface == "main backlog rows that reach no registered project: 1")
  ' >/dev/null || fail "a done row naming an unregistered project was dropped silently, or torn-down history was counted: $out"
  pass "a completed row naming an unregistered project is still disclosed"
}

test_pull_request_list_is_bounded_like_landed() {
  local home epoch out
  home=$(make_home pr-cap)
  write_fleet_fixture "$home"
  jq --arg home "$home" '
    .backlog.records = [range(0;40) as $i | {structured:true,id:("done-" + ($i|tostring)),repo:"alpha",
      title:("Landed " + ($i|tostring)),state:"done",hold_kind:null,
      pr_url:("https://github.com/example/alpha/pull/" + (($i + 1)|tostring)),
      completion:{date:("2026-07-" + (if $i < 9 then "0" else "" end) + (($i + 1)|tostring))}}]
    | .backlog.records += [
        {structured:true,id:"open-now",repo:"alpha",title:"Open work",
         state:"in_flight",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[],
         pr_url:"https://github.com/example/alpha/pull/999"},
        {structured:true,id:"tear",repo:"alpha",title:"Merged, not yet torn down",state:"done",
         hold_kind:null,pr_url:"https://github.com/example/alpha/pull/1000",
         completion:{date:"2020-01-01"}}]
    | .tasks = [
        {id:"tear",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/alpha-work.meta"),present:true},
                status_log:{path:($home + "/state/alpha-work.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],
         current_state:{state:"done",source:"fixture",detail:"run passed: PR merged/closed"},
         hints:{open_decisions:[]},pr:{url:"https://github.com/example/alpha/pull/1000"},
         backlog:{id:"tear",repo:"alpha",title:"Merged, not yet torn down"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "pr-cap snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | (.landed | length) == 5 and .counts.landed == 41
      and (.landed | map(.id)) == ["done-39","done-38","done-37","done-36","done-35"]
      and (.prs | length) == 5 and .counts.prs == 42
      and (.prs | map(.id)) == ["open-now","done-39","done-38","done-37","done-36"]
  ' >/dev/null || fail "the PR list is unbounded, misordered, or ranks landed work as current: $out"
  pass "the pull-request list keeps current work and the newest landings"
}

test_captain_decision_is_not_also_queued_work() {
  local home epoch out
  home=$(make_home decision-vs-queued)
  write_fleet_fixture "$home"
  jq '
    .backlog.records += [{structured:true,id:"alpha-next",repo:"alpha",title:"Real queued work",
      state:"queued",since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "decision-vs-queued snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | (.decisions | any(.id == "alpha-call"))
      and (.queued | map(.id)) == ["alpha-next"]
      and (.queued | any(.id == "alpha-call") | not)
      and (.waiting | any(.id == "alpha-call") | not)
  ' >/dev/null || fail "a captain decision was listed as queued or waiting work too: $out"

  jq '
    .backlog.records |= map(select(.repo != "alpha"))
    | .backlog.records += [{structured:true,id:"a-defer",repo:"alpha",title:"Superseded question",
        state:"queued",since:"2020-01-01",captain_actionable:true,hold_kind:"captain",
        hold_reason:"SUPERSEDED by alpha-new",deferred_marker:true,unresolved_blocker_ids:[]}]
    | .tasks |= map(select(.project != "alpha"))
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "deferred-only snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "idle_queued"
      and .queued == []
      and (.deferred_decisions | map(.id)) == ["a-defer"]
      and .next_step == "No work queued"
  ' >/dev/null || fail "a deferred captain hold was named as the next queued step: $out"
  pass "a captain decision is never also listed as queued work"
}

test_captain_held_done_row_is_neither_landed_nor_a_pr_link() {
  local home epoch out
  home=$(make_home captain-held-done)
  write_fleet_fixture "$home"
  jq --arg home "$home" '
    .backlog.records = [
      {structured:true,id:"cap",repo:"alpha",title:"Captain transfer record",state:"done",
       hold_kind:"captain",hold_reason:"handed to the captain",
       pr_url:"https://github.com/example/alpha/pull/1",completion:{date:"2026-08-25"}},
      {structured:true,id:"old",repo:"alpha",title:"Older landing",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/alpha/pull/3",completion:{date:"2026-01-01"}}]
    | .tasks = [
        {id:"cap",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/alpha-work.meta"),present:true},
                status_log:{path:($home + "/state/alpha-work.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"done",source:"fixture",detail:"handed over"},
         hints:{open_decisions:[]},pr:{url:"https://github.com/example/alpha/pull/1"},
         backlog:{id:"cap",repo:"alpha",title:"Captain transfer record"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "captain-held-done snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | (.landed | map(.id)) == ["old"] and .counts.landed == 1
      and (.prs | map(.id)) == ["old"] and .counts.prs == 1
      and (.resolved_decisions | map(.id)) == ["cap"]
      and .counts.resolved_decisions == 1
      and .resolved_decisions[0].summary == "handed to the captain"
  ' >/dev/null || fail "a captain-held done row reached the wrong surface, or vanished: $out"
  pass "a resolved captain decision surfaces under decisions, not landed work or PR history"
}

test_captain_held_in_flight_row_keeps_its_pr_link() {
  local home epoch out
  home=$(make_home captain-held-in-flight)
  write_fleet_fixture "$home"
  jq '
    .backlog.records = [
      {structured:true,id:"a-hold",repo:"alpha",title:"Held for the captain",state:"in_flight",
       current_role:"held",hold_kind:"captain",hold_reason:"Which rollout order?",
       captain_actionable:false,unresolved_blocker_ids:[],
       pr_url:"https://github.com/example/alpha/pull/11"},
      {structured:true,id:"a-old",repo:"alpha",title:"Older landing",state:"done",hold_kind:null,
       pr_url:"https://github.com/example/alpha/pull/3",completion:{date:"2026-01-01"}}]
    | .tasks = []
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "captain-held in-flight snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "waiting"
      and (.waiting | map(.id)) == ["a-hold"]
      and (.prs | map(.id)) == ["a-hold","a-old"]
      and .counts.prs == 2
  ' >/dev/null || fail "a still-in-flight captain hold lost its PR link: $out"
  pass "a captain hold that is still in flight keeps its PR link"
}

test_waiting_work_is_not_repeated_under_queued_next() {
  local home epoch out
  home=$(make_home waiting-vs-queued)
  write_fleet_fixture "$home"
  jq '
    .backlog.records = [
      {structured:true,id:"a-block",repo:"alpha",title:"Blocked on the vendor",state:"queued",
       since:"2020-01-01",captain_actionable:false,hold_kind:"external",
       hold_reason:"Vendor SDK is not released",unresolved_blocker_ids:["vendor"]},
      {structured:true,id:"a-free",repo:"alpha",title:"Ready to start",state:"queued",
       since:"2020-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks = []
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .active_children = []
          | .landed = []
          | .holds = [{id:"d-hold",title:"Delta hold",repo:"delta",reason:"Waiting on vendor"}]
          | .queued = [{id:"d-hold",title:"Delta hold",repo:"delta",captain_actionable:false},
                       {id:"d-next",title:"Delta next",repo:"delta",captain_actionable:false}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "waiting-vs-queued snapshot failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "alpha")
      | (.waiting | map(.id)) == ["a-block"]
        and (.queued | map(.id)) == ["a-free"]
        and .counts.waiting == 1 and .counts.queued == 1)
      and (.projects[] | select(.name == "delta")
        | (.waiting | map(.id)) == ["d-hold"]
          and (.queued | map(.id)) == ["d-next"])
  ' >/dev/null || fail "waiting work was repeated under queued next: $out"
  pass "waiting work appears only under waiting, never also under queued next"
}

test_date_deferred_decision_waits_until_it_is_due() {
  local home epoch out
  home=$(make_home deferred-until)
  write_fleet_fixture "$home"
  : > "$home/state/a-later.meta"
  : > "$home/state/a-later.status"
  jq --arg home "$home" '
    .backlog.records = [
      {structured:true,id:"a-later",repo:"alpha",title:"Pick the rollout window",state:"queued",
       since:"2020-01-01",hold_kind:"captain",hold_reason:"Revisit after the vendor ships",
       hold_until:"2099-01-01",captain_actionable:false,unresolved_blocker_ids:[]}]
    | .tasks = [
        {id:"a-later",kind:"ship",project:"alpha",
         paths:{meta:{path:($home + "/state/a-later.meta"),present:true},
                status_log:{path:($home + "/state/a-later.status"),present:true},
                worktree:{path:null,present:false},home:{path:null,present:false},report:{path:null,present:false}},
         secondmate_projects:[],current_state:{state:"parked",source:"fixture",detail:"Captain choice"},
         hints:{open_decisions:[]},pr:{url:null},
         backlog:{id:"a-later",repo:"alpha",title:"Pick the rollout window"}}]
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  epoch=$(date +%s)
  out=$(run_snapshot "$home" "$epoch") || fail "date-deferred snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "waiting"
      and (.waiting | map(.id)) == ["a-later"]
      and .decisions == [] and .counts.decisions == 0
      and .queued == []
  ' >/dev/null || fail "a decision deferred to a future date did not wait: $out"

  jq '.backlog.records |= map(if .id == "a-later" then
        .hold_until = "2020-01-01" | .captain_actionable = true else . end)' \
    "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  out=$(run_snapshot "$home" "$epoch") || fail "now-due snapshot failed"
  printf '%s' "$out" | jq -e '
    .projects[] | select(.name == "alpha")
    | .status == "needs_attention"
      and (.decisions | map(.id)) == ["a-later"]
      and .waiting == [] and .queued == []
  ' >/dev/null || fail "a decision that became due did not move to decisions only: $out"
  pass "a date-deferred decision waits until due, then appears only under decisions"
}

extract_payload() {  # <board>
  sed -n '/<script id="project-dashboard-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

write_board_driver() {  # <path>
  cat > "$1" <<'JS'
const fs = require("fs");
const [boardPath, hash, wantSelected] = process.argv.slice(2);
const html = fs.readFileSync(boardPath, "utf8");

class El {
  constructor(tag) {
    this.tagName = tag; this.children = []; this._class = ""; this._text = "";
    this.dataset = {}; this.attrs = {}; this.style = {};
    this.classList = {
      toggle: (name, on) => {
        const set = new Set(this._class.split(/\s+/).filter(Boolean));
        if (on) set.add(name); else set.delete(name);
        this._class = [...set].join(" ");
      }
    };
  }
  get className() { return this._class; }
  set className(v) { this._class = v || ""; }
  get textContent() { return this._text; }
  set textContent(v) { this._text = v === undefined || v === null ? "" : String(v); this.children = []; }
  append(...nodes) { nodes.forEach(n => this.children.push(n)); }
  insertBefore(node, ref) {
    const i = this.children.indexOf(ref);
    this.children.splice(i < 0 ? this.children.length : i, 0, node);
  }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k]; }
  addEventListener() {}
  _walk(out) { this.children.forEach(c => { out.push(c); c._walk(out); }); return out; }
  _matches(sel) { return this._class.split(/\s+/).includes(sel.slice(1)); }
  querySelectorAll(sel) { return this._walk([]).filter(n => n._matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  text() {
    return (this._text || "") + this.children.map(c => c.text()).join(" ");
  }
}

const root = new El("body");
const byId = {};
["project-dashboard-data", "project-grid", "generated", "stats"].forEach(id => {
  byId[id] = new El("div");
});
const main = new El("main"); main.className = "pd-main";
main.append(byId.generated, byId.stats, byId["project-grid"]);
root.append(byId["project-dashboard-data"], main);

const payload = html
  .split('<script id="project-dashboard-data" type="application/json">')[1]
  .split("</script>")[0];
byId["project-dashboard-data"]._text = payload;

global.document = {
  getElementById: id => byId[id] || null,
  createElement: tag => new El(tag),
  querySelector: sel => (sel === ".pd-main" ? main : root.querySelector(sel)),
  querySelectorAll: sel => root.querySelectorAll(sel)
};
global.location = { hash, pathname: "/project-dashboard.html", search: "" };
global.history = { replaceState: (a, b, url) => { global.location._replaced = url; } };

const script = html.split("</script>").slice(-2)[0].split("<script>").pop();
new Function(script)();

const cards = root.querySelectorAll(".pd-card");
const selected = cards.filter(c => c._class.includes("is-selected")).map(c => c.dataset.project);
const result = {
  cards: cards.map(c => c.dataset.project),
  selected,
  banner: root.querySelectorAll(".pd-disclosures").map(b => b.text().trim()),
  meta: cards.map(c => ({
    project: c.dataset.project,
    meta: (c.querySelector(".pd-detail-meta") || { text: () => "" }).text(),
    warn: c.querySelectorAll(".pd-meta-warn").map(w => w.text()),
    panels: c.querySelectorAll(".pd-panel").map(panel => (panel.children[0] || { textContent: "" }).textContent),
    items: c.querySelectorAll(".pd-panel").map(panel => ({
      title: (panel.children[0] || { textContent: "" }).textContent,
      rows: panel.querySelectorAll(".pd-item").map(r => r.text().trim())
    }))
  }))
};
if (wantSelected !== undefined && JSON.stringify(selected) !== JSON.stringify(wantSelected === "" ? [] : [wantSelected])) {
  console.error("selection mismatch: " + JSON.stringify(selected));
  process.exit(3);
}
console.log(JSON.stringify(result));

JS
}

build_board_for_render() {  # <home>
  local home=$1 payload
  payload="$home/dashboard.json"
  run_snapshot "$home" "$(date +%s)" > "$payload" || return 1
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/lavish-axi"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" build "$payload" >/dev/null || return 1
  printf '%s\n' "$home/.lavish/project-dashboard.html"
}

test_board_renders_every_card_and_its_disclosures() {
  local home board driver out
  command -v node >/dev/null 2>&1 || { pass "skipped board rendering: node not found"; return 0; }
  home=$(make_home board-render)
  write_fleet_fixture "$home"
  jq '
    .secondmate_current.truncated = 2
    | .secondmate_current.registry = {available:true,complete:false,records_truncated:false,
        input_truncated:false,reason:null}
    | .secondmate_current.records = []
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"
  board=$(build_board_for_render "$home") || fail "board build for rendering failed"
  driver="$home/board-driver.js"
  write_board_driver "$driver"

  out=$(node "$driver" "$board" "#%zz" "") \
    || fail "a malformed URL fragment stopped the board from rendering: $out"
  printf '%s' "$out" | jq -e '
    (.cards) == ["alpha","bravo","beta","gamma","delta","epsilon","zeta"]
      and .selected == []
      and (.banner | length) == 1
      and (.banner[0] | contains("registered secondmates omitted by the snapshot bound: 2"))
      and (.meta | any(.project == "delta" and (.meta | contains("delta-mate (state unavailable)"))))
  ' >/dev/null || fail "board rendering lost cards, disclosures, or unavailable-secondmate state: $out"

  out=$(node "$driver" "$board" "#delta" "delta") \
    || fail "the board did not expand the requested project: $out"
  printf '%s' "$out" | jq -e '
    .meta[] | select(.project == "alpha") | .items[]
    | select(.title == "Pull requests") | .rows
    | any(contains("Alpha shipped") and contains("main"))
  ' >/dev/null || fail "a note-less item lost its owner attribution: $out"
  pass "the board renders every card, its disclosures, and survives a malformed fragment"
}

test_board_caps_landed_visibly_and_honours_the_reader_fragment() {
  local home board driver out payload
  command -v node >/dev/null 2>&1 || { pass "skipped board caps: node not found"; return 0; }
  home=$(make_home board-caps)
  write_fleet_fixture "$home"
  jq '
    .backlog.records += [range(0;7) as $i | {structured:true,id:("alpha-done-" + ($i|tostring)),repo:"alpha",
      title:("Landed " + ($i|tostring)),state:"done",hold_kind:null,
      pr_url:("https://github.com/example/alpha/pull/1" + ($i|tostring)),
      completion:{date:("2026-08-1" + ($i|tostring))}}]
    | .tasks |= map(if .id == "delta-mate" then .secondmate_projects = ["delta"] else . end)
    | .secondmate_current.records |= map(
        if .id == "delta-mate" then
          .projects = ["delta"]
          | .active_children = [{id:"cross-child",title:"Gamma rollout",repo:"gamma",
              state:"working",doing:"Working on gamma"}]
        else . end)
  ' "$home/fleet.json" > "$home/fleet.tmp"
  mv "$home/fleet.tmp" "$home/fleet.json"

  payload="$home/dashboard.json"
  run_snapshot "$home" "$(date +%s)" --select delta > "$payload" || fail "board caps snapshot failed"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/lavish-axi"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" build "$payload" >/dev/null \
    || fail "board caps build failed"
  board="$home/.lavish/project-dashboard.html"
  driver="$home/board-driver.js"
  write_board_driver "$driver"

  out=$(node "$driver" "$board" "" "delta") || fail "the --select seed was not honoured: $out"
  printf '%s' "$out" | jq -e '
    (.meta[] | select(.project == "alpha") | .panels | any(startswith("Recently landed (5 of 8)")))
      and (.meta[] | select(.project == "alpha") | .panels | any(startswith("Pull requests (5 of 8)")))
      and ((.meta[] | select(.project == "alpha") | .items[]
            | select(.title | startswith("Recently landed")) | .rows
            | map(sub(" [0-9]{4}-[0-9]{2}-[0-9]{2} . main$"; ""))) as $landed_titles
           | (.meta[] | select(.project == "alpha") | .items[]
              | select(.title | startswith("Pull requests")) | .rows
              | map(sub(" main$"; ""))) == $landed_titles)
  ' >/dev/null || fail "the landed list was capped without saying so: $out"
  printf '%s' "$out" | jq -e '
    (.meta[] | select(.project == "gamma")
      | (.meta | contains("delta-mate")) and .warn == [])
  ' >/dev/null || fail "a mate working outside its clone list was flagged as a failure: $out"

  out=$(node "$driver" "$board" "#alpha" "alpha") \
    || fail "the reader fragment lost to the build-time selection: $out"
  out=$(node "$driver" "$board" "#not-a-project" "delta") \
    || fail "an unknown fragment did not fall back to the built-in selection: $out"
  pass "the board discloses the landed cap and lets the reader fragment win"
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
test_finished_task_is_reported_verbatim_never_interpreted
test_unreadable_task_state_is_disclosed_not_idle
test_a_hold_never_hides_another_open_decision
test_blank_detail_never_renders_a_blank_next_step
test_one_captain_hold_is_one_decision
test_blocked_status_fold_is_not_a_captain_decision
test_backlog_order_survives_deduplication
test_deferred_captain_hold_is_disclosed_not_escalated
test_captain_hold_next_step_keeps_the_question
test_repo_labelled_secondmate_work_attributes_to_that_project
test_bounded_snapshot_drops_are_disclosed_board_wide
test_per_home_bounded_drops_are_disclosed
test_one_hold_reason_absorbs_at_most_one_fold
test_finished_non_https_pr_link_does_not_fail_the_board
test_unattributable_item_escalates_only_to_its_own_kind
test_secondmate_reaching_no_project_is_disclosed
test_state_reaching_no_card_is_disclosed_whatever_the_clone_list
test_next_step_names_the_item_that_set_the_status
test_unattributable_deferred_and_blocked_rows_do_not_paint_cards_red
test_held_in_flight_backlog_row_reaches_the_card_without_task_metadata
test_invalid_main_inventory_is_disclosed
test_stranded_count_counts_each_row_once
test_repo_less_backlog_row_follows_its_task
test_main_state_reaching_no_registered_project_is_disclosed
test_secondmate_holds_truncation_is_disclosed
test_home_summary_discloses_its_own_holds_truncation
test_torn_down_done_rows_do_not_raise_the_incomplete_banner
test_done_row_naming_an_unregistered_project_is_disclosed
test_pull_request_list_is_bounded_like_landed
test_captain_decision_is_not_also_queued_work
test_captain_held_done_row_is_neither_landed_nor_a_pr_link
test_captain_held_in_flight_row_keeps_its_pr_link
test_date_deferred_decision_waits_until_it_is_due
test_waiting_work_is_not_repeated_under_queued_next
test_attention_next_step_is_an_action_not_a_bare_title
test_unattributable_secondmate_state_is_disclosed
test_registered_secondmate_without_a_task_still_owns_its_projects
test_live_secondmate_owner_activity_defeats_stale_risk
test_non_https_pr_link_discloses_itself_without_failing_the_board
test_stale_risk_is_strictly_older_than_eight_days
test_selected_project_payload_is_validated
test_bounded_secondmate_state_keeps_registered_ownership_visible
test_board_build_is_stable_read_only_and_selection_preserving
test_board_renders_every_card_and_its_disclosures
test_board_caps_landed_visibly_and_honours_the_reader_fragment
