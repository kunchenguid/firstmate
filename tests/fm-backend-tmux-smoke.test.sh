#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
#
# The final section extends that to fm_backend_tmux_container_ensure's
# server-BIRTH environment, which only a real server can show: it reproduces
# the color-control leak as a control, then proves the adapter's own birth is
# clean (docs/verification/runtime-backends.md, "Server birth environment").
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
# The launch-environment section below births its own servers on their own
# private sockets, so they are tracked and torn down here too.
EXTRA_SOCKETS=
EXTRA_DIR=
trap cleanup_all EXIT

cleanup_all() {
  local extra
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  for extra in ${EXTRA_SOCKETS:-}; do
    "$REAL_TMUX" -L "$extra" kill-server >/dev/null 2>&1 || true
  done
  [ -n "${EXTRA_DIR:-}" ] && rm -rf "$EXTRA_DIR"
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
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
OTHER_SESSION="smoke-other"
PREFIX_SESSION="smoke-prefix-live"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
tmux new-session -d -s "$OTHER_SESSION" -x 200 -y 50 \
  || fail "real tmux: second new-session failed"
tmux new-session -d -s "$PREFIX_SESSION" -n "$WINDOW" -x 200 -y 50 \
  || fail "real tmux: prefix-sharing session failed"
tmux new-session -d -s firstmate -n supervisor -x 200 -y 50 \
  || fail "real tmux: default supervisor session failed"
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

# --- target_exists requires exact window and pane membership ----------------

fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists should report the existing window present"
pass "real tmux: fm_backend_target_exists finds an existing window"

LIVE_PANE=$(tmux display-message -p -t "$TARGET" '#{pane_id}') \
  || fail "could not read the existing pane id"
fm_backend_target_exists tmux "$LIVE_PANE" \
  || fail "fm_backend_target_exists should report the existing pane present"
pass "real tmux: fm_backend_target_exists finds an existing pane"

LIVE_WINDOW_ID=$(tmux display-message -p -t "$TARGET" '#{window_id}') \
  || fail "could not read the existing window id"
LIVE_WINDOW_INDEX=$(tmux display-message -p -t "$TARGET" '#{window_index}') \
  || fail "could not read the existing window index"
LIVE_PANE_INDEX=$(tmux display-message -p -t "$TARGET" '#{pane_index}') \
  || fail "could not read the existing pane index"

for exact_target in "$LIVE_WINDOW_ID" "$SESSION:$LIVE_WINDOW_ID"; do
  fm_backend_target_exists tmux "$exact_target" \
    || fail "fm_backend_target_exists rejected live window-id target $exact_target"
done
pass "real tmux: fm_backend_target_exists accepts bare and session-scoped window ids"

for indexed_target in "$SESSION:$LIVE_WINDOW_INDEX" firstmate:0; do
  fm_backend_target_exists tmux "$indexed_target" \
    || fail "fm_backend_target_exists rejected live window-index target $indexed_target"
done
pass "real tmux: fm_backend_target_exists accepts window indexes including firstmate:0"

fm_backend_target_exists tmux "$SESSION:$LIVE_WINDOW_INDEX.$LIVE_PANE_INDEX" \
  || fail "fm_backend_target_exists rejected live index.pane target"
pass "real tmux: fm_backend_target_exists accepts index.pane targets"

for exact_target in "$SESSION" "=$SESSION:=$WINDOW"; do
  fm_backend_target_exists tmux "$exact_target" \
    || fail "fm_backend_target_exists rejected exact target $exact_target"
done
pass "real tmux: fm_backend_target_exists accepts a bare session and explicit exact markers"

if fm_backend_target_exists tmux "smoke-prefix:$WINDOW"; then
  fail "fm_backend_target_exists prefix-matched a missing session"
fi
pass "real tmux: fm_backend_target_exists anchors the session name"

for malformed_target in '' : "$SESSION:" ":$WINDOW" "$SESSION:$WINDOW:extra"; do
  if fm_backend_target_exists tmux "$malformed_target"; then
    fail "fm_backend_target_exists accepted malformed target '$malformed_target'"
  fi
done
pass "real tmux: fm_backend_target_exists rejects malformed targets"

# A gone name that prefixes a live neighbor is the dangerous send-keys case:
# tmux itself would fall through to the neighbor, so the adapter must stop first.
tmux new-window -d -t "$SESSION:" -n fm-t10 \
  || fail "real tmux: prefix-neighbor window failed"
tmux new-window -d -t "$SESSION:" -n fm-t1 \
  || fail "real tmux: gone-prefix window failed"
tmux kill-window -t "=$SESSION:=fm-t1" \
  || fail "real tmux: could not remove the gone-prefix window"
tmux send-keys -t "$SESSION:fm-t10" \
  "bash -c 'printf \"prefix-neighbor-ready\\n\"; read -r -n 1 key; printf \"%s\" \"\$key\" > \"$SHIM_DIR/key-capture\"'" Enter
wait_for_capture_text "$SESSION:fm-t10" prefix-neighbor-ready \
  || fail "real tmux: prefix-neighbor reader did not become ready"
if fm_backend_tmux_send_key "$SESSION:fm-t1" X; then
  fail "fm_backend_tmux_send_key accepted a gone prefix target"
fi
sleep 0.1
[ ! -e "$SHIM_DIR/key-capture" ] \
  || fail "fm_backend_tmux_send_key delivered a key to the prefix neighbor"
pass "real tmux: fm_backend_tmux_send_key withholds a key from a gone prefix target"

# A gone dotted task window must not resolve as a pane of its undotted neighbor.
tmux new-window -d -t "$SESSION:" -n fm-v1 \
  || fail "real tmux: undotted neighbor window failed"
DOTTED_WINDOW_ID=$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION:" -n fm-v1.0) \
  || fail "real tmux: dotted window failed"
tmux kill-window -t "$DOTTED_WINDOW_ID" \
  || fail "real tmux: could not remove the dotted window"
if fm_backend_target_exists tmux "$SESSION:fm-v1.0"; then
  fail "fm_backend_target_exists reported a gone dotted window present beside fm-v1"
fi
if fm_backend_tmux_send_key "$SESSION:fm-v1.0" X; then
  fail "fm_backend_tmux_send_key accepted a gone dotted target"
fi
pass "real tmux: a gone dotted window reads absent beside its undotted neighbor"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
if fm_backend_target_exists tmux "$TARGET"; then
  fail "fm_backend_target_exists still reports the killed window present"
fi
pass "real tmux: fm_backend_target_exists rejects a killed window while another session stays alive"

if fm_backend_target_exists tmux "smoke-missing:$WINDOW"; then
  fail "fm_backend_target_exists reports a window in a missing session present"
fi
tmux has-session -t "$OTHER_SESSION" \
  || fail "the second session should remain alive while missing-session membership is checked"
pass "real tmux: fm_backend_target_exists rejects a missing session while another session stays alive"

# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- container resolution under a grouped session ---------------------------

# An external client attached through a grouped session (`new-session -t`) is
# the most recently used member of the group; the container must still be the
# session of firstmate's own pane.
OWN_SID=$(tmux display-message -p -t "$SESSION" '#{session_id}')
OWN_SID=${OWN_SID#\$}
tmux new-session -d -s smoke-viewer -t "$SESSION" \
  || fail "real tmux: grouped viewer session failed"
tmux select-window -t smoke-viewer:0 >/dev/null 2>&1 || true
got=$(TMUX="/fake,0,$OWN_SID" fm_backend_tmux_container_ensure)
[ "$got" = "$SESSION" ] \
  || fail "container_ensure chose '$got' instead of the pane's own session '$SESSION' beside a grouped session"
pass "real tmux: container_ensure names the pane's own session, not a more recent grouped session"

# A pane opened from the viewer's session keeps the viewer's id in $TMUX after
# the viewer closes; tmux answers that stale id with empty output and exit 0,
# so the container must come from the pane's surviving session instead.
VIEWER_SID=$(tmux display-message -p -t smoke-viewer '#{session_id}')
VIEWER_SID=${VIEWER_SID#\$}
OWN_PANE=$(tmux display-message -p -t "$SESSION:0" '#{pane_id}')
tmux kill-session -t smoke-viewer || fail "real tmux: killing the grouped viewer session failed"
got=$(TMUX="/fake,0,$VIEWER_SID" TMUX_PANE="$OWN_PANE" fm_backend_tmux_container_ensure)
[ "$got" = "$SESSION" ] \
  || fail "container_ensure chose '$got' instead of the pane's surviving session '$SESSION' for a stale \$TMUX session id"
pass "real tmux: container_ensure falls back to the pane's surviving session when the \$TMUX session id is stale"

# --- container_ensure's server-birth launch environment ---------------------
#
# A secondmate or agent can launch firstmate under NO_COLOR=1. Outside tmux
# with no server running, fm_backend_tmux_container_ensure's `new-session`
# BIRTHS the server, which hands its startup environment to every window
# created afterwards, and NO_COLOR is not in tmux's default
# `update-environment` set, so a later client attach cannot repair it.
#
# The control half proves that inheritance is real before the fixed half
# claims to have blocked it. Both use their own private sockets, because the
# section above already birthed this file's main server.

EXTRA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-env.XXXXXX")

# The launcher environment an agent-started firstmate can carry, plus one
# unrelated variable that must survive any scrub.
pollute_color_env() {
  unset TMUX
  export NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_TMUX_LAUNCH_SENTINEL=kept
}

# A `tmux` shim bound to <socket>, so bin/backends/tmux.sh's bare `tmux ...`
# calls reach that private server rather than this file's or the host's.
# Each caller registers its socket in EXTRA_SOCKETS itself, because this
# function is used in command substitution and an assignment here would die
# with that subshell, leaving the server it births alive after cleanup.
make_socket_shim() {  # <socket> -> prints the shim dir
  local sock=$1 dir="$EXTRA_DIR/shim-$1"
  mkdir -p "$dir"
  cat > "$dir/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$sock" "\$@"
SH
  chmod +x "$dir/tmux"
  printf '%s' "$dir"
}

# The real environment of a window created on <socket>'s server - the same
# inheritance every crew window gets.
birthed_window_env() {  # <socket> -> prints that window's environment
  local sock=$1 out="$EXTRA_DIR/env-$1.txt" i=0
  # Drop any previous probe's output for this socket first: otherwise a second
  # probe can read the stale file before the new window truncates it and prove
  # nothing about the window it just created.
  rm -f "$out"
  "$REAL_TMUX" -L "$sock" new-window -d -t firstmate: "env > '$out'" \
    || fail "could not create the environment probe window on socket $sock"
  while [ "$i" -lt 100 ]; do
    [ -s "$out" ] && { cat "$out"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  fail "the environment probe window on socket $sock never reported"
}

CONTROL_SOCKET="fm-backend-smoke-control-$$"
EXTRA_SOCKETS="$EXTRA_SOCKETS ${CONTROL_SOCKET}"
control_shim=$(make_socket_shim "$CONTROL_SOCKET")
(
  pollute_color_env
  # shellcheck disable=SC2030,SC2031  # scoping the shim to this subshell is the point
  export PATH="$control_shim:$PATH"
  tmux new-session -d -s firstmate
) || fail "control: could not birth a tmux server under the polluted environment"
control_env=$(birthed_window_env "$CONTROL_SOCKET")
case "$control_env" in
  *NO_COLOR=1*) : ;;
  *) fail "control: this tmux does not propagate NO_COLOR from the birth environment, so the assertions below prove nothing" ;;
esac
pass "real tmux: an unscrubbed server birth really does hand NO_COLOR to every later window"

FIXED_SOCKET="fm-backend-smoke-fixed-$$"
EXTRA_SOCKETS="$EXTRA_SOCKETS ${FIXED_SOCKET}"
fixed_shim=$(make_socket_shim "$FIXED_SOCKET")
ensured=$(
  pollute_color_env
  # shellcheck disable=SC2030,SC2031  # scoping the shim to this subshell is the point
  export PATH="$fixed_shim:$PATH"
  fm_backend_tmux_container_ensure
) || fail "fm_backend_tmux_container_ensure failed under a color-polluted launcher environment"
[ "$ensured" = firstmate ] || fail "container_ensure should echo 'firstmate', got '$ensured'"

fixed_env=$(birthed_window_env "$FIXED_SOCKET")
for name in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
  case "$fixed_env" in
    *"$name"=*) fail "container_ensure leaked $name into the long-lived tmux server it birthed" ;;
  esac
done
case "$fixed_env" in
  *FM_TMUX_LAUNCH_SENTINEL=kept*) : ;;
  *) fail "container_ensure removed an unrelated launch environment variable" ;;
