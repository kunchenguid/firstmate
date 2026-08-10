#!/usr/bin/env bash
# Spawn behavior tests for Herdr display labels, metadata, and crash journal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-label)

make_herdr_spawn_fake() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
cmd=${1:-}; sub=${2:-}
args=("$@")
workspace=
label=
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i + 1))]:-} ;;
    --label) label=${args[$((i + 1))]:-} ;;
  esac
done
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "session list")
    if [ "${FM_FAKE_MALFORMED_SOCKET:-0}" = 1 ]; then
      printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":null}]}\n'
    else
      printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"%s"}]}\n' "${FM_FAKE_SESSION_SOCKET:-$state/fmtest.sock}"
    fi
    ;;
  "workspace list")
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ] && [ -f "$state/projection-label" ]; then
      projection_label=$(cat "$state/projection-label")
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t0"},{"workspace_id":"w2","label":"%s","focused":false,"active_tab_id":"w2:t1"}]}}\n' "$projection_label"
    elif [ -f "$state/workspace" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t0"}]}}\n'
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    ;;
  "workspace create")
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ]; then
      printf '%s\n' "$label" > "$state/projection-label"
      touch "$state/projection-created"
      printf '{"result":{"workspace":{"workspace_id":"w2","label":"%s"},"tab":{"tab_id":"w2:t0"},"root_pane":{"pane_id":"w2:p0"}}}\n' "$label"
    else
      touch "$state/workspace"
      printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"root_pane":{"pane_id":"w1:p0"}}}\n'
    fi
    ;;
  "tab list")
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ] && [ "$workspace" = w2 ]; then
      projection_task_label=$(cat "$state/projection-task-label" 2>/dev/null || true)
      if [ -f "$state/projection-seeded-closed" ]; then
        printf '{"result":{"tabs":[{"tab_id":"w2:t1","label":"%s","workspace_id":"w2"}]}}\n' "$projection_task_label"
      else
        printf '{"result":{"tabs":[{"tab_id":"w2:t0","label":"1","workspace_id":"w2"},{"tab_id":"w2:t1","label":"%s","workspace_id":"w2"}]}}\n' "$projection_task_label"
      fi
    elif [ -f "$state/task-label" ]; then
      label=$(cat "$state/task-label")
      printf '{"result":{"tabs":[{"tab_id":"w1:t0","label":"%s","workspace_id":"w1","focused":true}]}}\n' "$label"
    else
      printf '{"result":{"tabs":[{"tab_id":"w1:t0","label":"1","workspace_id":"w1","focused":true}]}}\n'
    fi
    ;;
  "tab create")
    if [ -f "${FM_FAKE_LABEL_JOURNAL:?}" ]; then
      cp "$FM_FAKE_LABEL_JOURNAL" "$state/journal-at-create"
    fi
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ] && [ "$workspace" = w2 ]; then
      printf '%s\n' "$label" > "$state/projection-task-label"
      if [ "${FM_FAKE_FAIL_AFTER_CREATE:-0}" = 1 ]; then
        exit 1
      fi
      printf '{"result":{"tab":{"tab_id":"w2:t1"},"root_pane":{"pane_id":"w2:p1"}}}\n'
    else
      printf '%s\n' "$label" > "$state/task-label"
      if [ "${FM_FAKE_FAIL_AFTER_CREATE:-0}" = 1 ]; then
        exit 1
      fi
      printf '{"result":{"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    fi
    ;;
  "pane list")
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ] && [ "$workspace" = w2 ]; then
      if [ -f "$state/projection-seeded-closed" ]; then
        printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n'
      else
        printf '{"result":{"panes":[{"pane_id":"w2:p0","tab_id":"w2:t0"},{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n'
      fi
    else
      printf '{"result":{"panes":[]}}\n'
    fi
    ;;
  "tab get")
    printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"w1"}}}\n' "${workspace:-w1:t0}"
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found"}}\n'
    ;;
  "pane close")
    case "${args[2]:-}" in
      w2:p0) touch "$state/projection-seeded-closed" ;;
    esac
    ;;
  "pane get")
    pane_id=${args[2]:-w1:p1}
    if [ "${FM_FAKE_PROJECTION:-0}" = 1 ] && [ "$pane_id" = w2:p1 ] \
      && [ "${FM_FAKE_CLEANUP_WAIT:-0}" = 1 ] \
      && [ -f "$state/projection-created" ] \
      && [ -f "$state/send-failed" ] \
      && [ ! -f "$state/cleanup-started" ]; then
      touch "$state/cleanup-started"
      while [ ! -f "$state/cleanup-proceed" ]; do sleep 0.01; done
    fi
    case "$pane_id" in
      w2:p0) printf '{"result":{"pane":{"pane_id":"w2:p0","tab_id":"w2:t0","workspace_id":"w2"}}}\n' ;;
      w2:p1) printf '{"result":{"pane":{"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2","foreground_cwd":"%s"}}}\n' "${FM_FAKE_WORKTREE:?}" ;;
      *) printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s"}}}\n' "${FM_FAKE_WORKTREE:?}" ;;
    esac
    ;;
  "pane run")
    run_command=${args[3]:-}
    case "$run_command" in
      *spawn-worktree*)
        proof=${run_command#*\> \'}
        proof=${proof%%\'*}
        [ -n "$proof" ] && printf '%s\n' "${FM_FAKE_WORKTREE:?}" > "$proof"
        ;;
    esac
    ;;
  "pane send-text")
    if [ "${FM_FAKE_FAIL_SEND_LITERAL:-0}" = 1 ]; then
      touch "$state/send-failed"
      exit 1
    fi
    ;;
  "pane send-keys")
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$case_dir/herdr-state" "$case_dir/tmp" "$case_dir/bin/backends"
  for bin_file in fm-spawn.sh fm-worker-isolation-lib.sh fm-tool-path-lib.sh fm-ff-lib.sh \
    fm-wake-lib.sh fm-config-inherit-lib.sh fm-cbm-lib.sh fm-backend.sh \
    fm-task-label-lib.sh fm-pr-lib.sh fm-agent-cwd-lib.sh fm-session-lock-lib.sh fm-slot-owner-lib.sh \
    fm-scope-contract.sh fm-harness.sh fm-route.sh fm-project-mode.sh fm-cbm-cli.sh \
    fm-composer-lib.sh fm-transition-lib.sh; do
    ln -s "$ROOT/bin/$bin_file" "$case_dir/bin/$bin_file"
  done
  ln -s "$ROOT/bin/backends/herdr.sh" "$case_dir/bin/backends/herdr.sh"
  ln -s "$case_dir/bin" "$home/bin"
  cat > "$case_dir/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fakebin=$(make_herdr_spawn_fake "$case_dir/fake")
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  SPAWN="$CASE_DIR/bin/fm-spawn.sh"
}

