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
# contract, its rationale, the escalation exception, and the off switch.
#
# The reminder is deliberately NOT wrapped in the operational-input protocol
# (bin/fm-operational-input.sh). That marker means "this text is Firstmate
# machinery talking, not the captain", and away mode exits on the first UNMARKED
# captain message (AGENTS.md section 8). Marking a line that rides along with
# every captain turn would make every captain message look marked and could
# strand a home in away mode.
#
# Usage:
#   <UserPromptSubmit JSON on stdin> | bin/fm-plainenglish-hook.sh
#
# Contract:
#   REMIND - exit 0 and one line of stdout, which the harness adds to context.
#   SILENT - exit 0 with no output: this home switched the reminder off, this is
#            not a genuine primary home (a crewmate/scout task worktree or a
#            non-firstmate repo), or this is a no-mistakes gate agent.
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

printf '%s\n' "[plain-english] Answer the captain in one paragraph of at most two sentences that leads with the ask or the answer, keeping evidence, options, and detail in a file or task note rather than in the message; an escalation keeps that shape and still leads with the evidence and consequence that let it stand alone. Load the plainenglish skill for the full contract."
exit 0
