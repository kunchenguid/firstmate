#!/usr/bin/env bash
# Focused behavior tests for the local Cursor harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

test_detects_cursor_agent_ancestry_without_generic_agent_match() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field=${2:-}
pid=${4:-}
case "$field:$pid" in
  comm=:4242) printf '%s\n' node ;;
  args=:4242) printf '%s\n' '/opt/cursor/cursor-agent --use-system-ca /opt/cursor/index.js' ;;
  ppid=:4242) printf '%s\n' 1 ;;
  comm=:*) printf '%s\n' bash ;;
  args=:*) printf '%s\n' bash ;;
  ppid=:*) printf '%s\n' 4242 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # Drop the Layer-1 env markers so a claude/pi/grok/cursor host session cannot
  # short-circuit the ancestry walk this test pins with its fake ps.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
    PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "cursor-agent ancestry should detect cursor, got '$out'"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field=${2:-}
pid=${4:-}
case "$field:$pid" in
  comm=:4242) printf '%s\n' node ;;
  args=:4242) printf '%s\n' '/opt/something/agent --serve' ;;
  ppid=:4242) printf '%s\n' 1 ;;
  comm=:*) printf '%s\n' bash ;;
  args=:*) printf '%s\n' bash ;;
  ppid=:*) printf '%s\n' 4242 ;;
esac
SH
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
    PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "generic agent ancestry must stay unknown, got '$out'"
  pass "fm-harness detects cursor-agent specifically and rejects generic agent"
}

test_tmux_liveness_requires_cursor_agent_argv0() {
  local out
  FM_BACKEND_LIB_DIR="$ROOT/bin"
  # shellcheck source=bin/backends/tmux.sh
  . "$ROOT/bin/backends/tmux.sh"
  fm_backend_tmux_current_command() { printf '%s\n' node; }
  fm_backend_tmux_current_args() { printf '%s\n' '/opt/cursor/cursor-agent --use-system-ca /opt/cursor/index.js'; }
  out=$(fm_backend_tmux_agent_alive fake)
  [ "$out" = alive ] || fail "node with cursor-agent argv0 should be alive, got '$out'"

  fm_backend_tmux_current_args() { printf '%s\n' '/opt/something/agent --serve'; }
  out=$(fm_backend_tmux_agent_alive fake)
  [ "$out" = unknown ] || fail "generic node agent should stay unknown, got '$out'"
  pass "tmux liveness attributes node only through exact cursor-agent argv0"
}

test_tmux_args_resolve_foreground_process_group() {
  local out
  out=$(
    FM_BACKEND_LIB_DIR="$ROOT/bin"
    # shellcheck source=bin/backends/tmux.sh
    . "$ROOT/bin/backends/tmux.sh"
    tmux() {
      printf '%s\n' 4242
    }
    ps() {
      if [ "$*" = "-o tpgid= -p 4242" ]; then
        printf '%s\n' 7777
      elif [ "$*" = "-o args= -p 7777" ]; then
        printf '%s\n' '/opt/cursor/cursor-agent --use-system-ca /opt/cursor/index.js'
      else
        return 1
      fi
    }
    fm_backend_tmux_current_args fake
  )
  [ "$out" = '/opt/cursor/cursor-agent --use-system-ca /opt/cursor/index.js' ] \
    || fail "tmux args should come from the pane foreground process group, got '$out'"
  pass "tmux liveness resolves the pane foreground process instead of its shell"
}

test_cursor_busy_signature_is_specific() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s\n' ' ⠘⠆ Running  50 tokens' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "Cursor 2026.07.09 Running token status should match the busy regex"
  printf '%s\n' '  → Add a follow-up                        ctrl+c to stop' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "Cursor 2026.07.16 ctrl+c to stop footer should match the busy regex"
  if printf '%s\n' 'Running tests now' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "ordinary prose containing Running must not match the Cursor busy signature"
  fi
  if printf '%s\n' 'Press ctrl+c to stop the dev server before rebuilding' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "mid-line prose containing ctrl+c to stop must not match the end-anchored busy signature"
  fi
  pass "Cursor busy signatures match both build generations without prose false positives"
}

