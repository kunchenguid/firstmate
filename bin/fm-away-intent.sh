#!/usr/bin/env bash
# fm-away-intent.sh - deterministic operator away/return intent resolution, and
# the non-model caller that turns it into the canonical action.
#
# The gap this closes: "I have to step away for a while" previously reached away
# mode only because a model read AGENTS.md, judged the sentence, and chose to run
# a script. If the model judged differently, nothing happened at all, silently,
# with no record that intent was missed. Here the judgement is a fixed, testable
# pattern set, and the caller can be a harness prompt hook that runs before any
# model turn.
#
# Usage:
#   fm-away-intent.sh classify [--text <t>]     print away | return | none
#   fm-away-intent.sh apply [--text <t>] [--native]
#                                               classify, then run the canonical
#                                               action for that intent
#   fm-away-intent.sh hook --claude             Claude Code UserPromptSubmit
#                                               entrypoint: reads the hook JSON on
#                                               stdin and applies the intent
#   fm-away-intent.sh patterns                  print the matched pattern sets
#
# Text comes from --text, else stdin. `classify` always exits 0; a caller reads
# the printed token, so an unclassifiable message is a normal result and never an
# error.
#
# PRECISION OVER RECALL. This resolver only ever acts on a message whose
# first-person departure or return is explicit. `none` is the safe answer,
# because a `none` changes nothing and the pre-existing paths (`/afk`, running
# the canonical action directly) still work unchanged. Third-person subjects and
# continued phrases ("I'm back to reviewing the diff") never match, and a
# reporting verb anywhere in the message suppresses the whole match, so relaying
# what someone else said is not an activation.
#
# Refusals that come before any pattern match, so no phrasing can bypass them:
#   - operational input (the U+2063 FIRSTMATE_OP prefix or the from-firstmate
#     label): machine traffic, never operator intent;
#   - a message over FM_AWAY_INTENT_MAX_WORDS words (default 60): a departure
#     announcement is short, and a long message is discussing something else;
#   - a message containing a fenced code block: pasted or quoted content;
#   - a message containing a reporting verb (FM_AWAY_REPORTING_RE): the sentence
#     is about someone's statement, not the operator leaving or returning;
#   - a message matching BOTH away and return: ambiguous, so never guessed.
#
# The Claude hook is DEFAULT-OFF and gated three times: the home must contain the
# config/away-intent presence flag, the checkout must be a genuine primary
# firstmate home (never a crewmate's linked task worktree), and the prompt must
# not be operational input. It always exits 0 and never blocks or rewrites a
# prompt; on activation it prints one confirmation line for the transcript.
set -u

FM_AWAY_INTENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-away-lib.sh
. "$FM_AWAY_INTENT_DIR/fm-away-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_AWAY_INTENT_DIR/fm-operational-input.sh"

FM_AWAY_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_AWAY_INTENT_MAX_WORDS="${FM_AWAY_INTENT_MAX_WORDS:-60}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

# Away-intent patterns, matched against normalized text (see normalize).
# Every pattern requires either an explicit first-person subject or a
# start-anchored departure token, so third-person and reported speech never
# match.
FM_AWAY_PATTERNS='
^afk$
^afk (for|until|till|in)
^going afk( |$)
^stepping (away|out)( |$)
(^| )i (have to|need to|gotta|must|will|ll|am going to|m going to|am gonna|m gonna) (step|head) (away|out)( |$)
(^| )i (am|m) (stepping|heading) (away|out)( |$)
(^| )i (am|m|will be|ll be) (afk|away)( |$)
(^| )i (have to|need to|gotta|must) (go|run) afk( |$)
(^| )i (am|m) going afk( |$)
(^| )i (will|ll) be back (later|in|after|around)( |$)
'

# Return-intent patterns. The bare "back" family is deliberately narrow: a
# continuation preposition after it (FM_RETURN_CONTINUATIONS) means the sentence
# is about being back TO something, not about the operator being present again.
FM_RETURN_PATTERNS='
^back$
^back (now|again)( |$)
(^| )i (am|m) back( |$)
(^| )i (have|ve) returned( |$)
'
FM_RETURN_CONTINUATIONS='(^| )i (am|m) back (to|on|at|in|from|with|under|into|onto|by|for|against)( |$)'

# Reporting verbs. Their presence anywhere in the message means the sentence is
# relaying a statement, so no pattern in either set may fire from it.
FM_AWAY_REPORTING_RE='(^| )(said|says|saying|told|telling|tells|asked|asking|wrote|writes|mentioned|mentions|claimed|claims|reported|reports|thinks|thought|quoted|quotes)( |$)'

