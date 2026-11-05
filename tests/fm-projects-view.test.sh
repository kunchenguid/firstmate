#!/usr/bin/env bash
# Behavior tests for bin/fm-projects-view.sh: the fm-projects.v1 config parser,
# deterministic project grouping, the per-project counters, the add-a-task and
# correct-this actions, page publication, and the opt-in automatic refresh.
# Every case drives the script's public commands against fixture homes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-projects-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-projects-view)
NOW=2026-11-05T12:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '%s\n' "$home"
}

write_config() {  # <home>
  cat > "$1/config/projects.json" <<'JSON'
{
  "schema": "fm-projects.v1",
  "window_days": 30,
  "projects": [
    {"id": "store-launch", "name": "Store launch", "color": "#ef4444",
     "repos": ["store-app", "shared"], "match": ["store-*", "launch-*"]},
    {"id": "platform", "name": "Platform", "repos": ["shared"], "match": ["platform-*"]}
  ]
}
JSON
}

hold() {  # <reason>
  printf '(hold: fm-hold-v1:%s) (hold-kind: captain)' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

write_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] store-build - Build the store package (repo: store-app) (kind: ship) (since 2026-11-01)
## Queued
- [ ] store-ask - Submit to the store? (repo: store-app) (kind: captain) (since 2026-11-04) $(hold 'The listing is ready')
  Captain hold set: 2026-11-04T10:00:00Z
- [ ] old-ask - Pick a vendor (repo: shared) (kind: captain) (since 2026-10-01) $(hold 'Two vendors are left')
  Captain hold set: 2026-10-01T10:00:00Z
  Project: store-launch
- [ ] later-ask - Revisit pricing (since 2026-11-01) $(hold 'After the launch') (hold-until: 2026-12-01)
  Captain hold set: 2026-11-01T10:00:00Z
  Project: platform
- [ ] platform-next - Platform cleanup blocked-by: store-build (since 2026-11-02)
- [ ] shared-thing - Shared repo work (repo: shared) (since 2026-11-02)
- [ ] launch-x - Launch prep (repo: other-repo) (since 2026-11-02)
  Project: platform
- [ ] orphan-x - Nobody claims this (since 2026-11-02)
- [ ] bogus-p - Names an unknown project (repo: store-app) (since 2026-11-02)
  Project: nope
## Done
- [x] store-done - Shipped the popup (repo: store-app) (kind: ship) (done 2026-11-03)
  local main
- [x] store-old - Old work (repo: store-app) (kind: ship) (done 2026-09-01)
  local main
- [x] store-q - Answered question (repo: store-app) (kind: captain) (done 2026-11-03)
EOF
  cat > "$1/data/done-archive.md" <<'EOF'
## Archived 2026-08-01
- [x] store-ancient - Ancient work (repo: store-app) (kind: ship) (done 2026-07-30)
  local main

## Archived 2026-10-20
- [x] store-arch - Archived ship (repo: store-app) (kind: ship) (done 2026-10-19)
  local main
EOF
}

fixture_home() {  # <name>
  local home
  home=$(make_home "$1")
  write_config "$home"
  write_backlog "$home"
  printf '%s\n' "$home"
}

model_of() {  # <home> [model args...]
  local home=$1
  shift
  FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" bash "$VIEW" model "$@"
}

# --- config parser -------------------------------------------------------------

test_check_accepts_a_valid_config() {
  local home out
  home=$(fixture_home check-ok)
  out=$(FM_HOME="$home" bash "$VIEW" check) || fail "check refused a valid config"
  assert_equals "ok: 2 projects" "$out" "check reports the project count"
  pass "check accepts a valid fm-projects.v1 config"
}

