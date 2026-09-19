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
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervisor-target-lib.sh"
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

# --- endpoint presence: tmux's silent fallbacks ------------------------------
#
# Regression (2026-09-14 fleet-loss incident): tmux resolves an UNKNOWN window
# name to the session's active window and exits 0, so an addressed
# display-message call is not a presence proof. Assert that real behavior first -
# if a future tmux stops doing this, this guard fails loudly and names the
# version rather than letting the endpoint-presence contract rot silently - then
# prove the probe trusts tmux's own answer: a vanished window name reads absent
# while its session is genuinely alive, and the real window still reads present.
if ! tmux display-message -p -t "$SESSION:no-such-window-xyz" '#{pane_id}' >/dev/null 2>&1; then
  fail "real tmux ($(tmux -V 2>/dev/null || printf 'version unknown')) no longer silently resolves an unknown window name to the active window; re-verify the endpoint-presence contract"
fi
fm_backend_tmux_target_present "$TARGET" \
  || fail "fm_backend_tmux_target_present must read a live window as present"
if fm_backend_tmux_target_present "$SESSION:no-such-window-xyz"; then
  fail "fm_backend_tmux_target_present must not read a name tmux silently resolved to the active window as present"
fi
fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists must read a live window as present"
if fm_backend_target_exists tmux "$SESSION:no-such-window-xyz"; then
  fail "fm_backend_target_exists must not read a vanished window name as a live endpoint"
fi
# tmux's "=" exact-match modifier is not part of the window name, so both
# spellings must resolve to the same live endpoint and refuse an absent one.
if ! tmux display-message -p -t "=$SESSION:=$WINDOW" '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must resolve the '=' exact-match target of a live window"
fi
fm_backend_target_exists tmux "$SESSION:=$WINDOW" \
  || fail "an '=' exact-match window name must read as a live endpoint"
fm_backend_target_exists tmux "=$SESSION:=$WINDOW" \
  || fail "an '=' exact-match session and window name must read as a live endpoint"
if fm_backend_target_exists tmux "$SESSION:=no-such-window-xyz"; then
  fail "an '=' exact-match name tmux does not hold must not read as a live endpoint"
fi
if fm_backend_target_exists tmux "=$SESSION:=no-such-window-xyz"; then
  fail "an '=' exact-match session and absent name must not read as a live endpoint"
fi
# The away-mode daemon addresses the supervisor PANE (its own $TMUX_PANE), so
# the bare pane-id shape must keep reading present, while a missing pane id - for
# which real tmux answers an empty pane_id and exit 0 - must not.
PANE_ID=$(tmux display-message -p -t "$TARGET" '#{pane_id}')
[ -n "$PANE_ID" ] || fail "real tmux: could not read the task pane id"
fm_backend_target_exists tmux "$PANE_ID" \
  || fail "the away-mode daemon's bare pane-id target must read as a live endpoint"
if fm_backend_target_exists tmux '%999999'; then
  fail "a missing pane id, which real tmux answers with an empty pane_id, must not read as live"
fi
# A numeric window-index target must be proved from the session's own
# inventory, and an index the session does not hold must read absent. The index
# is derived rather than pinned so this assertion also holds on a host whose tmux
# config sets a non-default `base-index`.
FIRST_INDEX=$(tmux list-windows -t "$SESSION" -F '#{window_index}' | head -n1)
[ -n "$FIRST_INDEX" ] || fail "real tmux: could not read a window index"
fm_backend_target_exists tmux "$SESSION:$FIRST_INDEX" \
  || fail "a window index the session holds must read as a live endpoint"
if fm_backend_target_exists tmux "$SESSION:$((FIRST_INDEX + 900))"; then
  fail "a window index the session does not hold must not read as a live endpoint"
fi
FIRST_ID=$(tmux list-windows -t "$SESSION" -F '#{window_id}' | head -n1)
[ -n "$FIRST_ID" ] || fail "real tmux: could not read a window id"
fm_backend_target_exists tmux "$SESSION:$FIRST_ID" \
  || fail "a window id the session holds must read as a live endpoint"
if fm_backend_target_exists tmux "$SESSION:@999999"; then
  fail "a window id the session does not hold must not read as a live endpoint"
