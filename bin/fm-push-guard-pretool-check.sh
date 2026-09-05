#!/usr/bin/env bash
# Stable PreToolUse transport for the push-guard command policy.
#
# 2026-09-04 firstmate pushed two configuration commits straight to a project's
# main from a scratch clone, without the pipeline that would have caught the
# regression; each turned that project's main red. GitHub branch protection
# needs a paid plan the captain declined, so this seatbelt denies a direct
# `git push` to `main` or `master` on any remote before it runs.
# bin/fm-push-guard-command-policy.mjs is the sole owner of the block/allow
# decision for everything text alone can settle; it reuses the shell classifier
# owned by bin/fm-arm-command-policy.mjs. This wrapper acquires the harness
# payload, invokes that policy, resolves the one case text cannot settle (a
# bare `git push` with no repository/refspec, which pushes the current branch),
# and renders the established harness responses. It never executes, sources,
# evaluates, or expands the SUBMITTED command; the one `git` invocation it runs
# itself queries real, already-committed repository state (the current branch),
# the same trust boundary bin/fm-cd-pretool-check.sh uses to scope itself.
# See docs/push-guard.md for the complete contract, and docs/cd-guard.md for
# the sibling family this guard belongs to.
#
# Unlike bin/fm-cd-pretool-check.sh, this guard is NOT scoped to the primary
# firstmate checkout: for Claude, it fires against a `git push` from any
# working directory, in any git repository, because a direct push to a
# project's main is unsafe regardless of which checkout the primary session's
# shell has wandered into. Codex's own registration re-resolves this script's
# path from the session's tracked cwd on every call (the same mechanism its
# sibling guards already use there), so under Codex this guard's reach is
# bounded to sessions whose cwd is still the firstmate checkout root - a
# documented per-harness difference, not a bug; see docs/push-guard.md. It is
# registered only for Claude and Codex (see the COMMON RULES this hook was
# built under); Grok, OpenCode, Pi, and Cursor have no registration for this
# guard and are a documented vendor gap, not a silent omission.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-push-guard-pretool-check.sh [--claude]
#   bin/fm-push-guard-pretool-check.sh --command '<cmd>' [--claude]
#
# Stdin mode extracts .tool_input.command, the shape both Claude and Codex
# deliver (docs/cd-guard.md's transport table). CLI mode is for direct testing.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a
#          Codex-compatible duplicate on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or the policy owner, or an invalid policy
#               response. A branch check that cannot determine the current
#               branch (not a git repository, detached HEAD, missing git) also
#               fails open: this guard denies known main/master targets, not
#               every ambiguous repository state.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-push-guard-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin
(Claude/Codex tool_input.command).
Not scoped to the primary firstmate checkout: fires against a git push from
any working directory, in any git repository.
Exits 0 to allow and 2 to deny a direct `git push` to main or master on any
remote.
The deny reason is written to stderr, with a duplicate decision object on
stdout unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open, as does a
bare `git push` whose current branch cannot be determined.
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
  SCRIPT_DIR_EARLY=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR_EARLY/fm-hook-host-lib.sh"
  # This guard is registered only for Claude and Codex, both of which deliver
  # .tool_input.command. A payload stamped by a foreign host (Cursor loads the
  # tracked Claude-settings entry in addition to its own registration) must not
  # be double-evaluated here; see bin/fm-hook-host-lib.sh.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every case this guard denies is a `git push` invocation, so any
# command whose text carries no "push" substring is fast-allowed before paying
# for the Node process. This is coupled to the classifier: it looks for `push`
# anywhere (including inside a subshell, substitution, or eval payload) because
# the policy owner recurses into all of those, so a strict-superset prefilter
# cannot filter on `git` too without risking a false allow through an aliased
# or path-qualified git invocation whose word is not literally "git".
case "$CMD" in
  *push*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
POLICY="$SCRIPT_DIR/fm-push-guard-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

emit_deny() {  # <code> <reason>
  local code=$1 reason=$2 detail escaped
  detail="[$code] $reason"
  escaped=$(json_escape "$detail")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ "$DECISION" = "deny" ]; then
  REST=${POLICY_OUTPUT#*"$TAB"}
  [ "$REST" != "$POLICY_OUTPUT" ] || exit 0
  CODE=${REST%%"$TAB"*}
  REASON=${REST#*"$TAB"}
  [ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0
  emit_deny "$CODE" "$REASON"
fi

if [ "$DECISION" = "check-branch" ]; then
  REST=${POLICY_OUTPUT#*"$TAB"}
  DIR=$REST
  [ "$REST" != "$POLICY_OUTPUT" ] || DIR=""
  EFFECTIVE_DIR=$DIR
  [ -n "$EFFECTIVE_DIR" ] || EFFECTIVE_DIR=$(pwd -P) || exit 0
  command -v git >/dev/null 2>&1 || exit 0
  # Real, already-committed repository state - never a byte of the submitted
  # command - the same trust boundary bin/fm-cd-pretool-check.sh's own
  # git -C "$FM_ROOT" scoping calls rely on.
  BRANCH=$(git -C "$EFFECTIVE_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0
  [ -n "$BRANCH" ] || exit 0
  case "$BRANCH" in
    main|master)
      emit_deny "protected-branch-push" "a direct git push to main or master is blocked; land it through a PR so CI proves it before main - use bin/fm-pr-merge.sh or bin/fm-merge-local.sh."
      ;;
    *) exit 0 ;;
  esac
fi

exit 0
