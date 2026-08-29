#!/usr/bin/env bash
# GATE h7 - a LIVE pre-cutover pane can still be read, steered and closed.
#
# WHAT THIS GATE USED TO SAY, AND WHY IT CHANGED. It exercised a live tmux pane
# through the multiplexer seam, to prove the tmux DRIVER worked end to end. That
# driver is gone: herdr is the only surface and nothing spawns onto tmux any
# more. Left as written, the gate would keep passing while proving something the
# fleet no longer does.
#
# WHAT IT PROVES NOW is the constraint the cutover was not allowed to break.
# Crewmates spawned before the cutover are still running in real tmux windows,
# some carrying unlanded commits. Until they are torn down, firstmate must be
# able to:
#     READ  them  - or the watcher is blind to a live crewmate
#     STEER them  - or a supervisor can watch work go wrong and not correct it
#     CLOSE them  - or teardown strands the work it cannot clean up
#
# Losing any one of those is a self-inflicted outage, so this drives all three
# against a REAL tmux window through the REAL fm-peek.sh and fm-send.sh - not
# through a fake, and not through the library in isolation. It creates and
# destroys its own throwaway session; it never touches the fleet's.
set -u

# This gate needs the REAL binaries; tests/lib.sh otherwise shims both away so
# no suite can touch the captain's live servers by accident. The tmux opt-out is
# the narrow one it sounds like: every tmux verb below is scoped to the
# throwaway session this file creates and kills ($SES, below), never the fleet's
# - which is the whole reason a stray tmux call is denied by default.
FM_TEST_ALLOW_LIVE_HERDR=1
FM_TEST_ALLOW_LIVE_TMUX=1

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

if ! command -v tmux >/dev/null 2>&1; then
  printf 'not ok - GATE h7 cannot run: tmux is not installed\n' >&2
  printf '  the drain path must be proven against a REAL pane; a skip here is a gap\n' >&2
  exit 1
fi

PEEK="$ROOT/bin/fm-peek.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-h7)
SES="fmh7-$$"
# The guard shim only lets a kill through against the session declared here.
FM_TEST_LIVE_TMUX_SESSION="$SES"; export FM_TEST_LIVE_TMUX_SESSION
WORKDIR="$TMP_ROOT/work"; mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd -P)
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/state"

cleanup() {
  tmux kill-session -t "$SES" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

tmux new-session -d -s "$SES" -c "$WORKDIR" 2>/dev/null \
  || fail "could not start a throwaway tmux session"
tmux new-window -d -t "$SES:" -n fm-drainer -c "$WORKDIR" 2>/dev/null \
  || fail "could not create a throwaway tmux window"

# A pre-cutover meta, in the exact shape the live ones have: a tmux window and
# no mux= line, because the seam that would have written one did not exist when
# these crewmates were spawned.
cat > "$HOME_DIR/state/drainer.meta" <<META
window=$SES:fm-drainer
worktree=$WORKDIR
project=$WORKDIR
harness=claude
kind=ship
META

# FM_COMPOSER_IDLE_RE is the documented per-harness knob for "what an idle
# composer looks like" (bin/fm-tmux-lib.sh). This fixture's pane holds a bare
# SHELL rather than an agent TUI, and a shell prompt ends in % or $ - without
# telling the detector that, it reads an idle prompt as unsubmitted text and
# fm-send reports a swallowed Enter for a line that actually landed. Setting it
# here is exactly what the knob exists for; it changes no production behaviour.
run() {  # <script> <args...>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SEND_SETTLE=0 FM_COMPOSER_IDLE_RE='[%$#]$' "$@" 2>&1
}

# --- READ: the watcher must not go blind ------------------------------------

test_live_drain_pane_is_readable_through_fm_peek() {
  local marker out waited
  marker="h7drain$$"
  tmux send-keys -t "$SES:fm-drainer" "printf '%s\\n' $marker-read" Enter
  out=""; waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    out=$(run "$PEEK" fm-drainer 40)
    case "$out" in *"$marker-read"*) break ;; esac
    sleep 0.25
  done
  assert_contains "$out" "$marker-read" \
    "fm-peek could not read a live pre-cutover tmux pane; the watcher would be blind to it"
  pass "drain: a live pre-cutover pane is readable through the real fm-peek.sh"
}

