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
test_removed_home_summary_mode_is_rejected
