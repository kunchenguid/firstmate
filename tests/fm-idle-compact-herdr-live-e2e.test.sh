#!/usr/bin/env bash
# tests/fm-idle-compact-herdr-live-e2e.test.sh - live-harness-optin guard for
# the idle-compact eligibility gate's vendor-rendered-signal surface, herdr
# backend (task fm-quota-efficiency; live-harness-optin family). Herdr is the
# fleet default backend, so this sibling of
# tests/fm-idle-compact-live-e2e.test.sh proves the same live safety gate
# (bin/fm-busy-lib.sh's fm_busy_classify, bin/fm-backend.sh's
# fm_backend_composer_state, together through fm_idle_compact_safe_to_send)
# against a REAL, idle Claude Code pane hosted in a herdr pane instead of tmux
# - the tmux-only sibling never exercised the herdr per-backend dispatch
# fm_idle_compact_safe_to_send calls into.
#
# Only fm_idle_compact_send and bin/fm-crew-state.sh are stubbed, exactly as
# the tmux sibling does: no message is ever actually submitted to the live
# claude process, and crew-state's own reconciliation contract is separately
# owned and tested (tests/fm-crew-state.test.sh). No prompt is ever submitted
# to claude, so no model tokens are spent.
#
# Run explicitly with FM_IDLE_COMPACT_LIVE=1. An absent claude, herdr, or jq
# fails loudly rather than passing vacuously. Refresh
# docs/verification/runtime-backends.md ("Idle-worker pre-compaction") from
# this guard's output after any Herdr or Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_IDLE_COMPACT_LIVE herdr jq claude

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1) || CLAUDE_VERSION='version-unknown'
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION='version-unknown'

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-idlec-herdr-live-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-compact-herdr-live.XXXXXX")
cleanup_all() {
  rm -rf "$LAB"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

STATE="$LAB/state"; CONFIG="$LAB/config"; DATA="$LAB/data"
mkdir -p "$STATE" "$CONFIG" "$DATA"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-idlec1" "$ROOT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
WIN="$SESSION:$PANE_ID"

fm_backend_herdr_send_literal "$WIN" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
  || fail "could not type the claude launch command into the real herdr pane"
fm_backend_herdr_send_key "$WIN" Enter \
  || fail "could not submit the claude launch command in the real herdr pane"

# Wait for the real Claude Code composer to settle idle+empty, dismissing one
# benign startup modal if it appears - never Escape a trust prompt (that would
# exit the harness and erase the actionable failure surface).
budget=${FM_IDLE_COMPACT_LIVE_POLLS:-45}
i=0
dismissed=0
verdict=''
while [ "$i" -lt "$budget" ]; do
  verdict=$(fm_backend_composer_state herdr "$WIN")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
    screen=$(fm_backend_herdr_capture "$WIN" 30 2>/dev/null || true)
    if ! printf '%s\n' "$screen" | grep -qi trust; then
      fm_backend_herdr_send_key "$WIN" Escape 2>/dev/null || true
    fi
    dismissed=1
  fi
  sleep 1
done
if [ "$verdict" != empty ]; then
  printf '# claude pane tail at failure:\n' >&2
  fm_backend_herdr_capture "$WIN" 30 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "claude ($CLAUDE_VERSION) on herdr: idle composer never classified empty - cannot run the idle-compact live guard"
fi

# --- fixture: one ship task pointed at the real idle herdr pane -------------

TASK=t1
printf 'window=%s\nbackend=herdr\nharness=claude\nkind=ship\n' "$WIN" > "$STATE/$TASK.meta"
printf 'done: fixture\n' > "$STATE/$TASK.status"
touch -d '@1' "$STATE/$TASK.status" "$STATE/$TASK.meta"
printf '1\n' > "$CONFIG/idle-compact"  # 1-minute threshold

CREW_STATE_STUB="$LAB/fake-crew-state.sh"
cat > "$CREW_STATE_STUB" <<'SH'
#!/usr/bin/env bash
printf 'state: parked \xc2\xb7 source: fixture \xc2\xb7 live-guard fixture\n'
SH
chmod +x "$CREW_STATE_STUB"

BUSY_EV="$ROOT/bin/fm-busy-event.sh"
BUSY_GEN=$("$BUSY_EV" arm "$STATE" "$TASK") \
  || fail "claude ($CLAUDE_VERSION) on herdr: could not arm the busy-state contract for the fixture task"

SENDLOG="$LAB/sends.log"
: > "$SENDLOG"

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$LAB"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$DATA"
export FM_CREW_STATE_BIN="$CREW_STATE_STUB"
export FM_IDLE_COMPACT_INTERVAL=0

# shellcheck source=bin/fm-idle-compact.sh
. "$ROOT/bin/fm-idle-compact.sh"

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
  fail "claude ($CLAUDE_VERSION) on herdr: a freshly armed (busy) real busy-state record must block the send"
elif [ -e "$MARKER" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: a busy task must never get a marker"
else
  pass "claude ($CLAUDE_VERSION) on herdr: a real busy-state record correctly blocks the send through fm_busy_classify, even with a genuinely empty composer"
fi

# --- 2. flipping the real busy-state record to idle unblocks the send: first
#        sweep reaches phase=save-sent ---------------------------------------

"$BUSY_EV" apply "$STATE" "$TASK" idle --gen "$BUSY_GEN" --source claude-hook --event stop \
  || fail "claude ($CLAUDE_VERSION) on herdr: could not apply the idle busy-state event for the fixture task"

fm_idle_compact_tick "$STATE" "$CONFIG"
if [ ! -f "$MARKER" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: a real idle busy-state record plus a real empty composer was not read as safe - no marker written"
elif [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != save-sent ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: expected phase=save-sent after the first sweep, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ "$(wc -l < "$SENDLOG")" != 1 ] || [ "$(sent_task)" != "$TASK" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: expected exactly one save-message send to $TASK"
else
  pass "claude ($CLAUDE_VERSION) on herdr: a real idle busy-state record plus a real empty Claude Code composer together permit the send through fm_idle_compact_safe_to_send"
fi

# --- 3. a real pending (unsubmitted) composer blocks the send, independent of
#        the still-idle busy-state record -------------------------------------

touch "$STATE/$TASK.turn-ended"   # simulate the save turn completing
fm_backend_herdr_send_literal "$WIN" "audit-probe-never-submitted" \
  || fail "claude ($CLAUDE_VERSION) on herdr: could not type an unsubmitted probe into the real composer"
sleep 1
: > "$SENDLOG"
fm_idle_compact_tick "$STATE" "$CONFIG"
if [ -s "$SENDLOG" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: /compact must never be sent while the real composer holds unsubmitted text"
elif [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != save-sent ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: a blocked send must leave the marker at phase=save-sent, not advance it"
else
  pass "claude ($CLAUDE_VERSION) on herdr: a real pending (unsubmitted) composer correctly blocks the send"
fi

# Clear the unsubmitted probe (never Enter) before re-proving the positive
# path, so the composer returns to genuinely empty.
fm_backend_herdr_send_key "$WIN" "C-u" 2>/dev/null || true
sleep 1

# --- 4. once the pane is idle+empty again, the same episode completes:
#        /compact is sent, the marker settles, then reaches phase=done ------

fm_idle_compact_tick "$STATE" "$CONFIG"
if [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != settling ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: expected phase=settling once the real composer read empty again, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ "$(wc -l < "$SENDLOG")" != 1 ] || [ "$(sent_task)" != "$TASK" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: expected exactly one further send once the pane read empty again"
else
  case "$(sent_message)" in
    '/compact '*) pass "claude ($CLAUDE_VERSION) on herdr: a real idle+empty composer after the save turn completes sends /compact and reaches phase=settling" ;;
    *) fail "claude ($CLAUDE_VERSION) on herdr: expected the second send to be a literal /compact command, got '$(sent_message)'" ;;
  esac
fi

: > "$SENDLOG"
fm_idle_compact_tick "$STATE" "$CONFIG"
if [ "$(fm_idle_compact_marker_field "$MARKER" phase)" != 'done' ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: expected phase=done after the settle window elapsed, got '$(fm_idle_compact_marker_field "$MARKER" phase)'"
elif [ -s "$SENDLOG" ]; then
  fail "claude ($CLAUDE_VERSION) on herdr: settling into phase=done must never send anything"
else
  pass "claude ($CLAUDE_VERSION) on herdr: the settle sweep captures the post-render baseline and reaches phase=done without further sends"
fi

note "no message was ever actually submitted to the live claude process - fm_idle_compact_send was stubbed throughout, so no model tokens were spent"
fm_backend_herdr_kill "$WIN"
echo "all fm-idle-compact-herdr-live-e2e checks passed"
