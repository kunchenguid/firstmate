#!/usr/bin/env bash
# Portable behavior tests for Copilot CLI identity and primary hook translation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Gemini, Rovo, Pi, or Grok inherits those
# markers, which can outrank the fake ancestry many cases set up. Drop the
# ambient markers so the asserted verdict does not depend on which harness
# launched the suite.
unset CLAUDECODE COPILOT_CLI COPILOT_AGENT_SESSION_ID COPILOT_LOADER_PID COPILOT_CLI_BINARY_VERSION GEMINI_CLI PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

HARNESS="$ROOT/bin/fm-harness.sh"
LOCK_LIB="$ROOT/bin/fm-session-lock-lib.sh"
TMUX_LIB="$ROOT/bin/fm-tmux-lib.sh"
HOOK="$ROOT/bin/fm-copilot-hook.sh"
WATCH_RECEIPT_LIB="$ROOT/bin/fm-copilot-watcher-receipt-lib.sh"
OPINPUT="$ROOT/bin/fm-operational-input.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

make_ps() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FM_FAKE_PS_COMM:-MainThread}" ;;
  *"args="*) printf '%s\n' "${FM_FAKE_PS_ARGS:-copilot}" ;;
  *"ppid="*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_environment_marker_wins() {
  local fakebin out
  fakebin="$TMP_ROOT/env-marker"
  make_ps "$fakebin"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = copilot ] || fail "COPILOT_CLI marker detected as '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent "$HARNESS")
  [ "$out" = copilot ] || fail "COPILOT_CLI marker lost to inherited Cursor markers: '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 GEMINI_CLI=1 "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI lost to inherited Copilot markers: '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 ATLASSIAN_AGENT_TYPE=rovo "$HARNESS")
  [ "$out" = rovo ] || fail "ATLASSIAN_AGENT_TYPE=rovo lost to inherited Copilot markers: '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 ROVODEV_CLI=1 "$HARNESS")
  [ "$out" = rovo ] || fail "ROVODEV_CLI lost to inherited Copilot markers: '$out'"
  out=$(env -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi "$HARNESS")
  [ "$out" = pi ] || fail "PI_CODING_AGENT=true lost to inherited Copilot markers: '$out'"
  out=$(env -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed "$HARNESS")
  [ "$out" = pi-signed ] || fail "FM_PI_HARNESS=pi-signed lost to inherited Copilot markers: '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 GROK_AGENT=1 "$HARNESS")
  [ "$out" = grok ] || fail "GROK_AGENT lost to inherited Copilot markers: '$out'"
  pass "Copilot fallback yields only to ambiguous Claude/Cursor conflicts"
}

test_process_shapes_are_anchored() {
  local fakebin out
  fakebin="$TMP_ROOT/process-shapes"
  make_ps "$fakebin"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=copilot FM_FAKE_PS_ARGS='copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "native copilot command detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='/opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "MainThread with Copilot argv zero detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='/opt/copilot/bin/runner.js --allow-all' "$HARNESS")
  [ "$out" = unknown ] || fail "a MainThread decoy under a copilot-named directory detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=/opt/copilot/bin/copilot FM_FAKE_PS_ARGS='/opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "path-prefixed copilot executable detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node /opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "node-bundled copilot script detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node /tmp/copilot --allow-all' "$HARNESS")
  [ "$out" = unknown ] || fail "an arbitrary node script named copilot detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=python FM_FAKE_PS_ARGS='python /opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = unknown ] || fail "a python copilot script path detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node /opt/copilot/bin/runner.js --allow-all' "$HARNESS")
  [ "$out" = unknown ] || fail "a node script under a copilot-named directory detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node runner.js copilot' "$HARNESS")
  [ "$out" = unknown ] || fail "an unrelated later copilot argument detected as '$out'"
  pass "Copilot process detection accepts native, path, MainThread, and node-bundle shapes while rejecting later-argument decoys"
}

