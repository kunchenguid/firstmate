#!/usr/bin/env bash
# Shared question-rule helpers: does a captain-facing reply end in a question,
# and is that question already a board card? Sourced, no side effects.
#
# The question rule is the owner's, 2026-10-25: "if you ask questions as well
# make sure they are posted, posting questions will be stricter way of working".
# A chat-only question to him is a violation, so a reply that ends in one must
# cite the card it was asked on. bin/fm-question-card.sh posts that card and
# prints the key; bin/fm-turnend-guard.sh calls the predicate at the turn
# boundary; the reply and status writers that already run flag it in place.
#
# The board is read through sign-off-axi's own `list --json`, never a private
# copy of it, so this file stays a reader and posts nothing itself.

# Print the board file to read, or nothing to let sign-off-axi walk its default.
# An explicit SIGN_OFF_HOME is authoritative: a home that names a board must
# never fall through to the machine's shared board.
fm_question_board() {
  local dir
  if [ -n "${SIGN_OFF_HOME:-}" ]; then
    # A named home is authoritative; sign-off-axi keeps its board in .sign-off/.
    for dir in "$SIGN_OFF_HOME/.sign-off/decisions.json" "$SIGN_OFF_HOME/decisions.json"; do
      [ -f "$dir" ] && printf '%s\n' "$dir" && return 0
    done
    return 0
  fi
  dir="$HOME/.sign-off/decisions.json"
  [ -f "$dir" ] && printf '%s\n' "$dir"
  return 0
}

fm_question_signoff_available() { command -v sign-off-axi >/dev/null 2>&1; }

# Print the key of every card still open on the board.
fm_question_open_keys() {
  local board
  fm_question_signoff_available || return 0
  board=$(fm_question_board)
  if [ -n "$board" ]; then
    sign-off-axi list "$board" --json 2>/dev/null
  elif [ -n "${SIGN_OFF_HOME:-}" ]; then
    return 0
  else
    sign-off-axi list --json 2>/dev/null
  fi | jq -r '(.decisions // [])[]?.key // empty' 2>/dev/null
  return 0
}

# Print the last non-empty line of a reply, trailing markup trimmed.
fm_question_tail() {
  printf '%s\n' "$1" \
    | grep -v '^[[:space:]]*$' \
    | tail -1 \
    | tr -d '\r' \
    | sed -e 's/[[:space:]]*$//' -e 's/[][<"'"'"'*_`)>:]*$//' -e 's/[[:space:]]*$//'
}

# Return 0 when this reply ends in a question the owner has to answer.
# A guard-generated continuation (the U+2063 marker) is never his question.
fm_question_asks() {
  local tail_line
  [ -n "${1-}" ] || return 1
  [ "${1:0:1}" = "$(printf '\u2063')" ] && return 1
  tail_line=$(fm_question_tail "$1")
  case "$tail_line" in
    *\?) return 0 ;;
  esac
  return 1
}

# Return 0 when the reply cites a card that is still open on the board, so the
# question is already filed. An absent sign-off tool or an unreadable board
# confirms no card, which is not the same as confirming one; callers decide what
# that means for them.
fm_question_filed() {
  local key
  [ -n "${1-}" ] || return 1
  fm_question_signoff_available || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$1" in
      *"$key"*) return 0 ;;
    esac
  done < <(fm_question_open_keys)
  return 1
}

# Nag each distinct trailing question once: 0 the first time it is seen, 1 once
# this home has already flagged it, so no harness can be wedged in a loop.
fm_question_first_sighting() {  # <state-dir> <reply-text>
  local state=$1 stamp
  [ -n "$state" ] || return 0
  stamp=$(fm_question_tail "${2-}" | cksum | awk '{print $1 "-" $2}')
  if [ -f "$state/.question-flagged" ] && [ "$(head -1 "$state/.question-flagged" 2>/dev/null)" = "$stamp" ]; then
    return 1
  fi
  mkdir -p "$state" 2>/dev/null || return 0
  printf '%s\n' "$stamp" > "$state/.question-flagged" 2>/dev/null || true
  return 0
}

# Print the last assistant text of a turn-end payload's transcript, if it has one.
fm_question_reply_text() {  # <turn-end payload json>
  local path
  command -v jq >/dev/null 2>&1 || return 0
  path=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 0
  tail -n 400 "$path" 2>/dev/null | jq -Rrs '
    split("\n")
    | map(fromjson? // empty)
    | map(
        if ((.message.content? | type) == "array") then
          (.message.content[]? | if type == "object" and (.type == "text") then .text else empty end)
        elif ((.message.content? | type) == "string") then .message.content
        elif ((.payload.content? | type) == "array") then
          (.payload.content[]? | if type == "object" and (.type == "output_text" or .type == "text") then .text else empty end)
        else empty end)
    | map(select(. != null and . != "")) | last // empty' 2>/dev/null
  return 0
}

# Flag a captain-facing text that ends in a question no open card covers.
# This is a flag, not a gate: it returns 0 whether or not it printed, so a
# writer that already ran keeps its own contract and only gains the line.
fm_question_flag_reply() {
  local text=${1-}
  fm_question_asks "$text" || return 0
  fm_question_filed "$text" && return 0
  printf 'flag: this text ends in a question that no open board card covers; post it with %s/fm-question-card.sh post and cite the key in the text\n' \
    "$(dirname "${BASH_SOURCE[0]}")" >&2
  return 0
}