test_cursor_primary_sessionstart_nudge_is_wired() {
  local hooks nudge
  hooks="$ROOT/.cursor/hooks.json"
  [ -f "$hooks" ] || fail "tracked Cursor hooks are missing"
  nudge=$(jq -r '.hooks.sessionStart[0].command // empty' "$hooks")
  assert_contains "$nudge" 'CURSOR_PROJECT_DIR' "Cursor sessionStart nudge must anchor through CURSOR_PROJECT_DIR"
  assert_contains "$nudge" 'fm-sessionstart-nudge.sh' "Cursor sessionStart nudge must invoke the shared wrapper"
  jq -e '.hooks.sessionStart[0].failClosed == false' "$hooks" >/dev/null \
    || fail "Cursor sessionStart nudge must stay fail-open"
  pass "tracked Cursor hooks register the shared session-start nudge fail-open"
}

# fm-cursor-lib contract: atomic idempotent install, token-scoped registry, and
# deterministic last-task cleanup that preserves foreign hooks.json entries.
test_cursor_lib_install_is_idempotent_and_cleanup_is_last_token_scoped() {
  local home hooks_dir auth_dir hook_cmd state
  home="$TMP_ROOT/lib-home"
  state="$TMP_ROOT/lib-state"
  hooks_dir="$home/.cursor/hooks"
  auth_dir="$hooks_dir/fm-turn-end.d"
  mkdir -p "$auth_dir" "$state"
  (
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    # shellcheck disable=SC2030  # HOME is deliberately overridden only inside this subshell
    HOME="$home"
    printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"user-own-hook.sh","timeout":9,"failClosed":false}]}}' > "$home/.cursor/hooks.json"
    hook_cmd=$(fm_cursor_shell_quote "$hooks_dir/fm-turn-end.sh")
    fm_cursor_hooks_lock "$hooks_dir" || exit 61
    fm_cursor_write_turnend_hook "$hooks_dir" "$auth_dir" || exit 62
    fm_cursor_merge_stop_entry "$home/.cursor" "$hook_cmd" || exit 63
    fm_cursor_merge_stop_entry "$home/.cursor" "$hook_cmd" || exit 64
    fm_cursor_hooks_unlock "$hooks_dir"
    [ -x "$hooks_dir/fm-turn-end.sh" ] || exit 65
    [ "$(jq '.hooks.stop | length' "$home/.cursor/hooks.json")" = 2 ] || exit 66
    ls "$hooks_dir"/fm-turn-end.sh.tmp.* >/dev/null 2>&1 && exit 67

    # Two registered tokens: removing the first must keep every shared artifact.
    printf '%s\n' "$state/a.turn-ended" > "$auth_dir/fm.aaaaaaaaaaaa"
    printf '%s\n' "$state/b.turn-ended" > "$auth_dir/fm.bbbbbbbbbbbb"
    printf '%s\n' 'fm.aaaaaaaaaaaa' > "$state/task-a.cursor-turnend-token"
    printf '%s\n' 'fm.bbbbbbbbbbbb' > "$state/task-b.cursor-turnend-token"
    fm_cursor_remove_turnend_auth "$state" task-a
    [ ! -e "$auth_dir/fm.aaaaaaaaaaaa" ] || exit 68
    [ -x "$hooks_dir/fm-turn-end.sh" ] || exit 69
    [ "$(jq '.hooks.stop | length' "$home/.cursor/hooks.json")" = 2 ] || exit 70

    # Removing the last token must clear the script, our entry, and the registry
    # dir while preserving the user's own stop entry and the file's version.
    fm_cursor_remove_turnend_auth "$state" task-b
    [ ! -e "$auth_dir/fm.bbbbbbbbbbbb" ] || exit 71
    [ ! -e "$hooks_dir/fm-turn-end.sh" ] || exit 72
    [ ! -d "$auth_dir" ] || exit 73
    [ ! -d "$hooks_dir/.fm-turn-end.lock" ] || exit 74
    [ "$(jq '.hooks.stop | length' "$home/.cursor/hooks.json")" = 1 ] || exit 75
    [ "$(jq -r '.hooks.stop[0].command' "$home/.cursor/hooks.json")" = 'user-own-hook.sh' ] || exit 76
    [ "$(jq -r '.version' "$home/.cursor/hooks.json")" = 1 ] || exit 77
  ) || fail "cursor lib install/cleanup contract failed (subshell exit $?)"
  pass "cursor lib installs idempotently and cleans shared artifacts only after the last token"
}