test_real_process_identity_accepts_copilot_shapes_and_rejects_decoy() {
  command -v node >/dev/null 2>&1 || { pass "node not installed, skipping"; return; }
  local dir native_pid path_pid bundle_pid basename_decoy_pid path_decoy_pid decoy_pid comm args out
  dir="$TMP_ROOT/real-copilot-shapes"
  mkdir -p "$dir/bin"
  mkdir -p "$dir/copilot/bin"
  cat > "$dir/copilot/bin/copilot" <<'JS'
setTimeout(() => {}, 30000);
JS
  cat > "$dir/bin/copilot" <<'JS'
setTimeout(() => {}, 30000);
JS
  cat > "$dir/runner.js" <<'JS'
setTimeout(() => {}, 30000);
JS
  cat > "$dir/copilot/bin/runner.js" <<'JS'
setTimeout(() => {}, 30000);
JS
  bash -c 'exec -a copilot sleep 30' & native_pid=$!
  bash -c 'exec -a /opt/copilot/bin/copilot sleep 30' & path_pid=$!
  node "$dir/copilot/bin/copilot" --allow-all & bundle_pid=$!
  node "$dir/bin/copilot" --allow-all & basename_decoy_pid=$!
  node "$dir/copilot/bin/runner.js" --allow-all & path_decoy_pid=$!
  node "$dir/runner.js" copilot & decoy_pid=$!

  comm=$(LC_ALL=C ps -p "$native_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$native_pid" -o args= 2>/dev/null || true)
  out=$(bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args") || fail "native copilot argv0 was not identified"
  [ "$out" = copilot ] || fail "native copilot argv0 detected as '$out'"

  comm=$(LC_ALL=C ps -p "$path_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$path_pid" -o args= 2>/dev/null || true)
  out=$(bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args") || fail "path-prefixed copilot argv0 was not identified"
  [ "$out" = copilot ] || fail "path-prefixed copilot argv0 detected as '$out'"

  comm=$(LC_ALL=C ps -p "$bundle_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$bundle_pid" -o args= 2>/dev/null || true)
  out=$(bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args") || fail "node-bundled copilot was not identified"
  [ "$out" = copilot ] || fail "node-bundled copilot detected as '$out'"
  out=$(bash -c '. "$1"; fm_tmux_harness_process_name "$2" "$3"' -- "$TMUX_LIB" "$comm" "$args") || fail "tmux harness identity did not recognize the node-bundled copilot"
  [ "$out" = copilot ] || fail "tmux harness identity detected the node-bundled copilot as '$out'"

  comm=$(LC_ALL=C ps -p "$basename_decoy_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$basename_decoy_pid" -o args= 2>/dev/null || true)
  if bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args" >/dev/null 2>&1; then
    fail "an arbitrary node script named copilot was treated as copilot"
  fi

  comm=$(LC_ALL=C ps -p "$path_decoy_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$path_decoy_pid" -o args= 2>/dev/null || true)
  if bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args" >/dev/null 2>&1; then
    fail "a node script under a copilot-named directory was treated as copilot"
  fi

  comm=$(LC_ALL=C ps -p "$decoy_pid" -o comm= 2>/dev/null || true)
  args=$(LC_ALL=C ps -p "$decoy_pid" -o args= 2>/dev/null || true)
  if bash -c '. "$1"; fm_harness_process_name "$2" "$3"' -- "$LOCK_LIB" "$comm" "$args" >/dev/null 2>&1; then
    fail "a later-argument decoy real node process was treated as copilot"
  fi

  kill "$native_pid" "$path_pid" "$bundle_pid" "$basename_decoy_pid" "$path_decoy_pid" "$decoy_pid" 2>/dev/null || true
  wait "$native_pid" "$path_pid" "$bundle_pid" "$basename_decoy_pid" "$path_decoy_pid" "$decoy_pid" 2>/dev/null || true
  pass "real processes identify native, path, and verified node-bundled Copilot shapes while rejecting decoys"
}

test_tmux_identity_and_liveness_recognize_node_bundled_copilot() {
  local dir fakebin out
  dir="$TMP_ROOT/tmux-node-bundle"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-t pts/fm-copilot -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 node' ;;
  *'-p 111 -o args='*) printf '%s\n' 'node /opt/copilot/bin/copilot --allow-all' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "${*: -1}" in
      '#{pane_tty}') printf '/dev/pts/fm-copilot\n' ;;
      '#{pane_current_command}') printf 'node\n' ;;
      '#{cursor_y}') printf '0\n' ;;
      '#{pane_id}') printf '%s\n' '%1' ;;
      *) exit 1 ;;
    esac ;;
  list-windows)
    printf 'fm-copilot\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps" "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_identity s:fm-copilot' -- "$TMUX_LIB") || fail "tmux composer identity did not recognize a node-bundled Copilot pane"
  [ "$out" = $'copilot	present' ] || fail "tmux composer identity detected a node-bundled Copilot pane as '$out'"
  out=$(PATH="$fakebin:$PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" bash -c '. "$1"; fm_backend_tmux_agent_state s:fm-copilot' -- "$ROOT/bin/backends/tmux.sh") || fail "tmux agent-state did not evaluate the node-bundled Copilot pane"
  [ "$out" = alive ] || fail "tmux agent-state detected a node-bundled Copilot pane as '$out'"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-t pts/fm-copilot -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 MainThread' ;;
  *'-p 111 -o args='*) printf '%s\n' '/opt/copilot/bin/runner.js --allow-all' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_identity s:fm-copilot' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "tmux composer identity treated a MainThread decoy under a copilot-named directory as Copilot"
  fi
  out=$(PATH="$fakebin:$PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" bash -c '. "$1"; fm_backend_tmux_agent_state s:fm-copilot' -- "$ROOT/bin/backends/tmux.sh") || fail "tmux agent-state did not evaluate the MainThread decoy pane"
  [ "$out" = ambiguous ] || fail "tmux agent-state detected a MainThread decoy pane as '$out'"
  pass "tmux composer identity and liveness recognize node-bundled Copilot and reject MainThread decoys"
}

test_tmux_current_command_copilot_does_not_prove_identity() {
  local dir fakebin out
  dir="$TMP_ROOT/tmux-stale-current-command"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "${*: -1}" in
      '#{pane_tty}') printf '/dev/pts/fm-stale\n' ;;
      '#{pane_current_command}') printf 'copilot\n' ;;
      '#{cursor_y}') printf '1\n' ;;
      '#{pane_id}') printf '%s\n' '%1' ;;
      *) exit 1 ;;
    esac ;;
  list-windows)
    printf 'fm-stale\n' ;;
  capture-pane)
    printf '╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃\n╹▀▀▀▀▀▀▀▀▀▀▀▀\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-t pts/fm-stale -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 bash' ;;
  *'-p 111 -o args='*) printf '%s\n' 'bash' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps" "$fakebin/tmux"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_pane_is_copilot s:fm-stale' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "stale pane_current_command=copilot incorrectly proved Copilot identity over a bash foreground"
  fi
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_identity s:fm-stale' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "stale pane_current_command=copilot incorrectly produced Copilot composer identity"
  fi
  out=$(PATH="$fakebin:$PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" bash -c '. "$1"; fm_backend_tmux_agent_state s:fm-stale' -- "$ROOT/bin/backends/tmux.sh") || fail "tmux agent-state did not evaluate the stale current-command pane"
  case "$out" in
    dead|ambiguous) ;;
    *) fail "tmux agent-state detected a stale pane_current_command=copilot pane as '$out'" ;;
  esac
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_state s:fm-stale' -- "$TMUX_LIB") || fail "tmux composer state did not evaluate the stale current-command pane"
  [ "$out" = unknown ] || fail "tmux composer state treated stale pane_current_command=copilot as '$out'"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-t pts/fm-stale -o pid=,pgid=,tpgid=,comm='*) exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_pane_is_copilot s:fm-stale' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "pane_current_command=copilot incorrectly proved Copilot identity when ps was unreadable"
  fi
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_identity s:fm-stale' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "pane_current_command=copilot incorrectly produced Copilot identity when ps was unreadable"
  fi
  out=$(PATH="$fakebin:$PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" bash -c '. "$1"; fm_backend_tmux_agent_state s:fm-stale' -- "$ROOT/bin/backends/tmux.sh") || fail "tmux agent-state did not evaluate the unreadable-ps pane"
  [ "$out" = ambiguous ] || fail "tmux agent-state detected a pane_current_command=copilot pane with unreadable ps as '$out'"
  pass "tmux Copilot identity ignores stale pane_current_command fallbacks"
}

