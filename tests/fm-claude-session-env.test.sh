#!/usr/bin/env bash
# Regression: Claude launch template sanitizes inherited parent session identity.
#
# When a firstmate primary (or any ancestor) still carries Claude Code's
# intentional child-session environment, an unsanitized Claude crewmate or
# secondmate launch inherits CLAUDE_CODE_CHILD_SESSION and related identity
# variables. Claude then disables transcript saving with:
#   "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker"
# and the worker has no independently resumable session.
#
# The fix is owned by bin/fm-spawn.sh's Claude launch_template: a per-launch
# `env -u ...` prefix clears the parent identity pack for firstmate-launched
# Claude direct reports only. These tests pin that launch line for ordinary
# workers and secondmates, prove the prefix actually drops the markers while
# preserving unrelated environment, and leave live CLI evidence to maintainer
# verification docs (no transcript contents or credentials here).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-session-env)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

CLAUDE_SANITIZE_PREFIX='env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_JOB_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false'

make_launch_capturing_tmux() {
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

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# Extract the last non-export launch command from a capturing launch log.
last_launch_command() {
  local log=$1
  # Spawn sends `export GOTMPDIR=...` then the harness launch line.
  grep -v '^export GOTMPDIR=' "$log" | grep -v '^$' | tail -1
}

test_claude_launch_template_source_contains_sanitize_prefix() {
  local line
  line="    claude) printf '%s' '${CLAUDE_SANITIZE_PREFIX} claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "claude launch_template lost the session-identity sanitize prefix"$'\n'"expected source line:"$'\n'"$line"
  pass "claude launch_template source pins env -u parent session identity + prompt-suggestion suppress"
}

test_ordinary_claude_worker_launch_sanitizes_parent_session_env() {
  local case_dir home proj wt fakebin launchlog id out status launch
  case_dir="$TMP_ROOT/ship"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id=claude-sess-ship-z1
  fakebin=$(make_launch_capturing_tmux "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  : > "$launchlog"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
      "$SPAWN" "$id" "$proj" claude 2>&1
  )
  status=$?
  expect_code 0 "$status" "ordinary claude worker spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude" "ship spawn did not report claude"

  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "$CLAUDE_SANITIZE_PREFIX claude --dangerously-skip-permissions" \
    "ordinary claude launch missing sanitize prefix"
  assert_contains "$launch" "encode launch-brief" \
    "ordinary claude launch missing brief encoding"
  # Non-Claude harness markers must not appear on this launch line.
  case "$launch" in
    *codex*|*opencode*|*grok*|*' pi '*|*kimi*) fail "claude ship launch mixed foreign harness tokens: $launch" ;;
  esac
  pass "ordinary Claude worker launch includes the parent-session sanitize prefix"
}

test_claude_secondmate_launch_sanitizes_parent_session_env() {
  local case_dir primary sm fakebin launchlog out status launch
  case_dir="$TMP_ROOT/secondmate"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_launch_capturing_tmux "$case_dir/fake")
  mkdir -p "$primary/data" "$primary/projects" "$primary/state" "$primary/config"
  printf 'claude\n' > "$primary/config/crew-harness"
  printf 'claude\n' > "$primary/config/secondmate-harness"
  make_seeded_secondmate_home "$sm" sm-sess
  : > "$launchlog"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$primary" \
      FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
      FM_PROJECTS_OVERRIDE="$primary/projects" FM_CONFIG_OVERRIDE="$primary/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$sm" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
      "$SPAWN" sm-sess "$sm" claude --secondmate 2>&1
  )
  status=$?
  expect_code 0 "$status" "claude secondmate spawn should succeed"
  assert_contains "$out" "spawned sm-sess harness=claude kind=secondmate" \
    "secondmate spawn did not report claude secondmate"

  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "FM_HOME=" "secondmate launch missing FM_HOME isolation prefix"
  assert_contains "$launch" "$CLAUDE_SANITIZE_PREFIX claude --dangerously-skip-permissions" \
    "claude secondmate launch missing sanitize prefix"
  # Secondmate home overrides come first; sanitize prefix still reaches claude.
  case "$launch" in
    FM_ROOT_OVERRIDE=*\ env\ -u\ CLAUDE_CODE_CHILD_SESSION*) ;;
    *) fail "secondmate launch did not keep FM_* isolation before sanitize env: $launch" ;;
  esac
  pass "Claude secondmate launch includes the parent-session sanitize prefix"
}

