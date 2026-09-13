#!/usr/bin/env bash
# Behavior tests for the static task-status page projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE="$ROOT/bin/fm-status-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-page)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/projects"
  printf '%s\n' "$home"
}

make_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

write_task() {  # <home> <id> <title> <harness> <model> <status>
  local home=$1 id=$2 title=$3 harness=$4 model=$5 status=$6
  mkdir -p "$home/projects/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=test:fm-$id" \
    "worktree=$home/projects/$id" \
    "project=sample" \
    "harness=$harness" \
    "model=$model" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s\n' "$status" > "$home/state/$id.status"
  printf '%s\n' "- [ ] $id - $title (repo: sample) (kind: ship)" >> "$home/data/backlog.md"
}

render() {  # <home> <fakebin>
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    FM_STATUS_PAGE_NOW=2026-08-02T00:05:00Z FM_STATUS_PAGE_OUTPUT="$home/status-page.html" \
    "$PAGE"
}

render_fixture() {  # <home> <fakebin> <tasks-json>
  local home=$1 fakebin=$2 tasks=$3
  cat > "$home/fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
cat "$tasks"
SH
  cat > "$home/bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"secondmates":[]}'
SH
  chmod +x "$home/fleet-snapshot.sh" "$home/bearings-snapshot.sh"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATUS_PAGE_NOW=2026-08-02T00:05:00Z \
    FM_STATUS_PAGE_OUTPUT="$home/status-page.html" \
    FM_STATUS_PAGE_FLEET_SNAPSHOT="$home/fleet-snapshot.sh" \
    FM_STATUS_PAGE_BEARINGS_SNAPSHOT="$home/bearings-snapshot.sh" "$PAGE"
}

test_page_groups_tasks_and_labels_status_age_sources() {
  local home fakebin html tasks
  home=$(make_home groups)
  fakebin=$(make_fakebin "$home")
  tasks="$home/tasks.json"
  jq -n '{tasks:[
    {id:"decision",code:"A2-eng",backlog:{title:"Choose status colors",repo:"sample"},harness:"claude",model:"sonnet",current_state:{state:"parked"},hints:{open_decisions:[{verb:"needs-decision"}]},paths:{status_log:{last_event:{raw:"needs-decision: 2026-08-02T00:03:00Z choose a palette"}}}},
    {id:"blocked",backlog:{title:"Repair source owner",repo:"sample"},harness:"codex",model:"gpt-5.6-luna",current_state:{state:"blocked"},hints:{open_decisions:[]},paths:{status_log:{mtime_epoch:1785628800,last_event:{raw:"blocked: waiting for the source owner"}}}},
    {id:"working",backlog:{title:"Render the projection",repo:"sample"},harness:"cursor-agent",model:"composer-2.5",current_state:{state:"working"},hints:{open_decisions:[]},paths:{status_log:{mtime_epoch:1785628800,last_event:{raw:"working: rendering cards"}}}},
    {id:"paused",backlog:{title:"Await upstream release",repo:"sample"},harness:"pi",model:"qwen3.8-max",current_state:{state:"paused"},hints:{open_decisions:[]},paths:{status_log:{mtime_epoch:1785628800,last_event:{raw:"paused: upstream release window"}}}},
    {id:"done",backlog:{title:"Open review",repo:"sample"},harness:"codex",model:"gpt-5.6-sol",current_state:{state:"done"},hints:{open_decisions:[]},paths:{status_log:{mtime_epoch:1785628800,last_event:{raw:"done: PR awaiting merge"}}}},
    {id:"mystery",backlog:{title:"Keep unknown visible",repo:"sample"},harness:"codex",model:"gpt-5.6-luna",current_state:{state:"unknown"},hints:{open_decisions:[]},paths:{status_log:{mtime_epoch:1785628800,last_event:{raw:"mystery: still observable"}}}},
    {id:"stale",backlog:{title:"Reconciled state wins",repo:"sample"},harness:"claude",model:"sonnet",current_state:{state:"working"},hints:{open_decisions:[]},paths:{status_log:{last_event:{raw:"done: an old terminal event"}}}},
    {id:"failed",backlog:{title:"Failed work needs attention",repo:"sample"},harness:"codex",model:"gpt-5.6-luna",current_state:{state:"failed"},hints:{open_decisions:[]},paths:{status_log:{last_event:{raw:"failed: retry required"}}}}
  ]}' > "$tasks"
  render_fixture "$home" "$fakebin" "$tasks" || fail "status-page fixture render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "Needs decision <span>1</span>" "needs-decision count missing"
  assert_contains "$html" "Blocked <span>2</span>" "blocked count missing"
  assert_contains "$html" "Working <span>2</span>" "working count missing"
  assert_contains "$html" "Paused <span>1</span>" "paused count missing"
  assert_contains "$html" "Done awaiting merge <span>1</span>" "done count missing"
  assert_contains "$html" "Unknown <span>1</span>" "unknown count missing"
  assert_contains "$html" "[A2-eng] Choose status colors" "stored code was not shown with the task title"
  assert_contains "$html" "claude / sonnet" "agent tuple missing"
  assert_contains "$html" "2m · timestamp" "durable timestamp age label missing"
  assert_contains "$html" "5m · status file mtime" "mtime age label missing"
  assert_contains "$html" "Keep unknown visible" "unknown task was dropped"
  assert_contains "$html" "Reconciled state wins" "reconciled task missing"
  assert_contains "$html" "Failed work needs attention" "failed task missing"
  pass "status page renders status columns, counts, and age sources"
}

