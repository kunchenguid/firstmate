#!/usr/bin/env bash
# Droid PreToolUse guard for interactive approval questions during away mode.
#
# `.factory/settings.json` invokes this command only for Droid's exact AskUser
# tool.  While the durable away flag exists, the call is denied rather than
# answered, and every attempted question is first filed with the owner that
# already holds its decision.  Removing the flag through bin/fm-afk-return.sh
# restores AskUser with no saved answer or widened authority.
#
# OWNERSHIP COMES FROM THE CALLER, NEVER FROM PROSE.
# Native AskUser exposes one freeform questionnaire string and no typed owner
# field, so each numbered question block must carry its own binding line:
#
#   [firstmate-decision origin=<origin-slug> key=<decision-key> state=existing]
#   [firstmate-decision origin=<origin-slug> key=derive state=unseeded]
#
# `[topic]` is descriptive UI text and is never an owner, so a questionnaire may
# combine several origins and may omit topics entirely.  A block whose binding is
# missing or malformed is REJECTED with an error naming the missing requirement:
# it is never filed by inference from a topic, session, working directory, or
# question text, and never written to a synthetic ledger.  `key=derive` asks the
# guard for a stable identity computed from the origin, the question text, and
# the ordered option texts, so an exact replay keeps one identity while a
# substantively different question receives another.
#
# Filing itself belongs to bin/fm-decision-hold.sh, which owns the ordered
# resolution across the captain-hold and status-decision owners and their
# existing close paths.  This guard parses, validates, and denies; it creates no
# question queue, no parallel ledger, and no closing mechanism.  It is inert in
# linked task worktrees and non-Firstmate repositories through the shared
# primary-scope predicate.
#
# Usage:
#   <Droid AskUser PreToolUse JSON on stdin> | fm-droid-afk-askuser-check.sh
#
# Exit/output contract:
#   ALLOW - exit 0 and no output when AFK is inactive or scope is not a primary.
#   DENY  - exit 2, stdout empty, and a Droid-compatible deny object on stderr.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
LOCK="$STATE/.afk-return-catchup.lock"

DEFERRAL='This AskUser call is denied, not answered. Do not retry it or ask the captain in plain text while away mode is active; continue every independently authorized action, and present the outstanding question only after a real unmarked captain message has completed bin/fm-afk-return.sh. An operationally prefixed input is not the captain returning, and away mode grants no additional approval, merge, destructive, irreversible, or security authority.'

