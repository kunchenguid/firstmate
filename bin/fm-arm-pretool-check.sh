#!/usr/bin/env bash
# Stable PreToolUse transport for primary shell-command safety.
#
# A firstmate primary must leave worker-owned no-mistakes runs with their worker,
# and must arm the watcher or run a Codex checkpoint as a standalone verified
# harness call.
# bin/fm-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# This wrapper only acquires the harness payload, discovers the active roots,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh
#   bin/fm-arm-pretool-check.sh --command '<cmd>' [--background true|false]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. Cursor delivers the same .tool_input.command shape with
# tool_name "Shell" (verified live, cursor-agent 2026.08.11-e8db854), so it needs
# no new extraction - only --cursor, which selects Cursor's own deny rendering
# and marks this invocation as the Cursor registration rather than the
# Claude-settings duplicate Cursor also loads.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# command string.
# --background remains accepted for compatibility, but harness-native tracked
# background execution is not itself a policy signal.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status, and only that
#          rendering is verified to block the command and surface the reason.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
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
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
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

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# fm-watch byte sequence, and every primary pipeline drive resolves to the
# no-mistakes byte sequence, AFTER the classifier's byte normalization.
# A command that cannot contain either sequence can never be denied and is
# fast-allowed without the Node policy owner.
# We mirror the classifier's cheapest byte transforms here (drop line-
# continuation and escape backslashes, quotes, and newlines) so obfuscated
# protected paths such as fm-watc\<newline>h-arm.sh or fm-"watch"-arm.sh still
# delegate. Stripping only these non-alphanumeric bytes can never destroy an
# existing fm-watch run.
#
# The fast path may allow ONLY when BOTH hold: (a) the stripped/normalized text
# lacks the fm-watch watcher substring, AND (b) the raw command carries no
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"..."), both of which the classifier
# decodes and can therefore reconstruct fm-watch from bytes this cheap byte
# strip cannot. This marker set is COUPLED to the classifier's decoder set in
# bin/fm-arm-command-policy.mjs: adding any new quote/expansion form the
# classifier decodes REQUIRES extending this marker set in the same change, or
# the prefilter stops being a strict superset. Otherwise the command always
# delegates to the classifier - the single owner of every decision. Any deeper
# decode-required obfuscation stays the classifier's and the post-arm liveness
# guards' responsibility.
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
      *fm-watch*|*no-mistakes*|*sh\ *) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
ACTIVE_STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"
PRIMARY_SCOPE=false
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0

canonical_git_dir() {
  local base=$1 path=$2
  case "$path" in /*) ;; *) path="$base/$path" ;; esac
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)
}

meta_exact_value() {
  local meta=$1 key=$2
  awk -v key="$key" '
    index($0, key "=") == 1 { count++; value=substr($0, length(key) + 2) }
    END { if (count == 1) print value; else exit 1 }
  ' "$meta" 2>/dev/null
}

linked_checkout_has_task_owner() {
  local root=$1 git_dir common_dir common_abs owner candidate candidate_git meta kind worktree resolved
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  git_dir=$(canonical_git_dir "$root" "$git_dir") || return 1
  common_abs=$(canonical_git_dir "$root" "$common_dir") || return 1
  [ "$git_dir" != "$common_abs" ] || return 1
  owner=$(git -C "$root" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        candidate=${line#worktree }
        candidate_git=$(git -C "$candidate" rev-parse --git-dir 2>/dev/null) || continue
        candidate_git=$(canonical_git_dir "$candidate" "$candidate_git") || continue
        if [ "$candidate_git" = "$common_abs" ]; then
          (CDPATH='' cd -- "$candidate" 2>/dev/null && pwd -P)
          break
        fi
        ;;
    esac
  done)
  [ -n "$owner" ] || return 1
  root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 1
  for meta in "$owner/state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(meta_exact_value "$meta" kind) || continue
    case "$kind" in ship|scout) ;; *) continue ;; esac
    worktree=$(meta_exact_value "$meta" worktree) || continue
    resolved=$(canonical_git_dir "$owner" "$worktree") || continue
    [ "$resolved" = "$root" ] && return 0
  done
  return 1
}

if fm_primary_scope_matches "$ROOT" "$ACTIVE_STATE"; then
  PRIMARY_SCOPE=true
  GIT_DIR=$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null || true)
  GIT_COMMON_DIR=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)
  GIT_DIR=$(canonical_git_dir "$ROOT" "$GIT_DIR" 2>/dev/null || true)
  GIT_COMMON_DIR=$(canonical_git_dir "$ROOT" "$GIT_COMMON_DIR" 2>/dev/null || true)
  if [ -n "$GIT_DIR" ] && [ -n "$GIT_COMMON_DIR" ] && \
     [ "$GIT_DIR" != "$GIT_COMMON_DIR" ] && linked_checkout_has_task_owner "$ROOT"; then
    PRIMARY_SCOPE=false
  fi
fi

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" --primary "$PRIMARY_SCOPE" 2>/dev/null) || exit 0
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
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
