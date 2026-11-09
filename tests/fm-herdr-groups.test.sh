#!/usr/bin/env bash
# tests/fm-herdr-groups.test.sh - opt-in Herdr project groups, driven through
# bin/fm-herdr-groups.sh against a scripted `herdr` CLI and a logging stand-in
# for bin/backends/herdr-agent-view.py, plus the real socket helper against a
# local fake socket server and one real watcher poll. No real Herdr server is
# started. docs/herdr-backend.md "Project groups" owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# A Herdr pane identity leaked in from the developer's own terminal must never
# route a call anywhere; every call here goes to the scripted fake.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-groups)
TOKEN_A='AbCdEfGhIjKlMnOpQrStUv'

# make_fake_herdr <dir>: a `herdr` stand-in that logs every call (one line,
# unit-separated arguments) to $FAKE_HERDR_LOG and answers from files:
# status --json reports $FAKE_HERDR_PROTOCOL, workspace list and pane list
# print $FAKE_DIR/workspaces.json and $FAKE_DIR/panes.json, session list
# names one running session socket, and report-metadata succeeds silently.
make_fake_herdr() {  # <dir> -> fakebin
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
{
  printf 'herdr'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$FAKE_HERDR_LOG"
case "$1 ${2:-}" in
  "status --json") printf '{"client":{"version":"0.9.3","protocol":%s},"server":{"running":true}}\n' "${FAKE_HERDR_PROTOCOL:-22}" ;;
  "workspace list") cat "$FAKE_DIR/workspaces.json" ;;
  "pane list") cat "$FAKE_DIR/panes.json" ;;
  "session list") printf '{"sessions":[{"name":"s1","running":true,"socket_path":"/tmp/fm-groups-s1.sock"}]}\n' ;;
  "pane report-metadata"|"workspace report-metadata") ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/agent-view" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$FAKE_VIEW_LOG"
exit 0
SH
  chmod +x "$fakebin/agent-view"
  printf '%s\n' "$fakebin"
}

# new_home <name>: sets HOME_DIR, FAKE_DIR, FAKEBIN, and empty logs.
new_home() {
  FAKE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$FAKE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  FAKEBIN=$(make_fake_herdr "$FAKE_DIR")
  FAKE_HERDR_LOG="$FAKE_DIR/herdr.log"
  FAKE_VIEW_LOG="$FAKE_DIR/view.log"
  : > "$FAKE_HERDR_LOG"
  : > "$FAKE_VIEW_LOG"
  printf '{"result":{"workspaces":[]}}\n' > "$FAKE_DIR/workspaces.json"
  printf '{"result":{"panes":[]}}\n' > "$FAKE_DIR/panes.json"
}

add_task() {  # <id> <kind> <project-path> <workspace> [<status line>]
  printf 'window=s1:%s:p2\nproject=%s\nkind=%s\nbackend=herdr\nherdr_session=s1\nherdr_workspace_id=%s\nherdr_tab_id=%s:t2\nherdr_pane_id=%s:p2\n' \
    "$4" "$3" "$2" "$4" "$4" "$4" > "$HOME_DIR/state/$1.meta"
  [ -z "${5:-}" ] || printf '%s\n' "$5" > "$HOME_DIR/state/$1.status"
}

add_v2_journal() {  # <id> <workspace>
  printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\nsession=s1\nworkspace_id=%s\ntab_id=%s:t2\npane_id=%s:p2\nparent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ %s · p:%s\ntask_label=fm-%s\n' \
    "$1" "$TOKEN_A" "$HOME_DIR" "$2" "$2" "$2" "$1" "$TOKEN_A" "$1" > "$HOME_DIR/state/$1.herdr-presentation"
}

groups() {  # <args...>: run the real script against the case home
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" \
    FAKE_DIR="$FAKE_DIR" FAKE_HERDR_LOG="$FAKE_HERDR_LOG" FAKE_VIEW_LOG="$FAKE_VIEW_LOG" \
    FM_HERDR_GROUPS_AGENT_VIEW="$FAKEBIN/agent-view" \
    "$ROOT/bin/fm-herdr-groups.sh" "$@"
}

