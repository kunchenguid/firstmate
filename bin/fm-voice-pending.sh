#!/usr/bin/env bash
# fm-voice-pending.sh - captain-message turn-start presenter for pending voice
# notes in a firstmate PRIMARY session, wired as the Claude primary's
# UserPromptSubmit hook (.claude/settings.json).
#
# Why it exists: a captain voice note reaches firstmate as a durable wake row
# keyed by fm-wake-lib.sh's FM_WAKE_VOICE_KEY_PATTERN, and bin/fm-wake-drain.sh
# presents it first at session start and at every wake-handling turn. A
# captain-message turn never runs the drain. On 2026-09-10 eleven spoken turns
# sat queued behind a captain text message that pulled firstmate onto other
# work, and none were answered. This hook runs at the start of every Claude
# captain-message turn and prints the pending voice rows under the same VOICE
# heading the drain prints, so the turn sees them before its first work; Claude
# Code adds a UserPromptSubmit hook's stdout to the turn's context. AGENTS.md
# then has that turn run the drain, handle the rows, and acknowledge through
# the drain's WAKE_ACK_REQUIRED command, exactly like a wake-handling turn.
#
# Read-only, presentation-only contract: this script never takes the queue
# lock, never drains, never acknowledges, never claims rows, never writes any
# file under state/, and never touches the recovery marker. The drain and its
# generation-bound --ack-through remain the only mutation and acknowledgement
# path. A torn read of the queue can mis-present at most one turn, and the next
# drain re-presents the row - the same reasoning fm_wake_actor_pending_count in
# bin/fm-wake-lib.sh gives for counting without the lock. One awk pass over
# the queue bounds the cost.
#
# Every failure path exits 0 silently: this hook must never block or fail a
# captain turn. The silent-exit gates, in order: the checkout is not a primary
# home, this session does not own the home's fleet lock, or the wake queue is
# missing or unreadable. The hook never reads its stdin payload; nothing here
# depends on it.
#
# The tracked entry is deliberately UNGUARDED on Grok and Cursor, unlike the
# SessionStart, PreToolUse Bash, and Stop entries in .claude/settings.json.
# Neither host registers a counterpart for this event (.grok/hooks/ and
# .cursor/hooks.json cover session start, pre-tool, and stop only), so a guard
# here would remove the turn-start voice check on that host entirely instead
# of deduplicating it - the same reasoning that leaves
# bin/fm-subagent-pretool-check.sh unguarded. The wedge rationale behind
# guarding the Stop entries does not apply: this hook is read-only and has no
# asyncRewake, so a host that fires it synchronously gets one bounded awk pass
# and nothing else. A primary on either host that loads this repo's
# Claude-shaped settings therefore also gets the presenter; primaries whose
# hosts never fire this event present voice notes through the drain at
# session start and at wake-handling turns.
#
# Ships as a TRACKED hook target, so it is checked out into every worktree of
# this repo. It scopes itself to a genuine primary checkout - the main home or
# a marked secondmate home - through bin/fm-primary-scope-lib.sh and stays a
# silent no-op in child crew and scout worktrees, and it stands down unless
# this session owns the home's fleet lock, through bin/fm-session-lock-lib.sh's
# fm_session_lock_owned_by_self, the same predicate
# bin/fm-claude-stop-autoarm.sh and bin/fm-sessionstart-run.sh use. A second
# Claude session opened in the same home (the read-only session bin/fm-lock.sh
# refuses) would otherwise be told to answer the very note the lock-owning
# session is handling: a duplicate spoken reply, or a note retired under the
# owner. A missing or malformed lock fails closed the same way.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

QUEUE="$STATE/.wake-queue"
{ [ -f "$QUEUE" ] && [ -r "$QUEUE" ]; } || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

VOICE_VIEW=$(fm_wake_voice_rows "$QUEUE" 2>/dev/null) || exit 0
[ -n "$VOICE_VIEW" ] || exit 0
fm_wake_voice_heading "$(printf '%s\n' "$VOICE_VIEW" | awk 'END { print NR }')"
printf '%s\n' "$VOICE_VIEW"
exit 0
