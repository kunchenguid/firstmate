#!/usr/bin/env bash
# tests/fm-idle-compact-live-e2e.test.sh - live-harness-optin guard for the
# idle-compact eligibility gate's vendor-rendered-signal surface (task
# fm-idle-compact; live-harness-optin family): does a REAL, idle Claude Code
# pane read busy=idle + composer=empty through the exact primitives
# fm_idle_compact_safe_to_send composes (bin/fm-busy-lib.sh's
# fm_busy_classify, bin/fm-backend.sh's fm_backend_composer_state), and does a
# real pending (unsubmitted) composer correctly block the send. This guard
# runs the FULL fm_idle_compact_tick orchestration (state machine, markers)
# against that real pane, so the eligibility/state-machine wiring is proven
# together with the vendor-facing read.
#
# Only fm_idle_compact_send and bin/fm-crew-state.sh are stubbed: no message
# is ever actually submitted to the live claude process (its own delivery
# mechanics are separately owned and proven by tests/fm-send-settle.test.sh
# and tests/fm-send-popup-settle.test.sh) and crew-state's own reconciliation
# contract is separately owned and tested by tests/fm-crew-state.test.sh. No
# prompt is ever submitted to claude, so no model tokens are spent.
#
# Run explicitly with FM_IDLE_COMPACT_LIVE=1. An absent claude or tmux fails
# loudly rather than passing vacuously. Refresh
# docs/verification/runtime-backends.md ("Idle-worker pre-compaction") from
# this guard's output after any Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_IDLE_COMPACT_LIVE tmux claude

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1) || CLAUDE_VERSION='version-unknown'
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION='version-unknown'

SOCKET="fm-idlec-live-$$"
SESSION="idlec"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-compact-live.XXXXXX")

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

STATE="$LAB/state"; CONFIG="$LAB/config"; DATA="$LAB/data"
mkdir -p "$STATE" "$CONFIG" "$DATA"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n hx -c "$ROOT" -- claude \
  || fail "claude ($CLAUDE_VERSION): could not launch in the isolated tmux server"
WIN="$SESSION:hx"

# The library under test's bare `tmux` calls stay isolated from any live
# fleet, the same PATH-shim idiom tests/fm-composer-matrix-live-e2e.test.sh
# uses.
SHIM_DIR="$LAB/fakebin"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# Wait for the real Claude Code composer to settle idle+empty, dismissing one
# benign startup modal if it appears - never Escape a trust prompt (that
# would exit the harness and erase the actionable failure surface).
budget=${FM_IDLE_COMPACT_LIVE_POLLS:-45}
i=0
dismissed=0
verdict=''
while [ "$i" -lt "$budget" ]; do
  verdict=$(fm_tmux_composer_state "$WIN")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$WIN" 2>/dev/null || true)
    if ! printf '%s\n' "$screen" | grep -qi trust; then
      tmux -L "$SOCKET" send-keys -t "$WIN" Escape 2>/dev/null || true
    fi
    dismissed=1
  fi
  sleep 1
done
if [ "$verdict" != empty ]; then
  printf '# claude pane tail at failure:\n' >&2
  tmux -L "$SOCKET" capture-pane -p -t "$WIN" 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "claude ($CLAUDE_VERSION): idle composer never classified empty - cannot run the idle-compact live guard"
fi

# --- fixture: one ship task pointed at the real idle pane -------------------

TASK=t1
printf 'window=%s\nbackend=tmux\nharness=claude\nkind=ship\n' "$WIN" > "$STATE/$TASK.meta"
printf 'done: fixture\n' > "$STATE/$TASK.status"
# Far in the past: any real threshold clears. The spawn record is aged with the
# status log because the idle-duration basis is the newest of meta/status/
# turn-ended, and in production fm-spawn.sh writes the meta once, at spawn,
# always before the crew's own status appends.
touch -d '@1' "$STATE/$TASK.status" "$STATE/$TASK.meta"
printf '1\n' > "$CONFIG/idle-compact"  # 1-minute threshold

# fm-crew-state.sh's own reconciliation contract is separately owned and
# tested (tests/fm-crew-state.test.sh); this guard only needs a fixed "genuine
# long wait" verdict so it can focus on idle-compact's own vendor-facing read.
CREW_STATE_STUB="$LAB/fake-crew-state.sh"
cat > "$CREW_STATE_STUB" <<'SH'
#!/usr/bin/env bash
printf 'state: parked \xc2\xb7 source: fixture \xc2\xb7 live-guard fixture\n'
SH
chmod +x "$CREW_STATE_STUB"

# The semantic busy-state contract (bin/fm-busy-lib.sh) is a structured record
# (gen/seq sidecar files) armed and applied by bin/fm-busy-event.sh, not
# derived from pane content - a raw claude process launched directly in tmux
# (as above) never arms it. Its own write/read contract is separately owned
# and tested (tests/fm-busy-state.test.sh); this guard drives it through the
# same real script so fm_busy_classify's READ is genuinely exercised, while
# the composer-state READ below stays fully live against the real pane.
# arm alone seeds "busy fm-spawn" (the launch prompt IS a submitted turn) -
# the real lifecycle shape a fresh spawn starts in.
BUSY_EV="$ROOT/bin/fm-busy-event.sh"
BUSY_GEN=$("$BUSY_EV" arm "$STATE" "$TASK") \
  || fail "claude ($CLAUDE_VERSION): could not arm the busy-state contract for the fixture task"