reports() {  # <kind pane|workspace>: logged report-metadata calls, readable
  grep -a "^herdr"$'\x1f'"$1"$'\x1f'"report-metadata" "$FAKE_HERDR_LOG" | tr '\037' ' ' || true
}

test_absent_or_off_setting_does_nothing() {
  local out
  new_home off
  add_task web-a ship /p/storefront w2 'working: go'
  out=$(groups plan 2>&1) || fail "plan failed with the setting absent: $out"
  assert_equals "" "$out" "plan output with the setting absent"
  out=$(groups sync 2>&1) || fail "sync failed with the setting absent: $out"
  assert_equals "" "$out" "sync output with the setting absent"
  printf ' OFF \n' > "$HOME_DIR/config/herdr-project-groups"
  out=$(groups sync 2>&1) || fail "sync failed with the setting off: $out"
  out=$(groups order-key web-a /p/storefront 2>&1) || fail "order-key failed with the setting off: $out"
  assert_equals "" "$out" "order-key output with the setting off"
  assert_equals "" "$(cat "$FAKE_HERDR_LOG")" "herdr calls while off"
  assert_equals "" "$(cat "$FAKE_VIEW_LOG")" "agents view calls while off"
  pass "absent or off setting: no plan, no key, and not a single Herdr call"
}

test_on_with_zero_tasks_plan_is_empty() {
  local out
  new_home empty-plan
  printf 'on\n' > "$HOME_DIR/config/herdr-project-groups"
  # No *.meta tasks: cmd_plan must exit 0 with no lines even when TASKS stays empty
  # (Bash 3.2 under set -u rejects an unguarded empty "${TASKS[@]}").
  out=$(groups plan 2>&1) || fail "plan with zero tasks failed: $out"
  assert_equals "" "$out" "plan output with zero herdr tasks"
  out=$(groups sync 2>&1) || fail "sync with zero tasks failed: $out"
  assert_equals "" "$out" "sync output with zero herdr tasks"
  assert_equals "" "$(cat "$FAKE_HERDR_LOG")" "herdr calls with zero tasks"
  pass "on with zero tasks: plan and sync stay quiet and exit 0"
}

test_on_groups_by_project_and_sorts_by_status_rank() {
  local out sorted
  new_home on
  printf 'on\n' > "$HOME_DIR/config/herdr-project-groups"
  add_task web-run ship /p/storefront w2 'working: go'
  add_task web-ask scout /p/storefront/ w3 'needs-decision [key=pick]: which one'
  add_task web-done ship /p/storefront w4 'done: shipped'
  add_task web-fail ship /p/storefront w5 'failed: broke'
  add_task api-held ship /p/api-server w6 'captain-held: waiting on the captain'
  add_task api-new ship /p/api-server w7
  add_task api-resolved ship /p/api-server w8 "$(printf 'needs-decision [key=a]: q\nresolved [key=a]: answered')"
  add_task mate secondmate /p/api-server w9 'working: go'
  printf 'window=t:1\nproject=/p/api-server\nkind=ship\n' > "$HOME_DIR/state/tmux-task.meta"
  out=$(groups plan 2>&1) || fail "plan failed: $out"
  assert_contains "$out" $'web-ask\tstorefront\tneeds-captain\t000.storefront.1.web-ask\t000.storefront' "open decision"
  assert_contains "$out" $'web-fail\tstorefront\tproblem\t' "failed task"
  assert_contains "$out" $'web-done\tstorefront\tdone\t' "done task"
  assert_contains "$out" $'web-run\tstorefront\trunning\t' "working task"
  assert_contains "$out" $'api-held\tapi-server\tneeds-captain\t' "captain-held task"
  assert_contains "$out" $'api-new\tapi-server\trunning\t' "task without a status log"
  assert_contains "$out" $'api-resolved\tapi-server\trunning\t' "resolved decision"
  assert_not_contains "$out" "mate" "a secondmate pane is not a grouped task"
  assert_not_contains "$out" "tmux-task" "a non-Herdr task is not grouped"
  sorted=$(printf '%s\n' "$out" | sort -t $'\t' -k4,4 | cut -f1 | tr '\n' ' ')
  assert_equals "api-held api-new api-resolved web-ask web-fail web-run web-done " "$sorted" \
    "sort keys must order by group, then needs-captain, problem, running, done"
  pass "on: one group per project, status order needs-captain, problem, running, done"
}

