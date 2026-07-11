#!/usr/bin/env bash
# Behavior tests for the hermes (Hermes Agent over ACP) crewmate harness:
# named-session launch template, .acpxrc.json install/refusal/cleanup,
# secondmate refusal, process-liveness busy classification, and the
# fail-closed fm-send steer path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)

ACPXRC_CONTENT='{"agents":{"hermes":{"command":"hermes acp"}}}'

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_CMD:-}"; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
  exit 0
fi
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="hermes-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_hermes_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 log=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$log" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" hermes 2>&1
}

test_hermes_spawn_writes_session_launch_and_acpxrc() {
  local rec case_dir home proj wt fakebin id out status log launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  expect_code 0 "$status" "hermes spawn should succeed"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success"

  [ "$(cat "$wt/.acpxrc.json")" = "$ACPXRC_CONTENT" ] \
    || fail "worktree .acpxrc.json does not byte-match fm-spawn's content"
  assert_grep '.acpxrc.json' "$(git -C "$wt" rev-parse --git-path info/exclude)" \
    ".acpxrc.json was not git-excluded"
  assert_grep 'harness=hermes' "$home/state/$id.meta" "meta did not record harness=hermes"

  launch=$(grep 'acpx' "$log" || true)
  assert_contains "$launch" "sessions ensure --name 'fm-$id'" "launch did not ensure the named session"
  assert_contains "$launch" "hermes -s 'fm-$id' prompt" "launch did not prompt into the named session"
  # fm-spawn realpath-resolves the state dir for the turn-end target, so match
  # on the path suffix rather than the (possibly symlinked) $home prefix.
  assert_contains "$launch" "/state/$id.turn-ended'" "launch did not carry the turn-end touch"
  pass "hermes spawn installs .acpxrc.json and a named-session launch with turn-end touch"
}

test_hermes_spawn_refuses_foreign_acpxrc() {
  local rec case_dir home proj wt fakebin id out status log
  rec=$(make_spawn_case foreign)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  printf '%s\n' '{"defaultAgent":"codex"}' > "$wt/.acpxrc.json"
  out=$(run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a foreign .acpxrc.json"
  assert_contains "$out" "without a hermes agent entry" "refusal did not explain the .acpxrc.json conflict"
  [ "$(cat "$wt/.acpxrc.json")" = '{"defaultAgent":"codex"}' ] \
    || fail "foreign .acpxrc.json was modified"
  pass "hermes spawn refuses to overwrite a foreign .acpxrc.json"
}

test_hermes_secondmate_refused() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/sm-state" \
    "$SPAWN" sm-hermes-x1 hermes --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate spawn on hermes should be refused"
  assert_contains "$out" "hermes cannot run a secondmate" "secondmate refusal message missing"
  pass "hermes secondmate spawn is refused with a specific reason"
}

test_hermes_busy_state_process_liveness() {
  local state fakebin target
  state="$TMP_ROOT/busy-state"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/busy-fake")
  target='firstmate:fm-busy-x1'
  mkdir -p "$state"
  {
    echo "window=$target"
    echo "harness=hermes"
  } > "$state/busy-x1.meta"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  busy_probe() {  # <fake-pane-cmd> [state-dir]
    (
      export PATH="$fakebin:$PATH" FM_FAKE_PANE_CMD="$1"
      shift
      fm_backend_busy_state tmux "$target" "$@"
    )
  }
  [ "$(busy_probe node "$state")" = busy ] \
    || fail "non-shell foreground did not classify busy"
  [ "$(busy_probe zsh "$state")" = idle ] \
    || fail "bare shell foreground did not classify idle"
  [ "$(busy_probe '' "$state")" = unknown ] \
    || fail "empty foreground did not classify unknown"
  [ "$(busy_probe node)" = unknown ] \
    || fail "busy_state without a state dir should stay unknown for tmux"
  pass "hermes busy state classifies by foreground-process liveness"
}