test_check_refuses_missing_and_malformed_configs() {
  local home rc bad
  home=$(make_home check-bad)
  rc=0; FM_HOME="$home" bash "$VIEW" check >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a missing config"
  for bad in \
    'not json' \
    '{"schema":"fm-projects.v2","projects":[{"id":"a","name":"A"}]}' \
    '{"schema":"fm-projects.v1","projects":[]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"a","name":"A"},{"id":"a","name":"B"}]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"A b","name":"A"}]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"a","name":"A","colour":"#fff"}]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"a","name":"A","color":"red"}]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"a","name":"A","match":["a/b"]}]}' \
    '{"schema":"fm-projects.v1","projects":[{"id":"a","name":""}]}' \
    '{"schema":"fm-projects.v1","window_days":0,"projects":[{"id":"a","name":"A"}]}' \
    '{"schema":"fm-projects.v1","extra":1,"projects":[{"id":"a","name":"A"}]}'; do
    printf '%s\n' "$bad" > "$home/config/projects.json"
    rc=0; FM_HOME="$home" bash "$VIEW" check >/dev/null 2>&1 || rc=$?
    expect_code 1 "$rc" "malformed config: $bad"
    rc=0; FM_HOME="$home" bash "$VIEW" model >/dev/null 2>&1 || rc=$?
    expect_code 1 "$rc" "model on malformed config: $bad"
  done
  pass "check and model refuse a missing or malformed config"
}

# --- grouping and counters -----------------------------------------------------

test_membership_follows_body_line_then_glob_then_exclusive_repo() {
  local home model
  home=$(fixture_home grouping)
  model=$(model_of "$home") || fail "model failed"
  printf '%s' "$model" | jq -e '
    def ids($p; $g): [.projects[] | select(.id == $p) | (.[$g] | if type == "object" then .rows else . end)[] | .id] | sort;
    ids("store-launch"; "needs") == ["old-ask", "store-ask"]
    and ids("store-launch"; "moving") == ["store-build"]
    and ids("store-launch"; "next") == ["bogus-p"]
    and ids("platform"; "next") == ["later-ask", "launch-x", "platform-next"]
    and ([.unassigned.rows[].id] | sort) == ["orphan-x", "shared-thing"]
  ' >/dev/null || fail "membership precedence is wrong: $model"
  pass "membership: Project line, then id glob, then a repo exactly one project lists"
}

test_counters_count_captain_waits_and_windowed_done() {
  local home model
  home=$(fixture_home counters)
  model=$(model_of "$home") || fail "model failed"
  printf '%s' "$model" | jq -e '
    (.projects[] | select(.id == "store-launch")) as $s
    | (.projects[] | select(.id == "platform")) as $p
    | $s.counts == {needs: 2, moving: 1, done: 2, next: 1}
    and $p.counts == {needs: 0, moving: 0, done: 0, next: 3}
    and ([$s.done.rows[].id] == ["store-done", "store-arch"])
    and ([$s.needs[] | select(.id == "old-ask") | .aged] == [true])
    and ([$s.needs[] | select(.id == "store-ask") | .question] == ["The listing is ready"])
    and ([$p.next.rows[] | select(.id == "later-ask") | .reason] == ["Back on 2026-12-01"])
    and ([$p.next.rows[] | select(.id == "platform-next") | .reason] == ["After Build the store package"])
    and .totals == {needs: 2, moving: 1, done: 2}
    and .unassigned.count == 2
    and $s.now == "Build the store package"
  ' >/dev/null || fail "counters are wrong: $model"
  pass "counters: live and aged holds need the captain, dated holds wait, done stays in the window"
}

