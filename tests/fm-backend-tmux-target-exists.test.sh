#!/usr/bin/env bash
# tests/fm-backend-tmux-target-exists.test.sh - both-direction existence and
# identity pins for the tmux backend, against a REAL tmux server isolated on a
# short repo-local socket (`-S`), like tests/fm-backend-tmux-smoke.test.sh. A faked tmux
# cannot cover this: the defect these tests pin was a behavior of tmux itself.
#
# The defect: `tmux display-message -p -t <session>:<window>` is not an
# existence check. When the window component does not resolve, tmux silently
# falls back to the session's CURRENT window and exits 0, so a deliberately
# bogus window name produces the same successful output as a real-but-gone one.
# Every probe built on it therefore reported every closed tmux window as still
# alive for as long as its session existed, fm_backend_target_state always
# answered `present`, and fm-teardown.sh refused to release a completed
# tmux-backed task forever - leaking its worktree lease and metadata.
#
# So every existence assertion below is written in BOTH directions, and the
# negative direction always uses a deliberately bogus name alongside the
# realistic already-closed window. The bogus-name control is the assertion that
# would have caught the original defect: under it, the old probe returned
# exactly the same success it returned for a live window.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="./.fm-target-exists-$$.sock"
SHIM_DIR=

cleanup_all() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f -- "$SOCKET"
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH redirecting every call to the private socket, so the
# adapter's bare `tmux ...` invocations never touch the host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-target-exists.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -S "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="tgt"
LIVE="fm-live1"
GONE="fm-gone1"
BOGUS="__definitely_not_a_real_window__"

exists()  { if fm_backend_tmux_target_exists "$1"; then echo yes; else echo no; fi; }
bexists() { if fm_backend_target_exists tmux "$@" 2>/dev/null; then echo yes; else echo no; fi; }
guard()   { if fm_backend_tmux_expected_label_matches "$@" 2>/dev/null; then echo yes; else echo no; fi; }

tmux new-session -d -s "$SESSION" -n zsh -x 200 -y 50 || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$LIVE" "$HOME" >/dev/null \
  || fail "fm_backend_tmux_create_task failed to create the live window"
GONE_ID=$(fm_backend_tmux_create_task "$SESSION" "$GONE" "$HOME") \
  || fail "fm_backend_tmux_create_task failed to create the to-be-closed window"
LIVE_ID=$(tmux list-windows -t "$SESSION" -F '#{window_name} #{window_id}' | awk -v w="$LIVE" '$1==w{print $2}')
[ -n "$LIVE_ID" ] && [ -n "$GONE_ID" ] || fail "could not resolve window ids for the fixture windows"

# Make the session's CURRENT window a DIFFERENT window than the one about to be
# closed. This is the whole trap: display-message answers for the current
# window, so without this the fallback would coincidentally look correct.
tmux select-window -t "$SESSION:zsh" || fail "could not select the decoy current window"

# --- fm_backend_tmux_target_exists: every shape, both directions -------------

for shape in "$SESSION:$LIVE" "$SESSION:$LIVE.0" "$LIVE_ID" "$LIVE"; do
  [ "$(exists "$shape")" = yes ] \
    || fail "fm_backend_tmux_target_exists reported a LIVE target '$shape' as gone"
done
pass "fm_backend_tmux_target_exists: live session:window, session:window.pane, @window-id and bare window name all report present"

for shape in "$SESSION:$BOGUS" "$SESSION:$BOGUS.0" "$BOGUS" "@99999" "%99999" "__nope_session__:$BOGUS" "__nope_session__"; do
  [ "$(exists "$shape")" = no ] \
    || fail "fm_backend_tmux_target_exists reported a BOGUS target '$shape' as still present (the false positive that leaks leases)"
done
[ "$(exists "$SESSION:$LIVE.99")" = no ] \
  || fail "fm_backend_tmux_target_exists reported a live window's BOGUS pane index as present"
