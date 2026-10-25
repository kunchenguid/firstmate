#!/usr/bin/env bash
# PreToolUse hook for the supervisor-work guard. It stops a firstmate SUPERVISOR
# session from doing a worker's job: driving a crew-owned no-mistakes run,
# sleeping inside a turn, or (a secondmate lead) typing into a pane.
# install.sh copies this file, the policy and the decider into one data dir and
# writes that dir's ./home file, the Firstmate home the hook is registered for.
# The scope predicate and the shell lexer come from that home's checkout.
# Fails open: anything unknown is an allow, and a missing piece says so on stderr.
set -u

DEST=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0

command -v jq >/dev/null 2>&1 || { echo "fm-supervisor-work: jq missing, guard off" >&2; exit 0; }
[ -s "$DEST/home" ] || { echo "fm-supervisor-work: no home file, guard off" >&2; exit 0; }

PAYLOAD=$(cat)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
SESSION_CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null) || SESSION_CWD=""

# A command that names none of these cannot match the policy, so node is skipped.
# ANSI-C and locale quoting can spell a word in escapes, so those always reach node.
ESCAPED_QUOTE=0
case $CMD in *'$'\'*|*'$"'*) ESCAPED_QUOTE=1 ;; esac
if ((ESCAPED_QUOTE == 0)); then
  PLAIN=${CMD//[\"\'\\]/}
  PLAIN=${PLAIN//$'\n'/}
  case $PLAIN in *no-mistakes*|*sleep*|*herdr*|*tmux*) ;; *) exit 0 ;; esac
fi

# Scope: only the session that runs in the registered home is judged. A linked
# worktree of that home, or any other repo, is a worker and stays untouched.
SESSION=${CLAUDE_PROJECT_DIR:-}
[ -n "$SESSION" ] || SESSION=$(git -C "${SESSION_CWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || exit 0
SESSION=$(CDPATH='' cd -- "$SESSION" 2>/dev/null && pwd -P) || exit 0
FMH=
while IFS= read -r HOME_PATH; do
  [ -n "$HOME_PATH" ] && [ "$SESSION" = "$HOME_PATH" ] && { FMH=$HOME_PATH; break; }
done < "$DEST/home"
[ -n "$FMH" ] || exit 0
. "$FMH/bin/fm-primary-scope-lib.sh" 2>/dev/null || { echo "fm-supervisor-work: scope lib missing, guard off" >&2; exit 0; }
fm_primary_scope_matches "$FMH" "$FMH/state" || exit 0

ARGS=()
fm_root_is_secondmate_home "$FMH" && ARGS+=(--secondmate)
VERDICT=$(node "$DEST/fm-supervisor-work-decide.mjs" --lexer "$FMH/bin/fm-arm-command-policy.mjs" \
  "${ARGS[@]+"${ARGS[@]}"}" --command "$CMD" 2>/dev/null) \
  || { echo "fm-supervisor-work: policy could not run, allowing" >&2; exit 0; }

IFS=$'\t' read -r KIND CODE REASON <<< "$VERDICT"
[ "$KIND" = deny ] || exit 0
MESSAGE="[$CODE] $REASON"
jq -nc --arg m "$MESSAGE" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny"}, systemMessage: $m}' >&2
exit 2
