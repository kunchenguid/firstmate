#!/usr/bin/env bash
# tests/fm-claude-approval-notify-live-e2e.test.sh - opt-in credentialed drift
# guard proving the real installed Claude Code still publishes its tool
# permission gate as a structured Notification payload, and that
# bin/fm-claude-approval-hook.sh still recognises it.
#
# Why this file exists: the approval gate in bin/fm-busy-lib.sh is opened from a
# field the vendor emits (notification_type=permission_prompt). A stub cannot
# prove that field is still emitted, and neither can a payload transcribed from
# a previous release. The failure this guards is quiet by construction - if the
# payload changes shape, the hook simply never fires and a worker parked at a
# permission dialog silently goes back to reading as ordinary work - so the
# guard has to run a real session and refuse to pass without seeing the payload.
#
# The portable counterpart in tests/fm-busy-state.test.sh pins the classifier and
# the adapter's decisions in CI, and tests/fm-busy-adapter-wiring.test.sh pins
# the spawn's registration. This file pins only the vendor contract those two
# assume. Standard CI has no harness binary and no credentials, so it is opt-in
# and on demand: run it after a Claude upgrade and before trusting refreshed
# per-harness evidence in docs/verification/supervision.md.
#
# The lab is fully isolated - its own repository clone, its own linked worktree,
# its own firstmate home, and its own tmux server - and it never touches a live
# fleet home, worktree, or session. Claude keeps using its existing managed
# authentication, and the session is driven to exactly one cheap tool call.
set -u

if [ "${FM_CLAUDE_APPROVAL_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_APPROVAL_DRIFT=1 to run the Claude permission-notification drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAB=""
SOCKET="fm-approval-drift-$$"
REAL_TMUX=""

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1
  [ -n "$LAB" ] && rm -rf "$LAB"
  return 0
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# An absent harness is reported, never passed over: this guard exists precisely
# to check something only the real binary can answer.
command -v claude >/dev/null 2>&1 || fail "claude not installed: this guard checked nothing"
command -v tmux >/dev/null 2>&1 || fail "tmux not installed: this guard checked nothing"
command -v jq >/dev/null 2>&1 || fail "jq not installed: this guard checked nothing"
REAL_TMUX=$(command -v tmux)
CLAUDE_VERSION=$(claude --version)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-approval-drift.XXXXXX")
PROJECT="$LAB/project"
WT="$LAB/wt"
HOME_DIR="$LAB/fmhome"
CAPTURE="$LAB/notification.jsonl"
mkdir -p "$HOME_DIR/state"

# A real linked worktree, because trust pre-registration refuses a primary
# checkout and every fleet worker runs in a linked worktree anyway.
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
git -C "$PROJECT" worktree add -q --detach "$WT" >/dev/null 2>&1 \
  || fail "could not create the lab worktree"
"$ROOT/bin/fm-claude-trust.sh" "$WT" "$PROJECT" >/dev/null \
  || fail "could not pre-register workspace trust for the lab worktree"

GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" drift) \
  || fail "could not arm the busy contract for the lab task"

# The registration is deliberately a raw capture rather than a copy of what
# bin/fm-spawn.sh writes: the spawn's wiring is already pinned portably, and
# what only a live session can answer is whether the payload still carries the
# gate. The captured payload is then fed through the real adapter below.
mkdir -p "$WT/.claude"
cat > "$WT/.claude/settings.local.json" <<JSON
{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"cat >> $CAPTURE"}]}]}}
JSON

"$REAL_TMUX" -L "$SOCKET" new-session -d -s drift -x 200 -y 50 -c "$WT" \
  || fail "could not start the lab tmux session"
"$REAL_TMUX" -L "$SOCKET" send-keys -t drift:0 \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --permission-mode manual --effort low 'Run this exact shell command with the Bash tool and nothing else: node -e \"console.log(1)\"'" Enter \
  || fail "could not launch Claude in the lab session"

# Bounded wait: a permission gate that never arrives is exactly the drift this
# guard exists to catch, so the timeout is a failure, never a skip.
DEADLINE=$(( $(date +%s) + ${FM_CLAUDE_APPROVAL_DRIFT_TIMEOUT:-180} ))
while [ ! -s "$CAPTURE" ]; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || {
    printf '# last pane:\n' >&2
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t drift:0 >&2 2>/dev/null
    fail "Claude $CLAUDE_VERSION reached no permission notification: the gate signal firstmate depends on may have changed"
  }
  sleep 3
done

PAYLOAD=$(grep -m1 permission_prompt "$CAPTURE" 2>/dev/null || true)
[ -n "$PAYLOAD" ] \
  || fail "Claude $CLAUDE_VERSION emitted a notification without notification_type=permission_prompt: $(cat "$CAPTURE")"
[ "$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name')" = Notification ] \
  || fail "Claude $CLAUDE_VERSION no longer names the permission gate a Notification: $PAYLOAD"

# The adapter must still open the gate from the payload the harness actually
# emitted, not from the fixture the portable tests use.
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-claude-approval-hook.sh" "$HOME_DIR/state" drift --gen "$GEN" \
  || fail "the approval hook exited non-zero on a live Claude $CLAUDE_VERSION payload"
fm_busy_approval_wait "$HOME_DIR/state" drift claude \
  || fail "the approval gate did not open on a live Claude $CLAUDE_VERSION permission notification: $PAYLOAD"

# Leave the session at no dialog before teardown: 4 is the decline option, and
# Enter is never sent, because these dialogs start on their refusing choice.
"$REAL_TMUX" -L "$SOCKET" send-keys -t drift:0 "4" >/dev/null 2>&1

printf 'ok - Claude %s still publishes its tool permission gate as notification_type=permission_prompt and the approval hook opens on it\n' "$CLAUDE_VERSION"