test_rules_order_groups_and_prefer_task_over_repo_over_catch_all() {
  local out
  new_home rules
  cat > "$HOME_DIR/config/herdr-project-groups" <<'EOF'
# area groups
Web      task:web repo:storefront
Backend  task:api
Bad/Name task:x
Other    * bogus
Web      task:shop
EOF
  add_task api-in-storefront ship /p/storefront w2 'working: go'
  add_task shop-x ship /p/tools w3 'working: go'
  add_task storefront-thing ship /p/storefront w4 'working: go'
  add_task loose-end ship /p/tools w5 'working: go'
  add_task webby ship /p/tools w6 'working: go'
  : > "$HOME_DIR/state/task:web"
  out=$(cd "$HOME_DIR/state" && groups plan 2>"$FAKE_DIR/err") || fail "plan failed: $out"
  assert_contains "$out" $'api-in-storefront\tBackend\trunning\t002.Backend.3.api-in-storefront\t002.Backend' \
    "a task-id prefix beats a repository rule on an earlier line"
  assert_contains "$out" $'shop-x\tWeb\t' "a group spanning two lines keeps its first rank"
  assert_contains "$out" $'storefront-thing\tWeb\t' "repository selector"
  assert_contains "$out" $'loose-end\tOther\trunning\t003.Other.' "catch-all ranks by first appearance"
  assert_contains "$out" $'webby\tOther\t' "a task prefix matches only the whole id or <prefix>-"
  assert_contains "$(cat "$FAKE_DIR/err")" 'invalid group name "Bad/Name"' "invalid group warning"
  assert_contains "$(cat "$FAKE_DIR/err")" 'unknown selector "bogus"' "unknown selector warning"
  printf 'Web task:web\n' > "$HOME_DIR/config/herdr-project-groups"
  out=$(groups plan 2>&1) || fail "plan failed: $out"
  assert_contains "$out" $'loose-end\ttools\trunning\t999.tools.3.loose-end\t999.tools' \
    "an unmatched task falls back to its project after every rule group"
  out=$(groups order-key web-new /p/whatever 2>&1) || fail "order-key failed: $out"
  assert_equals "001.Web" "$out" "order-key for a rule group"
  pass "rules: line order sets group order; task prefix beats repo beats catch-all; bad rules warn"
}

test_all_invalid_rules_leave_empty_rule_group_and_still_plan() {
  local out
  new_home all-invalid
  cat > "$HOME_DIR/config/herdr-project-groups" <<'EOF'
# every line invalid: RULE_GROUP stays empty after load_setting
Bad/Name task:x
!!! task:y
EOF
  add_task web-a ship /p/storefront w2 'working: go'
  out=$(groups plan 2>"$FAKE_DIR/err") || fail "plan after all-invalid rules failed: $out"
  assert_contains "$(cat "$FAKE_DIR/err")" 'invalid group name "Bad/Name"' "invalid group warning"
  assert_contains "$(cat "$FAKE_DIR/err")" 'invalid group name "!!!"' "second invalid group warning"
  assert_contains "$out" $'web-a\tstorefront\trunning\t999.storefront.3.web-a\t999.storefront' \
    "with no valid rules the task falls back to its project under the unmatched rank"
  pass "all-invalid rules: empty RULE_GROUP still plans via project fallback"
}

