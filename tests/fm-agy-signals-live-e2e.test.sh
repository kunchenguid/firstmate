#!/usr/bin/env bash
# Live drift guard for the Antigravity CLI adapter's vendor-controlled surface:
# process name, trust dialog, rendered busy/interrupt/exit behavior.
# Opt-in because it submits real prompts (no echo provider exists for agy).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
LAB=
SESSION="fm-lab-agy-signals-$$"
TARGET=

cleanup() {
  if declare -F herdr_safe_stop_and_delete >/dev/null 2>&1; then
    herdr_safe_stop_and_delete "$SESSION"
  fi
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  trap - EXIT
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE agy herdr jq
[ -n "$AGY_BIN" ] || fail "agy is not installed"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
export HERDR_SESSION="$SESSION"
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr session"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated agy workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated agy workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated agy workspace"

# The worker runs under a throwaway HOME holding a copy of ~/.gemini (the
# method recorded in docs/verification/agy.md), so its trust answer and every
# other agy write land in the lab store, never the operator's real one.
AGY_HOME="$LAB/home"
mkdir -p "$AGY_HOME" || fail "could not create the throwaway agy HOME"
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini to stage for the throwaway agy HOME"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr backend"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WORKSPACE") \
  || fail "could not create the isolated Herdr workspace"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-agy-signals" "$WORKSPACE" "$SEEDED_TAB_ID") \
  || fail "could not create the isolated agy pane"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "Herdr did not return the agy pane identity"
TARGET="$SESSION:$PANE_ID"

FM_TEST_HOME="$LAB/firstmate-home"
mkdir -p "$FM_TEST_HOME/state" "$FM_TEST_HOME/data/agy-signals"
cat > "$FM_TEST_HOME/state/agy-signals.meta" <<EOF
window=$TARGET
endpoint_task_id=agy-signals
worktree=$WORKSPACE
project=$WORKSPACE
harness=agy
kind=scout
mode=no-mistakes
yolo=off
model=gemini-3.8-flash-low
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF

capture() {
  fm_backend_capture herdr "$TARGET" 100 2>/dev/null || true
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo (including across
# terminal-wrapped rows). It also asks the real worker to publish its durable
# completion event, letting this guard exercise the public crew-state read.
STATUS_FILE="$FM_TEST_HOME/state/agy-signals.status"
printf -v LAUNCH 'HOME=%q %q --prompt-interactive %q --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions' \
  "$AGY_HOME" "$AGY_BIN" "Using a shell command, append exactly 'done: live completion probe' to $STATUS_FILE, then add 12345 and 67890. Reply with exactly the sum and nothing else"
fm_backend_herdr_send_literal "$TARGET" "$LAUNCH" \
  || fail "could not type the agy launch line"
fm_backend_herdr_send_key "$TARGET" Enter \
  || fail "could not submit the agy launch line"

# A fresh workspace stops on the folder-trust dialog. Answer the preselected
# safe choice once it renders. The answer appends the workspace to
# trustedWorkspaces in the throwaway HOME's copy of the agy settings store.
screen=
for _ in $(seq 1 150); do
  screen=$(capture)
  case "$screen" in
    *"Do you trust the contents of this project?"*|*80235*|*80,235*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Do you trust the contents of this project?"*)
    fm_backend_herdr_send_key "$TARGET" Enter \
      || fail "could not answer the agy trust dialog"
    ;;
esac

# The initial turn executes and its reply lands; the busy footer must render
# while it is in flight so the portable matcher has live text to prove.
# Trivial turns were observed taking one to two minutes (cold start plus model
# latency), so these windows are generous; the guard is opt-in.
busy_live=
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_agy_tail_busy; then busy_live=1; break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "fm_busy_agy_tail_busy never matched the real agy turn in flight"
pass "the real agy busy footer matches fm_busy_agy_tail_busy in flight"

for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
reply=$(capture)
case "$reply" in
  *80235*|*80,235*) pass "the real agy worker processed its launch prompt" ;;
  *) fail "the real agy worker never answered its launch prompt" ;;