[ "$(exists "")" = no ] || fail "fm_backend_tmux_target_exists must reject an empty target"
pass "fm_backend_tmux_target_exists: bogus window, bogus pane, bogus @id/%id, bogus session and empty target all report gone"

# The regression pin proper: the primitive must not be built on display-message,
# whose exit status carries no existence information at all.
case "$(declare -f fm_backend_tmux_target_exists)" in
  *display-message*) fail "fm_backend_tmux_target_exists must not use display-message: it exits 0 for a window that no longer exists" ;;
esac
pass "fm_backend_tmux_target_exists: does not rely on display-message for existence"

# --- the identity guard must not fail OPEN -----------------------------------

[ "$(guard "$SESSION:$LIVE" "$LIVE" "$SESSION:$LIVE")" = yes ] \
  || fail "the identity guard rejected a live session:window target carrying its own correct label"
[ "$(guard "$LIVE_ID" "$LIVE" "$SESSION:$LIVE")" = yes ] \
  || fail "the identity guard rejected a live @window-id target carrying its own correct label"
pass "identity guard: a live target whose recorded session and label match is accepted"

# A wrong expected label against a LIVE window is the cleanest fail-open probe:
# the guard has everything it needs to say no, and used to say yes for every
# target shape except @window-id.
[ "$(guard "$SESSION:$LIVE" "fm-__wrong_label__" "$SESSION:fm-__wrong_label__")" = no ] \
  || fail "the identity guard PASSED a live session:window target whose label does not match (fails open)"
[ "$(guard "$SESSION:$LIVE" "fm-__wrong_label__")" = no ] \
  || fail "the identity guard PASSED a live session:window target with a mismatched label and no recorded target (fails open)"
[ "$(guard "$LIVE_ID" "fm-__wrong_label__" "$SESSION:fm-__wrong_label__")" = no ] \
  || fail "the identity guard PASSED a live @window-id target whose label does not match"
[ "$(guard "$SESSION:$LIVE" "$LIVE" "__other_session__:$LIVE")" = no ] \
  || fail "the identity guard PASSED a target whose recorded SESSION does not match"
pass "identity guard: a mismatched label or session is rejected for session:window and @window-id alike"

[ "$(guard "$SESSION:$BOGUS" "fm-$BOGUS" "$SESSION:fm-$BOGUS")" = no ] \
  || fail "the identity guard PASSED a deliberately bogus window (fails open)"
[ "$(guard "@99999" "fm-$BOGUS" "$SESSION:fm-$BOGUS")" = no ] \
  || fail "the identity guard PASSED a bogus @window-id"
pass "identity guard: a deliberately bogus target is rejected"

[ "$(guard "$SESSION:$LIVE")" = yes ] \
  || fail "the identity guard must stay a no-op when no label and no recorded target are supplied"
pass "identity guard: with nothing to verify it defers to the caller's own existence check"

# A session:window target is resolved EXACTLY, so a label that merely looks like
# a live window's name can never borrow that window's identity.
tmux new-window -d -t "$SESSION:" -n "${LIVE}-suffix" || fail "could not create the near-miss window"
[ "$(guard "$SESSION:$LIVE" "$LIVE" "$SESSION:$LIVE")" = yes ] \
  || fail "the identity guard rejected an exact live window while a longer similarly-named window existed"
[ "$(guard "$SESSION:${LIVE}-suf" "${LIVE}-suf" "$SESSION:${LIVE}-suf")" = no ] \
  || fail "the identity guard accepted a PREFIX of a live window name as its own window"
[ "$(guard "$SESSION:${LIVE}*" "${LIVE}*" "$SESSION:${LIVE}*")" = no ] \
  || fail "the identity guard accepted an fnmatch PATTERN as a concrete window identity"
[ "$(exists "$SESSION:=${LIVE}-suffix")" = yes ] \
  || fail "the near-miss window fixture is not actually live"