deny() {  # <reason>
  local escaped
  escaped=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$STATE/.afk" ] || exit 0
PAYLOAD=$(cat)

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# The identity for `key=derive`: origin, question text, and ordered option texts,
# each NUL-terminated. The descriptive topic and the binding line are excluded, so
# retitling a topic cannot fork one decision into two.
derive_key() {  # <origin> <block-file>
  local origin=$1 block=$2 digest
  digest=$({
    printf '%s\0' "$origin"
    sed -n 's/^\([0-9]*\.[[:space:]]*\)\{0,1\}\[question\][[:space:]]*\(.*\)$/\2/p' "$block" \
      | head -1 | tr -d '\n'
    printf '\0'
    sed -n 's/^\[option\][[:space:]]*\(.*\)$/\1/p' "$block" \
      | while IFS= read -r option; do printf '%s\0' "$option"; done
  } | sha256_stdin)
  printf 'droid-askuser-%s' "$digest"
}

QUESTIONNAIRE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.questionnaire // empty' 2>/dev/null) || QUESTIONNAIRE=
[ -n "$QUESTIONNAIRE" ] \
  || deny "[afk-approval-deferral] away mode is active and this AskUser call carries no questionnaire to file with a decision owner. $DEFERRAL"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-afk.XXXXXX") \
  || deny "[afk-approval-deferral] away mode is active but the attempted question could not be staged for its decision owner. $DEFERRAL"
trap 'rm -rf "$WORK"' EXIT

# Numbered blocks are the unit of ownership, because one questionnaire may combine
# several origins. An unnumbered questionnaire is one block.
printf '%s\n' "$QUESTIONNAIRE" | LC_ALL=C awk -v dir="$WORK" '
  /^[0-9]+\.[[:space:]]/ { n++ }
  { if (n == 0) n = 1; printf "%s\n", $0 >> sprintf("%s/block.%03d", dir, n) }
'

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_lock_acquire_wait "$LOCK" \
  || deny "[afk-approval-deferral] away mode is active but the attempted question could not reach its decision owner while a return was in progress. $DEFERRAL"
if [ ! -e "$STATE/.afk" ]; then
  fm_lock_release "$LOCK"
  exit 0
fi

REJECTED=''
FILED=''
FAULT=''
INDEX=0
for BLOCK in "$WORK"/block.*; do
  [ -f "$BLOCK" ] || continue
  # Text before the first numbered block is preamble, not a question, so it is
  # skipped rather than rejected for carrying no binding.
  grep -q '\[question\]\|^\[firstmate-decision[[:space:]]' "$BLOCK" || continue
  INDEX=$((INDEX + 1))
  BINDING_CANDIDATES=$(grep -c '^\[firstmate-decision' "$BLOCK" || true)
  if [ "$BINDING_CANDIDATES" -ne 1 ]; then
    if [ "$BINDING_CANDIDATES" -eq 0 ]; then
      REJECTED="${REJECTED}question $INDEX has no [firstmate-decision origin=<origin> key=<key|derive> state=existing|unseeded] line; "
    else
      REJECTED="${REJECTED}question $INDEX has multiple [firstmate-decision] candidate lines; require exactly one origin=, one key=, and one state= field with no extra tokens; "
    fi
    continue
  fi
  BINDING=$(sed -n 's/^\[firstmate-decision[[:space:]]\{1,\}\(.*\)\]$/\1/p' "$BLOCK")
  if [ -z "$BINDING" ]; then
    REJECTED="${REJECTED}question $INDEX has a malformed [firstmate-decision] line; require exactly one origin=, one key=, and one state= field with no extra tokens; "
    continue
  fi
  if [ "$(printf '%s\n' "$BINDING" | wc -l | tr -d ' ')" -ne 1 ]; then
    REJECTED="${REJECTED}question $INDEX has multiple [firstmate-decision] lines; require exactly one origin=, one key=, and one state= field with no extra tokens; "
    continue
  fi
  ORIGIN=''
  KEY=''
  BSTATE=''
  ORIGIN_COUNT=0
  KEY_COUNT=0
  STATE_COUNT=0
  EXTRA_COUNT=0
  read -r -a BINDING_FIELDS <<< "$BINDING"
  for FIELD in "${BINDING_FIELDS[@]}"; do
    case "$FIELD" in
      origin=*) ORIGIN_COUNT=$((ORIGIN_COUNT + 1)); ORIGIN=${FIELD#origin=} ;;
      key=*) KEY_COUNT=$((KEY_COUNT + 1)); KEY=${FIELD#key=} ;;
      state=*) STATE_COUNT=$((STATE_COUNT + 1)); BSTATE=${FIELD#state=} ;;
      *) EXTRA_COUNT=$((EXTRA_COUNT + 1)) ;;
    esac
  done
  if [ "$ORIGIN_COUNT" -eq 0 ]; then
    REJECTED="${REJECTED}question $INDEX has no valid origin= slug in its [firstmate-decision] line; "
    continue
  fi
  if [ "$KEY_COUNT" -eq 0 ]; then
    REJECTED="${REJECTED}question $INDEX has no valid key= slug or key=derive in its [firstmate-decision] line; "
    continue
  fi
  if [ "$STATE_COUNT" -eq 0 ]; then
    REJECTED="${REJECTED}question $INDEX has no state=existing or state=unseeded in its [firstmate-decision] line; "
    continue
  fi
  if [ "${#BINDING_FIELDS[@]}" -ne 3 ] || [ "$ORIGIN_COUNT" -ne 1 ] \
      || [ "$KEY_COUNT" -ne 1 ] || [ "$STATE_COUNT" -ne 1 ] || [ "$EXTRA_COUNT" -ne 0 ]; then
    REJECTED="${REJECTED}question $INDEX has a malformed [firstmate-decision] line; require exactly one origin=, one key=, and one state= field with no extra tokens; "
    continue
  fi
  case "$ORIGIN" in
    ''|*[!A-Za-z0-9._-]*)
      REJECTED="${REJECTED}question $INDEX has no valid origin= slug in its [firstmate-decision] line; "
      continue ;;
  esac
  case "$KEY" in
    ''|*[!A-Za-z0-9._-]*)
      REJECTED="${REJECTED}question $INDEX has no valid key= slug or key=derive in its [firstmate-decision] line; "
      continue ;;
  esac
  case "$BSTATE" in
    existing|unseeded) ;;
    *)
      REJECTED="${REJECTED}question $INDEX has no state=existing or state=unseeded in its [firstmate-decision] line; "
      continue ;;
  esac

  QUESTION="$WORK/question.$INDEX"
  grep -v '^\[firstmate-decision[[:space:]]' "$BLOCK" > "$QUESTION" || true
  [ -s "$QUESTION" ] || {
    REJECTED="${REJECTED}question $INDEX carries a binding line and no question text; "
    continue
  }
  [ "$KEY" != derive ] || KEY=$(derive_key "$ORIGIN" "$QUESTION")

  if OWNER=$("$SCRIPT_DIR/fm-decision-hold.sh" preserve-question "$ORIGIN" "$KEY" \
      --state "$BSTATE" --question-file "$QUESTION" 2>"$WORK/err.$INDEX"); then
    FILED="${FILED}question $INDEX ${OWNER#preserved: }; "
  else
    FAULT="${FAULT}question $INDEX could not be filed: $(tr '\n' ' ' < "$WORK/err.$INDEX"); "
  fi
done

fm_lock_release "$LOCK"

REASON="[afk-approval-deferral] away mode is active."
[ -z "$FILED" ] || REASON="$REASON Preserved for the captain's return: ${FILED}"
[ -z "$REJECTED" ] || REASON="$REASON CONTRACT VIOLATION, not filed: ${REJECTED}Re-attempt each rejected question with its authoritative owner binding."
[ -z "$FAULT" ] || REASON="$REASON OWNER FAULT, not filed: ${FAULT}Treat this as an implementation fault, not permission to proceed."
deny "$REASON $DEFERRAL"
