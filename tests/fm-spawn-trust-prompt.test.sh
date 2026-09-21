#!/usr/bin/env bash
# Regression test for fm-spawn.sh's post-launch trust/bypass-permissions
# dialog check (spawn_trust_prompt_check et al, near kimi_spawn_fail).
#
# The incident this guards against: a worker parked on a harness's
# first-launch trust dialog reports the exact same semantic busy-state
# ("harness busy (fm-spawn)") as one actually processing its brief, because
# no harness hook fires while its own dialog blocks input. Nothing
# distinguished the two until a stale wake, 40 minutes in (see
# data/learnings.md, "Harness/dispatch mechanics", 2026-09-03). This test
# drives a fake tmux pane through: a dialog that clears on the recorded
# remedy (spawn must succeed), a dialog that never clears (spawn must fail
# loudly instead of reporting success), a pane with no dialog at all (spawn
# must succeed without needlessly stalling), and a harness with no recorded
# match string (spawn must print the fallback reminder instead of guessing).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-trust-prompt)

# make_trust_fakebin <dir> builds a fake tmux that: always reports the pane
# already settled in the worktree (so the treehouse-get settle loop resolves
# on its first pair of reads), answers capture-pane from a countfile-driven
# sequence (dialog text for the first FM_FAKE_CAPTURE_DIALOG_CALLS calls,
# clear text after), and appends every send-keys invocation to a log file so
# a test can assert exactly which keys the remedy sent.
make_trust_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *capture-pane*)
    countfile="${FM_FAKE_CAPTURE_COUNTFILE:?FM_FAKE_CAPTURE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_CAPTURE_DIALOG_CALLS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_CAPTURE_DIALOG_TEXT:-}"
    else
      printf '%s\n' "${FM_FAKE_CAPTURE_CLEAR_TEXT:-ready}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  send-keys)
    [ -z "${FM_FAKE_SENDKEYS_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SENDKEYS_LOG"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # pi's harness resolves and probes a real executable on PATH before it ever
  # reaches the trust-prompt check (resolve_pi_executable, pi_supports_tui_mode);
  # only the pi case below needs it, but the stub is harmless for every other
  # harness's spawn.
  fm_fake_exit0 "$fakebin" pi
  printf '%s\n' "$fakebin"
}

# make_trust_case <name> <id> builds a home and a project with a real worktree
# (the settled pane path), matching the fixture shape fm-spawn-worktree-settle
# uses, plus a countfile and send-keys log this suite drives independently.
make_trust_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin countfile keylog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  countfile="$case_dir/capture-call-count"
  keylog="$case_dir/send-keys.log"
  fakebin=$(make_trust_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf '# Task\n\n[captain] brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$keylog"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$countfile|$keylog"
}

read_trust_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR COUNTFILE KEYLOG <<EOF
$1
EOF
}

# run_trust_spawn <id> <harness> <dialog-calls> <dialog-text> <clear-text>
# <detect-polls> <clear-polls>: launch fm-spawn.sh against the fixture read by
# read_trust_record, with small poll counts and a short interval so a
# never-clearing dialog fails the test suite in well under a second rather
# than actually waiting out a production-sized window.
run_trust_spawn() {
  local id=$1 harness=$2 dialog_calls=$3 dialog_text=$4 clear_text=$5 \
    detect_polls=${6:-3} clear_polls=${7:-3}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_CAPTURE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_CAPTURE_DIALOG_CALLS="$dialog_calls" \
    FM_FAKE_CAPTURE_DIALOG_TEXT="$dialog_text" \
    FM_FAKE_CAPTURE_CLEAR_TEXT="$clear_text" \
    FM_FAKE_SENDKEYS_LOG="$KEYLOG" \
    FM_TRUST_DETECT_POLLS="$detect_polls" FM_TRUST_CLEAR_POLLS="$clear_polls" \
    FM_TRUST_POLL_INTERVAL=0.05 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness "$harness" 2>&1
}

CLAUDE_DIALOG='Is this a project you created or one you trust?
❯ 2. No, exit'