# Lowercase, then turn every non-alphanumeric BYTE into a space, collapse runs,
# and trim. Byte-wise under LC_ALL=C on purpose: an ASCII apostrophe and a UTF-8
# curly one both fall out as separators, so "I'm", "I m" and "I<U+2019>m" all
# normalize to the same "i m" without a locale-dependent or sed-dialect-dependent
# escape. Pure text transformation; the input is never evaluated by any shell.
normalize() {  # <text>
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9' ' ' \
    | LC_ALL=C tr -s ' ' \
    | LC_ALL=C sed 's/^ //; s/ $//'
}

matches_any() {  # <normalized> <pattern-set>
  local text=$1 patterns=$2 pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    printf '%s' "$text" | LC_ALL=C grep -Eq "$pattern" && return 0
  done <<EOF
$patterns
EOF
  return 1
}

is_operational_input() {  # <raw text>
  case "$1" in
    "$FM_OPERATIONAL_PREFIX"*|*"$FM_OPERATIONAL_PREFIX"*) return 0 ;;
    "$FM_FROMFIRST_LABEL"*) return 0 ;;
  esac
  return 1
}

classify_text() {  # <raw text> -> away | return | none
  local raw=$1 text words away=0 back=0
  if [ -z "$raw" ] || is_operational_input "$raw"; then
    printf 'none'
    return 0
  fi
  case "$raw" in
    *'```'*) printf 'none'; return 0 ;;
  esac
  text=$(normalize "$raw")
  [ -n "$text" ] || { printf 'none'; return 0; }
  words=$(printf '%s' "$text" | wc -w | tr -d ' ')
  if [ "$words" -gt "$FM_AWAY_INTENT_MAX_WORDS" ]; then
    printf 'none'
    return 0
  fi
  if printf '%s' "$text" | LC_ALL=C grep -Eq "$FM_AWAY_REPORTING_RE"; then
    printf 'none'
    return 0
  fi
  matches_any "$text" "$FM_AWAY_PATTERNS" && away=1
  if matches_any "$text" "$FM_RETURN_PATTERNS" \
    && ! printf '%s' "$text" | LC_ALL=C grep -Eq "$FM_RETURN_CONTINUATIONS"; then
    back=1
  fi
  if [ "$away" -eq 1 ] && [ "$back" -eq 1 ]; then
    printf 'none'
  elif [ "$away" -eq 1 ]; then
    printf 'away'
  elif [ "$back" -eq 1 ]; then
    printf 'return'
  else
    printf 'none'
  fi
}

read_text() {  # <--text value or empty>
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    cat
  fi
}

command_classify() {
  local text=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text) shift; text=${1:-} ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  classify_text "$(read_text "$text")"
  printf '\n'
}

command_apply() {
  local text='' native='' intent raw
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text) shift; text=${1:-} ;;
      --native) native=--native ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  raw=$(read_text "$text")
  intent=$(classify_text "$raw")
  case "$intent" in
    away)
      "$FM_AWAY_INTENT_DIR/fm-away-session.sh" start --activation intent \
        --intent "$raw" ${native:+"$native"} >/dev/null || return 1
      printf 'away\n'
      ;;
    return)
      "$FM_AWAY_INTENT_DIR/fm-away-session.sh" return
      return $?
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

# --- Claude Code UserPromptSubmit entrypoint --------------------------------
#
# Always exits 0. A hook that blocked or failed loudly here would put a parser
# in the path of every captain message, which is a far worse failure than
# missing one activation the existing paths still cover.
command_hook() {
  local payload prompt intent
  [ "${1:-}" = --claude ] || { usage >&2; return 2; }
  [ -f "$FM_AWAY_CONFIG/away-intent" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  fm_primary_scope_matches "$FM_ROOT" "$FM_AWAY_STATE" || return 0

  payload=$(cat) || return 0
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null) || return 0
  [ -n "$prompt" ] || return 0

  intent=$(classify_text "$prompt")
  case "$intent" in
    away)
      if "$FM_AWAY_INTENT_DIR/fm-away-session.sh" start --activation prompt-hook \
        --intent "$prompt" >/dev/null 2>&1; then
        printf 'Away mode is active. Authorized work continues; only genuine operator decisions wait for your return.\n'
      fi
      ;;
    return)
      if "$FM_AWAY_INTENT_DIR/fm-away-session.sh" return --no-report >/dev/null 2>&1; then
        printf 'Away mode ended; the return catch-up gate is clear.\n'
      fi
      ;;
  esac
  return 0
}

# fm_primary_scope_matches lives in the shared hook predicate library; source it
# only for the hook path so the pure classifier stays dependency-free.
if [ "${1:-}" = hook ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$FM_AWAY_INTENT_DIR/fm-primary-scope-lib.sh"
fi

case "${1:-}" in
  classify) shift; command_classify "$@" ;;
  apply) shift; command_apply "$@" ;;
  hook) shift; command_hook "$@" ;;
  patterns) printf 'away:%s\nreturn:%s\nreturn-continuation:\n%s\n' \
    "$FM_AWAY_PATTERNS" "$FM_RETURN_PATTERNS" "$FM_RETURN_CONTINUATIONS" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