tmux kill-window -t "$SESSION:=${LIVE}-suffix" || fail "could not remove the near-miss window"
pass "identity guard: session:window targets resolve exactly, never by prefix or fnmatch pattern"

# --- fm_backend_target_exists / fm_backend_target_state, both directions -----

[ "$(bexists "$SESSION:$LIVE" "$LIVE" "$SESSION:$LIVE")" = yes ] \
  || fail "fm_backend_target_exists reported a LIVE recorded target as gone"
[ "$(bexists "$SESSION:$LIVE")" = yes ] \
  || fail "fm_backend_target_exists reported a LIVE bare-recorded target as gone"
[ "$(bexists "$SESSION:$BOGUS" "fm-$BOGUS" "$SESSION:fm-$BOGUS")" = no ] \
  || fail "fm_backend_target_exists reported a BOGUS window as present"
[ "$(bexists "$SESSION:$BOGUS")" = no ] \
  || fail "fm_backend_target_exists reported a BOGUS window with no label args as present"
[ "$(bexists "$SESSION:$BOGUS.0")" = no ] \
  || fail "fm_backend_target_exists reported a BOGUS pane-qualified window as present"
pass "fm_backend_target_exists: live targets present, bogus targets gone (with and without label arguments)"

[ "$(fm_backend_target_state tmux "$SESSION:$LIVE" "$LIVE" "$SESSION:$LIVE")" = present ] \
  || fail "fm_backend_target_state did not report a LIVE target as present"
state=$(fm_backend_target_state tmux "$SESSION:$BOGUS" "fm-$BOGUS" "$SESSION:fm-$BOGUS")
[ "$state" = absent ] \
  || fail "fm_backend_target_state reported a BOGUS window as '$state', expected absent (teardown releases only on absent)"
pass "fm_backend_target_state: live -> present, deliberately bogus -> absent"

# --- the real leak scenario: a window that existed and then closed -----------

[ "$(fm_backend_target_state tmux "$SESSION:$GONE" "$GONE" "$SESSION:$GONE")" = present ] \
  || fail "fm_backend_target_state did not report the fixture window as present while it was still open"
[ "$(fm_backend_target_state tmux "$GONE_ID" "$GONE" "$SESSION:$GONE")" = present ] \
  || fail "fm_backend_target_state did not report the fixture window as present by @window-id while it was still open"

tmux kill-window -t "$GONE_ID" || fail "could not close the fixture window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$GONE" \
  && fail "the fixture window is still listed after kill-window"
# Precondition for the trap: the session survives the closed window, and its
# current window is a different, live one.
tmux has-session -t "$SESSION" || fail "the fixture session should outlive the closed window"

[ "$(exists "$SESSION:$GONE")" = no ] \
  || fail "fm_backend_tmux_target_exists reported a CLOSED window as still present"
[ "$(exists "$GONE_ID")" = no ] \
  || fail "fm_backend_tmux_target_exists reported a CLOSED window's @window-id as still present"
[ "$(bexists "$SESSION:$GONE" "$GONE" "$SESSION:$GONE")" = no ] \
  || fail "fm_backend_target_exists reported a CLOSED window as still present"
state=$(fm_backend_target_state tmux "$SESSION:$GONE" "$GONE" "$SESSION:$GONE")
[ "$state" = absent ] \
  || fail "fm_backend_target_state reported a CLOSED window as '$state', expected absent; teardown releases only on absent, so this is the lease leak"
state=$(fm_backend_target_state tmux "$GONE_ID" "$GONE" "$SESSION:$GONE")
[ "$state" = absent ] \
  || fail "fm_backend_target_state reported a CLOSED window's @window-id as '$state', expected absent"
pass "closed-window lifecycle: present while open, absent once closed, by session:window and by @window-id (the teardown lease leak)"

# --- property reads must not answer for a DIFFERENT window -------------------
# These two are the root cause the probes were built on: for a closed window
# display-message reports the session's CURRENT window and exits 0, so both
# readers used to return that other window's values (verified: 'zsh' and its
# cwd) instead of nothing.