test_secondmate_work_groups_read_only() {
  local home snap model
  home=$(make_home mates)
  write_config "$home"
  snap="$home/snapshot.json"
  jq -n --arg now "$NOW" '{
    schema: "fm-fleet-snapshot.v1", generated: $now,
    backlog: {records: []}, tasks: [],
    secondmate_current: {records: [{
      id: "mate-pc",
      queued: [
        {id: "store-remote-ask", title: "Remote call", hold_bucket: "live", hold_reason: "Pick one", repo: null},
        {id: "platform-remote-next", title: "Remote next", hold_bucket: null, repo: null}
      ],
      decisions_open: [
        {id: "platform-remote-d", verb: "captain-hold", summary: "Remote decision", reason: "Why", hold_bucket: "live"},
        {id: "store-remote-ask", verb: "captain-hold", summary: "Remote call", reason: "Pick one", hold_bucket: "live"},
        {id: "store-status-d", verb: "needs-decision", summary: "Worker question"}
      ],
      active_children: [{id: "store-remote-work", name: "Remote work", repo: "store-app", state: "working"}],
      landed: [{id: "platform-landed", title: "Remote landed", completion: {date: "2026-11-01", verb: "done"}}]
    }]}
  }' > "$snap"
  model=$(model_of "$home" --snapshot "$snap") || fail "model failed"
  printf '%s' "$model" | jq -e '
    (.projects[] | select(.id == "store-launch")) as $s
    | (.projects[] | select(.id == "platform")) as $p
    | $s.counts == {needs: 1, moving: 1, done: 0, next: 0}
    and $p.counts == {needs: 1, moving: 0, done: 1, next: 1}
    and ([$s.needs[], $s.moving[], $p.needs[], $p.done.rows[]] | all(.local == false and .home == "mate-pc"))
    and ($s.moving[0].correctable == false)
  ' >/dev/null || fail "secondmate items grouped wrong: $model"
  pass "secondmate items group by the same rules and carry no actions"
}

test_live_local_work_is_correctable() {
  local home model
  home=$(fixture_home correctable)
  fm_write_meta "$home/state/store-build.meta" "window=x:fm-store-build" "kind=ship" "project=store-app"
  model=$(model_of "$home") || fail "model failed"
  printf '%s' "$model" | jq -e '
    [.projects[] | select(.id == "store-launch") | .moving[] | select(.id == "store-build") | .correctable] == [true]
  ' >/dev/null || fail "live local work is not offered for correction: $model"
  pass "in-progress work with a local task record is correctable"
}

# --- actions -------------------------------------------------------------------

test_add_files_a_queued_item_with_its_project() {
  local home id rc before
  home=$(fixture_home add)
  id=$(FM_HOME="$home" bash "$VIEW" add platform "Tidy the build (fast path)
and say what changed") || fail "add failed"
  case "$id" in platform-*) ;; *) fail "add printed no project-prefixed id: $id" ;; esac
  assert_grep "- [ ] $id - Tidy the build (fast path) and say what changed (repo: shared)" "$home/data/backlog.md" \
    "the new item is queued with the project's only repo"
  assert_grep "  Project: platform" "$home/data/backlog.md" "the body names the project"
  assert_grep "  and say what changed" "$home/data/backlog.md" "the captain's words stay verbatim"
  FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" bash "$VIEW" model \
    | jq -e --arg id "$id" '[.projects[] | select(.id == "platform") | .next.rows[] | select(.id == $id)] | length == 1' >/dev/null \
    || fail "the new item is not grouped under its project"
  before=$(cat "$home/data/backlog.md")
  rc=0; FM_HOME="$home" bash "$VIEW" add nope "x" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "add to an unknown project"
  rc=0; FM_HOME="$home" bash "$VIEW" add platform "   " >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "add with empty words"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "a refused add leaves the backlog untouched"
  pass "add files a queued item under its project and refuses bad input"
}