make_send_case() {
  local name=$1 case_dir home fakebin id target
  case_dir="$TMP_ROOT/send-$name"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="hermes-send-$name"
  target="firstmate:fm-$id"
  mkdir -p "$home/state"
  {
    echo "window=$target"
    echo "harness=hermes"
    echo "kind=scout"
  } > "$home/state/$id.meta"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$fakebin|$id|$target"
}

run_hermes_send() {
  local home=$1 fakebin=$2 pane_cmd=$3 log=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_PANE_CMD="$pane_cmd" FM_FAKE_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    PATH="$fakebin:$PATH" \
    "$SEND" "$@" 2>&1
}

test_hermes_send_wraps_prompt_when_idle() {
  local rec case_dir home fakebin id target out status log sent
  rec=$(make_send_case idle)
  IFS='|' read -r case_dir home fakebin id target <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_hermes_send "$home" "$fakebin" zsh "$log" "$id" "rebase onto main, then re-run the tests")
  status=$?
  expect_code 0 "$status" "idle hermes steer should send (got: $out)"
  sent=$(cat "$log")
  assert_contains "$sent" "hermes -s 'fm-$id' prompt 'rebase onto main, then re-run the tests'" \
    "steer was not wrapped in an acpx session prompt"
  assert_contains "$sent" "touch '$home/state/$id.turn-ended'" "steer did not carry the turn-end touch"
  pass "fm-send wraps a hermes steer in a named-session acpx prompt"
}

test_hermes_send_fails_closed_when_busy_or_unknown() {
  local rec case_dir home fakebin id target out status log
  rec=$(make_send_case busy)
  IFS='|' read -r case_dir home fakebin id target <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_hermes_send "$home" "$fakebin" node "$log" "$id" "steer text")
  status=$?
  [ "$status" -ne 0 ] || fail "busy hermes steer should be refused"
  assert_contains "$out" "mid-turn" "busy refusal did not explain mid-turn"

  out=$(run_hermes_send "$home" "$fakebin" '' "$log" "$id" "steer text")
  status=$?
  [ "$status" -ne 0 ] || fail "unknown-surface hermes steer should be refused"
  assert_contains "$out" "unconfirmed surface" "unknown refusal did not explain the surface gate"

  out=$(run_hermes_send "$home" "$fakebin" zsh "$log" "$id" "line one
line two")
  status=$?
  [ "$status" -ne 0 ] || fail "multiline hermes steer should be refused"
  assert_contains "$out" "single line" "multiline refusal did not explain the constraint"
  [ ! -s "$log" ] || fail "a refused steer still typed into the pane"
  pass "fm-send fails closed on busy, unknown, and multiline hermes steers"
}

test_hermes_teardown_removes_acpxrc_only_ours() {
  local rec case_dir home proj wt fakebin id out status log
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  expect_code 0 "$status" "hermes spawn should succeed before teardown"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "hermes teardown failed"
  assert_absent "$wt/.acpxrc.json" "firstmate-written .acpxrc.json survived teardown"

  rec=$(make_spawn_case teardown-foreign)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log")
  status=$?
  expect_code 0 "$status" "hermes spawn should succeed before foreign-file teardown"
  printf '%s\n' '{"agents":{"hermes":{"command":"hermes acp"},"other":{}}}' > "$wt/.acpxrc.json"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "hermes teardown (foreign file) failed"
  assert_present "$wt/.acpxrc.json" "a non-matching .acpxrc.json was deleted by teardown"
  pass "teardown removes .acpxrc.json only when it byte-matches fm-spawn's content"
}

test_hermes_spawn_writes_session_launch_and_acpxrc
test_hermes_spawn_refuses_foreign_acpxrc
test_hermes_secondmate_refused
test_hermes_busy_state_process_liveness
test_hermes_send_wraps_prompt_when_idle
test_hermes_send_fails_closed_when_busy_or_unknown
test_hermes_teardown_removes_acpxrc_only_ours
