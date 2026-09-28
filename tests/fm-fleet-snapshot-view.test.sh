#!/usr/bin/env bash
# Behavioral coverage for the canonical single-home fleet snapshot and renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship"
  printf '%s\n' "$home"
}

make_fakebin() {
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'status --json') echo '{"server":{"running":true}}' ;;
  'pane get') jq -n --arg p "$3" '{result:{pane:{pane_id:$p}}}' ;;
  'agent get') echo '{"result":{"agent":{"agent_status":"working"}}}' ;;
  'pane process-info') jq -n --arg p "${4:-}" '{result:{type:"pane_process_info",process_info:{pane_id:$p,shell_pid:101,foreground_processes:[{pid:102,name:"pi",argv0:"pi"}]}}}' ;;
  'pane read') printf 'working\n> \n' ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

test_empty_snapshot_and_view() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .tasks == []
      and .backlog.records == []
      and .scout_reports == []
      and .main_inventory.valid == true
  ' >/dev/null || fail "empty fleet snapshot has the wrong public shape: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty view did not render the empty task state"
  assert_not_contains "$view" "Secondmates" "fleet view still advertises a removed Secondmates section"
  pass "fleet snapshot and view render an empty single-home fleet"
}

test_main_home_inventory_and_historical_refusal() {
  local home fakebin out view
  home=$(make_home fixture)
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-09-26)

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-09-27)

## Done
- [x] done-task - Done Task https://github.com/example/repo/pull/7 (repo: alpha) (kind: ship) (merged 2026-09-25)
EOF
  fm_test_write_herdr_meta "$home/state/ship-task.meta" \
    "window=fmtest:w1:p1" "endpoint_task_id=ship-task" \
    "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "worktree=$home/projects/ship" "project=alpha" "harness=pi" \
    "kind=ship" "mode=no-mistakes"
  printf 'needs-decision [key=api]: choose API\n' > "$home/state/ship-task.status"
  fm_test_write_herdr_meta "$home/state/retired-home.meta" \
    "window=fmtest:w2:p1" "endpoint_task_id=retired-home" \
    "backend=herdr" "worktree=$home/retired" "project=retired" \
    "harness=pi" "kind=secondmate" "mode=secondmate" "home=$home/retired"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s\n' "$out" | jq -e '
    (.tasks | any(.id == "ship-task" and .kind == "ship"))
      and (.tasks | any(.id == "retired-home" and .current_state.state == "unsupported"
        and .actions == null))
      and (.backlog.records | any(.id == "queued-task" and .state == "queued"))
  ' >/dev/null || fail "single-home inventory or historical-record refusal is wrong: $out"

  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "ship-task" "fleet view omitted the ordinary ship task"
  assert_contains "$view" "retired-home" "fleet view hid the preserved historical record"
  assert_contains "$view" "unsupported" "fleet view did not label the historical record unsupported"
  assert_not_contains "$view" "fm-send.sh retired-home" "fleet view advertised an action for a retired owner"
  assert_not_contains "$view" "## Secondmates" "fleet view still renders a removed feature section"
  pass "fleet snapshot keeps ordinary work active and preserves historical secondmate records as unsupported"
}