esac
pass "real tmux: fm_backend_tmux_container_ensure scrubs color control from the server it births, leaving unrelated launch environment intact"

# Reuse is only reuse if it is the SAME server under the SAME scrubbed
# environment: a restart (defeating this PR's scrub state) or a color variable
# leaking into the windows the server hands out afterwards would still echo
# 'firstmate'. Record the server pid before the second call so a restart is
# visible, then probe a fresh window's environment exactly like the first-birth
# loop above.
server_pid_before=$("$REAL_TMUX" -L "$FIXED_SOCKET" display-message -p '#{pid}') \
  || fail "could not read the tmux server pid on socket $FIXED_SOCKET before the reuse call"
reused=$(
  pollute_color_env
  # shellcheck disable=SC2030,SC2031  # scoping the shim to this subshell is the point
  export PATH="$fixed_shim:$PATH"
  fm_backend_tmux_container_ensure
) || fail "a second container_ensure against the existing session failed"
[ "$reused" = firstmate ] || fail "the reuse path should echo 'firstmate', got '$reused'"
server_pid_after=$("$REAL_TMUX" -L "$FIXED_SOCKET" display-message -p '#{pid}') \
  || fail "could not read the tmux server pid on socket $FIXED_SOCKET after the reuse call"
[ "$server_pid_after" = "$server_pid_before" ] \
  || fail "the reuse call restarted the tmux server (pid $server_pid_before -> $server_pid_after)"
pass "real tmux: a second container_ensure reuses the existing session instead of birthing another server"

reused_env=$(birthed_window_env "$FIXED_SOCKET")
for name in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
  case "$reused_env" in
    *"$name"=*) fail "the reuse path let $name into the environment inherited by later windows" ;;
  esac
done
pass "real tmux: the reuse path leaves the scrubbed server environment clean for windows born after it"

cleanup_all
for sock in "$CONTROL_SOCKET" "$FIXED_SOCKET"; do
  if "$REAL_TMUX" -L "$sock" list-sessions >/dev/null 2>&1; then
    fail "cleanup left the tmux server on socket $sock running"
  fi
done
pass "real tmux: cleanup kills every private server this test births"
trap - EXIT
