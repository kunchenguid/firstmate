#!/usr/bin/env bash
# tests/fm-claude-permission-mode-live-e2e.test.sh - opt-in credentialed live
# regression for bin/fm-spawn.sh's claude launch (live-harness-optin family).
#
# Whether a Claude Code launch blocks a crewmate on an interactive approval
# prompt is a fact only the real installed binary can confirm - a stub can
# only replay the assumption already written into the stub. Per
# .agents/skills/firstmate-coding-guidelines "Harness-dependent checks", this
# guard proves it against the real installed claude, in a real tmux pane, as
# root outside a declared sandbox (this fleet's actual launch posture).
#
# Root cause (data/claude-workers-auto-mode/report.md, 2026-09-08, claude
# 2.1.263): --dangerously-skip-permissions does not grant real autonomy here.
# This fleet always runs claude as root without IS_SANDBOX set, and the
# installed binary refuses bypassPermissions in that case - silently
# downgrading to manual mode - so a worker still parks on the first Write
# approval prompt. --permission-mode auto is a separate, always-honored
# CLI-flag source that does not hit either guard.
#
# This guard launches the SAME two flags side by side in fresh, never-seen
# project directories:
#   - "before": --dangerously-skip-permissions alone (the pre-fix posture)
#   - "after":  --dangerously-skip-permissions --permission-mode auto (the
#     exact flags bin/fm-spawn.sh's claude case now emits)
# and asserts the divergence itself: "before" must still hit the interactive
# Write approval prompt (never answered, so it is killed rather than
# resolved), while "after" must complete the requested file write and shell
# command with no prompt ever appearing. Asserting both sides is deliberate:
# a future claude release that stopped blocking "before" too would make this
# guard vacuous if it checked only "after".
#
# Run explicitly with FM_CLAUDE_PERMISSION_MODE_LIVE_E2E=1. Spends a small,
# bounded number of real model tokens (two short one-shot turns) - authorized
# by the harness-dependent-checks rule. Cleans up its own fresh-project
# entries from ~/.claude.json (or $CLAUDE_CONFIG_DIR/.claude.json) afterward,
# the same self-cleaning practice the source scout report used. Record the
# dated result in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_PERMISSION_MODE_LIVE_E2E claude tmux

# This guard proves the root-without-sandbox posture documented above; the
# "before" arm's blocking assertion is not valid evidence outside it (a
# non-root or declared-sandbox launch can legitimately proceed without the
# root-specific approval prompt, which would otherwise read as a false
# failure rather than the vendor behavior changing).
if [ "$(id -u)" != 0 ] || [ -n "${IS_SANDBOX:-}" ]; then
  printf 'skip: live: requires uid=0 with IS_SANDBOX unset (this fleet'"'"'s actual claude launch posture); got uid=%s IS_SANDBOX=%s\n' \
    "$(id -u)" "${IS_SANDBOX:-unset}"
  exit 0
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null || printf 'version-unknown')
CLAUDE_STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

SOCKET="fm-cwam-live-$$"
SESSION="cwamlive"
LAB=$(fm_test_tmproot fm-claude-permission-mode-live-e2e)
DIR_BEFORE="$LAB/before"
DIR_AFTER="$LAB/after"
mkdir -p "$DIR_BEFORE" "$DIR_AFTER"

FAILED=0
CHECKED=0

cleanup_trust_entries() {
  # Strip only the two throwaway paths this guard registered, preserving
  # every other project entry in the launching user's own store - the same
  # scope fm-claude-trust.sh's own write is limited to. Written atomically
  # (temp file + os.replace) so a mid-write crash never leaves a truncated
  # store; this narrows, but cannot fully close, the race against a
  # concurrent Claude session also touching the file (the existing
  # "Claude workspace trust" verification record already documents that
  # residual risk for the same store). A real cleanup failure is reported
  # rather than silenced, but never aborts this exit-trap cleanup.
  [ -f "$CLAUDE_STORE" ] || return 0
  python3 - "$CLAUDE_STORE" "$DIR_BEFORE" "$DIR_AFTER" <<'PY'
import json, os, sys, tempfile
path, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
projects = data.get("projects")
if isinstance(projects, dict):
    for p in (before, after):
        projects.pop(p, None)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
PY
  status=$?
  [ "$status" -eq 0 ] || printf 'warning: fm-claude-permission-mode-live-e2e cleanup could not prune its trust-store entries (exit %s); check %s by hand\n' "$status" "$CLAUDE_STORE" >&2
  return 0
}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  cleanup_trust_entries
}
trap cleanup EXIT

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$LAB"