run_spawn() {
  local id=$1
  shift
    FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMPDIR="$CASE_DIR/tmp" \
    FM_AGENT_ROLE=secondmate FM_AGENT_TASK="$id" FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_MALFORMED_SOCKET="${FM_FAKE_MALFORMED_SOCKET:-0}" FM_FAKE_SESSION_SOCKET="${FM_FAKE_SESSION_SOCKET:-}" \
    FM_FAKE_FAIL_AFTER_CREATE="${FM_FAKE_FAIL_AFTER_CREATE:-0}" FM_FAKE_PROJECTION="${FM_FAKE_PROJECTION:-0}" \
    FM_FAKE_FAIL_SEND_LITERAL="${FM_FAKE_FAIL_SEND_LITERAL:-0}" FM_FAKE_CLEANUP_WAIT="${FM_FAKE_CLEANUP_WAIT:-0}" \
    FM_FAKE_LABEL_JOURNAL="$HOME_DIR/state/$id.herdr-label" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --backend herdr "$@" 2>&1
}

test_spawn_publishes_journal_before_create_then_atomic_meta() {
  local rec id out status meta task_tmp
  id=herdr-label-c1db
  rec=$(make_case success "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --scout --display-title "Herdr labels")
  status=$?
  expect_code 0 "$status" "Herdr display-label spawn should succeed (output: $out)"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "display_label=Scout - Herdr labels · c1db" "$meta" "meta missing persisted display label"
  assert_grep "task_key=c1db" "$meta" "meta missing task key"
  assert_grep "herdr_tab_id=w1:t1" "$meta" "meta missing response-derived tab id"
  assert_grep "herdr_pane_id=w1:p1" "$meta" "meta missing response-derived pane id"
  task_tmp=$(sed -n 's/^tasktmp=//p' "$meta")
  case "$task_tmp" in
    "$CASE_DIR/tmp/fm-$id".*) ;;
    *) fail "spawn did not allocate a private task temp root: $task_tmp" ;;
  esac
  assert_present "$task_tmp/.fm-tasktmp-owner" "private task temp root lacks its ownership marker"
  assert_grep "herdr_home=$HOME_DIR" "$CASE_DIR/herdr-state/journal-at-create" "label journal missed the Herdr home before tab create"
  assert_grep "herdr_session=fmtest" "$CASE_DIR/herdr-state/journal-at-create" "label journal missed the Herdr session before tab create"
  assert_grep "herdr_workspace_id=w1" "$CASE_DIR/herdr-state/journal-at-create" "label journal missed the Herdr workspace before tab create"
  assert_absent "$HOME_DIR/state/$id.herdr-label" "label journal should retire only after final metadata publication"
  assert_grep "--label Scout - Herdr labels · c1db --no-focus" "$CASE_DIR/herdr.log" "Herdr tab did not use the display label"
  pass "fm-spawn Herdr: journal precedes create; final metadata persists label, key, and exact ids"
}