test_correct_steers_only_live_local_work() {
  local home bin rc
  home=$(fixture_home correct)
  bin="$TMP_ROOT/correct-bin"
  mkdir -p "$bin"
  cp "$VIEW" "$ROOT/bin/fm-landed-lib.sh" "$bin/"
  cat > "$bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$FM_HOME" "$1" "$2" >> "$FM_HOME/sent.log"
SH
  chmod +x "$bin/fm-send.sh"
  fm_write_meta "$home/state/store-build.meta" "window=x:fm-store-build" "kind=ship"
  FM_HOME="$home" bash "$bin/fm-projects-view.sh" correct store-build "Use the dark icon" \
    || fail "correct refused live work"
  assert_equals "$home|store-build|Use the dark icon" "$(cat "$home/sent.log")" \
    "the words reach fm-send for that task in this home"
  rc=0; FM_HOME="$home" bash "$bin/fm-projects-view.sh" correct bogus-p "x" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "correct on queued work"
  rc=0; FM_HOME="$home" bash "$bin/fm-projects-view.sh" correct store-build " " >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "correct with empty words"
  fm_write_meta "$home/state/mate-pc.meta" "window=x:fm-mate-pc" "kind=secondmate"
  rc=0; FM_HOME="$home" bash "$bin/fm-projects-view.sh" correct mate-pc "y" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "correct on a secondmate record"
  rc=0; FM_HOME="$home" bash "$bin/fm-projects-view.sh" correct '../x' "y" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "correct on a non-id"
  assert_equals 1 "$(wc -l < "$home/sent.log" | tr -d ' ')" "refused corrections send nothing"
  pass "correct steers live local work through fm-send and refuses everything else"
}

# --- page publication and refresh ----------------------------------------------

test_build_publishes_an_inert_model_and_skips_unchanged() {
  local home page out tpl
  home=$(fixture_home build)
  awk '{ print } /^## Queued$/ { print "- [ ] store-xss - Ends </script><b>x (repo: store-app) (since 2026-11-02)" }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.new" && mv "$home/data/backlog.md.new" "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" bash "$VIEW" build) || fail "build failed"
  page=$(FM_HOME="$home" bash "$VIEW" path)
  assert_contains "$out" "written" "first build writes"
  assert_equals "$(grep -c '</script>' "$ROOT/.agents/skills/bearings/assets/projects-template.html" | tr -d ' ')" \
    "$(grep -c '</script>' "$page" | tr -d ' ')" "a title cannot close the data block early"
  sed -n '/<script id="projects-data" type="application\/json">/,/<\/script>/p' "$page" | sed '1d;$d' \
    | jq -e '.schema == "fm-projects-view.v1" and any(.projects[].next.rows[]; .title == "Ends </script><b>x")' >/dev/null \
    || fail "the published model does not round-trip"
  out=$(FM_HOME="$home" bash "$VIEW" build) || fail "rebuild failed"
  assert_contains "$out" "unchanged" "an unchanged model leaves the page alone"
  tpl="$TMP_ROOT/template-copy.html"
  { cat "$ROOT/.agents/skills/bearings/assets/projects-template.html"; printf '<!-- changed -->\n'; } > "$tpl"
  out=$(FM_HOME="$home" FM_PROJECTS_VIEW_TEMPLATE="$tpl" bash "$VIEW" build) || fail "template rebuild failed"
  assert_contains "$out" "written" "a changed template republishes"
  pass "build publishes an inert, readable model and skips an unchanged one"
}

