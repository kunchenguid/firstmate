#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-harness)
GROK_AGENT_PIDS=()

cleanup_grok_agents() {
  local pid
  for pid in "${GROK_AGENT_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_grok_agents EXIT

start_grok_agent() {
  local home=$1 wt=$2 id=$3 fifo
  fifo="${home%/home}/agent.fifo"
  mkfifo "$fifo"
  (
    cd "$wt" || exit 1
    exec env FM_AGENT_TASK="$id" FM_AGENT_OWNER_HOME="$home" \
      FM_AGENT_ROLE=crewmate bash -c \
      'fifo=$1; exec 3<>"$fifo"; trap "cd /tmp" TERM; while :; do IFS= read -r -t 1 -u 3 _ || :; done' \
      _ "$fifo"
  ) >/dev/null 2>&1 &
  GROK_AGENT_PIDS+=("$!")
  GROK_AGENT_PID=$!
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_AGENT_PID:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    if [ -n "${FM_FAKE_AGENT_PID:-}" ] && kill -0 "$FM_FAKE_AGENT_PID" 2>/dev/null; then
      printf '%s\n' grok
    else
      printf '%s\n' bash
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{window_name}"*) cat "$FM_FAKE_TMUX_STATE" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0 ;;
  list-windows)
    case "$*" in
      *"#{window_id}"*) printf '@42 %s\n' "${FM_FAKE_WINDOW_NAME:-}" ;;
      *"#{window_name}"*) [ -f "$FM_FAKE_TMUX_STATE" ] && cat "$FM_FAKE_TMUX_STATE" ;;
    esac
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  kill-window)
    kill "${FM_FAKE_AGENT_PID:-}" 2>/dev/null || true
    exit 0
    ;;
  send-keys)
    for arg in "$@"; do
      if [[ "$arg" == *"treehouse get --lease --lease-holder"* ]]; then
        bash -c "$arg"
        break
      fi
    done
    exit 0
    ;;
  new-window) printf '%s\n' '@42'; exit 0 ;;
  set-window-option) exit 0 ;;
  rename-window) printf '%s\n' "${@: -1}" > "$FM_FAKE_TMUX_STATE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:?}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id runtime
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  runtime="$case_dir/runtime"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home" "$runtime"
  fm_git_init_commit "$home"
  printf '# agents\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm agents
  cp -a "$ROOT/bin" "$runtime/"
  if [ -n "${NO_MISTAKES_GATE:-}" ]; then
    cat >> "$runtime/bin/fm-agent-cwd-lib.sh" <<'SH'
fm_agent_worktree_process_census() { return 1; }
SH
  fi
  ln -s "$runtime/bin" "$home/bin"
  printf 'brief\n' > "$home/data/$id/brief.md"
  printf 'root=%s\ntoken=grok-%s\n' "$home" "$name" > "$home/state/.primary-attestation"
  printf '%s|codex:grok-harness|fallback\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6 token
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' "$home/state/.primary-attestation")
  (
    cd "$home" || exit 1
    env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_PRIMARY_ATTESTATION="$token" CODEX_THREAD_ID=grok-harness \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_AGENT_PID="$GROK_AGENT_PID" FM_FAKE_WINDOW_NAME="fm-$id" \
      FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_STATE="$home/tmux-window-name" \
      TMUX="fake,1,0" \
      GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
      "$home/bin/fm-spawn.sh" "$id" "$proj" grok 2>&1
  )
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook config token target evil evil_target
  rec=$(make_spawn_case hook-conflict)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  mkdir -p "$grok_home/hooks"
  printf '%s\n' user-hook > "$grok_home/hooks/fm-turn-end.sh"
  printf '%s\n' user-config > "$grok_home/hooks/fm-turn-end.json"
  start_grok_agent "$home" "$wt" "$id"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 1 "$status" "grok spawn should refuse a conflicting global hook"
  [ "$(cat "$grok_home/hooks/fm-turn-end.sh")" = user-hook ] \
    || fail "grok spawn overwrote the user's global hook script"
  [ "$(cat "$grok_home/hooks/fm-turn-end.json")" = user-config ] \
    || fail "grok spawn overwrote the user's global hook configuration"
  kill -KILL "$GROK_AGENT_PID" 2>/dev/null || true
  wait "$GROK_AGENT_PID" 2>/dev/null || true

  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  start_grok_agent "$home" "$wt" "$id"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  config="$grok_home/hooks/fm-turn-end.json"
  assert_present "$hook" "grok hook script was not installed"
  assert_present "$config" "grok hook configuration was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"
  unlink "$target"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  kill -KILL "$GROK_AGENT_PID" 2>/dev/null || true
  wait "$GROK_AGENT_PID" 2>/dev/null || true
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token attestation
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  attestation=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' "$home/state/.primary-attestation")
  start_grok_agent "$home" "$wt" "$id"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  (
    cd "$home" || exit 1
    env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_ATTESTATION="$attestation" CODEX_THREAD_ID=grok-harness \
      FM_FAKE_AGENT_PID="$GROK_AGENT_PID" FM_FAKE_WINDOW_NAME="fm-$id" \
      FM_FAKE_TMUX_STATE="$home/tmux-window-name" \
      GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
      "$home/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1
  ) || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  kill -KILL "$GROK_AGENT_PID" 2>/dev/null || true
  wait "$GROK_AGENT_PID" 2>/dev/null || true
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