write_live_lists() {  # <tagged 0|1>
  local tokens='{}' ws_tokens='{}'
  if [ "$1" = 1 ]; then
    tokens='{"fm_group":"storefront","fm_state":"running","fm_task":"web-run","fm_sort":"000.storefront.3.web-run"}'
    ws_tokens='{"fm_group":"storefront","fm_state":"running","fm_group_order":"000.storefront"}'
  fi
  cat > "$FAKE_DIR/workspaces.json" <<EOF
{"result":{"workspaces":[
 {"workspace_id":"w1","label":"firstmate","pane_count":3},
 {"workspace_id":"w2","label":"└ web-run · p:$TOKEN_A","pane_count":1,"tokens":$ws_tokens}
]}}
EOF
  cat > "$FAKE_DIR/panes.json" <<EOF
{"result":{"panes":[
 {"pane_id":"w1:p1","workspace_id":"w1"},
 {"pane_id":"w1:p2","workspace_id":"w1"},
 {"pane_id":"w2:p2","workspace_id":"w2","tokens":$tokens}
]}}
EOF
}

test_sync_reports_only_differences_and_sets_the_view() {
  local out pane_reports ws_reports
  new_home sync
  printf 'on\n' > "$HOME_DIR/config/herdr-project-groups"
  add_task web-run ship /p/storefront w2 'working: go'
  add_v2_journal web-run w2
  add_task flat-task ship /p/storefront w1 'blocked: stuck'
  add_task gone-task ship /p/storefront w8 'working: go'
  write_live_lists 0
  # The flat task's tab shares the launcher workspace and its pane is w1:p2.
  out=$(groups sync 2>&1) || fail "first sync failed: $out"
  pane_reports=$(reports pane)
  ws_reports=$(reports workspace)
  assert_contains "$pane_reports" "pane report-metadata w2:p2 --source firstmate --token fm_group=storefront --token fm_state=running --token fm_task=web-run --token fm_sort=000.storefront.3.web-run" \
    "projected task pane tokens"
  assert_contains "$pane_reports" "pane report-metadata w1:p2 --source firstmate --token fm_group=storefront --token fm_state=problem --token fm_task=flat-task --token fm_sort=000.storefront.2.flat-task" \
    "flat task pane tokens"
  assert_not_contains "$pane_reports" "w8:p2" "a pane missing from the live list is skipped"
  assert_equals "1" "$(printf '%s\n' "$ws_reports" | grep -c 'report-metadata')" "workspace reports"
  assert_contains "$ws_reports" "workspace report-metadata w2 --source firstmate --token fm_group=storefront --token fm_state=running --token fm_group_order=000.storefront" \
    "only the exactly bound projected workspace gets workspace tokens"
  assert_equals "/tmp/fm-groups-s1.sock	set" "$(cat "$FAKE_VIEW_LOG")" "agents view set once for the session"

  : > "$FAKE_HERDR_LOG"; : > "$FAKE_VIEW_LOG"
  rm -f "$HOME_DIR/state/flat-task.meta"
  write_live_lists 1
  out=$(groups sync 2>&1) || fail "second sync failed: $out"
  assert_equals "" "$(reports pane)$(reports workspace)" "an unchanged layout reports nothing"
  assert_equals "" "$(cat "$FAKE_VIEW_LOG")" "an unchanged layout leaves the agents view alone"

  printf 'needs-decision [key=q]: which\n' >> "$HOME_DIR/state/web-run.status"
  out=$(groups sync web-run 2>&1) || fail "status-change sync failed: $out"
  assert_equals "herdr pane report-metadata w2:p2 --source firstmate --token fm_state=needs-captain --token fm_sort=000.storefront.1.web-run --session s1" \
    "$(reports pane)" "a status change reports only the changed pane tokens"
  assert_contains "$(reports workspace)" "--token fm_state=needs-captain --session s1" "workspace status token follows"
  assert_not_contains "$(reports workspace)" "fm_group=" "unchanged workspace tokens are not re-reported"
  assert_equals "/tmp/fm-groups-s1.sock	set" "$(cat "$FAKE_VIEW_LOG")" "agents view re-set after a pane change"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" $'\x1fmove' "sync never moves anything"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" $'\x1fclose' "sync never closes anything"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" $'\x1ffocus' "sync never changes focus"
  pass "sync: reports only drifted tokens, workspace tokens only on the exact projection, view set on change"
}