# The refresh runs detached under the home's own lock, and its argv does not
# name the fixture root, so wait for it to finish rather than leave it running.
wait_for_refresh() {  # <home>
  local home=$1 page i=0
  page="$home/.lavish/projects.html"
  while [ "$i" -lt 150 ]; do
    if [ -f "$page" ] && [ ! -e "$home/state/.projects-view.dirty" ] \
        && [ ! -e "$home/state/.projects-view.lock" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_refresh_is_opt_in_and_runs_detached() {
  local home page
  home=$(make_home refresh-off)
  write_backlog "$home"
  FM_HOME="$home" bash "$VIEW" refresh || fail "refresh failed without a config"
  sleep 0.3
  assert_absent "$(FM_HOME="$home" bash "$VIEW" path)" "no config builds nothing"
  assert_absent "$home/state/projects-view.log" "no config logs nothing"
  home=$(fixture_home refresh-on)
  page=$(FM_HOME="$home" bash "$VIEW" path)
  FM_HOME="$home" FM_PROJECTS_VIEW_COOLDOWN_SECS=0 bash "$VIEW" refresh || fail "refresh failed"
  FM_HOME="$home" FM_PROJECTS_VIEW_COOLDOWN_SECS=0 bash "$VIEW" refresh || fail "a second refresh failed"
  wait_for_refresh "$home" || fail "refresh never published the page"
  assert_present "$page" "the page is at its stable path"
  pass "refresh does nothing without a config and publishes the page in the background"
}

test_wake_drain_triggers_a_refresh() {
  local home page
  home=$(fixture_home drain)
  page=$(FM_HOME="$home" bash "$VIEW" path)
  FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  wait_for_refresh "$home" || fail "a wake drain did not redraw the projects page"
  assert_present "$page" "the page is at its stable path"
  pass "every wake drain redraws the projects page"
}

published_status() {  # <home> <project> <task>
  sed -n '/<script id="projects-data" type="application\/json">/,/<\/script>/p' "$1/.lavish/projects.html" | sed '1d;$d' \
    | jq -r --arg p "$2" --arg t "$3" '.projects[] | select(.id == $p) | .moving[] | select(.id == $t) | .status'
}

published_has_next() {  # <home> <project> <task>
  sed -n '/<script id="projects-data" type="application\/json">/,/<\/script>/p' "$1/.lavish/projects.html" | sed '1d;$d' \
    | jq -e --arg p "$2" --arg t "$3" 'any(.projects[] | select(.id == $p) | .next.rows[]; .id == $t)' >/dev/null
}

# A live worker the fleet snapshot can observe: a claude-harness task whose
# semantic busy-state record says busy, behind a tmux stand-in that lists its
# window and reports a working pane.
start_live_worker() {  # <home> <task>
  local home=$1 task=$2 fakebin gen
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  mkdir -p "$home/projects/$task"
  fm_write_meta "$home/state/$task.meta" "window=firstmate:fm-$task" "worktree=$home/projects/$task" \
    "project=store-app" "harness=claude" "kind=ship" "mode=ship"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task") || fail "cannot arm the busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$task" busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "cannot record the worker busy"
  printf '%s\n' "$fakebin"
}

idle_worker() {  # <home> <task>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2") || fail "cannot re-arm the busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" --source claude-hook --event stop \
    || fail "cannot record the worker idle"
}

test_routine_refresh_is_local_only_and_rate_limited() {
  local home fakebin full_status
  home=$(fixture_home routine)
  fakebin=$(start_live_worker "$home" store-build)
  PATH="$fakebin:$PATH" FM_HOME="$home" bash "$VIEW" build >/dev/null || fail "full build failed"
  full_status=$(published_status "$home" store-launch store-build)
  assert_equals Working "$full_status" "a full snapshot observes the live worker"

  idle_worker "$home" store-build
  PATH="$fakebin:$PATH" FM_HOME="$home" bash "$VIEW" refresh || fail "refresh failed"
  wait_for_refresh "$home" || fail "the first routine refresh never finished"
  assert_equals Working "$(published_status "$home" store-launch store-build)" \
    "a routine refresh probes no worker and keeps the published status"

  awk '{ print } /^## Queued$/ { print "- [ ] store-late - Late addition (repo: store-app) (since 2026-11-05)" }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.new" && mv "$home/data/backlog.md.new" "$home/data/backlog.md"
  PATH="$fakebin:$PATH" FM_HOME="$home" bash "$VIEW" refresh || fail "second refresh failed"
  sleep 1
  assert_present "$home/state/.projects-view.dirty" "inside the cooldown the view stays dirty"
  assert_present "$home/state/.projects-view.lock" "inside the cooldown the rebuild waits instead of running"
  published_has_next "$home" store-launch store-late && fail "a routine refresh rebuilt inside the cooldown"

  PATH="$fakebin:$PATH" FM_HOME="$home" bash "$VIEW" refresh --full || fail "full refresh failed"
  wait_for_refresh "$home" || fail "the full refresh never finished"
  published_has_next "$home" store-launch store-late || fail "the full refresh did not publish the new item"
  assert_not_equals Working "$(published_status "$home" store-launch store-build)" \
    "the full refresh probes the worker again"
  assert_absent "$home/state/.projects-view.full" "the full request is consumed"
  pass "routine refreshes are local-only and rate-limited; --full bypasses the cooldown with a full snapshot"
}

# --- review regressions --------------------------------------------------------

test_cached_home_age_alone_never_rewrites_the_page() {
  local home snap out
  home=$(fixture_home cached-age)
  snap="$home/snapshot.json"
  mate_snapshot() {  # <age-seconds> <omitted-count>
    jq -n --arg now "$NOW" --argjson age "$1" --argjson omitted "$2" '{
      schema: "fm-fleet-snapshot.v1", generated: $now,
      backlog: {records: []}, tasks: [],
      secondmate_current: {records: [
        {id: "mate-mac", provenance: {selected: "structured-home", trust: "complete"}, current: {state: "no_active_work", reason: null},
         freshness: {status: "cached", age_seconds: $age}, active_children: [], queued: [], landed: [], decisions_open: [],
         omitted: [{surface: "queued", count: $omitted}]}
      ]}
    }' > "$snap"
  }
  mate_snapshot 3600 0
  out=$(FM_HOME="$home" bash "$VIEW" build --snapshot "$snap") || fail "first build failed"
  assert_contains "$out" "written" "first build writes"
  mate_snapshot 4200 0
  out=$(FM_HOME="$home" bash "$VIEW" build --snapshot "$snap") || fail "rebuild failed"
  assert_contains "$out" "unchanged" "an older cached ledger with the same rows leaves the page alone"
  sed -n '/<script id="projects-data" type="application\/json">/,/<\/script>/p' "$home/.lavish/projects.html" | sed '1d;$d' \
    | jq -e '.homes == [{id: "mate-mac", status: "cached", reason: null, age_seconds: 3600, omitted: 0}]' >/dev/null \
    || fail "the page lost the cached age it shows"
  mate_snapshot 4200 2
  out=$(FM_HOME="$home" bash "$VIEW" build --snapshot "$snap") || fail "changed rebuild failed"
  assert_contains "$out" "written" "a changed home disclosure republishes"
  pass "a cached ledger's growing age alone never rewrites the page"
}

test_local_refresh_shows_plain_state_without_a_task_record() {
  local home fakebin
  home=$(fixture_home torn-down)
  fakebin=$(start_live_worker "$home" store-build)
  SNAPSHOT_SCOPE=local PATH="$fakebin:$PATH" FM_HOME="$home" bash "$VIEW" build >/dev/null || fail "full build failed"
  assert_equals Working "$(published_status "$home" store-launch store-build)" \
    "build pays for the full scope whatever the caller's environment says"

  rm -f -- "$home/state/store-build.meta"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROJECTS_VIEW_COOLDOWN_SECS=0 bash "$VIEW" refresh || fail "refresh failed"
  wait_for_refresh "$home" || fail "the routine refresh never finished"
  assert_equals Started "$(published_status "$home" store-launch store-build)" \
    "a routine refresh carries the published status only while the task record exists"
  pass "a routine refresh shows the plain state once the task record is gone"
}

test_page_keys_never_name_a_task() {
  local home model
  home=$(fixture_home keys)
  fm_write_meta "$home/state/store-build.meta" "window=x:fm-store-build" "kind=ship"
  model=$(model_of "$home") || fail "model failed"
  printf '%s' "$model" | jq -e '
    [.projects[] | .add_key] == ["pv.add.store-launch", "pv.add.platform"]
    and [.projects[] | .moving[] | select(.id == "store-build") | .fix_key] == ["pv.fix.store-build"]
  ' >/dev/null || fail "page keys are not namespaced: $model"
  awk '{ print } /^## Queued$/ {
      print "- [ ] pv.add.platform - Collides with the platform add key (since 2026-11-02)"
      print "- [ ] pv.fix.store-build - Collides with the store-build fix key (since 2026-11-02)" }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.new" && mv "$home/data/backlog.md.new" "$home/data/backlog.md"
  model=$(model_of "$home") || fail "model failed"
  printf '%s' "$model" | jq -e '
    [.projects[] | .add_key] == ["pv.add.store-launch", null]
    and [.projects[] | .moving[] | select(.id == "store-build") | .fix_key] == [null]
  ' >/dev/null || fail "a page key that names a task was published: $model"
  pass "page keys are namespaced and withheld when they would name a task"
}

