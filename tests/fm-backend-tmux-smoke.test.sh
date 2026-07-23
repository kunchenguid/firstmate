#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Poll the pane until <needle> shows up, instead of sleeping a fixed guess.
# A fixed sleep races the pane's shell on a loaded container: the keys arrive
# before the shell is reading, the tty echoes them, and nothing ever runs. The
# read here is a raw tmux capture on purpose, so the adapter's own
# fm_backend_tmux_capture stays the thing under test rather than the mechanism
# this loop depends on.
# Every needle passed here must be text the pane can only show by EXECUTING a
# command - never text that also appears in the command line itself, or this
# would go back to passing on an idle shell's echo.
pane_shows() {  # <needle> <timeout-secs> -> 0 if seen, 1 on timeout (never fails)
  local needle=$1 timeout=$2
  local deadline=$((SECONDS + timeout)) out=
  while [ "$SECONDS" -lt "$deadline" ]; do
    out=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null) || out=
    case "$out" in *"$needle"*) return 0 ;; esac
    sleep 0.05
  done
  return 1
}
wait_for_pane_output() {  # <needle> <timeout-secs> <what-failed>
  local needle=$1 timeout=$2 what=$3
  pane_shows "$needle" "$timeout" && return 0
  local out
  out=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null) || out=
  fail "$what: '$needle' never reached the pane within ${timeout}s; the pane's shell is not executing what it is sent"$'\n'"--- pane ---"$'\n'"$out"
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

HOME_MAIN="$SHIM_DIR/homes/firstmate"
HOME_LIFE="$SHIM_DIR/homes/firstmate-life"
HOME_COLLISION="$SHIM_DIR/other/firstmate"
mkdir -p "$HOME_MAIN" "$HOME_LIFE" "$HOME_COLLISION"
HOME_MAIN=$(cd "$HOME_MAIN" && pwd -P)
HOME_LIFE=$(cd "$HOME_LIFE" && pwd -P)
HOME_COLLISION=$(cd "$HOME_COLLISION" && pwd -P)

main_session=$(FM_HOME="$HOME_MAIN" fm_backend_tmux_container_ensure) \
  || fail "real tmux: main-home container ensure failed"
life_session=$(FM_HOME="$HOME_LIFE" fm_backend_tmux_container_ensure) \
  || fail "real tmux: life-home container ensure failed"
[ "$main_session" = firstmate ] \
  || fail "real tmux: main home resolved session '$main_session', expected 'firstmate'"
[ "$life_session" = firstmate-life ] \
  || fail "real tmux: life home resolved session '$life_session', expected 'firstmate-life'"
[ "$(tmux show-options -t firstmate -v @firstmate-home)" = "$HOME_MAIN" ] \
  || fail "real tmux: main session ownership stamp does not match its physical FM_HOME"
[ "$(tmux show-options -t firstmate-life -v @firstmate-home)" = "$HOME_LIFE" ] \
  || fail "real tmux: life session ownership stamp does not match its physical FM_HOME"

fm_backend_tmux_create_task "$main_session" fm-main-home-task "$HOME_MAIN" >/dev/null \
  || fail "real tmux: main-home task window creation failed"
fm_backend_tmux_create_task "$life_session" fm-life-home-task "$HOME_LIFE" >/dev/null \
  || fail "real tmux: life-home task window creation failed"
[ "$(tmux list-windows -t firstmate -F '#{window_name}' | grep -cx fm-main-home-task)" -eq 1 ] \
  || fail "real tmux: main-home task did not land in session 'firstmate'"
[ "$(tmux list-windows -t firstmate-life -F '#{window_name}' | grep -cx fm-life-home-task)" -eq 1 ] \
  || fail "real tmux: life-home task did not land in session 'firstmate-life'"
pass "real tmux: two FM_HOME basenames create separate stamped sessions and task windows"

collision_error="$SHIM_DIR/collision-error"
if FM_HOME="$HOME_COLLISION" fm_backend_tmux_container_ensure > /dev/null 2>"$collision_error"; then
  fail "real tmux: an equal basename under another parent reused the stamped session"