test_sync_skips_an_unverified_protocol_with_one_warning() {
  local out
  new_home old-protocol
  printf 'on\n' > "$HOME_DIR/config/herdr-project-groups"
  add_task web-run ship /p/storefront w2 'working: go'
  write_live_lists 0
  out=$(FAKE_HERDR_PROTOCOL=21 groups sync 2>&1) || fail "sync on protocol 21 failed: $out"
  assert_contains "$out" "Herdr protocol 21 is below the verified protocol 22" "one-time warning"
  out=$(FAKE_HERDR_PROTOCOL=21 groups sync 2>&1) || fail "second sync on protocol 21 failed: $out"
  assert_equals "" "$out" "the warning is not repeated for the same protocol"
  assert_equals "" "$(reports pane)$(reports workspace)" "no report on an unverified protocol"
  assert_equals "" "$(cat "$FAKE_VIEW_LOG")" "no agents view on an unverified protocol"
  pass "sync: an older Herdr protocol warns once and stays inactive"
}

test_clear_removes_tokens_and_the_view_even_when_off() {
  local out
  new_home clear
  printf 'off\n' > "$HOME_DIR/config/herdr-project-groups"
  add_task web-run ship /p/storefront w2 'working: go'
  add_v2_journal web-run w2
  write_live_lists 1
  out=$(groups clear 2>&1) || fail "clear failed: $out"
  assert_equals "/tmp/fm-groups-s1.sock	clear" "$(cat "$FAKE_VIEW_LOG")" "agents view cleared"
  assert_contains "$(reports pane)" "pane report-metadata w2:p2 --source firstmate --clear-token fm_group --clear-token fm_state --clear-token fm_task --clear-token fm_sort" \
    "pane tokens cleared"
  assert_contains "$(reports workspace)" "workspace report-metadata w2 --source firstmate --clear-token fm_group --clear-token fm_state --clear-token fm_group_order" \
    "projected workspace tokens cleared"
  pass "clear: removes this home's tokens and the agents view after the feature is turned off"
}

test_sidebar_config_apply_backs_up_and_refuses_twice() {
  local out cfg backups
  new_home sidebar
  cfg="$FAKE_DIR/config.toml"
  printf '[ui]\nagent_panel_sort = "spaces"\n' > "$cfg"
  out=$(groups sidebar-config 2>&1) || fail "sidebar-config print failed: $out"
  assert_contains "$out" '[ui.sidebar.agents]' "printed rows"
  assert_equals "" "$(cat "$FAKE_HERDR_LOG")" "printing the rows calls no Herdr command"
  out=$(groups sidebar-config --apply "$cfg" 2>&1) || fail "sidebar-config apply failed: $out"
  backups=$(find "$FAKE_DIR" -maxdepth 1 -name 'config.toml.bak-*')
  [ -n "$backups" ] || fail "apply made no backup"
  assert_equals $'[ui]\nagent_panel_sort = "spaces"' "$(cat "$backups")" "backup holds the original"
  assert_contains "$(cat "$cfg")" '[ui.sidebar.spaces]' "rows appended"
  assert_contains "$(cat "$cfg")" 'agent_panel_sort = "spaces"' "original content kept"
  if out=$(groups sidebar-config --apply "$cfg" 2>&1); then
    fail "a second apply must refuse"
  fi
  assert_contains "$out" "already defines Herdr sidebar rows" "refusal reason"
  assert_equals "1" "$(grep -c '^\[ui.sidebar.spaces\]' "$cfg")" "rows appended exactly once"
  assert_equals "" "$(cat "$FAKE_HERDR_LOG")" "apply never reloads Herdr"
  pass "sidebar-config: prints rows; --apply backs up, appends once, never reloads Herdr"
}