test_tmux_foreground_identity_trims_indented_args() {
  local dir fakebin out cursor_path
  dir="$TMP_ROOT/tmux-indented-args"
  fakebin="$dir/fakebin"
  cursor_path='/home/u/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent'
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "${*: -1}" in
      '#{pane_tty}') printf '/dev/pts/fm-indented\n' ;;
      '#{pane_current_command}') printf 'node\n' ;;
      '#{cursor_y}') printf '0\n' ;;
      '#{pane_id}') printf '%s\n' '%1' ;;
      *) exit 1 ;;
    esac ;;
  list-windows)
    printf 'fm-indented\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *'-t pts/fm-indented -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 MainThread' ;;
  *'-p 111 -o args='*) printf '%s\n' '   /opt/copilot/bin/copilot --allow-all' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps" "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_foreground_harness_name s:fm-indented' -- "$TMUX_LIB") || fail "tmux foreground identity did not trim a Copilot MainThread argv0"
  [ "$out" = copilot ] || fail "tmux foreground identity detected trimmed Copilot MainThread argv0 as '$out'"
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_composer_identity s:fm-indented' -- "$TMUX_LIB") || fail "tmux composer identity did not recognize a trimmed Copilot MainThread argv0"
  [ "$out" = $'copilot	present' ] || fail "tmux composer identity detected trimmed Copilot MainThread argv0 as '$out'"

  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *'-t pts/fm-indented -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 MainThread' ;;
  *'-p 111 -o args='*) printf '%s\n' '   /opt/copilot/bin/runner.js --allow-all' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_foreground_harness_name s:fm-indented' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "tmux foreground identity treated a trimmed Copilot MainThread decoy as Copilot"
  fi

  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *'-t pts/fm-indented -o pid=,pgid=,tpgid=,comm='*) printf '%s\n' '111 222 222 node' ;;
  *'-p 111 -o args='*) printf '%s\n' '   $cursor_path --trust --yolo' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_foreground_harness_name s:fm-indented' -- "$TMUX_LIB") || fail "tmux foreground identity did not trim an indented Cursor argv0"
  [ "$out" = cursor ] || fail "tmux foreground identity detected trimmed Cursor argv0 as '$out'"
  PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_pane_is_cursor s:fm-indented' -- "$TMUX_LIB" >/dev/null \
    || fail "tmux cursor probe did not recognize an indented Cursor argv0"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-t pts/fm-indented -o pid=,pgid=,tpgid=,comm='*) printf '%s
' '111 222 222 node' ;;
  *'-p 111 -o args='*) printf '%s
' '   /tmp/cursor-agent/bin/runner --trust --yolo' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_tmux_foreground_harness_name s:fm-indented' -- "$TMUX_LIB" >/dev/null 2>&1; then
    fail "tmux foreground identity treated a trimmed Cursor decoy as Cursor"
  fi
  pass "tmux foreground identity trims indented Copilot and Cursor argv0 values without matching decoys"
}

test_actual_host_overrides_inherited_markers() {
  local fakebin out versioned_claude
  fakebin="$TMP_ROOT/ancestry-over-marker"
  make_ps "$fakebin"

  out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=claude FM_FAKE_PS_ARGS='claude --dangerously-skip-permissions' "$HARNESS")
  [ "$out" = claude ] || fail "real Claude ancestry lost to inherited Copilot markers: '$out'"

  versioned_claude='/home/test/.local/share/claude/versions/2.1.220/2.1.220'
  out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$versioned_claude" \
    FM_FAKE_PS_ARGS="$versioned_claude --dangerously-skip-permissions" "$HARNESS")
  [ "$out" = claude ] || fail "version-named Claude ancestry lost to inherited Copilot markers: '$out'"

  out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=cursor-agent FM_FAKE_PS_ARGS='cursor-agent --trust' "$HARNESS")
  [ "$out" = cursor ] || fail "real Cursor ancestry lost to inherited Copilot markers: '$out'"

  out=$(COPILOT_CLI=1 CLAUDECODE=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=/opt/kimi/bin/kimi FM_FAKE_PS_ARGS='kimi --auto' "$HARNESS")
  [ "$out" = kimi ] || fail "real Kimi ancestry lost to inherited Copilot markers: '$out'"

  out=$(COPILOT_CLI=1 CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='/opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "real Copilot ancestry lost to inherited foreign markers: '$out'"
  pass "Copilot-marked processes use actual ancestry to resolve inherited marker conflicts"
}