# fm-spawn.sh's exact launch_template flags for a claude crewmate around the
# folder-trust dialog and the Write action under test; CLAUDE_CODE_ENABLE_
# PROMPT_SUGGESTION/--settings are irrelevant to the approval-prompt behavior
# under test and are omitted for a smaller, more legible pane.
PROMPT='Use the Write tool to create a file named probe.txt in the current directory with the exact content AUTOMODE_OK. Then run the shell command: echo SHELL_OK. Then stop and take no further action.'

accept_trust_dialog() {  # <window>
  local win=$1 i=0 screen
  while [ "$i" -lt 20 ]; do
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
    if printf '%s\n' "$screen" | grep -q 'Quick safety check'; then
      tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Down 2>/dev/null || true
      sleep 0.3
      tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Enter 2>/dev/null || true
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# --- "before": --dangerously-skip-permissions alone must still block -------
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n before -c "$DIR_BEFORE" \
  -- claude --dangerously-skip-permissions "$PROMPT" \
  || fail "before (claude $CLAUDE_VERSION): could not launch in the isolated tmux server"

accept_trust_dialog before \
  || fail "before (claude $CLAUDE_VERSION): folder-trust dialog never appeared to accept"

blocked=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:before" 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -q 'Do you want to create'; then
    blocked=1
    break
  fi
  i=$((i + 1))
  sleep 0.5
done
tmux -L "$SOCKET" kill-window -t "$SESSION:before" 2>/dev/null || true

if [ "$blocked" -eq 1 ] && [ ! -e "$DIR_BEFORE/probe.txt" ]; then
  CHECKED=$((CHECKED + 1))
  pass "before (claude $CLAUDE_VERSION): --dangerously-skip-permissions alone still parks on the Write approval prompt as root"
else
  FAILED=1
  printf 'not ok - before (claude %s): expected the pre-fix flags to still block on the Write approval prompt (blocked=%s, probe.txt exists=%s) - the vendor default may have changed; re-verify the scout report\n' \
    "$CLAUDE_VERSION" "$blocked" "$([ -e "$DIR_BEFORE/probe.txt" ] && echo yes || echo no)" >&2
fi

# --- "after": --dangerously-skip-permissions --permission-mode auto -------
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n after -c "$DIR_AFTER" \
  -- claude --dangerously-skip-permissions --permission-mode auto "$PROMPT" \
  || fail "after (claude $CLAUDE_VERSION): could not launch in the isolated tmux server"

accept_trust_dialog after \
  || fail "after (claude $CLAUDE_VERSION): folder-trust dialog never appeared to accept"

done_ok=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:after" 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -q 'Do you want to'; then
    FAILED=1
    printf 'not ok - after (claude %s): --permission-mode auto still hit an approval prompt:\n%s\n' \
      "$CLAUDE_VERSION" "$screen" >&2
    break
  fi
  if [ -f "$DIR_AFTER/probe.txt" ] && printf '%s\n' "$screen" | grep -q 'SHELL_OK'; then
    done_ok=1
    break
  fi
  i=$((i + 1))
  sleep 0.5
done
final_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:after" 2>/dev/null || true)
tmux -L "$SOCKET" kill-window -t "$SESSION:after" 2>/dev/null || true

if [ "$done_ok" -eq 1 ] \
  && [ "$(cat "$DIR_AFTER/probe.txt" 2>/dev/null)" = AUTOMODE_OK ] \
  && ! printf '%s\n' "$final_screen" | grep -q 'Do you want to'; then
  CHECKED=$((CHECKED + 1))
  pass "after (claude $CLAUDE_VERSION): --dangerously-skip-permissions --permission-mode auto writes the file and runs the shell command with no approval prompt"
else
  FAILED=1
  printf 'not ok - after (claude %s): expected an unattended write+shell completion with no prompt (done_ok=%s, probe.txt=%s)\n%s\n' \
    "$CLAUDE_VERSION" "$done_ok" "$(cat "$DIR_AFTER/probe.txt" 2>/dev/null || echo absent)" "$final_screen" >&2
fi

[ "$CHECKED" -gt 0 ] || fail "no checks actually ran (both cases errored before producing a verdict)"
[ "$FAILED" -eq 0 ] || exit 1
printf 'ok - claude %s live E2E: --permission-mode auto is the flag that stops a claude crewmate blocking on an approval prompt as root\n' "$CLAUDE_VERSION"