test_lost_create_response_keeps_recovery_journal() {
  local rec id out status journal
  id=herdr-crash-be28
  rec=$(make_case crash "$id")
  read_case "$rec"
  set +e
  out=$(FM_FAKE_FAIL_AFTER_CREATE=1 run_spawn "$id" --display-title "UI Design")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "simulated create-response loss should fail spawn"
  journal="$HOME_DIR/state/$id.herdr-label"
  assert_present "$journal" "pre-create journal was lost after create-response failure"
  assert_grep "display_label=Crew - UI Design · be28" "$journal" "recovery journal lost exact created label"
  assert_grep "herdr_home=$HOME_DIR" "$journal" "recovery journal lost the Herdr home"
  assert_grep "herdr_workspace_id=w1" "$journal" "recovery journal lost the Herdr workspace"
  assert_present "$HOME_DIR/state/$id.herdr-cleanup-uncertain" "create uncertainty did not persist its recovery marker"
  assert_grep "reason=tab create mutation identity unavailable" "$HOME_DIR/state/$id.herdr-cleanup-uncertain" "create uncertainty lost its reason"
  assert_grep "scope=fmtest:w1" "$HOME_DIR/state/$id.herdr-cleanup-uncertain" "create uncertainty lost its exact scope"
  assert_absent "$HOME_DIR/state/$id.meta" "failed spawn must not publish final metadata"
  pass "fm-spawn Herdr: a create/final-meta crash gap remains exactly correlated by the journal"
}

test_failed_projection_releases_label_lock() {
  local rec id out status journal lock
  id=herdr-lock-f4a1
  rec=$(make_case lock-failure "$id")
  read_case "$rec"
  touch "$HOME_DIR/config/herdr-presentation-spaces"
  journal="$HOME_DIR/state/$id.herdr-presentation"
  printf 'broken journal\n' > "$journal"
  set +e
  out=$(run_spawn "$id" --scout --display-title "Lock failure")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "malformed projection recovery should refuse the spawn: $out"
  lock="$HOME_DIR/state/.herdr-label.lock"
  ROOT="$ROOT" LOCK="$lock" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_AGENT_ROLE=secondmate FM_AGENT_TASK="$id" \
    FM_AGENT_OWNER_HOME="$HOME_DIR" \
    bash -c '. "$ROOT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$LOCK" && fm_lock_release "$LOCK"' \
    || fail "failed projection left the Herdr label lock held"
  pass "fm-spawn Herdr: projection failure releases the label lock for later spawns"
}

