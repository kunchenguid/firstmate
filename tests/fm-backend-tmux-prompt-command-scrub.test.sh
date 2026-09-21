#!/usr/bin/env bash
# tests/fm-backend-tmux-prompt-command-scrub.test.sh - real tmux regression
# coverage for the 2026-09-21 fleet-wide launch wedge (see
# FM_BACKEND_PROMPT_COMMAND_SCRUB in bin/fm-backend.sh): a fleet that runs
# inside a tool exporting a bash-preexec PROMPT_COMMAND into its own process
# environment hands that same exported string, minus the matching __bp_*
# function definitions, to every fresh pane the tmux server creates. Mirrors
# tests/fm-backend-tmux-smoke.test.sh's real-tmux-on-a-private-socket
# technique so this never touches the host's real sessions, and exercises the
# same production primitives bin/fm-spawn.sh calls rather than reimplementing
# them.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> [samples]
  local path=$1 samples=${2:-100} i=0
  while [ "$i" -lt "$samples" ]; do
    [ -f "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-pc-scrub-$$"
SHIM_DIR=
SCRATCH=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
}

# The poisoned string from the incident transcripts: bash-preexec's
# PROMPT_COMMAND with none of its __bp_* function definitions along for the
# ride (shell functions never propagate through the environment).
POISON=$'history -a; __bp_precmd_invoke_cmd\nhistory -a\n:\n__bp_interactive_mode'

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc-scrub.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc-scrub-work.XXXXXX")

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
[ -n "$FM_BACKEND_PROMPT_COMMAND_SCRUB" ] || fail "FM_BACKEND_PROMPT_COMMAND_SCRUB is not set after sourcing bin/fm-backend.sh"

SESSION="smoke"

# The exported PROMPT_COMMAND must be present in the environment of the
# process that starts the tmux SERVER (its first invocation) - that is what
# the server captures and every later pane inherits from, exactly mirroring
# Herdr exporting it into the primary's own environment.
PROMPT_COMMAND="$POISON" \
  tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
# Deterministic pane shell for every window in this session: environment
# inheritance (the thing under test) is unaffected by --noprofile --norc,
# which only skips startup FILES, never already-exported variables - and it
# keeps this suite's result independent of whatever rc files happen to be on
# the CI runner.
tmux set-option -t "$SESSION" default-command 'exec bash --noprofile --norc' \
  || fail "real tmux: could not pin a deterministic default-command"

# --- mechanism (a): fm_backend_tmux_create_task overrides the new pane's own
# PROMPT_COMMAND, so a task window never inherits the poison in the first
# place. ------------------------------------------------------------------

WINDOW_A="fm-scrub-a"
TARGET_A="$SESSION:$WINDOW_A"
fm_backend_tmux_create_task "$SESSION" "$WINDOW_A" "$SCRATCH" \
  || fail "fm_backend_tmux_create_task failed to create the task window"

READY=false
for _ in $(seq 1 100); do
  fm_backend_tmux_send_text_line "$TARGET_A" "printf 'ready-%s\\n' a"
  if wait_for_capture_text "$TARGET_A" "ready-a" 10; then
    READY=true
    break
  fi
done
[ "$READY" = true ] || fail "mechanism (a): the task window's shell did not become ready"

# shellcheck disable=SC2016 # must expand inside the pane, not in this script
fm_backend_tmux_send_text_line "$TARGET_A" 'printf "PC=[%s]\n" "$PROMPT_COMMAND"'
wait_for_capture_text "$TARGET_A" "PC=[]" \
  || fail "mechanism (a): fm_backend_tmux_create_task did not clear the new pane's own PROMPT_COMMAND"
out=$(fm_backend_tmux_capture "$TARGET_A" 200)
case "$out" in
  *'command not found'*) fail "mechanism (a): a task window created by fm_backend_tmux_create_task still shows a bash-preexec error"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_create_task creates a task window whose own PROMPT_COMMAND starts empty, never inheriting the poisoned string"