test_cursor_lib_cleanup_skips_on_held_lock_and_malformed_hooks_json() {
  local home hooks_dir auth_dir state
  home="$TMP_ROOT/lib-home2"
  state="$TMP_ROOT/lib-state2"
  hooks_dir="$home/.cursor/hooks"
  auth_dir="$hooks_dir/fm-turn-end.d"
  mkdir -p "$auth_dir" "$state"
  (
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    # shellcheck disable=SC2030  # HOME is deliberately overridden only inside this subshell
    HOME="$home"
    fm_cursor_write_turnend_hook "$hooks_dir" "$auth_dir" || exit 61

    # A held (fresh) lock: cleanup removes only the token and leaves the hook.
    printf '%s\n' "$state/c.turn-ended" > "$auth_dir/fm.cccccccccccc"
    printf '%s\n' 'fm.cccccccccccc' > "$state/task-c.cursor-turnend-token"
    mkdir "$hooks_dir/.fm-turn-end.lock" || exit 62
    FM_CURSOR_HOOK_LOCK_TRIES=2 fm_cursor_remove_turnend_auth "$state" task-c
    [ ! -e "$auth_dir/fm.cccccccccccc" ] || exit 63
    [ -x "$hooks_dir/fm-turn-end.sh" ] || exit 64
    rmdir "$hooks_dir/.fm-turn-end.lock"

    # A malformed hooks.json is never rewritten or detached from its artifacts.
    printf '%s\n' 'not json at all' > "$home/.cursor/hooks.json"
    printf '%s\n' "$state/d.turn-ended" > "$auth_dir/fm.dddddddddddd"
    printf '%s\n' 'fm.dddddddddddd' > "$state/task-d.cursor-turnend-token"
    fm_cursor_remove_turnend_auth "$state" task-d
    [ "$(cat "$home/.cursor/hooks.json")" = 'not json at all' ] || exit 65
    [ -x "$hooks_dir/fm-turn-end.sh" ] || exit 66
    [ -d "$auth_dir" ] || exit 67
  ) || fail "cursor lib cleanup safety contract failed (subshell exit $?)"
  pass "cursor lib cleanup skips shared removal under a held lock and never rewrites malformed hooks.json"
}

test_cursor_lib_refuses_symlinked_hooks_json() {
  local home hooks_dir auth_dir state target hook_cmd
  home="$TMP_ROOT/lib-home-symlink"
  state="$TMP_ROOT/lib-state-symlink"
  hooks_dir="$home/.cursor/hooks"
  auth_dir="$hooks_dir/fm-turn-end.d"
  target="$home/dotfiles/hooks.json"
  mkdir -p "$auth_dir" "$state" "$(dirname "$target")"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"user-own-hook.sh","failClosed":true}]}}' > "$target"
  ln -s "$target" "$home/.cursor/hooks.json"
  (
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    # shellcheck disable=SC2030
    HOME="$home"
    hook_cmd=$(fm_cursor_shell_quote "$hooks_dir/fm-turn-end.sh")
    if fm_cursor_merge_stop_entry "$home/.cursor" "$hook_cmd" 2>/dev/null; then
      exit 61
    fi
    [ -L "$home/.cursor/hooks.json" ] || exit 62
    [ "$(jq -r '.hooks.stop[0].command' "$target")" = user-own-hook.sh ] || exit 63
    [ "$(jq -r '.hooks.stop[0].failClosed' "$target")" = true ] || exit 64

    fm_cursor_write_turnend_hook "$hooks_dir" "$auth_dir" || exit 65
    printf '%s\n' "$state/e.turn-ended" > "$auth_dir/fm.eeeeeeeeeeee"
    printf '%s\n' 'fm.eeeeeeeeeeee' > "$state/task-e.cursor-turnend-token"
    fm_cursor_remove_turnend_auth "$state" task-e
    [ -L "$home/.cursor/hooks.json" ] || exit 66
    [ -x "$hooks_dir/fm-turn-end.sh" ] || exit 67
    [ -d "$auth_dir" ] || exit 68
    [ "$(jq -r '.hooks.stop[0].failClosed' "$target")" = true ] || exit 69
  ) || fail "cursor symlinked hooks.json refusal contract failed (subshell exit $?)"
  pass "cursor hook lifecycle refuses symlinked hooks.json without replacing its target"
}

