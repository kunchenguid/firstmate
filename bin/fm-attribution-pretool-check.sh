#!/usr/bin/env bash
# PreToolUse guard that refuses AI self-attribution in a worker's commits and PRs.
#
# Claude Code's `attribution` setting (carried on every claude launch by
# bin/fm-spawn.sh) only changes the commit and PR text Claude Code's own
# system prompt asks the model to append; nothing in Claude Code rewrites a
# commit afterwards. A model can still type a `Co-Authored-By: Claude` trailer
# into its own `git commit -m` by habit, and a real worker commit did exactly
# that. bin/fm-spawn.sh registers this script as a Bash PreToolUse hook in a
# claude task worker's worktree .claude/settings.local.json, so such a command
# is denied before it runs and the model is told to retry without it.
#
# The guard fires only when the command both writes commit or PR text (a git
# commit, merge, tag, or notes invocation, or a gh / gh-axi pr or api call) and
# carries an attribution pattern, either inline or in a regular file the
# command names (for example `git commit -F msg.txt` or `--body-file=body.md`).
# Reading or searching for those patterns (`git log | grep Co-Authored-By`) is
# never denied. It never executes, sources, or expands the command.
#
# Usage:
#   <Claude PreToolUse JSON on stdin> | bin/fm-attribution-pretool-check.sh
#   bin/fm-attribution-pretool-check.sh --command '<cmd>'
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2 and the reason on stderr, which Claude shows the model.
# Stdin that jq cannot parse is scanned as raw text rather than allowed, so a
# broken transport still refuses an attributed commit; empty input allows.
set -u

usage() {
  cat <<'EOF'
Usage: fm-attribution-pretool-check.sh [--command <cmd>]

With no --command, reads a Claude PreToolUse JSON payload on stdin and checks
tool_input.command.
Exits 2 with the reason on stderr when a command that writes a commit or PR
message carries AI self-attribution (a Co-Authored-By trailer naming an AI,
a "Generated with" line, or a Claude session link), inline or in a file it
names; exits 0 otherwise.
EOF
}

CMD=
CMD_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 64; }
      CMD=$2 CMD_SET=1
      shift 2
      ;;
    --command=*) CMD=${1#--command=} CMD_SET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  if CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null); then
    # Resolve a relative message-file path from where the command runs.
    CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || true)
    [ -z "$CWD" ] || cd -- "$CWD" 2>/dev/null || true
  else
    CMD=$PAYLOAD
  fi
fi
[ -n "$CMD" ] || exit 0

NL=$'\n'
LINE="[^$NL]*"
# Matching is on lowercased text, so every pattern below is lowercase.
# Commands that write commit or PR text. The leading boundary excludes a word
# such as `legit` or a path suffix, and the verb must follow on the same line.
WRITER="(^|[^[:alnum:]_.-])(git[[:space:]]${LINE}(commit|merge|tag|notes)|gh(-axi)?[[:space:]]${LINE}(pr|api))([^[:alnum:]_-]|\$)"
# An AI or agent name as a whole word. Claude is also a human first name, so it
# counts only as a model or product name, or right before an email, a closing
# quote, or the end of a line.
AI_NAME="(^|[^[:alnum:]])((anthropic|openai|chatgpt|codex|copilot|gemini|devin|cursor ?agent|grok|kimi|opencode|an? ai)([^[:alnum:]]|\$)|claude([[:space:]]*[<(\"']|[[:space:]]+(code|opus|sonnet|haiku|fable)|[[:space:]]*$NL|[[:space:]]*\$))"
ATTRIBUTION="co-authored-by:${LINE}${AI_NAME}|generated (with|by)[^[:alnum:]$NL]*${AI_NAME}|claude-session:|claude\\.ai/code"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[[ $(lower "$CMD") =~ $WRITER ]] || exit 0

TEXT=$CMD
# Add the contents of every small regular file the command names, so a message
# written to a file first cannot slip past. Tokens split on whitespace and `=`
# with shell quotes dropped and globbing off; missing or unreadable files are
# skipped and each file is read up to 256 KiB.
TOKENS=${CMD//[\"\']/ }
TOKENS=${TOKENS//=/ }
set -f
for tok in $TOKENS; do
  case "$tok" in -*) continue ;; esac
  [ -f "$tok" ] && [ -r "$tok" ] || continue
  TEXT="$TEXT$NL$(head -c 262144 -- "$tok" 2>/dev/null || true)"
done
set +f

if [[ $(lower "$TEXT") =~ $ATTRIBUTION ]]; then
  cat >&2 <<EOF
Refused: this command writes a commit or PR message containing AI self-attribution.
Firstmate workers never credit an AI or agent in a commit message, PR title, or PR body: no Co-Authored-By trailer naming an AI, no "Generated with" line, and no session or tool link.
Remove that text and run the command again, writing the message the way a human developer would.
EOF
  exit 2
fi
exit 0
