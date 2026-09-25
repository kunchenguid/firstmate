#!/usr/bin/env bash
# The one owner of the AI self-attribution matcher for a worker's commits and
# PRs, run in two places:
#
# - As the commit-msg check (--message-file) of every ship and scout task
#   worktree on every harness: bin/fm-worktree-git-hook.sh runs it on the
#   message git is about to record, so an attributed commit is rejected whoever
#   typed it. This is the harness-neutral enforcement.
# - As a Bash PreToolUse hook in a claude task worker's worktree
#   .claude/settings.local.json (bin/fm-spawn.sh), a supplement that also
#   covers PR titles and bodies written through gh / gh-axi, which no git hook
#   can see.
#
# Claude Code's `attribution` setting (carried on every claude launch by
# bin/fm-spawn.sh) only changes the commit and PR text Claude Code's own
# system prompt asks the model to append; nothing in Claude Code rewrites a
# commit afterwards. A model can still type a `Co-Authored-By: Claude` trailer
# into its own `git commit -m` by habit, and a real worker commit did exactly
# that.
#
# In command mode the guard fires only when a command segment (split at |, &&,
# ||, ;, & and newlines) is itself a git commit, merge, tag, or notes invocation
# (only git's global options may sit between `git` and the verb), a gh /
# gh-axi pr create, edit, comment, review, or merge, or a gh / gh-axi api call
# that writes, and the command carries an attribution pattern, either
# inline or in a message file it passes (git commit -F/--file, gh --body-file/-F,
# gh api -F/--field body=@file). Reading or searching for those patterns
# (`git log | grep Co-Authored-By`, `gh pr view`, a GET `gh api`) is never
# denied, and files named any other
# way, such as by git add or a pathspec, are never read. It never executes,
# sources, or expands the command.
#
# Usage:
#   <Claude PreToolUse JSON on stdin> | bin/fm-attribution-pretool-check.sh
#   bin/fm-attribution-pretool-check.sh --command '<cmd>'
#   bin/fm-attribution-pretool-check.sh --message-file <path>
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2 and the reason, naming each offending line, on stderr, which
#           Claude shows the model and git shows the committer.
# Stdin that jq cannot parse is scanned as raw text for attribution, without the
# writer test, rather than allowed, so a broken transport still refuses an
# attributed commit; empty input allows.
set -u

usage() {
  cat <<'EOF'
Usage: fm-attribution-pretool-check.sh [--command <cmd> | --message-file <path>]

With no option, reads a Claude PreToolUse JSON payload on stdin and checks
tool_input.command.
Exits 2 with the reason on stderr when a command that writes a commit or PR
message carries AI self-attribution (a Co-Authored-By trailer naming an AI,
a "Generated with" line, or a Claude session link), inline or in a message file
it passes, or when --message-file names a commit message that carries it;
exits 0 otherwise.
EOF
}

