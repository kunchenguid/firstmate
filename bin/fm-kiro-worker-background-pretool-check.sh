#!/usr/bin/env bash
# PreToolUse guard against a Kiro worker detaching a long shell command from
# its own turn: trailing `&`, `nohup`, `disown`, or `setsid` on the executed
# command.
#
# A worker that backgrounds a long build or test and lets the turn end leaves
# that process with no supervisor: no watcher, no busy state, no status line
# tells firstmate it is still running, and the worktree it writes into can be
# torn down out from under it. The brief already asks a worker to run such
# work in the foreground or declare `paused:` and stop; this hook makes that
# the only path a Kiro worker can take, instead of relying on the model
# reading and following the instruction every time (data/done-archive.md's
# 28/09 retro, "censo R4": `build-mingw.sh` ran detached with `&` against the
# brief).
#
# Scoped to kiro-cli alone, where fm-kiro-turnend-hook.sh already owns the
# PreToolUse dispatch for both primary and worker sessions; no other verified
# harness gets new PreToolUse infrastructure here, including firstmate's own
# primary and secondmate Kiro sessions, which run under
# bin/fm-arm-command-policy.mjs's watcher seatbelt instead.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-kiro-worker-background-pretool-check.sh
#   bin/fm-kiro-worker-background-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .tool_input.command, the shape fm-kiro-turnend-hook.sh's
# header documents for kiro-cli's PreToolUse payload.
#
# Classification is a plain top-level-command scan, not the full shell lexer
# bin/fm-arm-command-policy.mjs owns for the watcher seatbelt: it strips
# balanced single- and double-quoted spans (so a quoted word such as the
# literal string "nohup" in a non-executed argument never matches) and then
# looks for an executed `nohup` or `setsid`, a `disown` invocation, or a
# trailing `&` that is not `&&`, at any top-level position (after `;`, `&&`,
# `||`, `|`, or a newline), anywhere in the command. Nothing here evaluates,
# sources, or expands the submitted command.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or
#               no command text to classify.
#
# Claude requires stdout to remain empty on deny.
# Kiro blocks on exit 2 and shows the model its stderr (verified live, see
# fm-kiro-turnend-hook.sh's header and docs/arm-pretool-check.md's PreToolUse
# contract for the same exit-2-and-stderr shape).
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-kiro-worker-background-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin
(.tool_input.command).
Denies a shell command that backgrounds itself with a trailing `&`, `nohup`,
`disown`, or `setsid`. Run the command in the foreground, or append
`paused: {job and completion condition}` to the status file and stop instead.
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
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strip balanced single- and double-quoted spans so a quoted word never
# matches as an executed token. This is a byte scan, not a shell parse: it
# does not resolve nesting through command substitution, so a command whose
# only `nohup`/`setsid`/`disown`/trailing `&` appears inside `$(...)` or
# backticks is not classified by this pass. That stays within scope: the
# retro item is a worker detaching ITS OWN foreground command, which is always
# a literal top-level token, never one buried inside a substitution the
# worker would have to construct on purpose to defeat this guard.
STRIPPED=""
REST=$CMD
while [ -n "$REST" ]; do
  case "$REST" in
    \'*)
      REST=${REST#\'}
      case "$REST" in
        *\'*) REST=${REST#*\'} ;;
        *) REST='' ;;
      esac
      STRIPPED="$STRIPPED "
      ;;
    \"*)
      REST=${REST#\"}
      case "$REST" in
        *\"*) REST=${REST#*\"} ;;
        *) REST='' ;;
      esac
      STRIPPED="$STRIPPED "
      ;;
    *)
      case "$REST" in
        *[\'\"]*)
          head=${REST%%[\'\"]*}
          STRIPPED="$STRIPPED$head"
          REST=${REST#"$head"}
          ;;
        *)
          STRIPPED="$STRIPPED$REST"
          REST=''
          ;;
      esac
      ;;
  esac
done

# Normalize every top-level separator to a newline so each candidate top-level
# command starts a line, then classify per line. `&&` and `||` are split
# before a lone `&` or `|` is, so a two-character operator is never mistaken
# for the single-character one it contains.
NORMALIZED=$STRIPPED
NORMALIZED=${NORMALIZED//&&/$'\n'}
NORMALIZED=${NORMALIZED//'||'/$'\n'}
NORMALIZED=${NORMALIZED//;/$'\n'}
NORMALIZED=${NORMALIZED//|/$'\n'}

MATCHED=""
MATCHED_LINE=""
while IFS= read -r line || [ -n "$line" ]; do
  trimmed=${line#"${line%%[![:space:]]*}"}
  trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
  [ -n "$trimmed" ] || continue
  case "$trimmed" in
    nohup|nohup\ *)
      MATCHED="nohup"
      ;;
    setsid|setsid\ *)
      MATCHED="setsid"
      ;;
    disown|disown\ *)
      MATCHED="disown"
      ;;
    *)
      case "$trimmed" in
        *'&')
          case "$trimmed" in
            *'&&') ;;
            *) MATCHED='trailing &' ;;
          esac
          ;;
      esac
      ;;
  esac
  [ -z "$MATCHED" ] || { MATCHED_LINE=$trimmed; break; }
done <<EOF
$NORMALIZED
EOF

[ -n "$MATCHED" ] || exit 0

REASON="[kiro-worker-background] a worker command detaches itself from the current turn ($MATCHED, in: $MATCHED_LINE), which leaves it unsupervised: no watcher, no busy state, and no status line tells firstmate it is still running. Run the command in the foreground instead, or if it genuinely needs to outlive this turn, append \`paused: {job and completion condition}\` to the status file and stop."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