lavish_fakebin() {  # <home>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    printf 'entered\n' > "$FM_HOME/stub-poll"
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
}

test_serve_keeps_the_page_out_of_the_answer_intake() {
  local home page sid out
  home=$(fixture_home serve)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/lavish-state"
  lavish_fakebin "$home"
  page=$(FM_HOME="$home" bash "$VIEW" path)
  mkdir -p "${page%/*}" && : > "$page"
  sid=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$page")
  # A page served by an earlier build was bound; serving again must remove it.
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" bind "$sid" >/dev/null || fail "could not pre-bind the source"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    bash "$VIEW" serve 2>&1) || fail "serve failed: $out"
  assert_contains "$out" "unbound: $sid" "serve did not drop the answer binding"
  ! printf '%s\n' "$out" | grep -qxF "bound: $sid" || fail "serve bound the page: $out"
  ! FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" binding "$sid" >/dev/null 2>&1 \
    || fail "the projects page still feeds the keyed-answer intake"
  pass "serve leaves the page unbound from the keyed-answer intake"
}

test_secondmate_rows_keep_membership_and_one_group() {
  local home snap model
  home=$(make_home mate-membership)
  write_config "$home"
  snap="$home/snapshot.json"
  jq -n --arg now "$NOW" '{
    schema: "fm-fleet-snapshot.v1", generated: $now,
    backlog: {records: []}, tasks: [],
    secondmate_current: {records: [{
      id: "mate-pc",
      provenance: {selected: "structured-home", trust: "complete"},
      freshness: {status: "fresh", age_seconds: 1},
      queued: [
        {id: "held-x", title: "Held and worked", hold_bucket: "live", hold_reason: "Pick", repo: null, project_hint: "platform"},
        {id: "tagged-next", title: "Tagged", hold_bucket: null, repo: "store-app", project_hint: "platform"}
      ],
      decisions_open: [{id: "held-x", verb: "captain-hold", summary: "Held and worked", reason: "Pick", hold_bucket: "live", project_hint: "platform"}],
      active_children: [
        {id: "held-x", name: "Held and worked", repo: null, state: "working", project_hint: "platform"},
        {id: "remote-work", name: "Remote work", repo: "other", state: "working", project_hint: null}
      ],
      landed: [{id: "remote-done", title: "Remote shipped", repo: "store-app", project_hint: null,
                completion: {date: "2026-11-01", verb: "done"}}]
    }]}
  }' > "$snap"
  model=$(model_of "$home" --snapshot "$snap") || fail "model failed"
  printf '%s' "$model" | jq -e '
    (.projects[] | select(.id == "store-launch")) as $s
    | (.projects[] | select(.id == "platform")) as $p
    | [$p.needs[].id] == ["held-x"] and $p.moving == []
    and [$p.next.rows[].id] == ["tagged-next"]
    and [$s.done.rows[].id] == ["remote-done"]
    and [.unassigned.rows[].id] == ["remote-work"]
    and .totals == {needs: 1, moving: 1, done: 1}
  ' >/dev/null || fail "secondmate membership or grouping is wrong: $model"
  pass "secondmate rows follow the project tag and repo, done included, and count once"
}