test_session_lock_identity_matches_copilot() {
  local fakebin out
  fakebin="$TMP_ROOT/lock-shape"
  make_ps "$fakebin"
  # shellcheck disable=SC2016 # Child shell intentionally expands its positional parameter.
  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    bash -c '. "$1"; fm_harness_ancestry_pid' -- "$LOCK_LIB")
  case "$out" in
    ''|*[!0-9]*) fail "Copilot MainThread lock identity returned '$out'" ;;
  esac
  # shellcheck disable=SC2016 # Child shell intentionally expands its positional parameter.
  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node /opt/copilot/bin/copilot --allow-all' \
    bash -c '. "$1"; fm_harness_ancestry_pid' -- "$LOCK_LIB")
  case "$out" in
    ''|*[!0-9]*) fail "Copilot node-bundle lock identity returned '$out'" ;;
  esac
  pass "session-lock ancestry recognizes Copilot MainThread and node-bundle process shapes"
}

make_hook_fixture() {
  local dir=$1 guard_status=${2:-0}
  mkdir -p "$dir/bin"
  cp "$HOOK" "$WATCH_RECEIPT_LIB" "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-harness-process-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-copilot-hook.sh"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
printf 'digest line one\ndigest line two\n'
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
cat > "\$FM_TEST_PAYLOAD"
[ -z "\${FM_TEST_ARGS:-}" ] || printf '%s\n' "\$*" > "\$FM_TEST_ARGS"
printf '%s\n' 'restore Firstmate supervision' >&2
exit $guard_status
SH
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"arm denied"}'
SH
  cat > "$dir/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"cd denied"}'
SH
  cat > "$dir/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"subagent denied"}'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh" "$dir/bin/fm-turnend-guard.sh" \
    "$dir/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh" \
    "$dir/bin/fm-subagent-pretool-check.sh"
}

make_primary_hook_fixture() {  # <dir> [guard-status]
  local dir=$1 guard_status=${2:-0}
  make_hook_fixture "$dir" "$guard_status"
  mkdir -p "$dir/state"
  fm_git_init_commit "$dir"
  : > "$dir/AGENTS.md"
}

make_child_worktree_hook_fixture() {  # <base> <dir> [guard-status]
  local base=$1 dir=$2 guard_status=${3:-0}
  fm_git_worktree "$base" "$dir" fm/copilot-hook-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  make_hook_fixture "$dir" "$guard_status"
}

run_copilot_hook_fixture() {  # <fakebin> <dir> <mode> <payload-file> [extra env...]
  local fakebin=$1 dir=$2 mode=$3 payload_file=$4
  shift 4
  PATH="$fakebin:$PATH" "$@" "$dir/bin/fm-copilot-hook.sh" "$mode" < "$payload_file"
}

make_tracked_primary_hook_fixture() {  # <dir> [guard-status]
  local dir=$1 guard_status=${2:-0}
  make_hook_fixture "$dir" "$guard_status"
  mkdir -p "$dir/.github/hooks" "$dir/state"
  git -C "$dir" init -q
  : > "$dir/AGENTS.md"
  cp "$ROOT/.github/hooks/fm-primary.json" "$dir/.github/hooks/fm-primary.json"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-operational-input.sh" \
     "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
}

copilot_watch_receipt_path() {  # <state>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    state=$(fm_copilot_watch_receipt_real_dir "$2") || exit 1
    fm_copilot_watch_receipt_path "$state"
  ' _ "$WATCH_RECEIPT_LIB" "$1"
}

copilot_watch_receipt_publish() {  # <root> <home> <state>
  bash -c '. "$1"; fm_copilot_watch_receipt_publish "$2" "$3" "$4"' _ \
    "$WATCH_RECEIPT_LIB" "$1" "$2" "$3"
}

