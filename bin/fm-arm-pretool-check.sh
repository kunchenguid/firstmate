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
# Exit/output contract (docs/arm-pretool-check.md owns the JSON documents):
#   ALLOW, no flag - exit 0 and no output.
#   ALLOW, --cursor or --claude - exit 0 and one JSON document on stdout.
#   DENY, no flag - exit 2, the stderr deny object, and the Grok stdout object.
#   DENY, --cursor or --claude - exit 0 and one JSON document on stdout.
#   FAIL OPEN - the allow rendering for the selected mode.
#
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor blocks a permission hook whose stdout is not JSON.
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0
CURSOR_MODE=0

# Resolve beside this file with builtins only. A missing-jq fail-open must
# still reach fm_hook_allow when the hook PATH has no dirname.
_fm_hook_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_hook_dir" != "${BASH_SOURCE[0]}" ] || _fm_hook_dir=.
# shellcheck source=bin/fm-hook-host-lib.sh
. "$_fm_hook_dir/fm-hook-host-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow.
With no mode flag, a deny exits 2: the reason is on stderr and a Grok
decision object is on stdout.
With --claude or --cursor, allow and deny both exit 0 and print one JSON
document on stdout. docs/arm-pretool-check.md owns those documents.
Malformed transport and an unavailable classifier runtime fail open through
the same allow rendering.
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
  [ -n "$PAYLOAD" ] || fm_hook_allow
  command -v jq >/dev/null 2>&1 || fm_hook_allow
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    fm_hook_allow
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || fm_hook_allow
  [ -n "$CMD" ] || fm_hook_allow
  # Kept for transport parity only.
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || fm_hook_allow

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
      *) fm_hook_allow ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || fm_hook_allow
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || fm_hook_allow
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || fm_hook_allow
[ -f "$POLICY" ] || fm_hook_allow

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || fm_hook_allow
[ -n "$POLICY_OUTPUT" ] || fm_hook_allow

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || fm_hook_allow
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || fm_hook_allow
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || fm_hook_allow

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
fm_hook_deny "$ESCAPED"
