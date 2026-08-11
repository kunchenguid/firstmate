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

# shellcheck source=/dev/null
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

# --- basename collision: the colliding home gets its OWN session --------------
# A secondmate home leased from the firstmate repo always has basename
# "firstmate", so before the home-tag fallback such a home could not open a
# session at all. HOME_COLLISION reproduces exactly that: same basename as
# HOME_MAIN, different parent, and HOME_MAIN already owns the "firstmate"
# session created above.

collision_session=$(FM_HOME="$HOME_COLLISION" fm_backend_tmux_container_ensure) \
  || fail "real tmux: an equal basename under another parent could not open any session"
[ "$collision_session" != firstmate ] \
  || fail "real tmux: the colliding home was handed the OTHER home's 'firstmate' session"
expected_tag=$(fm_backend_hometag_for "$HOME_COLLISION" "$HOME_COLLISION")
[ "$collision_session" = "$expected_tag" ] \
  || fail "real tmux: colliding home resolved '$collision_session', expected the home tag '$expected_tag'"
[ "$(tmux show-options -t "$collision_session" -v @firstmate-home)" = "$HOME_COLLISION" ] \
  || fail "real tmux: the fallback session is not stamped with the colliding home's FM_HOME"
fm_backend_tmux_create_task "$collision_session" fm-collision-home-task "$HOME_COLLISION" >/dev/null \
  || fail "real tmux: colliding home could not create a task window in its fallback session"
[ "$(tmux list-windows -t "$collision_session" -F '#{window_name}' | grep -cx fm-collision-home-task)" -eq 1 ] \
  || fail "real tmux: colliding home's task did not land in its own fallback session"
pass "real tmux: a home whose basename is owned by another home opens its own home-tagged session ($collision_session)"

# RED: the other home's session must be untouched - not reused, not renamed,
# not restamped, and none of its windows moved or lost.
[ "$(tmux show-options -t firstmate -v @firstmate-home)" = "$HOME_MAIN" ] \
  || fail "real tmux: the fallback changed the other home's ownership stamp"
tmux list-sessions -F '#{session_name}' | grep -Fqx firstmate \
  || fail "real tmux: the fallback renamed the other home's session out of the way"
[ "$(tmux list-windows -t firstmate -F '#{window_name}' | grep -cx fm-main-home-task)" -eq 1 ] \
  || fail "real tmux: the other home's existing task window did not survive the fallback"
tmux list-windows -t firstmate -F '#{window_name}' | grep -qx fm-collision-home-task \
  && fail "real tmux: the colliding home's window landed in the OTHER home's session"
pass "real tmux: the foreign-stamped session keeps its name, stamp, and windows - it is stepped around, never reused"

# The resolution is STABLE: a second ensure for the same home returns the same
# session rather than drifting to a new name each spawn.
collision_again=$(FM_HOME="$HOME_COLLISION" fm_backend_tmux_container_ensure) \
  || fail "real tmux: second ensure for the colliding home failed"
[ "$collision_again" = "$collision_session" ] \
  || fail "real tmux: colliding home is not stable across ensures ('$collision_session' then '$collision_again')"
pass "real tmux: the fallback session name is stable across repeated container ensures"

# The production shape of the collision: a secondmate home leased from the
# firstmate repo, carrying .fm-secondmate-home, whose basename is "firstmate".
# Its session must be identifiable at a glance in `tmux ls`, and must NOT depend
# on which home's scripts resolved it - the primary steering a secondmate runs
# the PRIMARY's FM_ROOT with the SECONDMATE's FM_HOME, and both callers have to
# name the same session.
SM_HOME="$SHIM_DIR/treehouse/lease/firstmate"
mkdir -p "$SM_HOME"
SM_HOME=$(cd "$SM_HOME" && pwd -P)
printf 'upstream-sync\n' > "$SM_HOME/.fm-secondmate-home"
sm_session=$(FM_HOME="$SM_HOME" FM_ROOT="$SM_HOME" fm_backend_tmux_container_ensure) \
  || fail "real tmux: secondmate-marked colliding home could not open a session"
case "$sm_session" in
  2ndmate-upstream-sync-*) : ;;
  *) fail "real tmux: secondmate home resolved '$sm_session', expected a 2ndmate-upstream-sync-* session" ;;
esac
[ "$(tmux show-options -t "$sm_session" -v @firstmate-home)" = "$SM_HOME" ] \
  || fail "real tmux: the secondmate's session is not stamped with its own FM_HOME"
sm_from_primary=$(FM_HOME="$SM_HOME" FM_ROOT="$HOME_MAIN" fm_backend_tmux_container_ensure) \
  || fail "real tmux: resolving the secondmate's session from the primary's root failed"
[ "$sm_from_primary" = "$sm_session" ] \
  || fail "real tmux: the same home resolved '$sm_session' from its own root but '$sm_from_primary' from the primary's; the session name must not depend on FM_ROOT"
pass "real tmux: a secondmate-marked colliding home gets a readable 2ndmate-<id> session, identical from either caller's FM_ROOT ($sm_session)"