test_sanitize_prefix_drops_parent_markers_and_preserves_unrelated_env() {
  # Evaluate the same env prefix the launch template emits against a polluted
  # parent environment and a fake claude that records the effective env.
  local case_dir fakebin marker_file launch
  case_dir="$TMP_ROOT/env-eval"
  fakebin="$case_dir/fakebin"
  marker_file="$case_dir/claude-env.txt"
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'CHILD=%s\n' "${CLAUDE_CODE_CHILD_SESSION-<unset>}"
  printf 'SID=%s\n' "${CLAUDE_CODE_SESSION_ID-<unset>}"
  printf 'PID=%s\n' "${CLAUDE_PID-<unset>}"
  printf 'JOB=%s\n' "${CLAUDE_JOB_DIR-<unset>}"
  printf 'PROMPT_SUGGESTION=%s\n' "${CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION-<unset>}"
  printf 'UNRELATED=%s\n' "${FM_TEST_UNRELATED_ENV-<unset>}"
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-<unset>}"
} > "${FM_FAKE_CLAUDE_ENV_OUT:?}"
exit 0
SH
  chmod +x "$fakebin/claude"

  launch="$CLAUDE_SANITIZE_PREFIX claude --dangerously-skip-permissions"
  # shellcheck disable=SC2086
  env \
    CLAUDE_CODE_CHILD_SESSION=1 \
    CLAUDE_CODE_SESSION_ID=parent-session-id-for-test \
    CLAUDE_PID=12345 \
    CLAUDE_JOB_DIR=/tmp/parent-job-dir \
    CLAUDECODE=1 \
    FM_TEST_UNRELATED_ENV=keep-me \
    FM_FAKE_CLAUDE_ENV_OUT="$marker_file" \
    PATH="$fakebin:$BASE_PATH" \
    bash -c "$launch"

  [ -f "$marker_file" ] || fail "fake claude did not write env capture"
  # assert_grep is fixed-string (grep -F); match whole lines without regex anchors.
  assert_grep 'CHILD=<unset>' "$marker_file" "CHILD_SESSION was not cleared"
  assert_grep 'SID=<unset>' "$marker_file" "SESSION_ID was not cleared"
  assert_grep 'PID=<unset>' "$marker_file" "CLAUDE_PID was not cleared"
  assert_grep 'JOB=<unset>' "$marker_file" "CLAUDE_JOB_DIR was not cleared"
  assert_grep 'PROMPT_SUGGESTION=false' "$marker_file" "prompt-suggestion suppress missing"
  assert_grep 'UNRELATED=keep-me' "$marker_file" "unrelated environment was not preserved"
  assert_grep 'CLAUDECODE=1' "$marker_file" "unrelated CLAUDECODE should still pass through"
  pass "sanitize prefix unsets parent Claude identity and preserves unrelated environment"
}

test_non_claude_launch_templates_untouched() {
  # Guardrail: the identity sanitize is Claude-only and must not leak into
  # other harness launch templates.
  if grep -n "CLAUDE_CODE_CHILD_SESSION" "$SPAWN" | grep -v "claude)" | grep -v '#' >/dev/null 2>&1; then
    # Allow only the claude) template line (and comments) to mention the marker.
    local hits
    hits=$(grep -n "CLAUDE_CODE_CHILD_SESSION" "$SPAWN" | grep -v '^[[:space:]]*#' || true)
    case "$hits" in
      *'claude) printf'*) ;;
      *) fail "CLAUDE_CODE_CHILD_SESSION sanitize leaked outside the claude launch template:"$'\n'"$hits" ;;
    esac
  fi
  ! grep -E "env -u CLAUDE_CODE_CHILD_SESSION" "$SPAWN" | grep -E 'codex|opencode|pi|grok|kimi' >/dev/null \
    || fail "non-claude launch template incorrectly carries Claude session sanitize"
  pass "non-Claude launch templates remain free of Claude session-identity sanitize"
}

test_claude_launch_template_source_contains_sanitize_prefix
test_ordinary_claude_worker_launch_sanitizes_parent_session_env
test_claude_secondmate_launch_sanitizes_parent_session_env
test_sanitize_prefix_drops_parent_markers_and_preserves_unrelated_env
test_non_claude_launch_templates_untouched