CMD=
MODE=stdin
MSG_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 64; }
      CMD=$2 MODE=command
      shift 2
      ;;
    --command=*) CMD=${1#--command=} MODE=command; shift ;;
    --message-file)
      [ "$#" -gt 1 ] || { echo "error: --message-file requires a value" >&2; exit 64; }
      MSG_FILE=$2 MODE=message
      shift 2
      ;;
    --message-file=*) MSG_FILE=${1#--message-file=} MODE=message; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

NL=$'\n'
# Matching is on lowercased text, one line at a time, so every pattern below is
# lowercase.
# Claude counts as an AI only as a model or product name, or right before an
# email, a closing quote, or the end of a line.
CLAUDE_AI="claude([[:space:]]*[<(\"']|[[:space:]]+(code|opus|sonnet|haiku|fable)|[[:space:]]*\$)"
# An AI or agent product named in a "Generated with" line, as a whole word.
AI_NAME="(^|[^[:alnum:]])((anthropic|openai|chatgpt|codex|copilot|gemini|devin|cursor ?agent|grok|kimi|opencode|an? ai)([^[:alnum:]]|\$)|${CLAUDE_AI})"
# A Co-Authored-By line credits an AI only with AI context, because most agent
# names are also human names (Claude Dupont, Jean-Claude, Devin Smith, Kimi
# Raikkonen): Claude in the form above as the whole name, a vendor-only name, a
# product or model qualifier, a vendor address, or an agent's bot account.
CO_AUTHOR_AI="(^|[^[:alnum:]])((anthropic|openai|chatgpt|an? ai)([^[:alnum:]]|\$)|codex[[:space:]]+(cli|agent)|gemini[[:space:]]+(cli|code|[0-9])|github[[:space:]]+copilot|copilot[[:space:]]+(agent|chat)|grok[[:space:]]+(cli|code|[0-9])|kimi[[:space:]]+(cli|code|k[0-9])|devin[[:space:]]+ai|opencode[[:space:]]+agent|cursor[[:space:]]?agent)|@(anthropic\\.com|openai\\.com|cursor\\.com|x\\.ai|moonshot\\.(ai|cn)|cognition\\.ai|opencode\\.ai)([^[:alnum:].-]|\$)|(claude|codex|copilot|gemini|devin|cursor|grok|kimi|opencode)[^[:space:]<>@]*\\[bot\\]|\\+copilot@users\\.noreply\\.github\\.com"
# A "Generated with" line counts only in attribution shape: it opens a line or a
# quoted message, after nothing but emoji, whitespace, or markup, so a subject
# like "parse the JSON generated by codex exec" is not attribution.
ATTRIBUTION="co-authored-by:[^[:alnum:]]*${CLAUDE_AI}|co-authored-by:.*(${CO_AUTHOR_AI})|(^|[\"'])[^[:alnum:]]*generated (with|by)[^[:alnum:]]*${AI_NAME}|claude-session:|claude\\.ai/code"
# A command segment that writes commit or PR text: git with only its global
# options before a writing verb, gh / gh-axi (optionally with -R/--repo) pr
# create, edit, comment, review, or merge, or a gh / gh-axi api call, which
# segment_writes admits only when it writes.
GIT_GLOBAL="([[:space:]]+(-[cC]|--git-dir|--work-tree|--namespace|--exec-path|--config-env)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*"
GH_GLOBAL="([[:space:]]+(-r|--repo)[[:space:]]+[^[:space:]]+|[[:space:]]+--repo=[^[:space:]]+)*"
SEGMENT_START="^[[:space:]({]*([[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?"
WRITER="${SEGMENT_START}(git${GIT_GLOBAL}[[:space:]]+(commit|merge|tag|notes)|gh(-axi)?${GH_GLOBAL}[[:space:]]+pr[[:space:]]+(create|edit|comment|review|merge))([[:space:]]|\$)"
GH_API="${SEGMENT_START}gh(-axi)?${GH_GLOBAL}[[:space:]]+api([[:space:]]|\$)"
GH_API_FIELDS="[[:space:]](-f|--field|--raw-field|--input)([[:space:]=]|\$)"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Succeeds when a lowercased command segment writes commit or PR text. A gh api
# call writes when any method it names is not GET, or when it sends fields or
# input without an explicit GET, which is gh's default POST. Methods are read
# only from the segment before its first quote, so quoted body text cannot turn
# a write into a read.
segment_writes() {  # <segment>
  local seg=$1 tok method= get=1 next_is_method=0
  [[ $seg =~ $WRITER ]] && return 0
  [[ $seg =~ $GH_API ]] || return 1
  set -f
  for tok in ${seg%%[\"\']*}; do
    if [ "$next_is_method" -eq 1 ]; then
      method=$tok
      next_is_method=0
    else
      case "$tok" in
        -x|--method) next_is_method=1; continue ;;
        -x?*) method=${tok#-x} ;;
        --method=*) method=${tok#--method=} ;;
        *) continue ;;
      esac
    fi
    if [ "$method" != get ]; then
      set +f
      return 0
    fi
    get=0
  done
  set +f
  [ "$get" -eq 1 ] && [[ $seg =~ $GH_API_FIELDS ]]
}

# Prints each line of <text> that carries attribution; fails when none does.
attribution_lines() {  # <text>
  local text=$1 lo orig found=1
  while IFS= read -r lo <&3 && IFS= read -r orig <&4; do
    if [[ $lo =~ $ATTRIBUTION ]]; then
      printf '  %s\n' "$orig"
      found=0
    fi
  done 3<<<"$(lower "$text")" 4<<<"$text"
  return "$found"
}

# A commit message file up to 256 KiB, without the diff `git commit -v` appends
# below its scissors line.
read_message_file() {  # <path>
  [ -f "$1" ] && [ -r "$1" ] || return 0
  head -c 262144 -- "$1" 2>/dev/null | awk 'index($0, "------------------------ >8 ------------------------") { exit } { print }'
}

deny() {  # <what> <offending-lines>
  cat >&2 <<EOF
Refused: $1 contains AI self-attribution.
Firstmate workers never credit an AI or agent in a commit message, PR title, or PR body: no Co-Authored-By trailer naming an AI, no "Generated with" line, and no session or tool link.
Remove these lines and try again, writing the message the way a human developer would:
$2
EOF
  exit 2
}

if [ "$MODE" = message ]; then
  hits=$(attribution_lines "$(read_message_file "$MSG_FILE")") && deny "this commit message" "$hits"
  exit 0
fi

if [ "$MODE" = stdin ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  if CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null); then
    # Resolve a relative message-file path from where the command runs.
    CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || true)
    [ -z "$CWD" ] || cd -- "$CWD" 2>/dev/null || true
  else
    CMD=$PAYLOAD MODE=raw
  fi
fi
[ -n "$CMD" ] || exit 0

SEGMENTS=$(lower "$CMD")
SEGMENTS=${SEGMENTS//&&/$NL}
SEGMENTS=${SEGMENTS//||/$NL}
SEGMENTS=${SEGMENTS//[|;&]/$NL}
writes=1
[ "$MODE" != raw ] || writes=0
while [ "$writes" -eq 1 ] && IFS= read -r seg; do
  if segment_writes "$seg"; then
    writes=0
    break
  fi
done <<<"$SEGMENTS"
[ "$writes" -eq 0 ] || exit 0

TEXT=$CMD
# Add each message file the command passes, so a message written to a file
# first cannot slip past. Tokens split on whitespace with shell quotes dropped
# and globbing off; `-` (stdin) and missing or unreadable files are skipped.
TOKENS=${CMD//[\"\']/ }
set -f
next_is_file=0
for tok in $TOKENS; do
  file=
  if [ "$next_is_file" -eq 1 ]; then
    file=$tok
    next_is_file=0
  else
    case "$tok" in
      -F|--file|--body-file|--field) next_is_file=1 ;;
      --file=*|--body-file=*|--field=*) file=${tok#*=} ;;
    esac
  fi
  [ -n "$file" ] || continue
  case "$file" in *=@*) file=${file#*=@} ;; *=*) continue ;; @*) file=${file#@} ;; esac
  [ "$file" != - ] || continue
  TEXT="$TEXT$NL$(read_message_file "$file")"
done
set +f

hits=$(attribution_lines "$TEXT") && deny "this command's commit or PR message" "$hits"
exit 0
