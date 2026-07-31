#!/usr/bin/env bash
# Regression tests for endpoint-state publication during fm-spawn bootstrap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-bootstrap-endpoint)

make_fakebin() {  # <case-dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "${FM_FAKE_HERDR_CASE:?}"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}\n'
    ;;
  "tab list")
    printf '{"result":{"tabs":[]}}\n'
    ;;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"t-target"},"root_pane":{"pane_id":"p-target"}}}\n'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = p-target ] && [ -f "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    elif [ "$pane" = p-target ]; then
      printf '{"result":{"pane":{"pane_id":"p-target","tab_id":"t-target","workspace_id":"w-home","foreground_cwd":"%s"}}}\n' "${FM_FAKE_HERDR_CWD:?}"
    elif [ "$pane" = p-unrelated ]; then
      printf '{"result":{"pane":{"pane_id":"p-unrelated","tab_id":"t-unrelated","workspace_id":"w-home","foreground_cwd":"/keep"}}}\n'
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    ;;
  "pane close")
    [ "${3:-}" = p-target ] || exit 97
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
esac
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 dir home proj wt fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/worktree"
  fakebin=$(make_fakebin "$dir")
  mkdir -p "$home/state" "$home/data/$id" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  : > "$dir/herdr.log"
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin|$dir/herdr.log|$dir/closed"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR HERDR_LOG CLOSED_FILE <<EOF
$1
EOF
}

run_spawn() {  # <id> <reported-pane-cwd>
  local id=$1 cwd=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_SPAWN_NO_GUARD=1 \
    HERDR_SESSION=default FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_HERDR_CASE="$CASE_DIR" \
    FM_FAKE_HERDR_CLOSED="$CLOSED_FILE" FM_FAKE_HERDR_CWD="$cwd" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "sh -c 'true'" --backend herdr 2>&1
}

test_failed_flat_herdr_bootstrap_stays_discoverable_and_tears_down_exactly() {
  local rec id=herdr-bootstrap-fail-a1 out status tdout
  rec=$(make_case failed "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "flat Herdr spawn should fail when bootstrap never leaves the project"
  assert_contains "$out" "treehouse get did not enter a worktree" "failure did not reach the post-endpoint bootstrap boundary"
  assert_present "$HOME_DIR/state/$id.meta" "failed flat Herdr spawn left no durable endpoint metadata"
  assert_grep 'spawn_phase=bootstrap' "$HOME_DIR/state/$id.meta" "bootstrap record was not marked for guarded endpoint-only teardown"
  assert_grep 'window=default:p-target' "$HOME_DIR/state/$id.meta" "bootstrap record did not bind the exact Herdr pane"
  assert_grep 'project=' "$HOME_DIR/state/$id.meta" "bootstrap record lost the project identity"
  assert_grep 'failed: spawn bootstrap did not complete' "$HOME_DIR/state/$id.status" "failed bootstrap did not publish terminal status"

  : > "$HERDR_LOG"
  tdout=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    HERDR_SESSION=default FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_HERDR_CASE="$CASE_DIR" \
    FM_FAKE_HERDR_CLOSED="$CLOSED_FILE" FM_FAKE_HERDR_CWD="$PROJ_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "guarded teardown should reclaim the recorded failed-bootstrap endpoint"
  assert_contains "$tdout" "tore down failed bootstrap endpoint" "teardown did not take its endpoint-only path"
  assert_present "$CLOSED_FILE" "guarded teardown did not close the exact failed Herdr pane"
  assert_absent "$HOME_DIR/state/$id.meta" "guarded teardown did not retire recovered bootstrap state"
  assert_not_contains "$(cat "$HERDR_LOG")" 'pane close p-unrelated' "bootstrap teardown closed an unrelated pane"
  assert_not_contains "$(cat "$HERDR_LOG")" 'session stop' "bootstrap teardown touched a Herdr session"
  assert_not_contains "$(cat "$HERDR_LOG")" 'session delete' "bootstrap teardown touched a Herdr session"
  pass "fm-spawn: failed flat Herdr bootstrap remains discoverable and teardown closes only its exact pane"
}

test_successful_spawn_replaces_bootstrap_record_with_normal_metadata() {
  local rec id=herdr-bootstrap-success-b2 out status
  rec=$(make_case successful "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "successful flat Herdr spawn should remain unchanged"
  assert_contains "$out" "spawned $id" "successful spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "successful spawn did not publish its isolated worktree"
  assert_no_grep 'spawn_phase=bootstrap' "$HOME_DIR/state/$id.meta" "successful spawn retained bootstrap-only metadata"
  pass "fm-spawn: successful Herdr spawn replaces the bootstrap record with ordinary metadata"
}

test_failed_flat_herdr_bootstrap_stays_discoverable_and_tears_down_exactly
test_successful_spawn_replaces_bootstrap_record_with_normal_metadata

echo "# all fm-spawn-bootstrap-endpoint tests passed"