test_agent_view_helper_sends_only_the_whitelisted_requests() {
  local dir sock server out status
  command -v python3 >/dev/null 2>&1 || { pass "agent view helper: skipped, python3 not found"; return 0; }
  dir="$TMP_ROOT/view-helper"; mkdir -p "$dir"
  sock="$dir/s.sock"
  for action in set clear; do
    rm -f "$sock" "$dir/request.json"
    python3 - "$sock" "$dir/request.json" "$action" > "$dir/server.log" 2>&1 <<'PY' &
import json, socket, sys
path, out, action = sys.argv[1:]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(1)
conn, _ = srv.accept()
data = b""
while b"\n" not in data:
    data += conn.recv(65536)
open(out, "wb").write(data)
result = {"type": "agent_view", "active": action == "set", "source": "firstmate", "label": "projects"}
conn.sendall((json.dumps({"id": "fm-agent-view", "result": result}) + "\n").encode())
conn.close()
PY
    server=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$sock" ] && break; sleep 0.2; done
    out=$("$ROOT/bin/backends/herdr-agent-view.py" "$sock" "$action" 2>&1)
    status=$?
    wait "$server" || true
    [ "$status" -eq 0 ] || fail "agent view helper $action failed ($status): $out $(cat "$dir/server.log")"
    case "$action" in
      set)
        assert_equals '{"method":"agent.view.set","params":{"label":"projects","sort":[{"field":{"token":"fm_sort"}},{"field":"workspace_order"}],"source":"firstmate"}}' \
          "$(jq -cS '{method, params}' "$dir/request.json")" "set request"
        ;;
      clear)
        assert_equals '{"method":"agent.view.clear","params":{"source":"firstmate"}}' \
          "$(jq -cS '{method, params}' "$dir/request.json")" "clear request"
        ;;
    esac
  done
  if "$ROOT/bin/backends/herdr-agent-view.py" "$sock" focus >/dev/null 2>&1; then
    fail "the helper accepted an action outside its whitelist"
  fi
  pass "agent view helper: exactly agent.view.set and agent.view.clear for source firstmate"
}

test_watcher_poll_tags_tasks() {
  local out
  new_home watcher
  printf 'on\n' > "$HOME_DIR/config/herdr-project-groups"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  add_task web-run ship /p/storefront w2 'working: go'
  write_live_lists 0
  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    PATH="$FAKEBIN:$PATH" FAKE_DIR="$FAKE_DIR" FAKE_HERDR_LOG="$FAKE_HERDR_LOG" \
    FAKE_VIEW_LOG="$FAKE_VIEW_LOG" FM_HERDR_GROUPS_AGENT_VIEW="$FAKEBIN/agent-view" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 2>&1)
  case "$out" in *"checkpoint:"*|*"signal:"*|*"stale:"*) ;; *) fail "watcher checkpoint did not run: $out" ;; esac
  assert_contains "$(reports pane)" "pane report-metadata w2:p2 --source firstmate --token fm_group=storefront" \
    "the watcher poll tagged the task pane"
  assert_contains "$(cat "$FAKE_VIEW_LOG")" "set" "the watcher poll set the agents view"
  pass "watcher: one poll cycle reconciles the project-group tags"
}

test_absent_or_off_setting_does_nothing
test_on_with_zero_tasks_plan_is_empty
test_on_groups_by_project_and_sorts_by_status_rank
test_rules_order_groups_and_prefer_task_over_repo_over_catch_all
test_all_invalid_rules_leave_empty_rule_group_and_still_plan
test_sync_reports_only_differences_and_sets_the_view
test_sync_skips_an_unverified_protocol_with_one_warning
test_clear_removes_tokens_and_the_view_even_when_off
test_sidebar_config_apply_backs_up_and_refuses_twice
test_agent_view_helper_sends_only_the_whitelisted_requests
test_watcher_poll_tags_tasks
