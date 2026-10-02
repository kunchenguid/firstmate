#!/usr/bin/env bash
# Behavior test: fm-spawn.sh must confirm a Claude positional launch brief was
# actually submitted.
#
# Claude takes the launch brief as a positional argument on the launch command, and
# a brief of more than one line is not always submitted by that argument alone:
# Claude leaves it in the composer waiting for its own Enter. Nothing noticed, so
# the worker started, never read a single instruction, and idled until a human
# looked at the pane. Kimi and Rovo already confirm their composer emptied; this
# covers Claude.
#
# Each case runs the real spawn against a fake tmux whose pane plays a scripted
# Claude boot after the launch Enter. Every composer read the shared classifier
# makes (it reads the cursor row first) advances the script by one frame, the last
# frame repeating: `boot` is a pane with no composer at the cursor (unclassifiable),
# `pending` is a composer holding the brief, and `empty` is a drawn, empty
# composer. An Enter pressed on a `pending` frame submits the brief when the case
# allows it, after which every read sees an empty composer.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-brief-submit)

make_claude_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
d=$FM_FAKE_CLAUDE_DIR
frame() {
  local idx=0 i=0 word last=empty
  [ ! -f "$d/submitted" ] || { printf 'empty'; return 0; }
  idx=$(cat "$d/idx" 2>/dev/null || echo 0)
  echo $((idx + 1)) >"$d/idx"
  for word in $FM_FAKE_CLAUDE_SCRIPT; do
    last=$word
    [ "$i" -eq "$idx" ] && { printf '%s' "$word"; return 0; }
    i=$((i + 1))
  done
  printf '%s' "$last"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*)
    if [ ! -f "$d/launched" ]; then
      printf 'none\n'
      exit 0
    fi
    phase=$(frame)
    printf '%s\n' "$phase" >"$d/phase"
    case "$phase" in boot) printf 'none\n' ;; *) printf '2\n' ;; esac
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  kill-window) printf 'kill-window\n' >>"$d/kills"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|set-window-option) exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = -l ]; then
        case "$a" in ". '"*"'") : >"$d/staged" ;; esac
        exit 0
      fi
      prev=$a
    done
    case " $* " in
      *' Enter ') ;;
      *) exit 0 ;;
    esac
    if [ ! -f "$d/launched" ]; then
      [ ! -f "$d/staged" ] || : >"$d/launched"
      exit 0
    fi
    printf 'enter\n' >>"$d/enters"
    if [ "$(cat "$d/phase" 2>/dev/null)" = pending ] && [ "$FM_FAKE_CLAUDE_ENTER_SUBMITS" = yes ]; then
      : >"$d/submitted"
    fi
    exit 0
    ;;
  capture-pane)
    [ -f "$d/launched" ] || exit 0
    phase=$(cat "$d/phase" 2>/dev/null || echo boot)
    [ ! -f "$d/submitted" ] || phase=empty
    case "$phase" in
      pending) printf 'Claude Code\n────────────────\n❯ Read the brief at the launch file\n────────────────\n  ? for shortcuts\n' ;;
      empty) printf 'Claude Code\n────────────────\n❯ \n────────────────\n  ? for shortcuts\n' ;;
      *) printf '$ . /tmp/launch.sh\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# run_claude_spawn <name> <id> <enter-submits> <script...>: spawn a claude task
# against the scripted pane. Sets CASE_DIR, HOME_DIR, OUT and RC.
run_claude_spawn() {
  local name=$1 id=$2 submits=$3 proj wt fakebin
  shift 3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  proj="$CASE_DIR/project"
  wt="$CASE_DIR/wt"
  mkdir -p "$CASE_DIR/pane"
  fakebin=$(make_claude_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise claude brief submission for $id."
  fm_git_worktree "$proj" "$wt" "wt-$name"
  RC=0
  OUT=$(FM_FAKE_CLAUDE_DIR="$CASE_DIR/pane" FM_FAKE_CLAUDE_SCRIPT="$*" \
    FM_FAKE_CLAUDE_ENTER_SUBMITS="$submits" \
    FM_CLAUDE_SUBMIT_POLLS=12 FM_CLAUDE_SUBMIT_RETRIES=3 \
    fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off) || RC=$?
}

enters_count() { [ -f "$CASE_DIR/pane/enters" ] && wc -l <"$CASE_DIR/pane/enters" | tr -d ' ' || echo 0; }

test_slow_boot_brief_is_submitted() {
  run_claude_spawn slow-boot claude-slow-z1 yes boot boot boot boot pending
  expect_code 0 "$RC" "a slow-booting claude whose brief submits on Enter should spawn"$'\n'"$OUT"
  [ "$(enters_count)" -eq 1 ] ||
    fail "a brief that appeared pending after a slow boot must be submitted with one Enter, got $(enters_count)"$'\n'"$OUT"
  pass "claude brief submission: waits through a slow boot, then presses Enter on the pending brief"
}

test_early_empty_composer_is_not_proof_of_submission() {
  run_claude_spawn early-empty claude-early-z2 yes boot empty pending
  expect_code 0 "$RC" "a composer drawn empty before the brief fills should still spawn"$'\n'"$OUT"
  [ "$(enters_count)" -eq 1 ] ||
    fail "a lone empty read before the brief filled must not end the check; expected one Enter, got $(enters_count)"$'\n'"$OUT"
  pass "claude brief submission: a lone empty read drawn before the brief fills keeps polling"
}

test_brief_that_never_submits_fails_the_spawn() {
  local id=claude-stuck-z3
  run_claude_spawn stuck "$id" no boot pending
  [ "$RC" -ne 0 ] || fail "a brief that never leaves the composer must fail the spawn"$'\n'"$OUT"
  assert_contains "$OUT" "composer still holds the launch brief" \
    "the refused spawn did not explain the unsent brief"
  [ "$(enters_count)" -eq 3 ] ||
    fail "the submit retries must bound the Enter attempts, got $(enters_count)"$'\n'"$OUT"
  assert_grep 'failed: claude started but its composer still holds the launch brief' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status") \
    "the refused spawn left no supervisor-visible failure stamp"
  assert_grep 'kill-window' "$CASE_DIR/pane/kills" \
    "the refused spawn left the launched claude running"
  pass "claude brief submission: a brief that never submits fails the spawn, stamps it, and closes the pane"
}

test_unclassifiable_pane_passes_through() {
  run_claude_spawn unknown claude-unknown-z4 yes boot
  expect_code 0 "$RC" "an unclassifiable pane must pass through rather than fail"$'\n'"$OUT"
  [ "$(enters_count)" -eq 0 ] || fail "an unclassifiable pane must not be pressed, got $(enters_count)"
  pass "claude brief submission: an unclassifiable pane is tolerated, not failed"
}

test_already_submitted_brief_needs_no_enter() {
  run_claude_spawn submitted claude-submitted-z5 yes boot empty
  expect_code 0 "$RC" "a brief already submitted should spawn"$'\n'"$OUT"
  [ "$(enters_count)" -eq 0 ] || fail "an empty composer must not be pressed, got $(enters_count)"
  pass "claude brief submission: a brief the launch already submitted needs no Enter"
}

test_slow_boot_brief_is_submitted
test_early_empty_composer_is_not_proof_of_submission
test_brief_that_never_submits_fails_the_spawn
test_unclassifiable_pane_passes_through
test_already_submitted_brief_needs_no_enter
