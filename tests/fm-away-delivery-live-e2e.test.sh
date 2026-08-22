#!/usr/bin/env bash
# tests/fm-away-delivery-live-e2e.test.sh - the live away-delivery guard
# (live-harness-optin family; task fm-afk-zustellblockade-spinner-daempfung).
#
# The away-mode delivery path now rests on two claims that only a REAL harness
# and a REAL transport can settle, so per
# .agents/skills/firstmate-coding-guidelines they are proven here end to end. A
# stub can only confirm the assumption already written into the stub, and both
# assumptions are exactly the kind a vendor upgrade can invalidate silently.
#
#   CLAIM 1 (the delivery override, bin/fm-composer-lib.sh's
#   fm_composer_injection_verdict): an IDLE harness pane is byte-stable across
#   the stability window, and a WORKING one is not. The whole safety of letting
#   an affirmatively empty composer outrank a rendered busy signature rests on
#   the second half: if some harness ever renders a completely static screen
#   while mid-turn, the override would fire during a live turn. This guard
#   submits one short prompt per harness precisely to observe that, which is the
#   token spend the guidelines authorize for a harness-dependent check.
#
#   CLAIM 2 (the transport ceiling, bin/fm-tmux-lib.sh's
#   fm_tmux_send_text_max_bytes): the computed budget is genuinely accepted by
#   the installed tmux, and the installed tmux genuinely refuses an oversize
#   command. If a future tmux raises or removes the ceiling, the budget stays
#   safe but this guard says the premise moved; if a future tmux LOWERS it, the
#   budget is no longer safe and this guard fails loudly rather than letting the
#   away channel wedge again the way it did on 2026-08-21/22.
#
# Run explicitly with FM_AWAY_DELIVERY_LIVE=1. An absent harness is reported and
# skipped; a run that verified no harness fails rather than passing vacuously.
# Refresh docs/verification/runtime-backends.md ("Away-delivery guards") from
# this guard's output after any harness or tmux upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_AWAY_DELIVERY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AWAY_DELIVERY_LIVE=1 to run the live away-delivery guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "not ok - FM_AWAY_DELIVERY_LIVE=1 but tmux is not installed" >&2; exit 1; }

SOCKET="fm-awaydel-live-$$"
SESSION="awaydel"
HARNESS_CHECKED=0

# Calibrate the window the daemon ACTUALLY uses, never a copy of it: a guard that
# validates its own hardcoded number would keep passing while the shipped default
# drifted underneath it. The daemon skips its main loop when sourced.
FM_TEST_DAEMON_SOURCED=1
export FM_TEST_DAEMON_SOURCED
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
STABLE_SECS=${FM_INJECT_STABLE_SECS:-$INJECT_STABLE_SECS_DEFAULT}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT

SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-awaydel-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$ROOT"

