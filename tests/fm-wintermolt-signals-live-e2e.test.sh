#!/usr/bin/env bash
# Live drift guard for the Wintermolt adapter's vendor-controlled surface: the
# pinned footer row the busy fallback matches (Esc stop / spinner working vs
# Esc quit / ● ready), the rounded bordered composer with its cursor-cell idle
# placeholder and the keybind row below it, the anchored `wintermolt` foreground
# process name both detection arms key on, single-Escape interrupt (which quits
# an idle TUI, the hazard the control plane guards), and /quit exit. Opt-in
# because it submits real prompts through the operator's configured backend.
#
# Run this deliberately, never from inside a validation step. Each scenario
# waits on real model turns, so the runtime is bounded only by the stall
# timeout. The portable regression tests/fm-wintermolt-harness.test.sh is what
# CI enforces; it does not cover the vendor-rendered surface above, so a green
# suite is not evidence these signals still work.
#
# Isolation: the worker runs in a throwaway workspace under a private tmux
# socket; no firstmate home, project, or config is touched. The backend and
# provider are the operator's wintermolt environment (WINTERMOLT_BACKEND plus
# the chosen backend's own URL/key variables); FM_WINTERMOLT_LIVE_ENV may name
# a sourced script that exports them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WM_BIN=
REAL_TMUX=
LAB=
SOCKET="fm-wintermolt-signals-$$"
SESSION=wintermolt-signals
TARGET="$SESSION:wm"
WM_VERSION='wintermolt(unknown)'

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s [%s]\n' "$1" "$WM_VERSION" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_WINTERMOLT_SIGNALS_LIVE wintermolt tmux
WM_BIN=$(command -v wintermolt 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
[ -n "$WM_BIN" ] || fail "wintermolt is not installed"
[ -n "$REAL_TMUX" ] || fail "tmux is not installed"
WM_VERSION=$("$WM_BIN" --version 2>/dev/null | head -1 || echo "wintermolt(unknown)")
case "$WM_VERSION" in
  *0.7.*) ;;
  *) echo "notice: verified surface was 0.7.0; this run refreshes evidence on '$WM_VERSION'" >&2 ;;
esac

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-wintermolt-signals.XXXXXX") || fail "could not create the isolated wintermolt lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated wintermolt workspace"

# The backend and its provider ride the operator's own wintermolt environment;
# an optional sourced script may pin them for the run.
if [ -n "${FM_WINTERMOLT_LIVE_ENV:-}" ]; then
  # shellcheck source=/dev/null
  . "$FM_WINTERMOLT_LIVE_ENV" || fail "could not source FM_WINTERMOLT_LIVE_ENV=$FM_WINTERMOLT_LIVE_ENV"
fi
[ -n "${WINTERMOLT_BACKEND:-}" ] \
  || fail "no WINTERMOLT_BACKEND in the environment; set the operator's wintermolt backend environment or name a script with FM_WINTERMOLT_LIVE_ENV"

# The liveness probe below runs a bare `tmux`, so the private socket is bound by
# a shim on PATH. That lets the guard drive the shipped reads rather than a
# transcription of them, which would go stale exactly when the probe changes.
mkdir -p "$LAB/shim"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not source the tmux backend"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n wm \
  || fail "could not open the isolated wintermolt window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

busy_verdict() {
  printf '%s' "$(capture)" | fm_busy_classify tmux "$TARGET" wintermolt "wm-live" "$LAB/state"
}

composer_verdict() {
  fm_backend_composer_state tmux "$TARGET"
}

wait_for() {  # <ere> <timeout-seconds>
  local elapsed=0
  while :; do
    rendered=$(capture)
    printf '%s\n' "$rendered" | grep -Eq -- "$1" && return 0
    awk -v e="$elapsed" -v t="$2" 'BEGIN{exit !(e < t)}' || return 1
    sleep 0.5
    elapsed=$(awk -v e="$elapsed" 'BEGIN{printf "%.3f", e + 0.5}')
  done
}

# Launch the real wintermolt TUI in the isolated window, on the operator's
# backend environment, with the no-fallback pin the fleet launch pins.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "cd \"$WORKSPACE\" && WINTERMOLT_NO_FALLBACK=1 $WM_BIN" \
  || fail "could not type the wintermolt launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the wintermolt launch line"

mkdir -p "$LAB/state"

# The ready footer must appear before anything is typed into the composer, and
# the idle composer must read empty through the real classifier. The keybind
# segment (`Esc quit`) is the ready signal: on a narrow pane the trailing
# status cell is truncated to an ellipsis while the keybind words stay.
wait_for 'Esc quit' 30 \
  || fail "the TUI never showed its ready footer (an unusable WINTERMOLT_BACKEND or missing backend key exits at startup)"
sleep 1
[ "$(composer_verdict)" = empty ] \
  || fail "the idle composer must read empty, got '$(composer_verdict)'"
pass "composer: the idle TUI reads empty through the shipped classifier"

# The anchored foreground identity: the pane's foreground process must be
# exactly wintermolt, and the tool-side harness detector must agree.
fg_comm=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
[ "$fg_comm" = wintermolt ] \
  || fail "the pane foreground is '$fg_comm', not the anchored wintermolt name"
detected=$(PATH="$LAB/shim:$PATH" "$ROOT/bin/fm-harness.sh" ancestry-descent "$(pgrep -n wintermolt)" 2>/dev/null || true)
case "$detected" in
  wintermolt|'comm wintermolt') ;;
  *) fail "the tool-side detector returned '$detected' from wintermolt ancestry" ;;
esac
pass "identity: the anchored wintermolt process name is what detection reads"

# Start a real turn and require the busy footer plus the busy verdict.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Run this bash command and report its output verbatim: sleep 5 && echo WINTERMOLT-LIVE-BUSY" \
  || fail "could not type the probe prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the probe prompt"
wait_for 'Esc stop' 30 \
  || fail "a running turn never showed the Esc stop footer"
case "$(busy_verdict)" in
  'busy wintermolt-regex') ;;
  *) fail "the busy fallback did not read busy wintermolt-regex, got '$(busy_verdict)'" ;;
esac
pass "busy: the pinned footer carries the busy verdict"

# Single Escape interrupts the running turn and returns the ready footer; the
# process must survive.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send the interrupt Escape"
wait_for 'Esc quit' 30 \
  || fail "the interrupted turn never returned to the ready footer"
sleep 1
fg_comm=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
[ "$fg_comm" = wintermolt ] \
  || fail "the process did not survive its interrupt (foreground now '$fg_comm')"
case "$(busy_verdict)" in
  busy*) fail "the interrupted pane still reads busy" ;;
esac
[ "$(composer_verdict)" = empty ] \
  || fail "the post-interrupt composer must read empty, got '$(composer_verdict)'"
pass "interrupt: one Escape stops the turn and leaves an empty ready composer"

# The exit command: /quit into a proven-empty composer exits to the shell.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" \
  || fail "could not type the exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the exit command"
wait_for 'Goodbye' 30 \
  || fail "/quit did not exit the TUI"
fg_comm=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
[ "$fg_comm" = wintermolt ] \
  && fail "the process did not exit on /quit (foreground still '$fg_comm')" || true
pass "exit: /quit exits the TUI to the pane shell"

fm_test_cleanup
printf 'all wintermolt live signal checks passed [%s]\n' "$WM_VERSION"
