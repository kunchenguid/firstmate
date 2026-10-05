#!/usr/bin/env bash
# PreToolUse transport for the supervisor-work command policy.
#
# A firstmate SUPERVISOR session must not do a worker's job: it must not drive a
# crew-owned `no-mistakes axi run`/`respond`, must not sleep or poll inside a
# turn, and a secondmate lead must not type raw keys into a worker's pane. The
# written rules forbid all three; this guard is what makes them deterministic.
# bin/fm-supervisor-work-command-policy.mjs is the sole owner of the patterns
# and the block/allow decision. This wrapper only scopes the guard to a genuine
# supervisor home, acquires the harness payload, invokes that policy, and
# renders the established harness responses. It never executes, sources,
# evaluates, or expands the command. See docs/supervisor-work-guard.md.
#
# A ship or scout worker OWNS its own no-mistakes run, may wait while it runs,
# and may drive its own terminal: the scope block below makes this a silent
# no-op there, which is why the guard is safe to ship in tracked hook config that
# linked worktrees inherit.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-supervisor-work-pretool-check.sh
#   bin/fm-supervisor-work-pretool-check.sh --command '<cmd>' [--secondmate]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine supervisor home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or a
#               missing Node or policy owner.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
SECONDMATE=0

usage() {
  cat <<'EOF'
Usage: fm-supervisor-work-pretool-check.sh [--command <cmd>] [--secondmate] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Fires only in a genuine firstmate supervisor home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny a command that does a worker's job: driving a
crew-owned `no-mistakes axi run`/`respond`, sleeping or polling inside a turn,
or (with --secondmate, a secondmate lead) typing into a pane with herdr or tmux.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --secondmate)
      SECONDMATE=1
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

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every deniable command contains `no-mistakes`, `sleep`, `herdr`,
# or `tmux` AFTER the tokenizer's byte normalization, and the classifier also
# decodes ANSI-C and locale quoting markers that this substring test cannot see.
# That marker set is COUPLED to the policy owner's decoder set: adding any new
# quote/expansion form it decodes REQUIRES extending it here in the same change.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *no-mistakes*|*sleep*|*herdr*|*tmux*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# Scope to a genuine supervisor home, exactly as the session-start nudge, the
# turn-end guard, and the subagent PreToolUse seatbelt do: a plain checkout or a
# marked secondmate home is a supervisor and operates a fleet, while a linked
# task worktree - the shape bin/fm-spawn.sh always hands a crewmate - is a
# worker and stays untouched. Any failure to confirm the home is inert (exit 0),
# never a block, so a broken environment never denies a command.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && SECONDMATE=1

# The policy owner ships next to this transport in the tracked repo, so it is
# resolved from the transport's own directory rather than the scoped home: the
# scope overrides below redirect WHICH session is judged, never which shipped
# rules judge it.
POLICY="$SCRIPT_DIR/fm-supervisor-work-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_ARGS=(--command "$CMD")
[ "$SECONDMATE" -eq 1 ] && POLICY_ARGS+=(--secondmate)
POLICY_OUTPUT=$(node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2