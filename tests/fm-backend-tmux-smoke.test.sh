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

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it. Clear any half-typed retry with C-u (a
# line-editing key), never C-c: SIGINT delivered while bash is still sourcing
# its startup files kills it before the interactive handler is armed, which
# closes the pane and the window with it (observed deterministically on a slow
# WSL2 host, tmux 3.6, 2026-07-22).
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-u
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
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
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
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

# --- numeric session name: a bare -t "$ses" parses "1" as a window INDEX -----
# Regression (observed live 2026-07-16): with firstmate inside a tmux session
# literally named "1" and window index 1 occupied, the old bare-name form
# `new-window -d -t "$ses"` resolved "1" as a window INDEX in the current
# session, so the first spawn filled index 1 and every further concurrent
# spawn failed with "create window failed: index 1 in use". The "=$ses:"
# target pins exact session-NAME parsing and appends at the next free index,
# so consecutive creations must all succeed. Kill the smoke session first so
# "1" is the server's only (and therefore current) session, matching the live
# failure's resolution context.
tmux kill-session -t "=$SESSION" 2>/dev/null || true
NUMSES="1"
tmux new-session -d -s "$NUMSES" -x 200 -y 50 \
  || fail "real tmux: could not create a session literally named '1'"
tmux new-window -d -t "=$NUMSES:" -n occupier \
  || fail "real tmux: could not occupy window index 1 of session '1'"
fm_backend_tmux_create_task "$NUMSES" "fm-num-a" "$HOME" >/dev/null \
  || fail "numeric session: first fm_backend_tmux_create_task failed"
fm_backend_tmux_create_task "$NUMSES" "fm-num-b" "$HOME" >/dev/null \
  || fail "numeric session: second fm_backend_tmux_create_task failed (bare -t parsed the session name as a window index?)"
for w in fm-num-a fm-num-b; do
  tmux list-windows -t "=$NUMSES" -F '#{window_name}' | grep -qx "$w" \
    || fail "numeric session: window $w did not land in session '$NUMSES'"
done
pass "real tmux: two consecutive task creations succeed in a session literally named '1' with index 1 occupied"

# --- exact-match session resolution: bare session names PREFIX-match ---------
# tmux resolves an unqualified session target by exact name, then prefix, then
# fnmatch: with only "firstmate2" present, a bare `has-session -t firstmate`
# succeeds, container-ensure would never create the real "firstmate" session,
# and every task window would land in the stranger session. The "=" probe pins
# exact-name matching, so the dedicated session must be created alongside the
# prefix-sibling. TMUX is unset in a subshell to force the detached-session
# branch regardless of where the test itself runs.
tmux new-session -d -s firstmate2 -x 200 -y 50 \
  || fail "real tmux: could not create the decoy session firstmate2"
ses=$( (unset TMUX; fm_backend_tmux_container_ensure) ) \
  || fail "fm_backend_tmux_container_ensure failed next to a prefix-sibling session"
[ "$ses" = firstmate ] || fail "fm_backend_tmux_container_ensure printed '$ses', expected 'firstmate'"
tmux has-session -t "=firstmate" 2>/dev/null \
  || fail "container-ensure did not create the exact 'firstmate' session (bare probe prefix-matched 'firstmate2'?)"
pass "real tmux: fm_backend_tmux_container_ensure creates the exact 'firstmate' session even when a prefix-sibling exists"

# --- a STALE recorded target must never reach into a stranger session --------
# The recorded endpoint is the plain "<session>:<window>" name pair, and tmux
# resolves BOTH halves by exact name, then prefix, then fnmatch. Verified live
# (tmux 3.6): with only session "firstmate2" holding window "fm-abcd",
# `display-message -p -t firstmate:fm-abc` reported "firstmate2:fm-abcd" and
# `kill-window -t firstmate:fm-abc` destroyed it. fm_tmux_pin_target pins every
# target the tmux primitives compose, so the stale record must now read as gone
# and leave the stranger's window standing.
tmux kill-session -t "=$NUMSES" 2>/dev/null || true
tmux kill-session -t "=firstmate" 2>/dev/null || true
tmux kill-session -t "=firstmate2" 2>/dev/null || true
tmux new-session -d -s firstmate2 -x 200 -y 50 \
  || fail "real tmux: could not create the stranger session firstmate2"
fm_backend_tmux_create_task firstmate2 fm-abcd "$HOME" >/dev/null \
  || fail "real tmux: could not create the stranger window firstmate2:fm-abcd"
STALE="firstmate:fm-abc"

[ "$(fm_backend_tmux_current_path "$STALE")" = "" ] \
  || fail "a stale record resolved to a live pane (bare target prefix-matched firstmate2:fm-abcd?)"
[ "$(fm_backend_tmux_current_command "$STALE")" = "" ] \
  || fail "a stale record read a live pane's foreground command (bare target prefix-matched?)"
if fm_backend_tmux_send_text_line "$STALE" "echo intruder" 2>/dev/null; then
  fail "a stale record accepted a send (bare target prefix-matched a stranger's pane?)"
fi
fm_backend_tmux_kill "$STALE"
tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -qx "firstmate2:fm-abcd" \
  || fail "killing a stale record destroyed the stranger's window firstmate2:fm-abcd"
pass "real tmux: a stale '$STALE' record neither reads, writes to, nor kills the stranger window firstmate2:fm-abcd"

# The pin must not cost the exact target anything: the same primitives still
# reach the real window by its recorded name pair.
[ -n "$(fm_backend_tmux_current_path "firstmate2:fm-abcd")" ] \
  || fail "the exact recorded target no longer resolves its own pane's cwd"
fm_backend_tmux_kill "firstmate2:fm-abcd"
if tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -qx "firstmate2:fm-abcd"; then
  fail "the exact recorded target no longer kills its own window"
fi
pass "real tmux: the exact-match pin still resolves and kills a target by its recorded name pair"

cleanup_all
trap - EXIT