[ -z "$(fm_backend_tmux_current_command "$SESSION:$GONE")" ] \
  || fail "fm_backend_tmux_current_command returned a command for a CLOSED window (it answered for another window)"
[ -z "$(fm_backend_tmux_current_path "$SESSION:$GONE")" ] \
  || fail "fm_backend_tmux_current_path returned a path for a CLOSED window (it answered for another window's cwd)"
[ -n "$(fm_backend_tmux_current_command "$SESSION:$LIVE")" ] \
  || fail "fm_backend_tmux_current_command returned nothing for a LIVE window"
[ -n "$(fm_backend_tmux_current_path "$SESSION:$LIVE")" ] \
  || fail "fm_backend_tmux_current_path returned nothing for a LIVE window"
pass "current_command/current_path: empty for a closed window, readable for a live one"

# --- agent liveness must not inherit another window's process ----------------
# A closed window is not provably anything, so the only correct verdict is
# `unknown`. It used to answer `dead` - a CONFIDENT verdict, read off whatever
# the session's current window happened to be running - and `dead` is exactly
# what bin/fm-bootstrap.sh's secondmate-liveness sweep gates a respawn on.
verdict=$(fm_backend_tmux_agent_alive "$SESSION:$GONE" "$GONE" "$SESSION:$GONE")
[ "$verdict" = unknown ] \
  || fail "fm_backend_tmux_agent_alive returned the confident verdict '$verdict' for a CLOSED window by reading another window; only 'unknown' is provable"
verdict=$(fm_backend_tmux_agent_alive "$SESSION:$BOGUS" "fm-$BOGUS" "$SESSION:fm-$BOGUS")
[ "$verdict" = unknown ] \
  || fail "fm_backend_tmux_agent_alive returned '$verdict' for a deliberately bogus window, expected unknown"
verdict=$(fm_backend_tmux_agent_alive "$SESSION:$LIVE" "$LIVE" "$SESSION:$LIVE")
[ "$verdict" = dead ] \
  || fail "fm_backend_tmux_agent_alive should still report a LIVE window sitting at a bare shell as 'dead', got '$verdict'"
pass "fm_backend_tmux_agent_alive: unknown for a closed or bogus window, still a real verdict for a live one"

# --- kill stays idempotent, and still refuses the WRONG window ---------------
# fm_backend_kill's contract is that an already-gone target is not an error, and
# fm-teardown.sh turns any nonzero return into "failed to stop task endpoint;
# retaining metadata" - so a correctly-rejecting identity guard must not turn
# every already-closed window into a fresh teardown refusal.

fm_backend_tmux_kill "$SESSION:$GONE" "" "$GONE" "$SESSION:$GONE" \
  || fail "fm_backend_tmux_kill on an ALREADY-CLOSED window must be a no-op success, not a teardown-blocking failure"
fm_backend_tmux_kill "$SESSION:$BOGUS" "" "fm-$BOGUS" "$SESSION:fm-$BOGUS" \
  || fail "fm_backend_tmux_kill on a deliberately bogus window must be a no-op success"
if fm_backend_tmux_kill "$SESSION:$LIVE" "" "fm-__wrong_label__" "$SESSION:fm-__wrong_label__" 2>/dev/null; then
  fail "fm_backend_tmux_kill must REFUSE a live window whose identity does not match the recorded task"
fi
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$LIVE" \
  || fail "fm_backend_tmux_kill killed a live window it should have refused"
fm_backend_tmux_kill "$SESSION:$LIVE" "" "$LIVE" "$SESSION:$LIVE" \
  || fail "fm_backend_tmux_kill failed on a live window whose identity matches"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$LIVE" \
  && fail "fm_backend_tmux_kill did not remove the matching live window"
pass "fm_backend_tmux_kill: no-op success when already gone, refuses an identity mismatch, removes a matching window"

cleanup_all
trap - EXIT