test_view_uses_authoritative_task_disposition() {
  local home fakebin out view under_way retained integrity queued
  home=$(make_home disposition-view)
  fakebin=$(make_fakebin "$home")
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
archive = "data/done-archive.md"
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-task - Active Task (repo: alpha) (kind: ship)
- [ ] ambiguous-task - Ambiguous Task (repo: alpha) (kind: ship)

## Queued
- [ ] queued-task - Queued Task (repo: alpha) (kind: ship)
- [ ] parked-task - Parked Task (repo: alpha) (kind: ship) (hold-kind: parked)
- [ ] ambiguous-task - Duplicate Ambiguous Task (repo: alpha) (kind: ship)

## Done
- [x] done-task - Done Task (repo: alpha) (kind: ship)
- [x] closed-working - Closed But Working Task (repo: alpha) (kind: ship)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-09
- [x] archived-task - Archived Task (repo: alpha) (kind: ship)
EOF
  for id in active-task queued-task done-task archived-task ambiguous-task unknown-task; do
    printf 'kind=secondmate\nproject=alpha\n' > "$home/state/$id.meta"
  done
  mkdir -p "$home/projects/parked-task" "$home/projects/closed-working"
  fm_test_write_herdr_meta "$home/state/parked-task.meta" \
    "window=fmtest:w3:p1" "endpoint_task_id=parked-task" \
    "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w3" \
    "herdr_tab_id=w3:t1" "herdr_pane_id=w3:p1" \
    "project=alpha" "worktree=$home/projects/parked-task" "harness=pi" "kind=ship"
  fm_test_write_herdr_meta "$home/state/closed-working.meta" \
    "window=fmtest:w4:p1" "endpoint_task_id=closed-working" \
    "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w4" \
    "herdr_tab_id=w4:t1" "herdr_pane_id=w4:p1" \
    "project=alpha" "worktree=$home/projects/closed-working" "harness=pi" "kind=ship"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s\n' "$out" | jq -e '
    (.tasks | any(.id == "active-task" and .record_disposition == "active"))
      and (.tasks | any(.id == "queued-task" and .record_disposition == "queued"))
      and (.tasks | any(.id == "parked-task" and .record_disposition == "parked"))
      and (.tasks | any(.id == "done-task" and .record_disposition == "done" and .retained_record == true))
      and (.tasks | any(.id == "archived-task" and .record_disposition == "archive_done" and .retained_record == true))
      and (.tasks | any(.id == "ambiguous-task" and .record_disposition == "ambiguous"))
      and (.tasks | any(.id == "unknown-task" and .record_disposition == "unknown"))
      and (.tasks | any(.id == "parked-task" and .record_disposition == "parked" and .current_state.state == "working"))
      and (.tasks | any(.id == "closed-working" and .record_disposition == "done" and .current_state.state == "working" and .retained_record == false))
  ' >/dev/null || fail "task disposition snapshot did not preserve active, queued, terminal, and integrity states: $out"

  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  under_way=$(printf '%s\n' "$view" | awk '$0 == "## Under Way" {show=1; next} /^## / && show {exit} show')
  retained=$(printf '%s\n' "$view" | awk '$0 == "## Retained execution records" {show=1; next} /^## / && show {exit} show')
  integrity=$(printf '%s\n' "$view" | awk '$0 == "## Task record integrity" {show=1; next} /^## / && show {exit} show')
  queued=$(printf '%s\n' "$view" | awk '$0 == "## Queued" {show=1; next} /^## / && show {exit} show')
  assert_contains "$under_way" "active-task" "active in-flight metadata was not rendered Under Way"
  assert_not_contains "$under_way" "queued-task" "queued metadata was rendered Under Way"
  assert_not_contains "$under_way" "parked-task" "parked metadata was rendered Under Way"
  assert_not_contains "$under_way" "done-task" "Done metadata was rendered Under Way"
  assert_not_contains "$under_way" "archived-task" "archived metadata was rendered Under Way"
  assert_not_contains "$under_way" "closed-working" "closed metadata with stale working evidence was rendered Under Way"
  assert_not_contains "$under_way" "ambiguous-task" "ambiguous metadata was rendered Under Way"
  assert_not_contains "$under_way" "unknown-task" "unknown metadata was rendered Under Way"
  assert_contains "$retained" "done-task" "Done metadata was not rendered as retained"
  assert_contains "$retained" "archived-task" "archive-retained metadata was not rendered as retained"
  assert_contains "$integrity" "ambiguous-task" "ambiguous metadata disappeared instead of surfacing as integrity"
  assert_contains "$integrity" "unknown-task" "unknown metadata disappeared instead of surfacing as integrity"
  assert_contains "$integrity" "parked-task" "parked metadata with working evidence disappeared instead of surfacing as integrity"
  assert_contains "$integrity" "closed-working" "closed metadata with working evidence disappeared instead of surfacing as integrity"
  assert_contains "$queued" "queued-task" "queued backlog row disappeared from the Queued section"
  assert_contains "$queued" "parked-task" "parked backlog row disappeared from the Queued section"
  pass "fleet view uses authoritative disposition for Under Way while retaining terminal and integrity visibility"
}

test_removed_home_summary_mode_is_rejected() {
  local home rc
  home=$(make_home removed-mode)
  set +e
  FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed secondmate home-summary mode still succeeded"
  assert_contains "$(cat "$home/err")" "usage:" "removed mode did not fail through the public CLI"
  pass "fleet snapshot rejects the removed secondmate home-summary mode"
}

test_empty_snapshot_and_view
test_main_home_inventory_and_historical_refusal
test_view_uses_authoritative_task_disposition
test_removed_home_summary_mode_is_rejected
