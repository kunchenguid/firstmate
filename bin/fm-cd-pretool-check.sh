#!/usr/bin/env bash
# Stable PreToolUse transport for the cd-guard command policy.
#
# A stray persistent top-level `cd projects/<clone>` in the PRIMARY firstmate
# shell silently relocates the shell, so a later firstmate-owned command (a
# backlog write, an fm-* lifecycle call, tasks-axi) runs inside a project clone
# instead of the home. This seatbelt denies such a command before it runs.
# bin/fm-cd-command-policy.mjs is the sole owner of the block/allow decision; it
# reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only scopes the guard to the real primary checkout, acquires the
# harness payload, invokes that policy, and renders the established harness
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/cd-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-cd-pretool-check.sh
#   bin/fm-cd-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude, Codex, and Cursor. CLI mode is used by OpenCode and Pi after their
# adapters extract the exact command string. --cursor selects Cursor's own deny
# rendering and marks this invocation as the Cursor registration rather than the
# Claude-settings duplicate Cursor also loads.
#
# Exit/output contract (docs/arm-pretool-check.md owns the JSON documents):
#   ALLOW, no flag - exit 0 and no output.
#   ALLOW, --cursor or --claude - exit 0 and one JSON document on stdout.
#   DENY, no flag - exit 2, the stderr deny object, and the Grok stdout object.
#   DENY, --cursor or --claude - exit 0 and one JSON document on stdout.
#   INERT - not the real primary checkout: the allow rendering for the mode.
#   FAIL OPEN - the allow rendering for the selected mode.
#
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor blocks a permission hook whose stdout is not JSON.
set -u

CMD=""
CMD_SET=0
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
Usage: fm-cd-pretool-check.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Fires only in the real primary firstmate checkout. Outside that checkout,
including a crewmate or scout task worktree, it uses the allow rendering
and never denies.
Exits 0 to allow a command, and exits 2 to deny one when no mode flag is set.
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
fi

[ -n "$CMD" ] || fm_hook_allow

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes that the classifier joins within a shell word
# before looking for cd/pushd/popd, so ordinary quoted or escaped fragments
# cannot hide a deniable cwd change from the policy owner. A quoting-decoder
# marker - a $ immediately followed by a
# single quote (ANSI-C $'...') or a double quote (bash locale $"...") - delegates
# too, because the classifier decodes those and can reconstruct cd from bytes
# this substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset. Deliberate deeper obfuscation is
# out of scope by the same agent-mistake threat model the policy uses.
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
      *cd*|*pushd*|*popd*) ;;
      *) fm_hook_allow ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || fm_hook_allow
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || fm_hook_allow

# Scope to a plain, non-worktree firstmate checkout, where git-dir equals
# git-common-dir. A crewmate/scout task worktree - the shape bin/fm-spawn.sh
# always hands out - is a linked git worktree where the two differ. This guard
# does not inspect .fm-secondmate-home, so it applies in a git-cloned secondmate
# home but remains inert when the secondmate home is itself a treehouse-leased
# linked worktree. docs/cd-guard.md owns this scope; docs/turnend-guard.md owns
# the turn-end guard's separate marker-aware scope. Any failure to confirm the
# checkout is inert (exit 0), never a block, so a broken environment never
# denies a shell command.
[ -f "$FM_ROOT/AGENTS.md" ] || fm_hook_allow
[ -d "$FM_ROOT/bin" ] || fm_hook_allow
command -v git >/dev/null 2>&1 || fm_hook_allow
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || fm_hook_allow
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || fm_hook_allow
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || fm_hook_allow

POLICY="$FM_ROOT/bin/fm-cd-command-policy.mjs"
command -v node >/dev/null 2>&1 || fm_hook_allow
[ -f "$POLICY" ] || fm_hook_allow

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || fm_hook_allow
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
