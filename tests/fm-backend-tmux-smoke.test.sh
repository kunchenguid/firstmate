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

# shellcheck source=/dev/null
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
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
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

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- how much that missing verdict actually proves --------------------------
#
# The same `missing` word covers a reachable server that answered and an
# unreachable socket that could not. Only the first proves nothing is running
# at the address, and only the first may recreate the endpoint automatically.

fm_backend_tmux_missing_grade "$TARGET"
[ "$FM_BACKEND_TMUX_MISSING_GRADE" = strong ] \
  || fail "a missing window in a REACHABLE session should grade strong, got '$FM_BACKEND_TMUX_MISSING_GRADE'"
[ -n "$FM_BACKEND_TMUX_MISSING_SOCKET" ] \
  || fail "a strong missing grade should still name the socket it consulted"

# A private TMUX_TMPDIR with no server on it is the real unreachable case: tmux
# answers about the socket, never about the window.
unreachable_tmpdir=$(mktemp -d) || fail "could not stage an empty tmux socket dir"
# tmux reports the physically resolved socket path, and the OS temp dir reaches
# it through a symlink on macOS.
unreachable_real=$(cd "$unreachable_tmpdir" && pwd -P)
(
  export TMUX_TMPDIR="$unreachable_tmpdir"
  unset TMUX
  fm_backend_tmux_missing_grade "$TARGET"
  [ "$FM_BACKEND_TMUX_MISSING_GRADE" = ambiguous ] \
    || fail "an unreachable tmux socket should grade ambiguous, got '$FM_BACKEND_TMUX_MISSING_GRADE'"
  case "$FM_BACKEND_TMUX_MISSING_SOCKET" in
    "$unreachable_real"/*) : ;;
    *) fail "the ambiguous grade should name the exact socket consulted, got '$FM_BACKEND_TMUX_MISSING_SOCKET'" ;;
  esac
  [ -n "$FM_BACKEND_TMUX_MISSING_RESPONSE" ] \
    || fail "the ambiguous grade should carry the backend's own response"
  state=$(fm_backend_agent_state tmux "$TARGET")
  [ "$state" = missing ] \
    || fail "an unreachable socket still classifies missing (that is what the grade exists to qualify), got '$state'"
) || exit 1
rm -rf "$unreachable_tmpdir"
pass "real tmux: a missing verdict grades strong only when a reachable server answered, and ambiguous when the socket could not be reached"

# --- recreate the exact missing endpoint ------------------------------------

recreated_id=$(fm_backend_tmux_recreate_task "$TARGET" "$HOME") \
  || fail "fm_backend_tmux_recreate_task failed to restore the missing task window"
[ -n "$recreated_id" ] || fail "fm_backend_tmux_recreate_task returned no stable window id"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "the recreated task window is not visible at its recorded address"
[ "$(tmux display-message -p -t "$recreated_id" '#{pane_current_path}')" = "$HOME" ] \
  || fail "the recreated endpoint did not start in the requested existing worktree"
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = dead ] \
  || fail "the recreated shell endpoint should classify as agent-free, got '$state'"
if fm_backend_tmux_recreate_task "$TARGET" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_recreate_task should refuse while the endpoint already exists"
fi
pass "real tmux: a missing task endpoint is recreated once at its recorded address and worktree"

# --- a read that merely SUCCEEDED never grades strong ------------------------
#
# The liveness verdict and the grade are two separate tmux reads, so the window
# can come back between them (an operator restoring it by hand). The grade must
# account for the exact window in the inventory it read, not treat a successful
# read as proof of absence - otherwise it hands a human an authoritative quote
# about a window that is sitting right there.

fm_backend_tmux_missing_grade "$TARGET"
[ "$FM_BACKEND_TMUX_MISSING_GRADE" != strong ] \
  || fail "an inventory that LISTS the recorded window must never grade strong"
case "$FM_BACKEND_TMUX_MISSING_RESPONSE" in
  *"does not list"*)
    fail "the grade quotes tmux as not listing a window the same inventory does list: $FM_BACKEND_TMUX_MISSING_RESPONSE"
    ;;
esac
[ -n "$FM_BACKEND_TMUX_MISSING_RESPONSE" ] \
  || fail "a non-strong grade should still carry the response it read"
pass "real tmux: a successful inventory that lists the recorded window is not strong evidence of its absence"

# --- a recorded session name is never resolved to a look-alike ---------------
#
# tmux resolves a bare `-t <session>` by exact match, then prefix, then fnmatch.
# "smok" is a prefix of the live "smoke" session, so a bare lookup would report
# smoke's inventory as if it were smok's and graft the replacement window into
# smoke - recovering the task into a session that was never its address.

PREFIX_SESSION="smok"
PREFIX_WINDOW="fm-smoke2"
PREFIX_TARGET="$PREFIX_SESSION:$PREFIX_WINDOW"

tmux has-session -t "=$PREFIX_SESSION" 2>/dev/null \
  && fail "the look-alike fixture requires '$PREFIX_SESSION' to be absent"

state=$(fm_backend_agent_state tmux "$PREFIX_TARGET")
[ "$state" = missing ] \
  || fail "an absent session with a live prefix-sibling should classify missing, got '$state'"
fm_backend_tmux_missing_grade "$PREFIX_TARGET"
case "$FM_BACKEND_TMUX_MISSING_RESPONSE" in
  *"does not list"*)
    fail "the missing evidence claims a session inventory that only the look-alike '$SESSION' could have answered: $FM_BACKEND_TMUX_MISSING_RESPONSE"
    ;;
esac
# A live server that reports the recorded session gone is the ordinary
# killed-session recovery, and the contract recreates it without asking a human.
[ "$FM_BACKEND_TMUX_MISSING_GRADE" = strong ] \
  || fail "a live server reporting the recorded session absent should grade strong, got '$FM_BACKEND_TMUX_MISSING_GRADE'"
[ -n "$FM_BACKEND_TMUX_MISSING_SOCKET" ] \
  || fail "a strong grade from a live server should name the socket it consulted"

recreated_id=$(fm_backend_tmux_recreate_task "$PREFIX_TARGET" "$HOME") \
  || fail "fm_backend_tmux_recreate_task failed for a session that no longer exists"
tmux has-session -t "=$PREFIX_SESSION" 2>/dev/null \
  || fail "recreating an endpoint whose session is gone should start a session named exactly '$PREFIX_SESSION'"
tmux list-windows -t "=$PREFIX_SESSION" -F '#{window_name}' | grep -qx "$PREFIX_WINDOW" \
  || fail "the replacement window is not in its recorded session"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -qx "$PREFIX_WINDOW"; then
  fail "the replacement window was grafted into the look-alike session '$SESSION'"
fi
[ "$(tmux display-message -p -t "$recreated_id" '#{pane_current_path}')" = "$HOME" ] \
  || fail "the replacement endpoint did not start in the requested worktree"
tmux kill-session -t "=$PREFIX_SESSION" >/dev/null 2>&1 || true
pass "real tmux: a recorded session is matched exactly, so a prefix look-alike never answers for it or absorbs its endpoint"

# --- the container probe and the windows created in it agree ----------------
#
# Whatever fm_backend_tmux_container_ensure hands back is immediately targeted
# exactly by fm_backend_tmux_create_task, so its own existence probe has to be
# exact too. A live "firstmate-lab" that merely prefix-matches must not be
# mistaken for the dedicated session: the name would then address nothing and
# every spawn into it would fail.

tmux new-session -d -s firstmate-lab || fail "could not stage the look-alike container session"
tmux has-session -t "=firstmate" 2>/dev/null \
  && fail "the container fixture requires no session named exactly 'firstmate'"
(
  # container-ensure only reaches the dedicated-session branch outside tmux.
  unset TMUX
  container=$(fm_backend_tmux_container_ensure) \
    || fail "fm_backend_tmux_container_ensure failed while a look-alike session was live"
  [ "$container" = firstmate ] \
    || fail "fm_backend_tmux_container_ensure resolved '$container', expected the dedicated 'firstmate'"
  tmux has-session -t "=$container" 2>/dev/null \
    || fail "fm_backend_tmux_container_ensure returned '$container' without ensuring that session exists"
  fm_backend_tmux_create_task "$container" fm-container1 "$HOME" >/dev/null \
    || fail "a task window could not be created in the container container-ensure resolved"
  tmux list-windows -t "=firstmate" -F '#{window_name}' | grep -qx fm-container1 \
    || fail "the task window is not in the dedicated container session"
  if tmux list-windows -t "=firstmate-lab" -F '#{window_name}' | grep -qx fm-container1; then
    fail "the task window was created in the look-alike session 'firstmate-lab'"
  fi
) || exit 1
pass "real tmux: container-ensure creates and returns the dedicated session a live look-alike would otherwise stand in for"

cleanup_all
trap - EXIT
