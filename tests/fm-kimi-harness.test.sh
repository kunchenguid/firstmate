#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

assert_source_line() {
  local line=$1
  grep -Fqx -- "$line" "$SPAWN" || fail "existing launch template changed: $line"
}

test_existing_launch_templates_are_byte_pinned() {
  assert_source_line "    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch __TURNEND__\\\"]\" \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\\''{\"permission\":{\"*\":\"allow\"}}'\\'' opencode __MODELFLAG__--prompt \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  pass "fm-spawn: the five pre-existing adapters' launch templates stay byte-pinned"
}

test_tracked_files_have_no_user_absolute_paths() {
  local pattern="/""Users/" matches
  matches=$(git -C "$ROOT" grep -n -F "$pattern" -- . || true)
  [ -z "$matches" ] || fail "tracked files contain user-specific absolute paths: $matches"
  pass "repository: tracked files contain no user-specific absolute paths"
}

test_kimi_is_not_detected_as_primary_harness() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/opt/kimi/bin/kimi\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "passive-only Kimi ancestry should not identify a primary harness, got '$out'"
  out=$(CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: passive-only Kimi is excluded from primary ancestry detection"
}

test_kimi_is_not_a_primary_session_lock_identity() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/kimi/bin/kimi'; exit 0 ;;
  *"args="*) printf '%s\n' 'kimi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  if PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$1/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid >/dev/null' _ "$ROOT"; then
    fail "passive-only Kimi ancestry was accepted as a primary session-lock identity"
  fi
  pass "session lock excludes passive-only Kimi ancestry"
}

test_kimi_busy_signature_is_scoped_to_spinner_lines() {
  local capture phase kimi_regex_lines
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  # These fixtures reproduce the observed spinner shape rather than byte-exact
  # transcriptions. Leading whitespace is deliberately varied; separator whitespace
  # follows the captured contract.
  printf ' 🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"\n│ > │\n' > "$capture"
  fm_pane_is_busy fake kimi || fail "the first real Kimi spinner shape was not recognized as busy"
  printf '   🌗 · Tip: /plugins: manage plugins ...\n│ > │\n' > "$capture"
  fm_pane_is_busy fake kimi || fail "the tool-execution Kimi spinner shape was not recognized as busy"
  printf 'ordinary response ending with 🌕\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "a moon outside Kimi's spinner-line shape was misread as busy"
  fi
  printf '🌕 Full moon details\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "moon-led Kimi output without the middot separator was misread as busy"
  fi
  printf '  🌗 · Tip: /plugins: manage plugins ...\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "Kimi's real spinner signature leaked into another harness"
  fi
  printf 'tip: ctrl+c: cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "kimi's independently rotating idle tip was misread as busy"
  fi
  printf 'Ctrl+c:cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Grok's exact busy token leaked into Kimi's harness-scoped matcher"
  fi
  printf 'auto  K2.7 Coding thinking  /some/path\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Kimi's idle thinking-effort status label was misread as busy"
  fi
  kimi_regex_lines=$(grep 'KIMI_BUSY_REGEX' "$ROOT/bin/fm-tmux-lib.sh" "$ROOT/bin/fm-watch.sh")
  if printf '%s\n' "$kimi_regex_lines" | grep -qi thinking; then
    fail "Kimi busy regex still depends on a Thinking or thinking token"
  fi
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    grep -Fq "$phase" "$ROOT/bin/fm-tmux-lib.sh" \
      || fail "shared Kimi matcher is missing moon phase $phase"
  done
  pass "busy detection: real Kimi moon-plus-middot captures require its harness while idle labels stay idle"
}

test_watcher_scopes_moon_spinner_to_recorded_kimi_task() (
  local state="$TMP_ROOT/watch-state" busy_capture='  🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'
  mkdir -p "$state"
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  window_is_busy fake "$busy_capture" \
    || fail "fm-watch did not recognize the real Kimi spinner-line shape"
  printf 'window=fake\nharness=codex\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch applied Kimi's real spinner signature to a recorded Codex task"
  fi
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  if window_is_busy fake 'ordinary response ending with 🌕'; then
    fail "fm-watch treated an ordinary Kimi moon as a spinner line"
  fi
  if window_is_busy fake '🌕 Full moon details'; then
    fail "fm-watch treated moon-led Kimi output without the middot separator as busy"
  fi
  if window_is_busy fake 'auto  K2.7 Coding thinking  /some/path'; then
    fail "fm-watch treated Kimi's idle thinking-effort status label as busy"
  fi
  if window_is_busy fake 'Ctrl+c:cancel'; then
    fail "fm-watch let Grok's exact busy token classify a recorded Kimi task busy"
  fi
  pass "fm-watch: Kimi spinner matching is metadata-scoped and ignores Grok's busy token"
)

test_kimi_bordered_prompt_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "kimi's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  pass "composer classifier: kimi's existing bordered > shape is already safe without an override"
}

test_tracked_files_have_no_user_absolute_paths
test_existing_launch_templates_are_byte_pinned
test_kimi_is_not_detected_as_primary_harness
test_kimi_is_not_a_primary_session_lock_identity
test_kimi_busy_signature_is_scoped_to_spinner_lines
test_watcher_scopes_moon_spinner_to_recorded_kimi_task
test_kimi_bordered_prompt_needs_no_override