# A claude worker parked on the trust dialog: the check must detect it, send
# the recorded Down-then-Enter remedy (never bare Enter, which selects the
# default "No, exit"), confirm the pane cleared, and let the spawn succeed.
test_claude_dialog_clears_on_remedy() {
  local rec id out status
  id=trust-claude-clears-z1
  rec=$(make_trust_case claude-clears "$id")
  read_trust_record "$rec"

  out=$(run_trust_spawn "$id" claude 1 "$CLAUDE_DIALOG" 'ready to work')
  status=$?
  expect_code 0 "$status" "spawn should succeed once the claude trust dialog clears"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep 'Down' "$KEYLOG" "remedy did not send Down off the default No,-exit selection"
  pass "a claude trust dialog that clears on the recorded remedy lets the spawn succeed"
}

# A claude worker parked on the trust dialog whose remedy never clears it
# (a version drift, or a second unrelated bypass-permissions confirmation)
# must fail the spawn loudly instead of reporting success over a parked pane.
test_claude_dialog_persists_fails_loud() {
  local rec id out status
  id=trust-claude-stuck-z2
  rec=$(make_trust_case claude-stuck "$id")
  read_trust_record "$rec"

  out=$(run_trust_spawn "$id" claude 999 "$CLAUDE_DIALOG" 'unused')
  status=$?
  expect_code 1 "$status" "spawn should fail when the trust dialog never clears"
  assert_contains "$out" "parked on its first-launch trust dialog" "failure did not name the parked dialog"
  assert_contains "$out" "$id" "failure did not name the task"
  assert_grep 'Down' "$KEYLOG" "the remedy attempt should still have been sent before failing"
  pass "a claude trust dialog that never clears fails the spawn loudly instead of reporting success"
}

# A pane with no dialog at all must let the spawn succeed without sending any
# remedy keys, and must not stall past its bounded detection window.
test_no_dialog_baseline_succeeds_without_remedy() {
  local rec id out status start end elapsed
  id=trust-claude-none-z3
  rec=$(make_trust_case claude-none "$id")
  read_trust_record "$rec"

  start=$(date +%s)
  out=$(run_trust_spawn "$id" claude 0 "$CLAUDE_DIALOG" 'ready to work')
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when no dialog ever appears"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep 'Down' "$KEYLOG" "no remedy should have been sent when no dialog was ever observed"
  [ "$elapsed" -le 10 ] || fail "a pane with no dialog took ${elapsed}s - the detection window should stay bounded"
  pass "a pane with no trust dialog succeeds without sending remedy keys and without stalling"
}

# Codex's recorded remedy is a single Enter (never Down): its dialog wording
# and default selection differ from claude's, so the harness-keyed table must
# route to the right one, not claude's.
test_codex_dialog_clears_on_single_enter() {
  local rec id out status
  id=trust-codex-clears-z4
  rec=$(make_trust_case codex-clears "$id")
  read_trust_record "$rec"

  out=$(run_trust_spawn "$id" codex 1 'Do you trust the contents of this directory?' 'ready to work')
  status=$?
  expect_code 0 "$status" "spawn should succeed once the codex trust dialog clears"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep 'Down' "$KEYLOG" "codex's remedy is Enter only - Down would be claude's key, not codex's"
  pass "a codex trust dialog clears on its own single-Enter remedy"
}

# Pi has no verified match string (harness-adapters pi.md), so the check must
# neither guess at a signature nor silently skip the harness: it prints the
# documented fallback reminder and lets the spawn proceed.
test_pi_with_no_signature_prints_reminder() {
  local rec id out status
  id=trust-pi-reminder-z5
  rec=$(make_trust_case pi-reminder "$id")
  read_trust_record "$rec"

  out=$(run_trust_spawn "$id" pi 0 '' 'ready to work')
  status=$?
  expect_code 0 "$status" "spawn should succeed for pi (no automated dialog handling)"
  assert_contains "$out" "no verified trust-dialog match string" "pi should print the fallback reminder, not guess at a signature"
  assert_no_grep 'Down' "$KEYLOG" "pi has no recorded remedy to send"
  pass "pi with no recorded trust-dialog signature prints the fallback reminder instead of guessing"
}

test_claude_dialog_clears_on_remedy
test_claude_dialog_persists_fails_loud
test_no_dialog_baseline_succeeds_without_remedy
test_codex_dialog_clears_on_single_enter
test_pi_with_no_signature_prints_reminder

echo "# all fm-spawn-trust-prompt tests passed"
