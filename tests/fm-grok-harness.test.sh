#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] || exit 1
    printf 'grok\n'
    exit 0
    ;;
  *"#{session_name}"*"#{window_name}"*)
    [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] || exit 1
    printf 'firstmate\tfm-%s\n' "${FM_FAKE_TASK_ID:?}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    case " $* " in
      *" -t "*) [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] || exit 1 ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows)
    [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] && printf 'fm-%s\n' "${FM_FAKE_TASK_ID:?}"
    exit 0
    ;;
  has-session|new-session|send-keys) exit 0 ;;
  new-window) touch "${FM_FAKE_ENDPOINT_FILE:?}"; printf '@1\n'; exit 0 ;;
  kill-window) rm "${FM_FAKE_ENDPOINT_FILE:?}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"firstmate-%s"}]}\n' \
      "${FM_FAKE_PANE_PATH:?}" "${FM_FAKE_TASK_ID:?}" > "${FM_FAKE_TREEHOUSE_STATE:?}"
    printf '%s\n' "$FM_FAKE_PANE_PATH"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$home/treehouse-pools/project/1/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/treehouse-pools" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$wt" checkout --quiet --detach
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false,"lease_holder":null}]}\n' \
    "$wt" > "$home/treehouse-pools/project/treehouse-state.json"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TASK_ID="$id" FM_FAKE_TREEHOUSE_STATE="$home/treehouse-pools/project/treehouse-state.json" \
    FM_FAKE_ENDPOINT_FILE="$home/state/.fake-endpoint" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

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
  pass "grok global hook requires a firstmate registry token"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n%s\n' "$$" 'Mon Jan  1 00:00:00 2024' > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"lstart="*) printf '%s\n' 'Mon Jan  1 00:00:00 2024'; exit 0 ;;
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
test_fm_lock_recognizes_grok_holder