# The resolution must come from the META, not from the target's shape by luck.
# A pre-cutover meta names a tmux window and carries no mux= line; that is what
# routes it, and it is what a future edit could silently break.
test_the_drain_route_comes_from_the_meta() {
  fm_herdr_resolve fm-drainer "$HOME_DIR/state" || fail "the drain meta would not resolve"
  assert_eq "$FM_HERDR_DRAIN" "1" "a live pre-cutover meta was not routed to the drain"
  assert_eq "$FM_HERDR_TARGET" "$SES:fm-drainer" "the drain target was lost"
  pass "drain: the route is read from the meta, not guessed from the target"
}

# --- STEER: a supervisor must be able to correct, not only watch -------------

test_live_drain_pane_is_steerable_through_fm_send() {
  local marker out waited rc=0
  marker="h7steer$$"
  # A real submit into a real shell, through the real fm-send: the text is typed
  # and the Enter verified, exactly as before the cutover.
  run "$SEND" fm-drainer "printf '%s\\n' $marker-steered" >/dev/null || rc=$?
  expect_code 0 "$rc" "fm-send failed against a live pre-cutover pane"
  out=""; waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    out=$(run "$PEEK" fm-drainer 40)
    case "$out" in *"$marker-steered"*) break ;; esac
    sleep 0.25
  done
  assert_contains "$out" "$marker-steered" \
    "fm-send did not land in a live pre-cutover pane; a draining crewmate would be uncorrectable"
  pass "drain: a live pre-cutover pane is steerable through the real fm-send.sh"
}

test_live_drain_pane_takes_a_control_key() {
  local rc=0
  tmux send-keys -t "$SES:fm-drainer" "sleep 30" Enter
  sleep 1
  run "$SEND" fm-drainer --key C-c >/dev/null || rc=$?
  expect_code 0 "$rc" "fm-send --key failed against a live pre-cutover pane"
  if ! fm_tmux_wait_shell_ready "$SES:fm-drainer" 15 2>/dev/null; then
    # fm-tmux-lib may not be sourced here; fall back to a direct probe.
    tmux send-keys -t "$SES:fm-drainer" "printf 'h7ready\\n'" Enter
    sleep 1
    tmux capture-pane -p -t "$SES:fm-drainer" | grep -qx h7ready \
      || fail "C-c did not return the real shell to a prompt"
  fi
  pass "drain: a control key reaches a live pre-cutover pane and the shell acts on it"
}

# --- CLOSE: teardown must be able to clean up --------------------------------

# Deliberately NOT migrated onto the herdr surface, which is exactly what keeps
# it working for the drain. Proven against the real window rather than assumed.
test_live_drain_pane_is_closable() {
  local waited gone=0
  tmux kill-window -t "$SES:fm-drainer" 2>/dev/null
  waited=0
  while [ "$waited" -lt 20 ]; do
    waited=$((waited + 1))
    if ! tmux list-windows -t "$SES" -F '#{window_name}' 2>/dev/null | grep -qx fm-drainer; then
      gone=1; break
    fi
    sleep 0.25
  done
  [ "$gone" = 1 ] || fail "the live pre-cutover window could not be closed; teardown would strand it"
  pass "drain: a live pre-cutover window can still be closed"
}

test_live_drain_pane_is_readable_through_fm_peek
test_the_drain_route_comes_from_the_meta
test_live_drain_pane_is_steerable_through_fm_send
test_live_drain_pane_takes_a_control_key
test_live_drain_pane_is_closable
