#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh proxy-env passthrough
# (data/fleet-constitution.md item 19).
#
# Firstmate may reach the Anthropic API/OAuth (and git remotes) through a
# local routing proxy on a restricted network. A freshly spawned crewmate
# pane inherits no environment by default, so without this it would take a
# direct route and be rejected or hang. fm-spawn.sh propagates the same
# proxy vars firstmate itself has set into (1) the treehouse-get window,
# before treehouse's own `git fetch` runs, and (2) the final launch command
# prefix, so the launched agent process gets the same route regardless of
# pane history.
#
# Same fake-tmux convention as tests/fm-spawn-dispatch-profile.test.sh: the
# fake tmux logs every `send-keys` call (both the plain text-line sends and
# the literal `-l` launch send) so assertions can pin exactly what firstmate
# would send to a real pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-proxy)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      printf -- '--- send-keys ---\n' >> "$FM_FAKE_SEND_LOG"
      for a in "$@"; do printf '%s\n' "$a" >> "$FM_FAKE_SEND_LOG"; done
    fi
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn_with_proxy <sendlog> <launchlog> <proxy-env-assignments...> -- <spawn args...>
# Proxy vars are passed as explicit env assignments rather than exported in
# this shell, so each case controls exactly which vars are set/unset without
# leaking the real test runner's ambient proxy config.
run_spawn_with_proxy() {
  local sendlog=$1 launchlog=$2; shift 2
  local proxy_args=()
  while [ "${1:-}" != -- ]; do proxy_args+=("$1"); shift; done
  shift # drop --
  : > "$sendlog"; : > "$launchlog"
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_SEND_LOG="$sendlog" FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    HTTP_PROXY= http_proxy= HTTPS_PROXY= https_proxy= ALL_PROXY= all_proxy= NO_PROXY= no_proxy= \
    "${proxy_args[@]+"${proxy_args[@]}"}" \
    "$SPAWN" "$@" 2>&1
}

test_no_proxy_env_sends_no_export_and_clean_launch() {
  local rec id out status sendlog launchlog launch
  id=proxy-off-z1
  rec=$(make_spawn_case proxy-off claude "$id")
  read_case_record "$rec"
  sendlog="$CASE_DIR/send.log"; launchlog="$CASE_DIR/launch.log"

  out=$(run_spawn_with_proxy "$sendlog" "$launchlog" -- "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with no proxy env set should succeed"

  assert_not_contains "$(cat "$sendlog")" "HTTP_PROXY" "no proxy vars set: window export must not mention HTTP_PROXY"
  launch=$(cat "$launchlog")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model 'claude-sonnet-5' \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "launch changed with no proxy env set"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no proxy env set: window export and launch command carry no proxy vars"
}

test_proxy_env_propagates_to_window_export_and_launch() {
  local rec id out status sendlog launchlog launch
  id=proxy-on-z2
  rec=$(make_spawn_case proxy-on claude "$id")
  read_case_record "$rec"
  sendlog="$CASE_DIR/send.log"; launchlog="$CASE_DIR/launch.log"

  out=$(run_spawn_with_proxy "$sendlog" "$launchlog" \
    HTTP_PROXY="http://127.0.0.1:7890" HTTPS_PROXY="http://127.0.0.1:7890" \
    NO_PROXY="localhost,127.0.0.1" \
    -- "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with proxy env set should succeed"

  # (1) the treehouse-get window: proxy vars exported before `treehouse get`
  # so treehouse's own git fetch takes firstmate's working route.
  assert_contains "$(cat "$sendlog")" "export HTTP_PROXY='http://127.0.0.1:7890' HTTPS_PROXY='http://127.0.0.1:7890' NO_PROXY='localhost,127.0.0.1'" \
    "window export missing the set proxy vars"
  assert_not_contains "$(cat "$sendlog")" "http_proxy=" "window export must not fabricate unset lowercase proxy vars"

  # (2) the launch command prefix: the same vars, quoted, ahead of the
  # harness's own launch command.
  launch=$(cat "$launchlog")
  assert_contains "$launch" "HTTP_PROXY='http://127.0.0.1:7890' HTTPS_PROXY='http://127.0.0.1:7890' NO_PROXY='localhost,127.0.0.1' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "launch command missing the proxy-var prefix"
  pass "set proxy env propagates into both the treehouse-get window export and the launch command prefix"
}

test_proxy_env_propagates_to_secondmate_launch_without_window_export() {
  local rec id out status sendlog launchlog launch sm
  id=proxy-sm-z3
  rec=$(make_spawn_case proxy-sm claude "$id")
  read_case_record "$rec"
  sendlog="$CASE_DIR/send.log"; launchlog="$CASE_DIR/launch.log"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn_with_proxy "$sendlog" "$launchlog" \
    ALL_PROXY="socks5h://127.0.0.1:7890" \
    -- "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with proxy env set should succeed"

  # Secondmate spawns skip `treehouse get` entirely (they launch directly in
  # the persistent home), so there is no window-export send to check - the
  # launch-command prefix is the only propagation path for this kind.
  assert_not_contains "$(cat "$sendlog")" "export ALL_PROXY" "secondmate spawn should not send a treehouse-get window export"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "ALL_PROXY='socks5h://127.0.0.1:7890'" "secondmate launch command missing the proxy-var prefix"
  pass "secondmate spawn (no treehouse-get window) still gets proxy vars via the launch command prefix"
}

test_no_proxy_env_sends_no_export_and_clean_launch
test_proxy_env_propagates_to_window_export_and_launch
test_proxy_env_propagates_to_secondmate_launch_without_window_export

echo "# all fm-spawn-proxy tests passed"
