#!/usr/bin/env bash
# PreToolUse guard against primary-session delegation outside the fleet.
#
# A firstmate primary that delegates through a harness's own delegation,
# scheduling, or background-work tool creates work with no `state/<id>.meta` and
# no `data/<id>/brief.md`. Only `bin/fm-spawn.sh` writes that metadata, and
# untracked project work contributes nothing to the in-flight branch of
# bin/fm-supervision-lib.sh or bin/fm-turnend-guard.sh. So such work is not
# merely unsupervised: absent an independent X-mode need, it makes the whole
# guard stack structurally inert, and it dies with the primary session instead
# of living in its own backend session.
#
# This scoped PreToolUse guard is the shipped mechanism.
# Claude primaries should also use an untracked per-home local
# `permissions.deny` list as hardening for known Claude delegation tools,
# because it removes them from the model's schema entirely.
# That deny list must not be tracked: it is Claude-only rather than
# harness-agnostic, and tracked project settings propagate into linked
# worktrees where they disarm legitimate crewmates.
# The tracked Claude matcher is deliberately `.*`: a stem-enumerating matcher
# would reintroduce the fail-open-by-enumeration problem this guard exists to
# solve, because any future tool name outside the matcher would never reach this
# script.
# This script is therefore the single owner of classification.
# It matches a delegation-SHAPED tool name rather than a fixed list, so a future
# tool that ships before anyone updates a local deny list is still refused.
#
# The guard is narrow by design. It classifies ONE thing: the shape of the tool
# name. It makes no judgment about whether the work should be delegated at all,
# which is a reasoning boundary no tool-shape hook can enforce.
# See docs/subagent-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-subagent-pretool-check.sh
#   bin/fm-subagent-pretool-check.sh --tool '<tool-name>'
#
# Stdin mode extracts .tool_name for Claude and Codex, or .toolName for Grok.
# CLI mode is for adapters that already hold the tool name (OpenCode, Pi).
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_SUBAGENT=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin, or missing jq for stdin transport.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

# Lowercase substrings that mark a tool name as delegation-shaped: it creates
# work, an agent, a schedule, or an isolated workspace that firstmate would not
# know about. This list is the single owner of the shipped classification.
DELEGATION_STEMS='agent subagent task workflow worktree delegate spawn dispatch handoff remote sendmessage monitor'

# Lowercase substrings that mark a tool name as self-scheduling: it re-invokes
# the caller's own session on a timer. Denied in both a primary and a task
# worktree because the re-invocation loops compound context costs and bypass
# supervision.
SELF_SCHEDULING_STEMS='schedul cron'

# Exact lowercase tool names that match a stem above but only OBSERVE or STOP
# work that already exists (e.g. crondelete stops an existing schedule). Reading
# or ending unaccounted work is not creating it, and denying these would strand
# already-running work with no way to inspect or end it. A local Claude deny
# list may still remove these from the schema; this shipped guard deliberately
# stays narrower so it can never be the reason a runaway task cannot be stopped.
# This relaxes the primary too, which is correct and intended.
OBSERVE_ONLY_TOOLS='taskoutput taskstop taskget tasklist cronlist crondelete bashoutput killshell'

# Exact lowercase tool names that match a stem above but create no RUNNABLE
# work. These write only the harness's session-local todo list, which has no
# executor: it spawns no agent, allocates no worktree, registers no schedule,
# and starts nothing that could outlive the session or escape a firstmate
# guard. Denying them stops the primary tracking its own plan while granting no
# delegation power, and the deny text would tell it to run bin/fm-brief.sh for a
# todo entry, so the stem match here is a false positive rather than a policy.
# This is a separate list from OBSERVE_ONLY_TOOLS on purpose: these tools WRITE,
# so folding them into a list documented as observe-or-stop would make that
# contract untrue. Both lists are exact-name, never substring, so neither can
# widen by accident.
PLAN_ONLY_TOOLS='taskcreate taskupdate'

