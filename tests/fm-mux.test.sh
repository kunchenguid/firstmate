#!/usr/bin/env bash
# Behavior tests for bin/fm-mux.sh — the terminal-multiplexer abstraction.
# Exercises BOTH backends through the fm-mux.sh CLI dispatcher with fakes on
# PATH, so it runs anywhere (Linux CI included) without a real tmux or WezTerm.
# Invocations pass env inline to a subprocess (repo convention), so no backend
# state leaks between cases.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUX="$ROOT/bin/fm-mux.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-mux.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# --- fake tmux: logs every invocation verbatim, answers the read verbs --------
make_fake_tmux() {
  local fb="$1/fb"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
echo "tmux $*" >> "$FB_LOG"
case "$1" in
  capture-pane) printf 'line-1\nline-2\n' ;;
  display-message) printf '7\n' ;;
  list-windows) printf 'nope\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- fake wezterm: a minimal `wezterm cli ...` surface ------------------------
make_fake_wezterm() {
  local fb="$1/fb"
  mkdir -p "$fb"
  cat > "$fb/wezterm" <<'SH'
#!/usr/bin/env bash
shift  # drop "cli"
verb=$1; shift
echo "wezterm $verb $*" >> "${FB_LOG:-/dev/null}"
case "$verb" in
  spawn) echo "${FB_SPAWN_PANE:-42}" ;;
  set-tab-title) : ;;
  send-text) cat >> "${FB_SENT:-/dev/null}" ;;   # text arrives on stdin
  get-text) printf 'top\nMARKER_OK\n\n\n' ;;       # trailing blanks = viewport padding
  kill-pane) : ;;
  list)
    cat <<'JSON'
[
  {
    "pane_id": 42,
    "title": "bash.exe",
    "cwd": "file:///home/u/proj/",
    "cursor_x": 3,
    "cursor_y": 9
  }
]
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fb/wezterm"
  printf '%s\n' "$fb"
}

# ============================================================================
# tmux backend — emits exactly the commands the rest of firstmate (and the
# other test shims) expect.
# ============================================================================
test_tmux_backend_commands() {
  local dir fb log
  dir="$TMP_ROOT/tmux"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  log="$dir/log"; : > "$log"

  [ "$(PATH="$fb:$PATH" FM_MUX=tmux "$MUX" backend)" = tmux ] || fail "backend not tmux"
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" send-text "s:fm-x" "hi there"
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" send-enter "s:fm-x"
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" send-key "s:fm-x" Escape
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" capture "s:fm-x" 40 >/dev/null
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" capture-visible "s:fm-x" >/dev/null
  PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" kill-window "s:fm-x"
  local h
  h=$(PATH="$fb:$PATH" FM_MUX=tmux FB_LOG="$log" "$MUX" new-window s fm-y /tmp/wd)
  [ "$h" = "s:fm-y" ] || fail "new_window handle wrong: $h"

  grep -qF 'tmux send-keys -t s:fm-x -l hi there' "$log" || fail "send_text cmd"
  grep -qF 'tmux send-keys -t s:fm-x Enter' "$log" || fail "send_enter cmd"
  grep -qF 'tmux send-keys -t s:fm-x Escape' "$log" || fail "send_key cmd"
  grep -qF 'tmux capture-pane -p -t s:fm-x -S -40' "$log" || fail "capture cmd"
  grep -qF 'tmux capture-pane -p -t s:fm-x' "$log" || fail "capture_visible cmd"
  grep -qF 'tmux kill-window -t s:fm-x' "$log" || fail "kill cmd"
  grep -qF 'tmux new-window -d -t s -n fm-y -c /tmp/wd' "$log" || fail "new_window cmd"
  pass "tmux backend emits the expected tmux commands"
}

# ============================================================================
# wezterm backend
# ============================================================================
test_wezterm_backend() {
  local dir fb log sent
  dir="$TMP_ROOT/wez"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  log="$dir/log"; sent="$dir/sent"; : > "$log"; : > "$sent"

  [ "$(PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" backend)" = wezterm ] || fail "backend not wezterm"

  # window-exists is always false on wezterm (cannot query by name)
  if PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" window-exists wezterm fm-foo; then
    fail "window-exists should be false on wezterm"
  fi

  local h
  h=$(PATH="$fb:$PATH" FM_MUX=wezterm FB_LOG="$log" "$MUX" new-window wezterm fm-foo /tmp/wd)
  [ "$h" = "wezterm:42" ] || fail "new_window handle: $h"

  # send-text / -enter / -key all funnel through send-text via stdin. Use a
  # value full of shell metacharacters (no $-expansion) to prove the text is
  # passed through verbatim, not mangled by argv conversion.
  PATH="$fb:$PATH" FM_MUX=wezterm FB_SENT="$sent" "$MUX" send-text "wezterm:42" 'echo "a|b;c&d"'
  grep -qF 'echo "a|b;c&d"' "$sent" || fail "send_text content not piped via stdin"

  # capture trims trailing blanks then tails (MARKER_OK is the last content line)
  local out
  out=$(PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" capture "wezterm:42" 1)
  [ "$out" = "MARKER_OK" ] || fail "capture trailing-blank trim/tail wrong: [$out]"

  # capture-visible keeps the raw viewport (trailing blank rows intact)
  local vis
  vis=$(PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" capture-visible "wezterm:42" | wc -l | tr -d ' ')
  [ "$vis" -ge 4 ] || fail "capture-visible should keep blank rows: $vis"

  # pane-path: file:///home/u/proj/ -> /home/u/proj (no cygpath on CI)
  local p
  p=$(PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" pane-path "wezterm:42")
  [ "$p" = "/home/u/proj" ] || fail "pane-path normalization wrong: [$p]"

  # cursor-y from the list JSON
  [ "$(PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" cursor-y "wezterm:42")" = "9" ] || fail "cursor-y wrong"

  # pane-alive: 42 present, 99 absent
  PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" pane-alive "wezterm:42" || fail "pane-alive should be true for 42"
  if PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" pane-alive "wezterm:99"; then fail "pane-alive should be false for 99"; fi

  PATH="$fb:$PATH" FM_MUX=wezterm FB_LOG="$log" "$MUX" kill-window "wezterm:42"
  grep -qF 'wezterm kill-pane' "$log" || fail "kill_window cmd"

  # find-window is unsupported on wezterm
  if PATH="$fb:$PATH" FM_MUX=wezterm "$MUX" find-window fm-foo 2>/dev/null; then
    fail "find-window should fail on wezterm"
  fi

  # resolve-supervisor maps WEZTERM_PANE to a handle
  [ "$(PATH="$fb:$PATH" FM_MUX=wezterm WEZTERM_PANE=11 "$MUX" resolve-supervisor)" = "wezterm:11" ] \
    || fail "resolve-supervisor should map WEZTERM_PANE"

  pass "wezterm backend spawns, sends, captures, and normalizes cwd"
}

# ============================================================================
# backend selection precedence
# ============================================================================
test_backend_precedence() {
  [ "$(FM_MUX=wezterm "$MUX" backend)" = wezterm ] || fail "FM_MUX override ignored"
  [ "$(TMUX=/tmp/x "$MUX" backend)" = tmux ] || fail "\$TMUX should select tmux"
  pass "backend selection honors FM_MUX and \$TMUX"
}

test_tmux_backend_commands
test_wezterm_backend
test_backend_precedence
echo "all fm-mux tests passed"
