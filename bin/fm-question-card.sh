#!/usr/bin/env bash
# fm-question-card.sh - post the board card for a question to the owner, then
# print its key so the reply can cite it.
#
# Usage:
#   fm-question-card.sh post --ask-ref <ref> --title "<one question>" [sign-off-axi raise flags...]
#   fm-question-card.sh post --board <decisions.json> ... (the same flags)
#   fm-question-card.sh keys
#
# The owner's rule (2026-10-25): "if you ask questions as well make sure they
# are posted, posting questions will be stricter way of working". A question to
# him must exist as a board card, and a chat-only question is a violation.
# bin/fm-turnend-guard.sh flags a reply that ends in a question while no open
# card is cited, and its banner points here.
#
# post   Post the question through sign-off-axi (this command re-implements none
#        of its question standard, options, outcomes or board rules - pass its
#        own flags through: --why, --outcome yes=..., --recommend, --default,
#        --option, --silent-by, --filer, ...), then print the card key alone on
#        stdout. Everything sign-off-axi prints goes to stderr. It refuses
#        without --title and --ask-ref, because a new Decide card needs both.
#        When the identical question is already open under a key, that key is
#        printed instead of posting a second card.
# keys   Print the key of every card still open on the board.
#
# The board is the one sign-off-axi reads: the explicit --board file, else the
# board sign-off-axi's own walk finds. Nothing here stores a private copy.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-question-lib.sh
. "$SCRIPT_DIR/fm-question-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-question-card: %s\n' "$1" >&2; exit 1; }

require_signoff() {
  fm_question_signoff_available \
    || die "sign-off-axi is not on PATH; install it from https://github.com/umeranjum17/sign-off"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the board"
}

# Split --board out of the pass-through arguments: sign-off-axi takes the board
# file as its positional argument, before every flag.
split_board() {
  BOARD=''
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)
        shift
        [ $# -gt 0 ] || die "--board needs a value"
        BOARD=$1
        ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

has_flag() {  # <flag>  -> 0 when the remaining arguments carry it
  local want=$1 arg
  for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    [ "$arg" = "$want" ] && return 0
  done
  return 1
}

flag_value() {  # <flag> -> the value that follows it
  local want=$1 i=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    if [ "${ARGS[$i]}" = "$want" ]; then
      printf '%s\n' "${ARGS[$((i + 1))]:-}"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

cmd_post() {
  local title ask_ref before after key board out rc=0
  split_board "$@"
  require_signoff
  title=$(flag_value --title)
  ask_ref=$(flag_value --ask-ref)
  [ -n "$title" ] || die "refused: post needs --title \"<the one question>\"; it is the card's title"
  [ -n "$ask_ref" ] || die "refused: post needs --ask-ref <the owner message or hold this question answers>; sign-off-axi requires it for a new Decide card"

  before=$(fm_question_open_keys)
  if [ -n "$BOARD" ]; then
    out=$(sign-off-axi raise "$BOARD" ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  else
    out=$(sign-off-axi raise ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || die "sign-off-axi refused the card (exit $rc); fix the flag it named and post again"

  after=$(fm_question_open_keys)
  key=$(comm -13 <(printf '%s\n' "$before" | sed '/^$/d' | LC_ALL=C sort) \
                <(printf '%s\n' "$after" | sed '/^$/d' | LC_ALL=C sort) | head -1)
  if [ -z "$key" ]; then
    key=$(printf '%s\n' "$after" | sed '/^$/d' | head -1)
    [ -n "$key" ] || die "sign-off-axi accepted the card but the board shows no open card; run sign-off-axi status and report this"
  fi
  printf '%s\n' "$key"
}

cmd_keys() {
  require_signoff
  fm_question_open_keys
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  post) cmd_post "$@" ;;
  keys) cmd_keys ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