test_unread_and_old_homes_are_disclosed() {
  local home snap model
  home=$(make_home mate-health)
  write_config "$home"
  snap="$home/snapshot.json"
  jq -n --arg now "$NOW" '{
    schema: "fm-fleet-snapshot.v1", generated: $now,
    backlog: {records: []}, tasks: [],
    secondmate_current: {records: [
      {id: "mate-pc", provenance: {selected: "parent-status"}, current: {state: "unknown", reason: "remote ledger unreachable"},
       freshness: {status: "observed", age_seconds: 0}, active_children: [], queued: [], landed: [], decisions_open: [], omitted: []},
      {id: "mate-mac", provenance: {selected: "structured-home", trust: "complete"}, current: {state: "no_active_work", reason: null},
       freshness: {status: "cached", age_seconds: 7200}, active_children: [], queued: [], landed: [], decisions_open: [],
       omitted: [{surface: "queued", count: 3}, {surface: "landed", count: 2}]},
      {id: "mate-ok", provenance: {selected: "structured-home", trust: "complete"}, current: {state: "no_active_work"},
       freshness: {status: "fresh", age_seconds: 1}, active_children: [], queued: [], landed: [], decisions_open: [], omitted: []}
    ]}
  }' > "$snap"
  model=$(model_of "$home" --snapshot "$snap") || fail "model failed"
  printf '%s' "$model" | jq -e '
    .homes == [
      {id: "mate-pc", status: "unread", reason: "remote ledger unreachable", age_seconds: 0, omitted: 0},
      {id: "mate-mac", status: "cached", reason: null, age_seconds: 7200, omitted: 5},
      {id: "mate-ok", status: "fresh", reason: null, age_seconds: 1, omitted: 0}]
  ' >/dev/null || fail "home read state is not carried: $model"
  pass "an unread, cached, or truncated secondmate summary is disclosed in the model"
}