fi
# A dotted name whose prefix window is live must still read absent: tmux reads
# the trailing ".0" as a pane qualifier and resolves it to the prefix window.
tmux new-window -d -t "$SESSION:" -n 'fm-prefix' \
  || fail "real tmux: could not create the fm-prefix window"
fm_backend_target_exists tmux "$SESSION:fm-prefix" \
  || fail "the live prefix window must read as a live endpoint"
tmux display-message -p -t "$SESSION:fm-prefix.0" '#{pane_id}' >/dev/null 2>&1 \
  || fail "fixture drifted: tmux must resolve the dotted name to its live prefix window"
if fm_backend_target_exists tmux "$SESSION:fm-prefix.0"; then
  fail "an absent dotted window whose live prefix window tmux resolved must not read as a live endpoint"
fi
# The explicit-target arm: an operator-typed pane-qualified target must read
# present while the window it names is live, and must still read absent when it
# is not, so tmux's silent fallback to the session's active window can never make
# an absent window present. The recorded-window arm must keep reading the same
# string as one literal window name, which is what keeps a vanished dotted
# worker window absent.
PANE_INDEX=$(tmux display-message -p -t "$SESSION:fm-prefix" '#{pane_index}')
[ -n "$PANE_INDEX" ] || fail "real tmux: could not read a pane index"
if ! tmux display-message -p -t "$SESSION:fm-prefix.$PANE_INDEX" '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must resolve a pane-qualified target"
fi
fm_backend_explicit_target_exists tmux "$SESSION:fm-prefix.$PANE_INDEX" \
  || fail "a pane-qualified explicit target whose window is live must read as present"
PREFIX_PANE_ID=$(tmux display-message -p -t "$SESSION:fm-prefix" '#{pane_id}')
[ -n "$PREFIX_PANE_ID" ] || fail "real tmux: could not read the fm-prefix pane id"
fm_backend_explicit_target_exists tmux "$SESSION:fm-prefix.$PREFIX_PANE_ID" \
  || fail "a pane-id-qualified explicit target whose pane is live must read as present"
fm_backend_explicit_target_exists tmux "$SESSION:fm-prefix" \
  || fail "a plain explicit window target must read as present"
# A dotted window name is addressable as a pane target only when tmux can form
# the pane qualifier from it: with a non-pane suffix such as `fm-dotted.id` the
# target is unrouteable, so the explicit arm reads it absent while the
# recorded-window arm still reads the live window present.
tmux new-window -d -t "$SESSION:" -n 'fm-dotted.id' \
  || fail "real tmux: could not create the fm-dotted.id window"
if tmux list-panes -t "$SESSION:fm-dotted.id" -F '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must not route a dotted name whose suffix is not a pane qualifier"
fi
fm_backend_target_exists tmux "$SESSION:fm-dotted.id" \
  || fail "the recorded-window arm must read a live dotted window name as present"
if fm_backend_explicit_target_exists tmux "$SESSION:fm-dotted.id"; then
  fail "a dotted name tmux cannot route as a pane target must read absent"
fi
# With a numeric suffix and no prefix window, tmux keeps the whole dotted name
# as the window and the target is deliverable, so the explicit arm must read the
# live window present and agree with the recorded-window arm.
tmux new-window -d -t "$SESSION:" -n 'fm-held.0' \
  || fail "real tmux: could not create the fm-held.0 window"
if ! tmux list-panes -t "$SESSION:fm-held.0" -F '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must route a dotted name whose suffix is a pane qualifier"
fi
fm_backend_target_exists tmux "$SESSION:fm-held.0" \
  || fail "the recorded-window arm must read a live dotted window name as present"
fm_backend_explicit_target_exists tmux "$SESSION:fm-held.0" \
  || fail "a deliverable dotted window name must read present through the explicit arm"
# tmux resolves an out-of-range pane index or id to the window's active pane and
# still exits 0, so a pane the window does not hold must be proved from the
# window's pane inventory and read absent.
OUT_OF_RANGE_PANE_INDEX=$((PANE_INDEX + 900))
if ! tmux display-message -p -t "$SESSION:fm-prefix.$OUT_OF_RANGE_PANE_INDEX" '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must resolve an out-of-range pane index to the window's active pane"
fi
if fm_backend_explicit_target_exists tmux "$SESSION:fm-prefix.$OUT_OF_RANGE_PANE_INDEX"; then
  fail "a pane-qualified explicit target naming a pane index the window does not hold must read absent"