test_projected_abort_cleanup_holds_session_lock() {
  local rec id out status spawn_pid lock
  id=herdr-projection-8e12
  rec=$(make_case projection-abort "$id")
  read_case "$rec"
  touch "$HOME_DIR/config/herdr-presentation-spaces"
  set +e
  FM_FAKE_PROJECTION=1 FM_FAKE_FAIL_SEND_LITERAL=1 FM_FAKE_CLEANUP_WAIT=1 \
    run_spawn "$id" --scout --display-title "Projection abort" > "$CASE_DIR/spawn.out" 2>&1 &
  spawn_pid=$!
  set -e
  for _ in $(seq 1 300); do
    [ -e "$CASE_DIR/herdr-state/cleanup-started" ] && break
    sleep 0.01
  done
  [ -e "$CASE_DIR/herdr-state/cleanup-started" ] || {
    out=$(cat "$CASE_DIR/spawn.out" 2>/dev/null || true)
    kill "$spawn_pid" 2>/dev/null || true
    wait "$spawn_pid" 2>/dev/null || true
    fail "projected abort cleanup did not reach its exact-pane close path: $out"
  }
  lock=$(FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    PATH="$FAKEBIN_DIR:$PATH" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT") \
    || fail "could not resolve the Herdr presentation session lock"
  if ROOT="$ROOT" LOCK="$lock" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_AGENT_ROLE=secondmate FM_AGENT_TASK="$id" \
    FM_AGENT_OWNER_HOME="$HOME_DIR" \
    bash -c '. "$ROOT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$LOCK"'; then
    touch "$CASE_DIR/herdr-state/cleanup-proceed"
    wait "$spawn_pid" 2>/dev/null || true
    fail "a concurrent Herdr projection mutation acquired the lock during abort cleanup"
  fi
  touch "$CASE_DIR/herdr-state/cleanup-proceed"
  set +e
  wait "$spawn_pid"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "forced post-projection send failure should abort spawn"
  ROOT="$ROOT" LOCK="$lock" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_AGENT_ROLE=secondmate FM_AGENT_TASK="$id" \
    FM_AGENT_OWNER_HOME="$HOME_DIR" \
    bash -c '. "$ROOT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$LOCK" && fm_lock_release "$LOCK"' \
    || fail "presentation lock remained held after projected abort cleanup"
  pass "fm-spawn Herdr: projected abort cleanup holds and then releases the session lock"
}

test_spawn_malformed_session_socket_uses_flat_layout() {
  local rec id out status
  id=herdr-flat-cb27
  rec=$(make_case malformed "$id")
  read_case "$rec"
  touch "$HOME_DIR/config/herdr-presentation-spaces"
  set +e
  out=$(FM_FAKE_MALFORMED_SOCKET=1 run_spawn "$id" --scout --display-title "Malformed socket")
  status=$?
  set -e
  expect_code 0 "$status" "malformed session socket should fall back to a successful flat spawn: $out"
  assert_present "$HOME_DIR/state/$id.meta" "flat fallback did not publish task metadata"
  assert_absent "$HOME_DIR/state/$id.herdr-presentation" "flat fallback published a projection journal"
  pass "fm-spawn Herdr: malformed session socket falls back through the executable spawn path"
}

test_spawn_insecure_session_socket_uses_flat_layout() {
  local rec id out status socket_dir socket
  id=herdr-flat-df38
  rec=$(make_case insecure "$id")
  read_case "$rec"
  touch "$HOME_DIR/config/herdr-presentation-spaces"
  socket_dir="$CASE_DIR/insecure-socket"; mkdir -m 755 "$socket_dir"
  socket="$socket_dir/fmtest.sock"; : > "$socket"
  set +e
  out=$(FM_FAKE_SESSION_SOCKET="$socket" run_spawn "$id" --scout --display-title "Insecure socket")
  status=$?
  set -e
  expect_code 0 "$status" "insecure session socket should fall back to a successful flat spawn: $out"
  assert_present "$HOME_DIR/state/$id.meta" "insecure lock fallback did not publish task metadata"
  assert_absent "$HOME_DIR/state/$id.herdr-presentation" "insecure lock fallback published a projection journal"
  pass "fm-spawn Herdr: insecure session socket falls back through the executable spawn path"
}

test_spawn_publishes_journal_before_create_then_atomic_meta
test_lost_create_response_keeps_recovery_journal
test_failed_projection_releases_label_lock
test_projected_abort_cleanup_holds_session_lock
test_spawn_malformed_session_socket_uses_flat_layout
test_spawn_insecure_session_socket_uses_flat_layout

echo "# all fm-spawn-herdr-label tests passed"
