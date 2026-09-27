#!/usr/bin/env bash
# Behavioral coverage for the bounded single-home bearings projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship" "$home/data/scout-done"
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
  for tool in gh gh-axi curl; do
    cat > "$fb/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${NET_LOG:?}"
exit 1
SH
    chmod +x "$fb/$tool"
  done
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

write_fixture() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-09-26)

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-09-27)

## Done
- [x] scout-done - Scout Report data/scout-done/report.md (repo: alpha) (kind: scout) (reported 2026-09-25)
- [x] ship-done - Shipped https://github.com/example/repo/pull/7 (repo: alpha) (kind: ship) (merged 2026-09-24)
EOF
  printf '# Report\n' > "$home/data/scout-done/report.md"
  fm_test_write_herdr_meta "$home/state/ship-task.meta" \
    "window=fmtest:w1:p1" "endpoint_task_id=ship-task" \
    "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "worktree=$home/projects/ship" "project=alpha" "harness=pi" \
    "kind=ship" "mode=no-mistakes"
  printf 'working: implementing\n' > "$home/state/ship-task.status"
  fm_test_write_herdr_meta "$home/state/retired-home.meta" \
    "window=fmtest:w2:p1" "endpoint_task_id=retired-home" \
    "backend=herdr" "worktree=$home/retired" "project=retired" \
    "harness=pi" "kind=secondmate" "mode=secondmate" "home=$home/retired"
}

test_empty_projection() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-bearings.v1"
      and .in_flight == []
      and .landed == []
      and .reports == []
      and .decisions_open == []
  ' >/dev/null || fail "empty bearings projection has the wrong public shape: $out"
  pass "bearings renders an empty single-home projection"
}

test_main_home_projection_is_local_and_complete() {
  local home fakebin out net
  home=$(make_home fixture)
  fakebin=$(make_fakebin "$home")
  write_fixture "$home"
  net="$home/network.log"; : > "$net"
  out=$(PATH="$fakebin:$PATH" NET_LOG="$net" FM_HOME="$home" "$BEARINGS" --json --all-landed --all-reports)
  [ ! -s "$net" ] || fail "default bearings path made a network call: $(cat "$net")"
  printf '%s\n' "$out" | jq -e '
    (.in_flight | any(.id == "ship-task" and .kind == "ship"))
      and ([.in_flight[].id] | index("retired-home") | not)
      and (.landed | any(.id == "ship-done" and .owner == "(main)"))
      and (.landed | any(.id == "scout-done" and .owner == "(main)"))
      and (.reports | any(.id == "scout-done" and (.path | endswith("data/scout-done/report.md"))))
  ' >/dev/null || fail "bearings did not project the retained main-home surfaces correctly: $out"
  pass "bearings projects ordinary tasks, landed work, and reports without retired homes or network access"
}

test_removed_secondmate_flag_is_rejected() {
  local home rc
  home=$(make_home removed-flag)
  set +e
  FM_HOME="$home" "$BEARINGS" --json --all-secondmates > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed --all-secondmates flag still succeeded"
  assert_contains "$(cat "$home/err")" "usage:" "removed bearings flag did not fail through the CLI"
  pass "bearings rejects the removed secondmate expansion flag"
}

test_empty_projection
test_main_home_projection_is_local_and_complete
test_removed_secondmate_flag_is_rejected