SENDLOG="$LAB/sends.log"
: > "$SENDLOG"

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$LAB"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$DATA"
export FM_CREW_STATE_BIN="$CREW_STATE_STUB"
# This guard calls fm_idle_compact_tick repeatedly, seconds apart, to observe
# each phase transition live - the real FM_IDLE_COMPACT_INTERVAL sweep-due
# gate (default 300s) would otherwise no-op every call after the first.
export FM_IDLE_COMPACT_INTERVAL=0

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

# The ONLY stub: recording instead of really submitting, so no model turn is
# ever triggered and no tokens are spent.
# shellcheck disable=SC2317  # invoked indirectly by fm_idle_compact_process_task
fm_idle_compact_send() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SENDLOG"
  return 0
}

sent_task() { cut -f2 "$SENDLOG" | tail -1; }
sent_message() { cut -f3 "$SENDLOG" | tail -1; }
MARKER=$(fm_idle_compact_marker_path "$STATE" "$TASK")

# --- 1. a real busy-state record (freshly armed: "busy fm-spawn") blocks the
#        send even though the composer itself reads empty --------------------

fm_idle_compact_tick "$STATE" "$CONFIG"
if [ -s "$SENDLOG" ]; then
  fail "claude ($CLAUDE_VERSION): a freshly armed (busy) real busy-state record must block the send"
elif [ -e "$MARKER" ]; then
  fail "claude ($CLAUDE_VERSION): a busy task must never get a marker"
else
  pass "claude ($CLAUDE_VERSION): a real busy-state record correctly blocks the send through fm_busy_classify, even with a genuinely empty composer"
fi

# --- 2. flipping the real busy-state record to idle (the Stop-hook shape)
#        unblocks the send: first sweep reaches phase=save-sent -------------

"$BUSY_EV" apply "$STATE" "$TASK" idle --gen "$BUSY_GEN" --source claude-hook --event stop \
  || fail "claude ($CLAUDE_VERSION): could not apply the idle busy-state event for the fixture task"

fm_idle_compact_tick "$STATE" "$CONFIG"
if [ ! -f "$MARKER" ]; then
  fail "claude ($CLAUDE_VERSION): a real idle busy-state record plus a real empty composer was not read as safe - no marker written"
elif [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != save-sent ]; then
  fail "claude ($CLAUDE_VERSION): expected phase=save-sent after the first sweep, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ "$(wc -l < "$SENDLOG")" != 1 ] || [ "$(sent_task)" != "$TASK" ]; then
  fail "claude ($CLAUDE_VERSION): expected exactly one save-message send to $TASK"
else
  pass "claude ($CLAUDE_VERSION): a real idle busy-state record plus a real empty Claude Code composer together permit the send through fm_idle_compact_safe_to_send"
fi

# --- 3. a real pending (unsubmitted) composer blocks the send, independent
#        of the still-idle busy-state record ---------------------------------

touch "$STATE/$TASK.turn-ended"   # simulate the save turn completing
tmux -L "$SOCKET" send-keys -t "$WIN" "audit-probe-never-submitted" 2>/dev/null \
  || fail "claude ($CLAUDE_VERSION): could not type an unsubmitted probe into the real composer"
sleep 1
: > "$SENDLOG"
fm_idle_compact_tick "$STATE" "$CONFIG"
if [ -s "$SENDLOG" ]; then
  fail "claude ($CLAUDE_VERSION): /compact must never be sent while the real composer holds unsubmitted text"
elif [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != save-sent ]; then
  fail "claude ($CLAUDE_VERSION): a blocked send must leave the marker at phase=save-sent, not advance it"
else
  pass "claude ($CLAUDE_VERSION): a real pending (unsubmitted) composer correctly blocks the send"
fi

# Clear the unsubmitted probe (never Enter - Ctrl+u clears the line) before
# re-proving the positive path, so the composer returns to genuinely empty.
tmux -L "$SOCKET" send-keys -t "$WIN" C-u 2>/dev/null || true
sleep 1

# --- 4. once the pane is idle+empty again, the same episode completes:
#        /compact is sent, the marker settles, then reaches phase=done ------

fm_idle_compact_tick "$STATE" "$CONFIG"
if [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != settling ]; then
  fail "claude ($CLAUDE_VERSION): expected phase=settling once the real composer read empty again, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ "$(wc -l < "$SENDLOG")" != 1 ] || [ "$(sent_task)" != "$TASK" ]; then
  fail "claude ($CLAUDE_VERSION): expected exactly one further send once the pane read empty again"
else
  case "$(sent_message)" in
    '/compact '*) pass "claude ($CLAUDE_VERSION): a real idle+empty composer after the save turn completes sends /compact and reaches phase=settling" ;;
    *) fail "claude ($CLAUDE_VERSION): expected the second send to be a literal /compact command, got '$(sent_message)'" ;;
  esac
fi

# FM_IDLE_COMPACT_INTERVAL=0 above also collapses the settle window's default
# (one sweep interval), so the next tick captures the post-render baseline.
: > "$SENDLOG"
fm_idle_compact_tick "$STATE" "$CONFIG"
if [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != 'done' ]; then
  fail "claude ($CLAUDE_VERSION): expected phase=done after the settle window elapsed, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ -s "$SENDLOG" ]; then
  fail "claude ($CLAUDE_VERSION): settling into phase=done must never send anything"
else
  pass "claude ($CLAUDE_VERSION): the settle sweep captures the post-render baseline and reaches phase=done without further sends"
fi

note "no message was ever actually submitted to the live claude process - fm_idle_compact_send was stubbed throughout, so no model tokens were spent"
echo "all fm-idle-compact-live-e2e checks passed"