test_page_uses_six_tracks_and_accessible_dark_badges() {
  local home fakebin html
  home=$(make_home presentation)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
EOF
  fakebin=$(make_fakebin "$home")
  render "$home" "$fakebin" || fail "presentation render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "grid-template-columns:repeat(6,minmax(230px,1fr))" "six status columns do not have six desktop tracks"
  assert_contains "$html" "--badge-ink:#10151d" "dark badge foreground is not locked to an AA contrast color"
  pass "status page uses six tracks and an accessible dark badge foreground"
}

test_page_buckets_only_canonical_current_states() {
  local home fakebin html tasks
  home=$(make_home canonical-states)
  fakebin=$(make_fakebin "$home")
  tasks="$home/tasks.json"
  jq -n '{tasks:[
    {id:"hint",backlog:{title:"Open decision wins"},current_state:{state:"working"},hints:{open_decisions:[{verb:"needs-decision"}]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}},
    {id:"parked",backlog:{title:"Parked task"},current_state:{state:"parked"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"working",raw:"working: historical"}}}},
    {id:"blocked",backlog:{title:"Blocked task"},current_state:{state:"blocked"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}},
    {id:"working",backlog:{title:"Working task"},current_state:{state:"working"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}},
    {id:"paused",backlog:{title:"Paused task"},current_state:{state:"paused"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}},
    {id:"done",backlog:{title:"Done task"},current_state:{state:"done"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"working",raw:"working: historical"}}}},
    {id:"failed",backlog:{title:"Failed task"},current_state:{state:"failed"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}},
    {id:"unknown",backlog:{title:"Unknown task"},current_state:{state:"unknown"},hints:{open_decisions:[]},paths:{status_log:{last_event:{state:"done",raw:"done: historical"}}}}
  ]}' > "$tasks"
  render_fixture "$home" "$fakebin" "$tasks" || fail "canonical-state fixture render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "Needs decision <span>2</span>" "parked or decision-hint task was not bucketed from current state"
  assert_contains "$html" "Blocked <span>2</span>" "failed current state was not mapped to blocked"
  assert_contains "$html" "Working <span>1</span>" "working current state was not retained"
  assert_contains "$html" "Paused <span>1</span>" "paused current state was not retained"
  assert_contains "$html" "Done awaiting merge <span>1</span>" "done current state was not retained"
  assert_contains "$html" "Unknown <span>1</span>" "unknown current state fell back to historical done"
  pass "status page buckets only decision hints and canonical current states"
}

test_page_escapes_hostile_task_data() {
  local home fakebin html
  home=$(make_home escaping)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
EOF
  write_task "$home" hostile '<script>alert("x")</script> & "quotes"' codex gpt-5.6-luna \
    'working: <img src=x onerror="alert(1)"> & "quoted"'
  fakebin=$(make_fakebin "$home")
  render "$home" "$fakebin" || fail "hostile-data render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &quot;quotes&quot;" "hostile title was not escaped"
  assert_contains "$html" "&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &quot;quoted&quot;" "hostile status was not escaped"
  assert_not_contains "$html" "<script>alert" "raw script markup reached the page"
  assert_not_contains "$html" "<img src=x onerror=" "raw event-handler markup reached the page"
  pass "status page renders hostile task data as inert text"
}

test_page_includes_agent_seat_rows() {
  local home mate fakebin html
  home=$(make_home seats)
  mate="$TMP_ROOT/agent-seat-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
EOF
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Fixture\n' > "$mate/AGENTS.md"
  printf 'observability\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  jq -n --arg home "$mate" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-08-02T00:00:00Z",
    generated_epoch:1785628800,
    home:$home,
    valid:true,
    reason:null,
    invalidity:{kind:null,ids:[]},
    state:"no_active_work",
    active_children:[],
    decisions_open:[],
    holds:[],
    queued:[],
    landed:[],
    endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},
    omitted:[]
  }' > "$mate/state/home-summary.json"
  printf -- '- observability - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-08-02)\n' \
    "$mate" > "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  render "$home" "$fakebin" || fail "status-page agent-seat render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "Agent seats" "agent-seat section missing"
  assert_contains "$html" "observability" "agent-seat row missing"
  assert_contains "$html" "no_active_work" "agent-seat state missing"
  pass "status page includes agent-seat rows and state"
}

test_page_handles_snapshot_larger_than_argv() {
  local home fakebin html payload
  home=$(make_home large-snapshot)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
EOF
  write_task "$home" large "Large status payload" codex gpt-5.6-luna 'working: small initial status'
  payload=$(dd if=/dev/zero bs=1200000 count=1 2>/dev/null | tr '\0' x)
  printf 'working: %s\n' "$payload" > "$home/state/large.status"
  fakebin=$(make_fakebin "$home")

  render "$home" "$fakebin" || fail "large snapshot render failed"
  html=$(<"$home/status-page.html")
  assert_contains "$html" "Large status payload" "large snapshot task was dropped"
  pass "status page handles a snapshot larger than the argument limit"
}

test_page_groups_tasks_and_labels_status_age_sources
test_page_uses_six_tracks_and_accessible_dark_badges
test_page_buckets_only_canonical_current_states
test_page_escapes_hostile_task_data
test_page_includes_agent_seat_rows
test_page_handles_snapshot_larger_than_argv