copilot_watch_receipt_write() {  # <state> <root> <home> <completed-at> [schema]
  local state=$1 root=$2 home=$3 completed=$4 schema=${5:-fm-copilot-watch-arm-receipt.v1}
  local receipt dir
  receipt=$(copilot_watch_receipt_path "$state") || return 1
  dir=${receipt%/*}
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1
  {
    printf 'schema=%s\n' "$schema"
    printf 'completed_at=%s\n' "$completed"
    printf 'root=%s\n' "$root"
    printf 'home=%s\n' "$home"
  } > "$receipt" || return 1
  chmod 600 "$receipt" || return 1
}

make_no_node_path() {  # <dir>
  local dir=$1 cmd source
  mkdir -p "$dir"
  for cmd in basename env bash cat chmod date dirname git grep jq mktemp mv ps rm stat tr uname wc; do
    source=$(command -v "$cmd" 2>/dev/null || true)
    [ -n "$source" ] || fail "required tool '$cmd' is unavailable"
    ln -sf "$source" "$dir/$cmd"
  done
}

assert_watcher_followup() {  # <json-output> <context>
  local out=$1 context=$2 message body kind
  message=$(printf '%s' "$out" | jq -r '.additionalContext')
  kind=$(printf '%s' "$message" | "$OPINPUT" kind)
  [ "$kind" = watcher ] || fail "$context must inject watcher operational context, got '$kind' from: $out"
  body=$(printf '%s' "$message" | "$OPINPUT" body)
  case "$body" in
    *'Inspect the completed task result for the reason line when needed.'*'Run bin/fm-wake-drain.sh first'*'open decisions and unread status lines'*'exact WAKE_ACK_REQUIRED --ack-through command printed by the drain.'*'Start the next attached asynchronous arm only if supervision remains required.'*) ;;
    *) fail "$context lost the required recovery protocol: $body" ;;
  esac
}

make_claude_compat_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.claude"
  git -C "$dir" init -q
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-harness-process-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-claude-compat-hook.sh" "$dir/bin/"
  cp "$ROOT/.claude/settings.json" "$dir/.claude/settings.json"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'sessionstart\n'
SH
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'arm\n'
SH
  cat > "$dir/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'cd\n'
SH
  cat > "$dir/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'subagent\n'
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'turnend\n'
SH
  cat > "$dir/bin/fm-claude-stop-autoarm.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'autoarm\n'
SH
  chmod +x "$dir/bin/"*
}

test_session_start_translates_context() {
  local dir payload out fakebin
  dir="$TMP_ROOT/session-start"
  payload="$dir/payload.json"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir"
  make_ps "$fakebin"
  printf '%s' '{"source":"startup"}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" session-start < "$dir/in.json")
  printf '%s' "$out" | jq -e '.additionalContext == "digest line one\ndigest line two\n"' >/dev/null \
    || fail "sessionStart adapter returned invalid context: $out"
  [ "$(cat "$payload")" = '{"source":"startup"}' ] || fail "sessionStart payload was not forwarded"
  [ "$(cat "$dir/args.txt")" = --copilot ] || fail "Copilot sessionStart did not use the native invocation mode"
  pass "Copilot sessionStart returns the full digest as additionalContext"
}

test_agent_stop_translates_block() {
  local dir payload out fakebin
  dir="$TMP_ROOT/agent-stop"
  payload="$dir/payload.json"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"
  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in.json")
  printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("restore Firstmate supervision"))' >/dev/null \
    || fail "agentStop adapter returned invalid block decision: $out"
  [ "$(cat "$payload")" = '{"sessionId":"s1","stop_hook_active":false}' ] \
    || fail "agentStop payload was not forwarded"
  pass "Copilot agentStop translates the shared guard refusal into a native block"
}

test_pretool_arm_delegates_only_in_primary_scope() {
  local dir fakebin payload out rc args
  dir="$TMP_ROOT/native-copilot-pretool-arm-primary"
  fakebin="$dir/fakebin"
  payload="$dir/payload.json"
  make_primary_hook_fixture "$dir" 2
  make_ps "$fakebin"

  printf '%s' '{"toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' > "$dir/arm.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" ./bin/fm-copilot-hook.sh pretool-arm < "$dir/arm.json" 2> "$dir/arm.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-arm should return Copilot's native deny object with exit 0 in a real primary, got $rc: $out"
  [ ! -s "$dir/arm.err" ] || fail "Copilot pretool-arm wrote stderr in a real primary: $(cat "$dir/arm.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "arm denied"' >/dev/null \
    || fail "Copilot pretool-arm lost the native deny payload in a real primary: $out"
  [ "$(cat "$payload")" = '{"toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' ] || fail "Copilot pretool-arm did not forward the payload in a real primary"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-arm did not use the native invocation mode in a real primary: $args"
  pass "Copilot pretool-arm delegates only in a genuine primary"
}

test_pretool_arm_stands_down_in_linked_task_worktree() {
  local base dir fakebin out rc
  base="$TMP_ROOT/native-copilot-pretool-arm-base"
  dir="$TMP_ROOT/native-copilot-pretool-arm-linked"
  fakebin="$dir/fakebin"
  make_child_worktree_hook_fixture "$base" "$dir" 2
  make_ps "$fakebin"

  printf '%s' '{"toolArgs":{"command":"bin/fm-watch-arm.sh --help"}}' > "$dir/arm.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$dir/payload.json" FM_TEST_ARGS="$dir/args.txt" ./bin/fm-copilot-hook.sh pretool-arm < "$dir/arm.json" 2> "$dir/arm.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-arm must stand down in a linked task worktree, got $rc: $out"
  [ -z "$out" ] || fail "Copilot pretool-arm must be silent in a linked task worktree, got: $out"
  [ ! -s "$dir/arm.err" ] || fail "Copilot pretool-arm wrote stderr in a linked task worktree: $(cat "$dir/arm.err")"
  assert_absent "$dir/payload.json" "Copilot pretool-arm should not invoke the primary checker in a linked task worktree"
  assert_absent "$dir/args.txt" "Copilot pretool-arm should not pass Copilot args to the primary checker in a linked task worktree"
  pass "Copilot pretool-arm stands down in linked task worktrees"
}

test_copilot_native_policies_bypass_compatibility_stand_down() {
  local dir fakebin payload out rc args
  dir="$TMP_ROOT/native-copilot-policies"
  fakebin="$dir/fakebin"
  payload="$dir/payload.json"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"

  printf '%s' '{"toolArgs":{"command":"cd projects/demo"}}' > "$dir/cd.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" pretool-cd < "$dir/cd.json" 2> "$dir/cd.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-cd should return Copilot's native deny object with exit 0, got $rc: $out"
  [ ! -s "$dir/cd.err" ] || fail "Copilot pretool-cd wrote stderr: $(cat "$dir/cd.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "cd denied"' >/dev/null \
    || fail "Copilot pretool-cd lost the native deny payload: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-cd did not use the native invocation mode: $args"

  printf '%s' '{"toolName":"task"}' > "$dir/subagent.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" pretool-subagent < "$dir/subagent.json" 2> "$dir/subagent.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-subagent should return Copilot's native deny object with exit 0, got $rc: $out"
  [ ! -s "$dir/subagent.err" ] || fail "Copilot pretool-subagent wrote stderr: $(cat "$dir/subagent.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "subagent denied"' >/dev/null \
    || fail "Copilot pretool-subagent lost the native deny payload: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-subagent did not use the native invocation mode: $args"

  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/stop.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/stop.json")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null || fail "Copilot agent-stop lost block translation: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot agent-stop did not use the native invocation mode: $args"
  pass "Copilot native hooks bypass only the compatibility stand-down"
}

test_agent_stop_allows_clean_stop() {
  local dir out fakebin
  dir="$TMP_ROOT/agent-stop-allow"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 0
  make_ps "$fakebin"
  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$dir/payload.json" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in.json")
  [ -z "$out" ] || fail "healthy agentStop must be silent, got: $out"
  pass "Copilot agentStop leaves a healthy turn end unchanged"
}

make_notification_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git -C "$dir" init -q
  : > "$dir/AGENTS.md"
  cp "$HOOK" "$WATCH_RECEIPT_LIB" "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-harness-process-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
     "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
     "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-copilot-hook.sh" "$dir/bin/fm-operational-input.sh"
}

test_notification_injects_watcher_followup_only_for_watcher_arm_completion() {
  local dir fakebin out receipt no_node_path stale sibling other_home
  dir="$TMP_ROOT/notification-watcher"
  fakebin="$dir/fakebin"
  mkdir -p "$dir"
  make_ps "$fakebin"
  make_notification_fixture "$dir"

  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh"}' > "$dir/in.json"
  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" || fail "could not publish a command-bearing watcher receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/in.json")
  assert_watcher_followup "$out" "Copilot watcher notification"

  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/in.json")
  [ -z "$out" ] || fail "a command-bearing watcher completion without receipt or success evidence must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh","success":true}' > "$dir/command-success-without-receipt.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/command-success-without-receipt.json")
  assert_watcher_followup "$out" "Copilot command-bearing watcher notification without receipt but with success evidence"

  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh","success":false}' > "$dir/command-explicit-failure.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/command-explicit-failure.json")
  [ -z "$out" ] || fail "an explicitly failed watcher completion without a receipt must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh","exitCode":17}' > "$dir/command-nonzero-exit.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/command-nonzero-exit.json")
  [ -z "$out" ] || fail "a nonzero watcher completion without a receipt must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","hook_event_name":"Notification","title":"Arm Firstmate watcher","message":"Shell command \"Arm Firstmate watcher\" (shellId: 0) has completed successfully. Use read_bash with shellId \"0\" to retrieve the output.","command":null,"commandLine":null,"command_line":null}' > "$dir/live-shape.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a title-only watcher completion without a receipt must stay inert, got: $out"

  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" || fail "could not publish a valid watcher completion receipt"
  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh"}' > "$dir/command-receipt.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/command-receipt.json")
  assert_watcher_followup "$out" "Copilot command-bearing watcher notification with receipt"

  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a command-bearing watcher completion left a replayable title-only receipt, got: $out"

  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" || fail "could not republish a valid watcher completion receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  assert_watcher_followup "$out" "Copilot live-shape watcher notification"

  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a consumed title-only watcher receipt must reject replay, got: $out"

  printf '%s' '{"notification_type":"shell_completed","hook_event_name":"Notification","title":"Arm the Firstmate watcher","message":"Shell command \"Arm the Firstmate watcher\" (shellId: 2) has completed successfully. Use read_bash with shellId \"2\" to retrieve the output.","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh --help"}' > "$dir/extra-argv.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/extra-argv.json")
  [ -z "$out" ] || fail "a watcher-arm completion with trailing argv must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","hook_event_name":"Notification","title":"Arm the Firstmate watcher","message":"Shell command \"Arm the Firstmate watcher\" (shellId: 3) has completed successfully. Use read_bash with shellId \"3\" to retrieve the output.","command":null,"commandLine":null,"command_line":null}' > "$dir/live-shape-replay-check.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape-replay-check.json")
  [ -z "$out" ] || fail "an extra-argv watcher completion must not leave a title-only replay receipt, got: $out"

  printf '%s' '{"notification_type":"shell_completed","hook_event_name":"Notification","title":"Arm the Firstmate watcher","message":"Shell command \"Arm the Firstmate watcher\" (shellId: 1) has completed successfully. Use read_bash with shellId \"1\" to retrieve the output.","command":null,"commandLine":null,"command_line":null}' > "$dir/live-shape-the.json"
  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" || fail "could not publish an alternate-title watcher receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape-the.json")
  assert_watcher_followup "$out" "Copilot alternate live watcher title"

  sibling="$TMP_ROOT/notification-watcher-sibling"
  mkdir -p "$sibling/config"
  : > "$sibling/config/x-mode.env"
  printf '%s' '{"notification_type":"shell_completed","command":"cd ../notification-watcher-sibling && [ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh"}' > "$dir/sibling.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/sibling.json")
  [ -z "$out" ] || fail "a sibling-root watcher completion must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","command":"export FM_HOME=/tmp/other; exec ./bin/fm-watch-arm.sh"}' > "$dir/home-rebind.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/home-rebind.json")
  [ -z "$out" ] || fail "an FM_HOME-rebound watcher completion must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","command":"export FM_STATE_OVERRIDE=/tmp/other; exec ./bin/fm-watch-arm.sh"}' > "$dir/state-rebind.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/state-rebind.json")
  [ -z "$out" ] || fail "an FM_STATE_OVERRIDE-rebound watcher completion must stay inert, got: $out"

  jq -n --arg cmd $'printf ready\nexec ./bin/fm-watch-arm.sh' \
    '{notification_type:"shell_completed",command:$cmd}' > "$dir/multiline-command.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/multiline-command.json")
  [ -z "$out" ] || fail "a multiline prefixed watcher completion must stay inert, got: $out"

  jq -n --arg cmd $'{ printf ready; }\nexec ./bin/fm-watch-arm.sh' \
    '{notification_type:"shell_completed",commandLine:$cmd}' > "$dir/multiline-commandline.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/multiline-commandline.json")
  [ -z "$out" ] || fail "a multiline bundled watcher completion in commandLine must stay inert, got: $out"

  printf '%s' '{"notification_type":"shell_completed","command":"sleep 1; printf done > background-result"}' > "$dir/other.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/other.json")
  [ -z "$out" ] || fail "an unrelated background completion must stay inert, got: $out"

  receipt=$(copilot_watch_receipt_path "$dir/state") || fail "could not resolve watcher receipt path"
  copilot_watch_receipt_write "$dir/state" "$sibling" "$dir" "$(date +%s)" || fail "could not write a wrong-root receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a wrong-root watcher receipt must stay inert, got: $out"

  other_home="$TMP_ROOT/notification-watcher-other-home"
  mkdir -p "$other_home"
  copilot_watch_receipt_write "$dir/state" "$dir" "$other_home" "$(date +%s)" || fail "could not write a wrong-home receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a wrong-home watcher receipt must stay inert, got: $out"

  stale=$(( $(date +%s) - 120 ))
  copilot_watch_receipt_write "$dir/state" "$dir" "$dir" "$stale" || fail "could not write a stale receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_COPILOT_WATCH_RECEIPT_MAX_AGE=60 ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a stale watcher receipt must stay inert, got: $out"

  mkdir -p "${receipt%/*}" || fail "could not create the watcher receipt directory"
  chmod 700 "${receipt%/*}" || fail "could not secure the watcher receipt directory"
  {
    printf 'schema=%s\n' 'fm-copilot-watch-arm-receipt.v1'
    printf 'completed_at=%s\n' "$(date +%s)"
    printf 'root=%s\n' "$dir"
  } > "$receipt" || fail "could not write a malformed receipt"
  chmod 600 "$receipt" || fail "could not secure the malformed receipt"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  [ -z "$out" ] || fail "a malformed watcher receipt must stay inert, got: $out"

  no_node_path="$dir/no-node-path"
  make_no_node_path "$no_node_path"
  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" || fail "could not publish a receipt for the no-node case"
  out=$(cd "$dir" && PATH="$fakebin:$no_node_path" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/live-shape.json")
  assert_watcher_followup "$out" "Copilot title-only watcher notification without node"
  pass "Copilot notifications accept receiptless command success evidence but still require receipts for title-only payloads"
}

test_notification_requires_primary_scope() {
  local dir fakebin out
  dir="$TMP_ROOT/notification-nonprimary"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/bin"
  make_ps "$fakebin"
  cp "$HOOK" "$WATCH_RECEIPT_LIB" "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-harness-process-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
     "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
     "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-copilot-hook.sh" "$dir/bin/fm-operational-input.sh"
  printf '%s' '{"notification_type":"shell_completed","command":"exec bin/fm-watch-arm.sh"}' > "$dir/in.json"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    ./bin/fm-copilot-hook.sh notification < "$dir/in.json")
  [ -z "$out" ] || fail "notification hook must stay inert outside a genuine Firstmate primary, got: $out"
  pass "Copilot notification stands down outside genuine primary scope"
}

test_tracked_primary_hook_commands_execute() {
  local dir fakebin hooks cmd out rc args payload reason seen_arm=0 seen_cd=0 seen_subagent=0
  dir="$TMP_ROOT/tracked-primary-hooks"
  fakebin="$dir/fakebin"
  make_tracked_primary_hook_fixture "$dir" 2
  make_ps "$fakebin"
  hooks="$dir/.github/hooks/fm-primary.json"

  printf '%s' '{"source":"startup"}' > "$dir/session.json"
  cmd=$(jq -r '.hooks.sessionStart[0].bash' "$hooks")
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$dir/payload.json" FM_TEST_ARGS="$dir/args.txt" sh -c "$cmd" < "$dir/session.json")
  printf '%s' "$out" | jq -e '.additionalContext == "digest line one\ndigest line two\n"' >/dev/null \
    || fail "tracked sessionStart command returned invalid context: $out"
  [ "$(cat "$dir/payload.json")" = '{"source":"startup"}' ] || fail "tracked sessionStart command did not forward the payload"
  [ "$(cat "$dir/args.txt")" = --copilot ] || fail "tracked sessionStart command did not preserve Copilot mode"

  printf '%s' '{"toolArgs":{"command":"echo hi"},"toolName":"bash"}' > "$dir/pretool-bash.json"
  printf '%s' '{"toolName":"task"}' > "$dir/pretool-subagent.json"
  while IFS= read -r cmd; do
    payload="$dir/pretool-bash.json"
    if [ "$(printf '%s' "$cmd" | grep -F 'pretool-subagent' || true)" ]; then
      payload="$dir/pretool-subagent.json"
    fi
    out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
      FM_TEST_PAYLOAD="$dir/payload.json" FM_TEST_ARGS="$dir/args.txt" sh -c "$cmd" < "$payload" 2> "$dir/pretool.err")
    rc=$?
    [ "$rc" -eq 0 ] || fail "tracked preToolUse command failed with $rc: $cmd"
    [ ! -s "$dir/pretool.err" ] || fail "tracked preToolUse command wrote stderr: $(cat "$dir/pretool.err")"
    reason=$(printf '%s' "$out" | jq -r '.permissionDecisionReason')
    args=$(cat "$dir/args.txt")
    [ "$args" = --copilot ] || fail "tracked preToolUse command lost Copilot mode: $cmd"
    case "$reason" in
      'arm denied') [ "$(cat "$dir/payload.json")" = '{"toolArgs":{"command":"echo hi"},"toolName":"bash"}' ] || fail "tracked arm command did not forward its payload"; seen_arm=1 ;;
      'cd denied') [ "$(cat "$dir/payload.json")" = '{"toolArgs":{"command":"echo hi"},"toolName":"bash"}' ] || fail "tracked cd command did not forward its payload"; seen_cd=1 ;;
      'subagent denied') [ "$(cat "$dir/payload.json")" = '{"toolName":"task"}' ] || fail "tracked subagent command did not forward its payload"; seen_subagent=1 ;;
      *) fail "tracked preToolUse command returned unexpected deny reason '$reason'" ;;
    esac
  done < <(jq -r '.hooks.preToolUse[].bash' "$hooks")
  [ "$seen_arm" -eq 1 ] && [ "$seen_cd" -eq 1 ] && [ "$seen_subagent" -eq 1 ] \
    || fail "tracked preToolUse commands did not cover arm/cd/subagent routing"

  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/stop.json"
  cmd=$(jq -r '.hooks.agentStop[0].bash' "$hooks")
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$dir/payload.json" FM_TEST_ARGS="$dir/args.txt" sh -c "$cmd" < "$dir/stop.json")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null || fail "tracked agentStop command lost its block translation: $out"
  [ "$(cat "$dir/payload.json")" = '{"sessionId":"s1","stop_hook_active":false}' ] || fail "tracked agentStop command did not forward the payload"
  [ "$(cat "$dir/args.txt")" = --copilot ] || fail "tracked agentStop command did not preserve Copilot mode"

  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  printf '%s' '{"notification_type":"shell_completed","command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec ./bin/fm-watch-arm.sh"}' > "$dir/notification.json"
  copilot_watch_receipt_publish "$dir" "$dir" "$dir/state" \
    || fail "could not publish a tracked notification watcher receipt"
  cmd=$(jq -r '.hooks.notification[0].bash' "$hooks")
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' sh -c "$cmd" < "$dir/notification.json")
  assert_watcher_followup "$out" "tracked notification command"
  pass "tracked Copilot hook commands execute through the shipped registration"
}

test_non_cli_hook_surface_stands_down() {
  local dir out fakebin
  dir="$TMP_ROOT/non-cli"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"
  printf '%s' '{"source":"startup"}' > "$dir/in.json"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' FM_TEST_PAYLOAD="$dir/payload.json" \
      "$dir/bin/fm-copilot-hook.sh" session-start < "$dir/in.json")
  [ -z "$out" ] || fail "non-CLI sessionStart hook printed output: $out"
  assert_absent "$dir/payload.json" "non-CLI hook invoked the Firstmate session-start owner"
  printf '%s' '{"sessionId":"cloud","stop_hook_active":false}' > "$dir/in-stop.json"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' FM_TEST_PAYLOAD="$dir/payload.json" \
      "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in-stop.json")
  [ -z "$out" ] || fail "non-CLI agentStop hook printed output: $out"
  assert_absent "$dir/payload.json" "non-CLI hook invoked the Firstmate turn-end owner"
  printf '%s' '{"notification_type":"shell_completed","command":"exec bin/fm-watch-arm.sh"}' > "$dir/in-note.json"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' \
      "$dir/bin/fm-copilot-hook.sh" notification < "$dir/in-note.json")
  [ -z "$out" ] || fail "non-CLI notification hook printed output: $out"
  pass "Copilot repository hooks stay inert outside local Copilot CLI"
}

test_claude_compatibility_hooks_stand_down() {
  local dir fakebin command out rc count=0
  dir="$TMP_ROOT/claude-compat-copilot"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
      sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed under native Copilot: $out"
    [ -z "$out" ] || fail "Claude compatibility hook $count printed under native Copilot: $out"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks stay inert under native Copilot hooks"
}

test_claude_compatibility_hooks_run_under_actual_claude_with_inherited_copilot_markers() {
  local dir fakebin command out rc count=0 versioned_claude
  dir="$TMP_ROOT/claude-compat-claude"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  versioned_claude='/home/test/.local/share/claude/versions/2.1.220/2.1.220'
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$versioned_claude" \
      FM_FAKE_PS_ARGS="$versioned_claude --dangerously-skip-permissions" \
      CLAUDE_PROJECT_DIR="$dir" sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed under real Claude ancestry: $out"
    [ -n "$out" ] || fail "Claude compatibility hook $count was suppressed by inherited Copilot markers"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks still run under actual Claude with inherited Copilot markers"
}

test_claude_compatibility_hooks_find_worktree_root_from_subdir() {
  local dir fakebin command out rc count=0
  dir="$TMP_ROOT/claude-compat-subdir"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  mkdir -p "$dir/subdir/nested"
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(cd "$dir/subdir/nested" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=claude FM_FAKE_PS_ARGS='claude --dangerously-skip-permissions' \
      sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed from a repository subdirectory: $out"
    [ -n "$out" ] || fail "Claude compatibility hook $count did not resolve the worktree root from a repository subdirectory"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks resolve their worktree root from repository subdirectories"
}

test_environment_marker_wins
test_process_shapes_are_anchored
test_actual_host_overrides_inherited_markers
test_session_lock_identity_matches_copilot
test_real_process_identity_accepts_copilot_shapes_and_rejects_decoy
test_tmux_identity_and_liveness_recognize_node_bundled_copilot
test_tmux_current_command_copilot_does_not_prove_identity
test_tmux_foreground_identity_trims_indented_args
test_session_start_translates_context
test_agent_stop_translates_block
test_pretool_arm_delegates_only_in_primary_scope
test_pretool_arm_stands_down_in_linked_task_worktree
test_copilot_native_policies_bypass_compatibility_stand_down
test_agent_stop_allows_clean_stop
test_notification_injects_watcher_followup_only_for_watcher_arm_completion
test_notification_requires_primary_scope
test_tracked_primary_hook_commands_execute
test_non_cli_hook_surface_stands_down
test_claude_compatibility_hooks_stand_down
test_claude_compatibility_hooks_run_under_actual_claude_with_inherited_copilot_markers
test_claude_compatibility_hooks_find_worktree_root_from_subdir

echo "# all fm-copilot-harness tests passed"