# --- mechanism (b): the universal floor. Simulate a pane that inherited the
# poison DESPITE mechanism (a) (an older tmux without per-pane -e support, or
# a creation path this brief did not touch) and prove the scrub line
# fm-spawn.sh sends - FM_BACKEND_PROMPT_COMMAND_SCRUB - clears it before the
# launch command is parsed, and a launch command shaped like the real one (a
# pre-launch export, then a two-step literal+Enter source of a staged file
# containing a command substitution) is delivered as one closed command. ----

WINDOW_B="fm-scrub-b"
TARGET_B="$SESSION:$WINDOW_B"
tmux new-window -d -t "$SESSION:" -n "$WINDOW_B" -c "$SCRATCH" \
  || fail "mechanism (b) setup: plain tmux new-window failed"

READY=false
for _ in $(seq 1 100); do
  fm_backend_tmux_send_text_line "$TARGET_B" "printf 'ready-%s\\n' b"
  if wait_for_capture_text "$TARGET_B" "ready-b" 10; then
    READY=true
    break
  fi
done
[ "$READY" = true ] || fail "mechanism (b): the unpatched-shape window's shell did not become ready"

# Sanity/negative control: this window must actually be poisoned, or the rest
# of this scenario proves nothing.
out=$(fm_backend_tmux_capture "$TARGET_B" 200)
case "$out" in
  *'__bp_precmd_invoke_cmd: command not found'*) : ;;
  *) fail "mechanism (b) setup: the unpatched-shape window did not inherit the poisoned PROMPT_COMMAND as expected"$'\n'"$out" ;;
esac

# The exact scrub line fm-spawn.sh sends as the very first text into the pane.
fm_backend_tmux_send_text_line "$TARGET_B" "$FM_BACKEND_PROMPT_COMMAND_SCRUB" \
  || fail "mechanism (b): could not send the scrub line"
# A marker line so later assertions can look only at what the pane showed
# AFTER the scrub, not at this scenario's own deliberately-poisoned
# scrollback from moments ago.
fm_backend_tmux_send_text_line "$TARGET_B" 'printf "post-scrub-marker-%s\n" ready'
wait_for_capture_text "$TARGET_B" "post-scrub-marker-ready" \
  || fail "mechanism (b): the pane did not execute the post-scrub marker line"

# The rest of fm-spawn.sh's pre-launch sequence: an export line via
# send_text_line, then the launch command via the two-step
# send_literal + send_key(Enter) form, sourcing a staged file (exactly what
# LAUNCH_FILE is) whose single logical command embeds a real command
# substitution - the shape the incident report says never closed.
fm_backend_tmux_send_text_line "$TARGET_B" "export GOTMPDIR=$SCRATCH/gotmp"

BRIEF_MARKER="$SCRATCH/brief-marker"
printf 'launch-brief-payload\n' > "$BRIEF_MARKER"
LAUNCH_OUT="$SCRATCH/launch-out"
DONE_MARKER="$SCRATCH/launch-done"
LAUNCH_FILE="$SCRATCH/launch.sh"
cat > "$LAUNCH_FILE" <<EOF
echo "brief=\$(cat '$BRIEF_MARKER')" > '$LAUNCH_OUT' && touch '$DONE_MARKER'
EOF

fm_backend_tmux_send_literal "$TARGET_B" ". '$LAUNCH_FILE'" \
  || fail "mechanism (b): fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET_B" Enter \
  || fail "mechanism (b): fm_backend_tmux_send_key Enter failed"

wait_for_file "$DONE_MARKER" \
  || fail "mechanism (b): the launch command (sourced from the staged file) never completed - the agent endpoint never came up"
[ "$(cat "$LAUNCH_OUT")" = "brief=launch-brief-payload" ] \
  || fail "mechanism (b): the embedded command substitution in the launch command did not resolve correctly - got: $(cat "$LAUNCH_OUT" 2>/dev/null)"

out=$(fm_backend_tmux_capture "$TARGET_B" 200 | awk '/post-scrub-marker-ready/{found=1; next} found')
case "$out" in
  *'command not found'*) fail "mechanism (b): a bash-preexec error still appeared after the scrub line"$'\n'"$out" ;;
esac
pass "real tmux: the scrub line clears an inherited poisoned PROMPT_COMMAND, and the launch command (export + two-step literal/Enter source of a file with an embedded command substitution) is delivered as one closed command and completes"

cleanup_all
trap - EXIT
