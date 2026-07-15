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
  out=$(PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-harness.sh")
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
  out=$(PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-harness.sh")
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
    || fail "Cursor Running token status should match the busy regex"
  if printf '%s\n' 'Running tests now' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "ordinary prose containing Running must not match the Cursor busy signature"
  fi
  pass "Cursor busy signature matches the token status without using one spinner glyph"
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
test_cursor_primary_hooks_are_wired
test_cursor_turnend_adapter_maps_followup_and_loop_guard

echo "# all fm-cursor-harness tests passed"