test_home_summary_carries_project_tag_and_repo() {
  local home out
  home=$(make_home summary-hints)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] tagged-q - Tagged queued (repo: store-app) (since 2026-11-02)
  Project: platform
## Done
- [x] tagged-d - Tagged done (repo: store-app) (kind: ship) (done 2026-11-03)
  Project: platform
  local main
EOF
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) \
    || fail "home summary failed"
  printf '%s' "$out" | jq -e '
    [.queued[] | select(.id == "tagged-q") | {repo, project_hint}] == [{repo: "store-app", project_hint: "platform"}]
    and [.landed[] | select(.id == "tagged-d") | {repo, project_hint}] == [{repo: "store-app", project_hint: "platform"}]
  ' >/dev/null || fail "the home summary dropped the project tag or repo: $out"
  pass "a home summary carries each row's project tag and repo"
}

fm_test_run \
  test_check_accepts_a_valid_config \
  test_check_refuses_missing_and_malformed_configs \
  test_membership_follows_body_line_then_glob_then_exclusive_repo \
  test_counters_count_captain_waits_and_windowed_done \
  test_secondmate_work_groups_read_only \
  test_live_local_work_is_correctable \
  test_add_files_a_queued_item_with_its_project \
  test_correct_steers_only_live_local_work \
  test_build_publishes_an_inert_model_and_skips_unchanged \
  test_refresh_is_opt_in_and_runs_detached \
  test_wake_drain_triggers_a_refresh \
  test_routine_refresh_is_local_only_and_rate_limited \
  test_cached_home_age_alone_never_rewrites_the_page \
  test_local_refresh_shows_plain_state_without_a_task_record \
  test_page_keys_never_name_a_task \
  test_serve_keeps_the_page_out_of_the_answer_intake \
  test_secondmate_rows_keep_membership_and_one_group \
  test_unread_and_old_homes_are_disclosed \
  test_home_summary_carries_project_tag_and_repo