# tmux rewrites '.' and ':' in a session name to '_', so a secondmate id
# carrying either must not make ensure print a session name that does not
# exist. Nothing validates that id's charset upstream, so this is reachable.
DOTTY_HOME="$SHIM_DIR/dotty/firstmate"
mkdir -p "$DOTTY_HOME"
DOTTY_HOME=$(cd "$DOTTY_HOME" && pwd -P)
printf 'up.sync:v2\n' > "$DOTTY_HOME/.fm-secondmate-home"
dotty_session=$(FM_HOME="$DOTTY_HOME" fm_backend_tmux_container_ensure) \
  || fail "real tmux: a secondmate id containing '.' or ':' could not open a session"
case "$dotty_session" in
  *.*|*:*) fail "real tmux: ensure returned '$dotty_session', a name tmux cannot create verbatim" ;;
esac
tmux list-sessions -F '#{session_name}' | grep -Fqx "$dotty_session" \
  || fail "real tmux: ensure printed '$dotty_session' but no such session exists"
[ "$(tmux show-options -t "$dotty_session" -v @firstmate-home)" = "$DOTTY_HOME" ] \
  || fail "real tmux: the sanitized session is not stamped with its home"
pass "real tmux: a secondmate id with '.'/':' resolves to the name tmux really created ($dotty_session)"

# Adoption beats creation: with its home-tag session already stamped and
# holding a live window, the home keeps using it even once the basename frees
# up, so recorded window= handles are never stranded in an abandoned session.
tmux kill-session -t firstmate-adopt-probe 2>/dev/null || true
ADOPT_HOME="$SHIM_DIR/adopt/firstmate-adopt-probe"
mkdir -p "$ADOPT_HOME"
ADOPT_HOME=$(cd "$ADOPT_HOME" && pwd -P)
adopt_tag=$(fm_backend_hometag_for "$ADOPT_HOME" "$ADOPT_HOME")
tmux new-session -d -s "$adopt_tag" || fail "real tmux: adoption-probe session setup failed"
tmux set-option -t "$adopt_tag" @firstmate-home "$ADOPT_HOME" \
  || fail "real tmux: adoption-probe stamp setup failed"
adopted=$(FM_HOME="$ADOPT_HOME" fm_backend_tmux_container_ensure) \
  || fail "real tmux: adoption-probe ensure failed"
[ "$adopted" = "$adopt_tag" ] \
  || fail "real tmux: an existing own-stamped home-tag session was abandoned for a fresh basename session ('$adopted')"
tmux list-sessions -F '#{session_name}' | grep -Fqx firstmate-adopt-probe \
  && fail "real tmux: ensure created a redundant basename session while its own tagged session was live"
pass "real tmux: an existing session already stamped for this home is adopted before any new one is created"

# RED: with BOTH candidate names owned by other homes, it must still refuse
# rather than invent a third name or steal one.
BLOCKED_HOME="$SHIM_DIR/blocked/firstmate"
mkdir -p "$BLOCKED_HOME"
BLOCKED_HOME=$(cd "$BLOCKED_HOME" && pwd -P)
blocked_tag=$(fm_backend_hometag_for "$BLOCKED_HOME" "$BLOCKED_HOME")
FOREIGN_HOME="$SHIM_DIR/foreign-owner"
mkdir -p "$FOREIGN_HOME"
FOREIGN_HOME=$(cd "$FOREIGN_HOME" && pwd -P)
tmux new-session -d -s "$blocked_tag" || fail "real tmux: forged-stamp session setup failed"
tmux set-option -t "$blocked_tag" @firstmate-home "$FOREIGN_HOME" \
  || fail "real tmux: forged-stamp setup failed"
blocked_error="$SHIM_DIR/blocked-error"
if FM_HOME="$BLOCKED_HOME" fm_backend_tmux_container_ensure > /dev/null 2>"$blocked_error"; then
  fail "real tmux: with both candidate sessions owned by other homes, ensure did not refuse"
fi
grep -Fq "tmux session 'firstmate' belongs to FM_HOME '$HOME_MAIN', not '$BLOCKED_HOME'" "$blocked_error" \
  || fail "real tmux: refusal did not name the basename candidate's owner"$'\n'"$(cat "$blocked_error")"
grep -Fq "tmux session '$blocked_tag' belongs to FM_HOME '$FOREIGN_HOME', not '$BLOCKED_HOME'" "$blocked_error" \
  || fail "real tmux: refusal did not name the home-tag candidate's owner"$'\n'"$(cat "$blocked_error")"
[ "$(tmux show-options -t "$blocked_tag" -v @firstmate-home)" = "$FOREIGN_HOME" ] \
  || fail "real tmux: a refused ensure restamped the foreign-owned session"
[ "$(tmux show-options -t firstmate -v @firstmate-home)" = "$HOME_MAIN" ] \
  || fail "real tmux: a refused ensure restamped the basename session"
pass "real tmux: both candidates owned elsewhere still errors and stops, naming both owners and restamping neither"

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

cleanup_all
trap - EXIT