esac
# The reply can render while the turn is still finishing: the busy footer stays
# pinned until the idle composer replaces it, so wait for the settled idle row
# before asserting what the settled pane must not match. The wait itself
# refreshes $screen: the reply-wait loop above can legitimately break on a
# frame that still carries the pinned busy footer, and asserting on that stale
# frame would fail every run whose reply lands mid-turn.
idle_settled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"? for shortcuts"*) idle_settled=1; break ;; esac
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the agy composer never settled to its idle footer after the reply"
# Scope to the visible tail the same way the owners do: mid-turn busy rows stay
# in scrollback after the turn settles and must not count as still busy.
printf '%s' "$screen" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match agy \
  && fail "harness=agy matched its own idle footer as busy" || true
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  && fail "the settled agy footer still matches the busy signature" || true

grep -Fx 'done: live completion probe' "$STATUS_FILE" >/dev/null 2>&1 \
  || fail "the real agy worker did not publish its completion event"
CREW_OUT=
for _ in $(seq 1 120); do
  CREW_OUT=$(FM_HOME="$FM_TEST_HOME" HERDR_SESSION="$SESSION" \
    "$ROOT/bin/fm-crew-state.sh" agy-signals 2>&1) \
    || fail "fm-crew-state could not read the completed real agy worker: $CREW_OUT"
  case "$CREW_OUT" in
    *"state: done"*"source: status-log"*"live completion probe"*) break ;;
  esac
  sleep 0.5
done
case "$CREW_OUT" in
  *"state: done"*"source: status-log"*"live completion probe"*) ;;
  *) fail "fm-crew-state did not report the real agy completion: $CREW_OUT" ;;
esac
printf 'fm-crew-state after real agy completion:\n%s\n' "$CREW_OUT"
pass "fm-crew-state reports the real idle agy worker's durable completion"

# The dialog can outlive the turn it gated, so a still-rendered dialog must be
# dismissed before steering anything: typed text would land in it instead of
# the composer.
if case "$(capture)" in *"Do you trust the contents of this project?"*) true ;; *) false ;; esac; then
  fm_backend_herdr_send_key "$TARGET" Enter \
    || fail "could not dismiss the residual agy trust dialog"
  idle=
  for _ in $(seq 1 120); do
    case "$(capture)" in *"? for shortcuts"*) idle=1; break ;; esac
    sleep 0.5
  done
  [ -n "$idle" ] || fail "the agy composer never went idle after the trust answer"
fi

# Interrupt a genuinely long turn: poll until busy is observed, then send
# exactly one Escape and wait only for the Interrupted row it prints; a busy
# footer that merely disappears is not cancellation and no further Escape is
# sent, so a turn that survives one Escape fails this guard.
fm_backend_herdr_send_literal "$TARGET" "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long agy prompt"
fm_backend_herdr_send_key "$TARGET" Enter \
  || fail "could not submit the long agy prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_agy_tail_busy && break
  sleep 0.5
done
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  || fail "the long agy turn never showed its busy footer"
fm_backend_herdr_send_key "$TARGET" Escape \
  || fail "could not send Escape to the real agy turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *Interrupted*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real agy turn"
printf 'agy rendered cancellation:\n%s\n' "$(printf '%s\n' "$screen" | grep 'Interrupted' | tail -1)"
pass "a single Escape cancels the real agy turn"

CONTROL_OUT=$(FM_HOME="$FM_TEST_HOME" HERDR_SESSION="$SESSION" \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 FM_CONTROL_EXIT_RETRIES=3 \
  "$ROOT/bin/fm-control.sh" agy-signals exit 2>&1) \
  || fail "fm-control exit did not stop the real agy process: $CONTROL_OUT"
case "$CONTROL_OUT" in
  "stopped agy-signals"*) ;;
  *) fail "fm-control exit returned an unexpected result: $CONTROL_OUT" ;;
esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] \
  || fail "fm-control exit returned before the real agy process terminated"
printf 'fm-control exit output:\n%s\n' "$CONTROL_OUT"
pass "fm-control /exit retry stops the real agy process"

cleanup
trap - EXIT
