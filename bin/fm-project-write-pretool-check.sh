#!/usr/bin/env bash
# Stable PreToolUse transport for the primary-session project-write guard.
#
# bin/fm-project-write-command-policy.mjs owns command and file-tool decisions;
# it reuses the shell classifier exported by bin/fm-arm-command-policy.mjs.
# This wrapper scopes enforcement to a plain firstmate primary checkout, invokes
# the policy, and renders each harness's deny response. See
# docs/project-write-guard.md for the full contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-project-write-pretool-check.sh
#   bin/fm-project-write-pretool-check.sh --command '<cmd>'
#
# Stdin accepts shell and file-tool payloads from Claude, Codex, Grok, Cursor,
# Pi, omp, and OpenCode. --cursor selects Cursor's returned decision object;
# --claude suppresses stdout on deny as required by Claude Code.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-project-write-pretool-check.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse JSON payload on stdin. It blocks shell
writes and native file edits aimed at projects/ or recorded worker copies, and
is inert outside a plain firstmate primary checkout.
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
    --cursor)
      CURSOR_MODE=1
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

PAYLOAD=""
if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/fm-hook-host-lib.sh"
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
FM_STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# A linked worktree is the disposable worker/scout shape and is intentionally
# inert. The primary and Pi supervision branch run against the plain checkout.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

POLICY="$FM_ROOT/bin/fm-project-write-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

if [ "$CMD_SET" -eq 1 ]; then
  POLICY_OUTPUT=$(node "$POLICY" --root "$FM_ROOT" --home "$FM_HOME" --state "$FM_STATE" --cwd "${PWD:-$FM_HOME}" --command "$CMD" 2>/dev/null) || exit 0
else
  POLICY_OUTPUT=$(printf '%s' "$PAYLOAD" | node "$POLICY" --root "$FM_ROOT" --home "$FM_HOME" --state "$FM_STATE" --cwd "${PWD:-$FM_HOME}" --payload-stdin 2>/dev/null) || exit 0
fi
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || exit 0
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
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
