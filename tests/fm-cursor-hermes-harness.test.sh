#!/usr/bin/env bash
set -u

# Detection, launch mechanics, and busy signatures for the cursor (cursor-agent)
# and hermes (Hermes Agent) harness adapters. Mirrors tests/fm-grok-harness.test.sh:
# a fake tmux stands in for the backend, and the launch command typed into the pane
# is captured to a send-log so the template, autonomy flag, model/effort flags, and
# (for hermes) the post-launch brief delivery can be asserted without a live agent.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-hermes-harness)

# Fake tmux that logs every send-keys payload to $FM_TEST_SENDLOG and answers the
# reads fm-spawn makes: pane_current_path (worktree entry poll) and capture-pane
# (hermes readiness banner). Everything else is a no-op exit 0.
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
  capture-pane)
    # hermes readiness poll greps for this welcome banner line.
    printf 'Welcome to Hermes Agent! Type your message or /help for commands.\n'
    exit 0 ;;
  send-keys)
    [ -n "${FM_TEST_SENDLOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_SENDLOG"
    exit 0 ;;
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
  id="ch-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief body\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <sendlog> <id> <extra-args...>
  local home=$1 proj=$2 wt=$3 fakebin=$4 sendlog=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_TEST_SENDLOG="$sendlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

# --- detection --------------------------------------------------------------

test_detects_cursor_before_claude() {
  local out
  # cursor-agent ALSO sets CLAUDECODE=1; the cursor marker must win.
  out=$(env -i CURSOR_AGENT=1 CLAUDECODE=1 bash "$HARNESS")
  expect_code 0 $? "fm-harness cursor detection should exit 0"
  [ "$out" = cursor ] || fail "cursor+claude markers detected as '$out', expected cursor"
  out=$(env -i CLAUDECODE=1 bash "$HARNESS")
  [ "$out" = claude ] || fail "claude marker alone detected as '$out', expected claude"
  pass "CURSOR_AGENT wins over CLAUDECODE"
}

test_detects_hermes() {
  local out
  out=$(env -i HERMES_SESSION_ID=20260705_x bash "$HARNESS")
  [ "$out" = hermes ] || fail "HERMES_SESSION_ID detected as '$out', expected hermes"
  out=$(env -i HERMES_INTERACTIVE=1 HERMES_SESSION_ID=x bash "$HARNESS")
  [ "$out" = hermes ] || fail "interactive hermes detected as '$out', expected hermes"
  pass "hermes detected from HERMES_SESSION_ID"
}

test_resolves_as_crew_and_secondmate() {
  local cfg
  cfg="$TMP_ROOT/resolve-config"
  mkdir -p "$cfg"
  printf 'cursor\n' > "$cfg/crew-harness"
  [ "$(FM_CONFIG_OVERRIDE=$cfg bash "$HARNESS" crew)" = cursor ] \
    || fail "crew-harness=cursor did not resolve to cursor"
  printf 'hermes\n' > "$cfg/secondmate-harness"
  [ "$(FM_CONFIG_OVERRIDE=$cfg bash "$HARNESS" secondmate)" = hermes ] \
    || fail "secondmate-harness=hermes did not resolve to hermes"
  pass "cursor/hermes resolve as crew and secondmate harnesses"
}

# --- cursor launch mechanics ------------------------------------------------

test_cursor_launch_template() {
  local rec case_dir home proj wt fakebin id sendlog out
  rec=$(make_spawn_case cursor-launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$sendlog" "$id" cursor)
  expect_code 0 $? "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_grep "harness=cursor" "$home/state/$id.meta" "meta did not record harness=cursor"
  assert_grep "cursor-agent --force " "$sendlog" "cursor launch command missing --force autonomy flag"
  # cursor is hookless (stale-pane): no worktree turn-end hook file is written, and
  # in particular NOT claude's Stop hook (cursor is Claude-Code-compatible under the hood).
  assert_absent "$wt/.claude/settings.local.json" "cursor wrongly installed a claude Stop hook"
  assert_absent "$wt/.fm-grok-turnend" "cursor wrongly installed a grok pointer"
  # No hermes post-launch brief pointer for a cursor spawn (the brief rides the launch command).
  assert_no_grep "Your task brief is the file at" "$sendlog" "cursor wrongly got a hermes-style brief pointer"
  pass "cursor launches with --force and no turn-end hook"
}

test_cursor_model_effort_bracket() {
  local rec case_dir home proj wt fakebin id sendlog
  rec=$(make_spawn_case cursor-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$sendlog" "$id" \
    cursor --model composer-2.5 --effort high >/dev/null
  expect_code 0 $? "cursor spawn with model+effort should succeed"
  # cursor folds effort into the model string as a bracket parameter.
  assert_grep "--model 'composer-2.5[effort=high]'" "$sendlog" \
    "cursor did not fold effort into the model bracket"
  assert_grep "model=composer-2.5" "$home/state/$id.meta" "meta did not record the cursor model"
  assert_grep "effort=high" "$home/state/$id.meta" "meta did not record the requested cursor effort"
  pass "cursor maps --effort onto the model bracket form"
}

# --- hermes launch mechanics ------------------------------------------------

test_hermes_launch_and_brief_delivery() {
  local rec case_dir home proj wt fakebin id sendlog out
  rec=$(make_spawn_case hermes-launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$sendlog" "$id" hermes)
  expect_code 0 $? "hermes spawn should succeed"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success"
  assert_grep "harness=hermes" "$home/state/$id.meta" "meta did not record harness=hermes"
  # The interactive TUI is `hermes chat --yolo` with NO positional brief.
  assert_grep "hermes chat --yolo" "$sendlog" "hermes launch command wrong"
  assert_no_grep 'hermes chat --yolo -m' "$sendlog" "hermes launch wrongly carried a model flag when none was set"
  # The brief is delivered as the first interactive message, pointing at the on-disk brief.
  assert_grep "Your task brief is the file at $home/data/$id/brief.md" "$sendlog" \
    "hermes did not deliver the post-launch brief pointer"
  # hermes is hookless (stale-pane): no worktree turn-end hook file.
  assert_absent "$wt/.claude/settings.local.json" "hermes wrongly installed a claude Stop hook"
  assert_absent "$wt/.fm-grok-turnend" "hermes wrongly installed a grok pointer"
  pass "hermes launches via chat --yolo and delivers the brief as the first message"
}

test_hermes_model_flag() {
  local rec case_dir home proj wt fakebin id sendlog
  rec=$(make_spawn_case hermes-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/sendlog"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$sendlog" "$id" \
    hermes --model 'deepseek/deepseek-v4-flash' >/dev/null
  expect_code 0 $? "hermes spawn with model should succeed"
  assert_grep "hermes chat --yolo -m 'deepseek/deepseek-v4-flash'" "$sendlog" \
    "hermes did not wire --model onto -m (provider encoded in the model string)"
  pass "hermes wires firstmate --model onto -m"
}

# --- busy signatures --------------------------------------------------------

test_busy_signatures_match() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  local re=$FM_TMUX_BUSY_REGEX_DEFAULT
  printf '%s\n' '  → Add a follow-up                    ctrl+c to stop' | grep -qiE "$re" \
    || fail "cursor busy footer 'ctrl+c to stop' not matched"
  printf '%s\n' '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel' | grep -qiE "$re" \
    || fail "hermes busy footer 'Ctrl+C cancel' not matched"
  # Idle footers must not read as busy.
  printf '%s\n' '  → Add a follow-up' | grep -qiE "$re" \
    && fail "cursor idle footer wrongly matched busy" || :
  printf '%s\n' '❯' | grep -qiE "$re" \
    && fail "hermes idle prompt wrongly matched busy" || :
  pass "cursor/hermes busy signatures registered in the default busy regex"
}

# --- lock live-holder recognition -------------------------------------------

test_fm_lock_recognizes_holders() {
  local harness comm home fakebin out
  for harness in cursor hermes; do
    home="$TMP_ROOT/lock-$harness"
    fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake-$harness")
    mkdir -p "$home/state"
    printf '%s\n' "$$" > "$home/state/.lock"
    # cursor's process basename is cursor-agent; hermes' is hermes.
    comm="/usr/local/bin/$harness"
    [ "$harness" = cursor ] && comm="/home/u/.local/bin/cursor-agent"
    cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\n' '$comm'; exit 0 ;;
  *"args="*) printf '%s\n' '$harness'; exit 0 ;;
esac
exit 1
SH
    chmod +x "$fakebin/ps"
    out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
    assert_contains "$out" "lock: held by live harness pid" \
      "fm-lock did not recognize $harness as a live holder"
  done
  pass "fm-lock recognizes cursor and hermes harness processes"
}

test_detects_cursor_before_claude
test_detects_hermes
test_fm_lock_recognizes_holders
test_resolves_as_crew_and_secondmate
test_cursor_launch_template
test_cursor_model_effort_bracket
test_hermes_launch_and_brief_delivery
test_hermes_model_flag
test_busy_signatures_match