TOOL=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-subagent-pretool-check.sh [--tool <tool-name>] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name, or Grok toolName).
Denies a delegation-SHAPED tool name in a genuine primary home, and denies
self-scheduling tools in BOTH a primary home and a task worktree.
Claude primaries may also add an untracked per-home permissions.deny list that
removes known delegation tools from the model schema before this hook is needed.
Do not ship that Claude-only list in tracked project settings, because linked
worktrees inherit it and legitimate crewmates would lose their delegation tools.
This hook remains as the shipped guard for future delegation-shaped names
outside any local fixed list.
For ordinary delegation tools (creating work/agents), it fires only in a
genuine firstmate primary home; it is a silent no-op in a crewmate/scout
task worktree where a worker using delegation tools is legitimate.
For self-scheduling tools (timer re-invocation), it fires in a task worktree
too, because timer loops compound context costs and bypass supervision.
Both remain a silent no-op in a non-firstmate repo.
Exits 0 to allow and 2 to deny, naming the appropriate wait or dispatch path.
Set FM_ALLOW_SUBAGENT=1 in the session environment to allow deliberately.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

# An MCP tool belongs to an external integration, not to the harness's own
# delegation surface, and its name is chosen by that server. Never classify one
# here: an MCP server with a task or agent noun in a tool name is common and
# blocking it would be a false positive with no bearing on fleet dispatch.
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

for allowed in $OBSERVE_ONLY_TOOLS $PLAN_ONLY_TOOLS; do
  [ "$NORMALIZED" != "$allowed" ] || exit 0
done

MATCHED_DELEGATION=""
for stem in $DELEGATION_STEMS; do
  case "$NORMALIZED" in
    *"$stem"*) MATCHED_DELEGATION=$stem; break ;;
  esac
done

MATCHED_SCHEDULING=""
for stem in $SELF_SCHEDULING_STEMS; do
  case "$NORMALIZED" in
    *"$stem"*) MATCHED_SCHEDULING=$stem; break ;;
  esac
done

if [ -z "$MATCHED_DELEGATION" ] && [ -z "$MATCHED_SCHEDULING" ]; then
  exit 0
fi

# The single deliberate escape hatch. It is an environment variable rather than
# a flag or a state file so it must be set when the session is launched, which
# makes a genuinely intended use possible and an accidental one impossible: no
# in-session tool call can set it for the call that follows.
[ "${FM_ALLOW_SUBAGENT:-}" != "1" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Is this ANY firstmate territory (primary, secondmate, or task worktree)?
# Task worktrees lack git_dir == git_common_dir but still carry firstmate files.
fm_any_firstmate_scope_matches() {
  local root=$1 state=$2
  if ! fm_root_is_secondmate_home "$root"; then
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# If it's not even a firstmate repo, everything is inert.
fm_any_firstmate_scope_matches "$FM_ROOT" "$STATE" || exit 0

if [ -n "$MATCHED_SCHEDULING" ]; then
  # Self-scheduling is denied in ANY firstmate territory (primary or task worktree).
  REASON="[subagent-dispatch] a self-scheduling tool (blocked tool: $TOOL, matched on \"$MATCHED_SCHEDULING\") re-invokes this session on a timer. Each wake replays the whole accumulated context, compounding costs in an unbounded loop that firstmate supervision cannot see. Instead, append a paused: or blocked: status line to let firstmate's supervision-owned poll wake you (firstmate can arm state/<id>.check.sh via bin/fm-check-register.sh for custom conditions). Launch the session with FM_ALLOW_SUBAGENT=1 for a deliberate exception."
else
  # Scope to a genuine primary home, exactly as the session-start nudge and the
  # turn-end guard do. fm_primary_scope_matches accepts a plain checkout or a
  # marked secondmate home - both operate a fleet and must dispatch through it -
  # and rejects a linked task worktree, which is the shape bin/fm-spawn.sh always
  # hands a crewmate. A crewmate using delegation tools inside its own task
  # worktree is legitimate and stays allowed. Any failure to confirm the home is
  # inert (exit 0), never a block, so a broken environment never denies a call.
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

  # Name the dedicated scout entry point only when this home carries it; degrade
  # to the two-step brief-then-spawn path when it does not, rather than naming a
  # script that is not there.
  if [ -f "$FM_ROOT/bin/fm-scout.sh" ]; then
    ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'
  else
    ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
  fi

  REASON="[subagent-dispatch] the firstmate primary dispatches through the fleet, not the harness's own delegation tools: work started that way has no durable fleet record, leaves every firstmate guard inert, and dies with this session. Instead, $ROUTE (blocked tool: $TOOL, delegation-shaped on \"$MATCHED_DELEGATION\"). Launch the session with FM_ALLOW_SUBAGENT=1 for a deliberate exception."
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