fi
if fm_backend_explicit_target_exists tmux "$SESSION:fm-prefix.%999999"; then
  fail "a pane-qualified explicit target naming a pane id the window does not hold must read absent"
fi
if ! tmux display-message -p -t "$SESSION:no-such-window-xyz.$PANE_INDEX" '#{pane_id}' >/dev/null 2>&1; then
  fail "fixture drifted: real tmux must resolve an absent window name to the active window"
fi
if fm_backend_explicit_target_exists tmux "$SESSION:no-such-window-xyz.$PANE_INDEX"; then
  fail "a pane-qualified explicit target whose window is absent must read absent even though tmux resolved it to the active window"
fi
if fm_backend_target_exists tmux "$SESSION:fm-prefix.$PANE_INDEX"; then
  fail "the recorded-window arm must keep reading a pane-qualified string as one literal window name"
fi
fm_backend_explicit_target_exists tmux "$PANE_ID" \
  || fail "the explicit-target arm must keep reading a bare pane id as present"
# tmux also resolves a target-session by exact name, then by unique prefix, then
# by glob, so a session that does not exist can still answer an inventory from a
# live prefix sibling and make a vanished endpoint read present. The presence
# proof forces tmux's exact session match, so the same window under a
# prefix-only session name must read absent while the real session still reads
# present.
PREFIX_SESSION="${SESSION%?}"
[ -n "$PREFIX_SESSION" ] && [ "$PREFIX_SESSION" != "$SESSION" ] \
  || fail "fixture drifted: the smoke session name must have a strict prefix"
tmux list-windows -t "$PREFIX_SESSION" -F '#{window_name}' >/dev/null 2>&1 \
  || fail "fixture drifted: real tmux must resolve the unique session-name prefix '$PREFIX_SESSION'"
if fm_backend_target_exists tmux "$PREFIX_SESSION:$WINDOW"; then
  fail "a target whose session exists only as a unique prefix of a live session must not read as a live endpoint"
fi
fm_backend_target_exists tmux "$SESSION:$WINDOW" \
  || fail "the exact session must still read as a live endpoint"
pass "real tmux: endpoint presence is proved from tmux's own answer, never its silent fallback"

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

# --- supervisor fallback under a non-default base-index ----------------------
#
# The away-mode supervisor fallback names the "firstmate" SESSION rather than a
# fixed window index, so it must resolve the session's active window whatever the
# operator's `base-index` is - a configuration this repo's own create path
# supports. Model exactly that on the private server: a session whose first (and
# only) window carries index 1.
fallback=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
  discover_supervisor_target 2>/dev/null) || true
[ "$fallback" = "$FM_SUPERVISOR_TARGET_DEFAULT" ] \
  || fail "fixture drifted: the bare supervisor fallback is '$fallback'"
tmux set-option -g base-index 1
tmux new-session -d -s "$FM_SUPERVISOR_TARGET_DEFAULT" -x 80 -y 24 \
  || fail "real tmux: could not create the fallback session"
SUPERVISOR_INDEX=$(tmux list-windows -t "$FM_SUPERVISOR_TARGET_DEFAULT" -F '#{window_index}' | head -n1)
[ "$SUPERVISOR_INDEX" != "0" ] \
  || fail "fixture drifted: base-index 1 must give the fallback session a window index other than 0"
if fm_backend_explicit_target_exists tmux "$FM_SUPERVISOR_TARGET_DEFAULT:0"; then
  fail "a fixed index-0 supervisor target must read absent when the session's windows start above 0"
fi
fm_backend_explicit_target_exists tmux "$FM_SUPERVISOR_TARGET_DEFAULT" \
  || fail "the supervisor fallback must resolve the session's active window under a non-default base-index"
pass "real tmux: the supervisor fallback resolves the session's active window under a non-default base-index"

cleanup_all
trap - EXIT
