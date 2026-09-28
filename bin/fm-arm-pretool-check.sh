#!/usr/bin/env bash
# Stable PreToolUse transport for the watcher-arm command policy.
#
# A firstmate primary must arm the watcher or run a Codex checkpoint as a
# standalone verified harness call.
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
#   ALLOW - exit 0, with {"permission":"allow"} on stdout for Cursor
#           (--cursor or a Cursor-payload duplicate), otherwise no output.
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

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=bin/fm-hook-host-lib.sh
. "$HOOK_DIR/fm-hook-host-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, both allow and deny return a Cursor permission object on stdout
and exit 0. A Cursor-payload duplicate also returns a Cursor allow object.
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
  [ -n "$PAYLOAD" ] || fm_hook_allow "$CURSOR_MODE"
  command -v jq >/dev/null 2>&1 || fm_hook_allow "$CURSOR_MODE"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    fm_hook_allow 1
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || fm_hook_allow "$CURSOR_MODE"
  [ -n "$CMD" ] || fm_hook_allow "$CURSOR_MODE"
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || fm_hook_allow "$CURSOR_MODE"

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# fm-watch byte sequence AFTER the classifier's byte normalization, so a command
# that cannot contain fm-watch even after that normalization can never be a
# deniable watcher command and is fast-allowed without the Node policy owner.
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
      *fm-watch*) ;;
      *) fm_hook_allow "$CURSOR_MODE" ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || fm_hook_allow "$CURSOR_MODE"
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || fm_hook_allow "$CURSOR_MODE"
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || fm_hook_allow "$CURSOR_MODE"
[ -f "$POLICY" ] || fm_hook_allow "$CURSOR_MODE"

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || fm_hook_allow "$CURSOR_MODE"
[ -n "$POLICY_OUTPUT" ] || fm_hook_allow "$CURSOR_MODE"

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || fm_hook_allow "$CURSOR_MODE"
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || fm_hook_allow "$CURSOR_MODE"
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || fm_hook_allow "$CURSOR_MODE"

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