test_cursor_abort_cleanup_owns_lock_and_auth_immediately() {
  local home state auth_file function_source
  home="$TMP_ROOT/abort-home"
  state="$TMP_ROOT/abort-state"
  mkdir -p "$home/.cursor/hooks/fm-turn-end.d" "$state"
  auth_file="$home/.cursor/hooks/fm-turn-end.d/fm.ffffffffffff"
  : > "$auth_file"
  mkdir "$home/.cursor/hooks/.fm-turn-end.lock"
  function_source=$(sed -n '/^spawn_abort_cleanup()/,/^trap spawn_abort_cleanup EXIT/p' "$ROOT/bin/fm-spawn.sh" | sed '$d')
  (
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    eval "$function_source"
    HOME="$home"
    STATE="$state"
    ID=task-f
    WT="$TMP_ROOT/no-worktree"
    HERDR_PROJECTION_ABORT_CLEANUP=0
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    ORCA_ABORT_CLEANUP=0
    CURSOR_ABORT_CLEANUP=1
    CURSOR_ABORT_LOCK_HELD=1
    CURSOR_ABORT_AUTH_FILE="$auth_file"
    SPAWN_TASK_LOCK_HELD=0
    CONFIG_INHERIT_LOCK_HELD=0
    spawn_abort_cleanup
    [ ! -d "$home/.cursor/hooks/.fm-turn-end.lock" ] || exit 61
    [ ! -e "$auth_file" ] || exit 62
  ) || fail "cursor early abort cleanup contract failed (subshell exit $?)"
  pass "cursor abort cleanup releases its lock and removes an untracked auth file"
}

test_cursor_primary_hooks_are_wired() {
  local hooks pretool stop
  hooks="$ROOT/.cursor/hooks.json"
  [ -f "$hooks" ] || fail "tracked Cursor hooks are missing"
  pretool=$(jq -r '.hooks.preToolUse[0].command // empty' "$hooks")
  stop=$(jq -r '.hooks.stop[0].command // empty' "$hooks")
  assert_contains "$pretool" 'CURSOR_PROJECT_DIR' "Cursor preToolUse must anchor through CURSOR_PROJECT_DIR"
  assert_contains "$pretool" 'fm-arm-pretool-check.sh' "Cursor preToolUse must invoke the shared checker"
  assert_contains "$stop" 'CURSOR_PROJECT_DIR' "Cursor stop hook must anchor through CURSOR_PROJECT_DIR"
  assert_contains "$stop" 'fm-turnend-guard-cursor.sh' "Cursor stop hook must invoke its adapter"
  [ "$(jq -r '.hooks.preToolUse[0].matcher' "$hooks")" = Shell ] \
    || fail "Cursor preToolUse must be scoped to Shell"
  [ "$(jq -r '.hooks.stop[0].loop_limit' "$hooks")" = 1 ] \
    || fail "Cursor stop hook must allow at most one follow-up"
  pass "tracked Cursor hooks wire pre-tool policy and one-follow-up turn-end guard"
}

test_cursor_turnend_adapter_maps_followup_and_loop_guard() {
  local dir out log
  dir="$TMP_ROOT/turnend"
  log="$dir/guard.log"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard-cursor.sh" "$dir/bin/"
  cat > "$dir/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
printf '%s\n' "\$payload" >> "$log"
printf '%s\n' 'TURN WOULD END BLIND: cursor adapter smoke' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-cursor.sh"

  out=$(printf '%s' '{"status":"completed","loop_count":0}' | "$dir/bin/fm-turnend-guard-cursor.sh")
  [ "$(printf '%s' "$out" | jq -r '.followup_message')" = 'TURN WOULD END BLIND: cursor adapter smoke' ] \
    || fail "Cursor adapter did not return the shared guard reason as followup_message"
  jq -e '.stop_hook_active == false' "$log" >/dev/null \
    || fail "Cursor adapter did not translate the first stop for the shared guard"

  : > "$log"
  out=$(printf '%s' '{"status":"completed","loop_count":1}' | "$dir/bin/fm-turnend-guard-cursor.sh")
  [ "$out" = '{}' ] || fail "Cursor adapter should allow a repeated stop, got '$out'"
  [ ! -s "$log" ] || fail "Cursor adapter must not invoke the shared guard after a follow-up"
  pass "Cursor stop adapter maps exit 2 to one follow-up and prevents recursion"
}

test_detects_cursor_agent_ancestry_without_generic_agent_match
test_tmux_liveness_requires_cursor_agent_argv0
test_tmux_args_resolve_foreground_process_group
test_cursor_busy_signature_is_specific
test_cursor_primary_sessionstart_nudge_is_wired
test_cursor_lib_install_is_idempotent_and_cleanup_is_last_token_scoped
test_cursor_lib_cleanup_skips_on_held_lock_and_malformed_hooks_json
test_cursor_lib_refuses_symlinked_hooks_json
test_cursor_abort_cleanup_owns_lock_and_auth_immediately
test_cursor_primary_hooks_are_wired
test_cursor_turnend_adapter_maps_followup_and_loop_guard

echo "# all fm-cursor-harness tests passed"