fi
grep -Fq "belongs to FM_HOME '$HOME_MAIN', not '$HOME_COLLISION'; refusing to reuse it" "$collision_error" \
  || fail "real tmux: basename collision did not report both the owner and rejected FM_HOME"
[ "$(tmux show-options -t firstmate -v @firstmate-home)" = "$HOME_MAIN" ] \
  || fail "real tmux: rejected collision changed the existing session ownership stamp"
pass "real tmux: a basename collision with a mismatched ownership stamp errors and stops"

LEGACY_HOME="$SHIM_DIR/legacy/legacy-home"
mkdir -p "$LEGACY_HOME"
LEGACY_HOME=$(cd "$LEGACY_HOME" && pwd -P)
tmux new-session -d -s legacy-home -x 200 -y 50 \
  || fail "real tmux: legacy unstamped session setup failed"
tmux new-window -d -t legacy-home: -n legacy-existing-window -c "$LEGACY_HOME" \
  || fail "real tmux: legacy existing-window setup failed"
legacy_session=$(FM_HOME="$LEGACY_HOME" fm_backend_tmux_container_ensure) \
  || fail "real tmux: existing unstamped session could not be claimed"
[ "$legacy_session" = legacy-home ] \
  || fail "real tmux: existing unstamped session resolved as '$legacy_session'"
[ "$(tmux show-options -t legacy-home -v @firstmate-home)" = "$LEGACY_HOME" ] \
  || fail "real tmux: existing unstamped session was not stamped on reuse"
tmux list-windows -t legacy-home -F '#{window_name}' | grep -qx legacy-existing-window \
  || fail "real tmux: claiming an existing unstamped session destroyed its existing window"
pass "real tmux: an existing unstamped basename session is claimed without disturbing its windows"

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- shell readiness ---------------------------------------------------------
# Every assertion below reads the pane, so the pane's shell must be executing
# commands before any of them mean anything. Prove that with a sentinel whose
# OUTPUT text differs from the command text that produced it (the `'-'` quoting
# splits the literal), so seeing the needle proves the shell ran the command
# rather than the tty merely echoing it. The same trick guards each assertion
# below. Ordering does the rest: the shell runs what it is sent in order, so the
# sentinel's output landing proves the PS1 and clear ahead of it also ran.

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ '" Enter
tmux send-keys -t "$TARGET" -l "clear" ; tmux send-keys -t "$TARGET" Enter
READY="fm-smoke-ready-$$"
# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter, so a single send races startup and is
# silently lost. Retry the harmless ready probe (interrupting any half-typed
# line first) until the pane shows the sentinel. The `'-'` quoting splits the
# literal so the sentinel's OUTPUT text differs from the command that produced
# it: a match proves the shell EXECUTED the command, not the tty echoing it.
shell_ready=false
for _ in $(seq 1 60); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "echo ${READY}'-'MARK" ; tmux send-keys -t "$TARGET" Enter
  if pane_shows "${READY}-MARK" 1; then shell_ready=true; break; fi
done
[ "$shell_ready" = true ] || fail "real tmux: pane shell never became ready"
pass "real tmux: pane shell is ready and executing sent commands"

# --- send text + Enter -------------------------------------------------------

fm_backend_tmux_send_text_line "$TARGET" "echo captain-on-deck'-'line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_pane_output "captain-on-deck-line" 30 "real tmux: fm_backend_tmux_send_text_line did not submit the line"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "echo literal-then-key'-'captain" \
  || fail "fm_backend_tmux_send_literal failed"
# The literal must sit unsubmitted until the separate Enter: assert the shell has
# NOT run it yet, which is the whole point of the two-step form.
sent=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null) || sent=
case "$sent" in
  *$'\n'literal-then-key-captain*) fail "real tmux: send_literal submitted on its own, before the separate Enter"$'\n'"$sent" ;;
esac
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_pane_output "literal-then-key-captain" 30 "real tmux: send_literal + send_key(Enter) did not submit the line"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
# tag-line-80 only exists if the loop actually ran: the command text carries the
# unexpanded `tag-line-$i`, never the expanded last line. Waiting for it is what
# makes the bounds assertions below read a settled pane on a slow container.
wait_for_pane_output "tag-line-80" 60 "real tmux: the 80-line loop never produced output"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

cleanup_all
trap - EXIT