harness_version() { "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'; }

# --- CLAIM 2: the transport ceiling -----------------------------------------
check_transport_ceiling() {
  local win="tx" target budget payload accepted_at refused_at probe
  tmux -L "$SOCKET" new-window -d -t "$SESSION" -n "$win" 'cat > /dev/null'
  target="$SESSION:$win"
  budget=$(fm_tmux_send_text_max_bytes "$target")
  [ "$budget" -gt 0 ] || fail "fm_tmux_send_text_max_bytes returned no budget for '$target'"

  # The computed budget must actually be accepted.
  payload=$(head -c "$budget" </dev/zero | tr '\0' a)
  tmux -L "$SOCKET" send-keys -t "$target" -l "$payload" 2>/dev/null \
    || fail "tmux $(tmux -V) REFUSED a payload of exactly the computed budget ($budget bytes) for target '$target'; the budget is unsafe and away-mode delivery can wedge"
  accepted_at=$budget

  # And the installed tmux must still have a ceiling at all, or the premise this
  # budget defends has moved and the reader must be told.
  probe=$(( FM_TMUX_SEND_IMSG_MAX * 4 ))
  payload=$(head -c "$probe" </dev/zero | tr '\0' a)
  if tmux -L "$SOCKET" send-keys -t "$target" -l "$payload" 2>/dev/null; then
    note "PREMISE MOVED: tmux $(tmux -V) accepted a ${probe}-byte command; the one-send ceiling this budget defends no longer applies on this version"
    refused_at="none"
  else
    refused_at="<= $probe"
  fi
  tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
  note "transport: tmux $(tmux -V) budget=$accepted_at accepted, refusal observed at $refused_at"
  pass "transport ceiling: the computed one-send budget is accepted by the installed tmux (tmux $(tmux -V), budget $accepted_at bytes)"
}

# --- CLAIM 1: idle is byte-stable, working is not ---------------------------
capture_win() { tmux -L "$SOCKET" capture-pane -p -t "$1" -S -40 2>/dev/null; }

wait_idle_composer() {  # <target> <budget-polls>
  local target=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_tmux_composer_state "$target")" = empty ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

check_harness() {  # <name> <launch-cmd...>
  local name=$1 win="ad-$1" target version a b i busy_seen=0 changed_seen=0 state
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION" -n "$win" -c "$ROOT" "$*"
  target="$SESSION:$win"

  if ! wait_idle_composer "$target" "${FM_AWAY_DELIVERY_LIVE_POLLS:-45}"; then
    state=$(fm_tmux_composer_state "$target")
    tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
    fail "$name ($version): never reached an idle empty composer (last verdict '$state'); the away-delivery override cannot be proven on this harness"
  fi

  # IDLE must SETTLE to byte-stable, or the override could never fire and every
  # escalation would sit behind residue exactly as it did during the incident.
  # A harness may still be painting its startup banner when its composer first
  # reads empty, so this waits for stability rather than demanding it at the
  # first instant; what it refuses to accept is an idle pane that never settles.
  i=0
  while [ "$i" -lt "${FM_AWAY_DELIVERY_LIVE_SETTLE_POLLS:-20}" ]; do
    i=$((i + 1))
    a=$(capture_win "$target")
    sleep "$STABLE_SECS"
    b=$(capture_win "$target")
    [ "$a" = "$b" ] && break
  done
  if [ "$a" != "$b" ]; then
    tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
    fail "$name ($version): an IDLE pane never became byte-stable across ${STABLE_SECS}s within $i attempts, so an escalation could never outrank finished-turn residue on this harness"
  fi
  note "$name ($version): idle settled to byte-stable after $i attempt(s)"
  [ "$(fm_composer_injection_verdict empty busy "$a" "$b")" = deliver ] \
    || fail "$name ($version): a byte-stable idle pane with an empty composer did not resolve to deliver"

  # WORKING must not stay byte-identical for longer than the stability window.
  # This is a CALIBRATION check, not an absolute one: the last frame of a turn is
  # legitimately static while the footer still advertises its interrupt key -
  # that is the residue the override exists to see through. What must not happen
  # is a harness going quiet MID-turn for longer than the window, so the guard
  # measures the longest byte-identical run observed while the pane reports busy
  # and requires the configured window to exceed it, naming the number to
  # configure when it does not.
  local prev='' run=0 longest=0
  tmux -L "$SOCKET" send-keys -t "$target" -l 'Count from 1 to 60, one number per line, nothing else.' 2>/dev/null || true
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
  i=0
  while [ "$i" -lt "${FM_AWAY_DELIVERY_LIVE_BUSY_POLLS:-90}" ]; do
    i=$((i + 1))
    a=$(capture_win "$target")
    if [ "$(fm_pane_busy_state "$target" "$name")" = busy ]; then
      busy_seen=$((busy_seen + 1))
      if [ -n "$prev" ] && [ "$a" = "$prev" ]; then
        run=$((run + 1))
        [ "$run" -gt "$longest" ] && longest=$run
      else
        run=0
        changed_seen=$((changed_seen + 1))
      fi
    elif [ "$busy_seen" -gt 0 ]; then
      break
    fi
    prev=$a
    sleep 1
  done
  tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true

  [ "$busy_seen" -gt 0 ] \
    || fail "$name ($version): never observed a busy window after submitting, so the mid-turn half of the override could not be checked; this guard refuses to report a pass it did not earn"
  if [ "$longest" -ge "${STABLE_SECS%%.*}" ] && [ "${STABLE_SECS%%.*}" -gt 0 ]; then
    fail "$name ($version): the screen stayed byte-identical for ${longest}s while the pane reported busy, which is at or above the ${STABLE_SECS}s stability window. Raise FM_INJECT_STABLE_SECS above ${longest} for this harness, or the away-mode override can fire mid-turn."
  fi
  note "$name ($version): $busy_seen busy samples, longest byte-identical run ${longest}s, window ${STABLE_SECS}s"
  pass "away-delivery override calibrated live on $name ($version): idle settles byte-stable, and the longest static stretch while busy (${longest}s) stays below the ${STABLE_SECS}s window"
  HARNESS_CHECKED=$((HARNESS_CHECKED + 1))
}

check_transport_ceiling

# Every verified primary harness this daemon can supervise. An absent binary is
# reported and skipped, never silently passed over.
if command -v claude >/dev/null 2>&1; then
  check_harness claude claude --dangerously-skip-permissions
else
  note "claude: not installed, skipped"
fi
if command -v codex >/dev/null 2>&1; then
  check_harness codex codex
else
  note "codex: not installed, skipped"
fi
if command -v opencode >/dev/null 2>&1; then
  check_harness opencode opencode
else
  note "opencode: not installed, skipped"
fi
if command -v grok >/dev/null 2>&1; then
  check_harness grok grok
else
  note "grok: not installed, skipped"
fi
if command -v kimi >/dev/null 2>&1; then
  check_harness kimi kimi
else
  note "kimi: not installed, skipped"
fi
if command -v cursor-agent >/dev/null 2>&1; then
  check_harness cursor cursor-agent
else
  note "cursor: not installed, skipped"
fi
if command -v pi >/dev/null 2>&1; then
  check_harness pi pi
else
  note "pi: not installed, skipped"
fi

[ "$HARNESS_CHECKED" -gt 0 ] \
  || fail "no verified harness was installed, so this guard checked no harness at all; install at least one before trusting the away-delivery override"
pass "live away-delivery guard verified $HARNESS_CHECKED installed harness(es) and the transport ceiling"
