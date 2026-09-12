#!/usr/bin/env bash
# Prompt-submission hook that puts firstmate's captain-facing reply-style rule
# in front of the model on the turn that will use it.
#
# Why this event and not a reply-time one: no harness fires a hook between the
# model composing prose and the captain reading it, so nothing can inspect,
# gate, or rewrite a reply. Prompt submission is the last event upstream of
# composition whose stdout the harness adds to that turn's context, which makes
# it the only place a standing style rule can be structural instead of
# remembered. docs/sessionstart-nudge.md's harness table owns which harnesses
# carry hook stdout into model context at all; Claude is the tracked transport
# here, and .claude/settings.json is the registration.
#
# The single line this prints is the compressed reminder.
# `.agents/skills/plainenglish/SKILL.md` is the single owner of the full
# contract, its rationale, the standing exceptions, and the off switch.
#
# The reminder is deliberately NOT wrapped in the operational-input protocol
# (bin/fm-operational-input.sh), and it is also suppressed entirely while away
# mode is active, because that marker cuts both ways. The marker means "this
# text is Firstmate machinery talking, not the captain", and away mode exits on
# the first UNMARKED captain message (AGENTS.md section 8), so marking a line
# that rides along with every captain turn would make every captain message look
# marked and could strand a home in away mode. Leaving it unmarked is only safe
# while away mode is off: the sub-supervisor daemon delivers its marked
# away-supervisor injections into the primary's pane, which is a prompt
# submission, so an unmarked line would ride along on that turn and read as the
# captain returning. The reminder is therefore unmarked AND silent while
# state/.afk exists. The accepted cost is one turn: bin/fm-afk-return.sh is what
# clears the flag, so the captain's own returning message arrives while the flag
# is still present and goes without the reminder, which is the right trade
# against dropping a fleet out of supervision.
#
# Usage:
#   <UserPromptSubmit JSON on stdin> | bin/fm-plainenglish-hook.sh
#
# Contract:
#   REMIND - exit 0 and one line of stdout, which the harness adds to context.
#   SILENT - exit 0 with no output: this home switched the reminder off, this is
#            not a genuine primary home (a crewmate/scout task worktree or a
#            non-firstmate repo), this is a no-mistakes gate agent, or away mode
#            is active.
#   Every path exits 0 and writes nothing. Claude blocks and erases the
#   captain's prompt on hook exit 2, so this script never returns non-zero, and
#   the registration in .claude/settings.json additionally pins the exit to 0 so
#   even an unparseable or missing script cannot wedge a turn.
set -u

# Claude writes the event payload to stdin. Nothing here needs it, but draining
# it keeps the harness from writing into a closed pipe.
cat >/dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" || exit 0
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh" || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Away mode: stay silent so no unmarked line rides along with the daemon's
# marked injections. The header owns the reasoning.
[ -e "$STATE/.afk" ] && exit 0

# The off switch: only the exact word "off" disables the reminder, read with the
# whitespace-stripped, case-folded convention the other scalar config items use.
# Absence means on, because the rule it carries is already AGENTS.md section 9's
# standing contract rather than an optional feature. An unrecognized value keeps
# the reminder rather than warning, because a hook that prints diagnostics into
# a captain's turn is worse than a typo that leaves the default in place.
if [ -f "$CONFIG/plainenglish" ]; then
  preference=$(tr -d '[:space:]' < "$CONFIG/plainenglish" 2>/dev/null | tr '[:upper:]' '[:lower:]') || preference=""
  [ "$preference" != off ] || exit 0
fi

printf '%s\n' "[plain-english] Answer the captain in one paragraph of at most two sentences that leads with the ask or the answer, keeping evidence, options, and detail in a file or task note rather than in the message. An escalation keeps that shape while still leading with the evidence and consequence that let it stand alone, an /updatethecaptain worker report keeps its own per-worker format, and the plainenglish skill owns the full contract."
exit 0
