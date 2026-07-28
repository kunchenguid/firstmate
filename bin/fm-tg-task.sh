#!/usr/bin/env bash
# Task-scoped operations for the private Telegram bridge: correlate a task with
# the request that asked for it, and run the two-step publish confirmation.
#
# Usage:
#   fm-tg-task.sh link <task-id> <request-id>
#   fm-tg-task.sh unlink <task-id>
#   fm-tg-task.sh show <task-id>
#   fm-tg-task.sh arm-publish <task-id> --head <rev>
#   fm-tg-task.sh confirm-publish <task-id> --head <rev> --message-file <path>
#   fm-tg-task.sh clear-publish <task-id>
#   fm-tg-task.sh --help
#
# PROJECT ROUTING IS CHECKED, NOT ASSUMED
#   Pairing pins exactly one project name. Every subcommand here compares the
#   task's own recorded project against that pinned name and refuses on any
#   mismatch (exit 6), so a request from the bridge can only ever move work in
#   the project it was paired for. Widening that is a captain decision made by
#   re-pairing, not something a message can ask for.
#
# THE TWO-STEP PUBLISH CONFIRMATION
#   A request authorizes preparing a change and showing a preview. It does not
#   authorize landing it. `arm-publish` records the exact prepared revision and
#   prints a one-time code to include in the preview message. `confirm-publish`
#   accepts only a reply that carries that code AND arrives while the prepared
#   revision is still exactly what was previewed. A confirmation is therefore
#   refused when it is late, guessed, replayed, or aimed at a preview that has
#   since been rebuilt - the person always approves the change they actually saw.
#
#   The incoming reply is read from a FILE, never an argument. Only the salted
#   hash of the code is stored, and only the code alphabet is scanned out of the
#   message, so no other part of that untrusted text is ever interpreted.
#
# confirm-publish exit codes:
#   0 confirmed and consumed        5 no matching code in the reply
#   3 nothing armed for this task   6 project mismatch, or the prepared change
#   4 the confirmation expired        moved since the preview
#   7 already used                  8 too many confirmation attempts
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-tg-task: %s\n' "$1" >&2
  exit 2
}

COMMAND=${1:-}
[ "$#" -gt 0 ] && shift
case "$COMMAND" in
  -h|--help|help|'') usage; exit 0 ;;
  link|unlink|show|arm-publish|confirm-publish|clear-publish) ;;
  *) die "unknown command: $COMMAND (see --help)" ;;
esac

TASK=${1:-}
[ -n "$TASK" ] || die "$COMMAND requires a task id"
shift 2>/dev/null || true

REQUEST=
HEAD_REV=
MESSAGE_FILE=
case "$COMMAND" in
  link)
    REQUEST=${1:-}
    [ -n "$REQUEST" ] || die "link requires a request id"
    shift 2>/dev/null || true
    ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head) [ "$#" -gt 1 ] || die "--head requires a revision"; HEAD_REV=$2; shift 2 ;;
    --message-file) [ "$#" -gt 1 ] || die "--message-file requires a path"; MESSAGE_FILE=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
fmtg_publish_task_valid "$TASK" || die "invalid task id: $TASK"
fmtg_load_config
NOW=$(fmtg_now) || die "cannot read the current time"
META="$STATE/$TASK.meta"

rev_valid() {
  case "$1" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 64 ]
}

# The pinned project is the only project this bridge may act in.
pinned_project() {
  local peer
  peer=$(fmtg_peer_get 2>/dev/null) || return 1
  printf '%s' "$peer" | jq -r '.project // empty'
}

require_project_match() {
  local pinned task_project
  pinned=$(pinned_project) || {
    printf 'fm-tg-task: no paired peer, so no project is authorized\n' >&2
    exit 6
  }
  [ -n "$pinned" ] || { printf 'fm-tg-task: the pinned peer record has no project\n' >&2; exit 6; }
  [ -f "$META" ] || die "no task record at $META"
  task_project=$(fmtg_meta_get "$META" project) || task_project=
  task_project=$(basename "${task_project:-}")
  if [ "$task_project" != "$pinned" ]; then
    printf 'fm-tg-task: task %s is in project "%s", but the bridge is paired for "%s"; refusing\n' \
      "$TASK" "${task_project:-<none>}" "$pinned" >&2
    exit 6
  fi
}

case "$COMMAND" in
  link)
    fmtg_request_id_valid "$REQUEST" || die "invalid request id: $REQUEST"
    require_project_match
    PEER=$(fmtg_peer_get) || die "no paired peer"
    PEER_CHAT=$(printf '%s' "$PEER" | jq -r '.chat_id // empty')
    fmtg_chat_id_valid "$PEER_CHAT" || die "the pinned peer record has no usable chat id"
    if CTX=$(fmtg_context_get "$REQUEST" 2>/dev/null); then
      CTX_CHAT=$(printf '%s' "$CTX" | jq -r '.chat_id // empty')
      if [ -n "$CTX_CHAT" ] && [ "$CTX_CHAT" != "$PEER_CHAT" ]; then
        printf 'fm-tg-task: request %s came from a chat that is no longer the paired peer; refusing\n' \
          "$REQUEST" >&2
        exit 6
      fi
    fi
    fmtg_meta_link_set "$META" "$REQUEST" "$PEER_CHAT" "$NOW" || die "cannot record the link"
    printf '%s\n' "$REQUEST"
    ;;

  unlink)
    [ -f "$META" ] || die "no task record at $META"
    fmtg_meta_link_clear "$META" || die "cannot clear the link"
    ;;

  show)
    [ -f "$META" ] || die "no task record at $META"
    printf 'task: %s\n' "$TASK"
    printf 'project: %s\n' "$(fmtg_meta_get "$META" project || printf '<none>')"
    printf 'linked request: %s\n' "$(fmtg_meta_get "$META" tg_request || printf '<none>')"
    printf 'linked chat: %s\n' "$(fmtg_meta_get "$META" tg_chat || printf '<none>')"
    if RECORD=$(fmtg_publish_show "$TASK" 2>/dev/null); then
      printf 'publish armed for: %s\n' "$(printf '%s' "$RECORD" | jq -r '.head // "?"')"
      printf 'publish expires at: %s\n' "$(printf '%s' "$RECORD" | jq -r '.expires_at // "?"')"
      printf 'publish attempts: %s\n' "$(printf '%s' "$RECORD" | jq -r '.attempts // 0')"
      printf 'publish consumed at: %s\n' "$(printf '%s' "$RECORD" | jq -r '.consumed_at // "never"')"
    else
      printf 'publish armed: no\n'
    fi
    ;;

  arm-publish)
    rev_valid "$HEAD_REV" || die "--head must be a git revision (7-64 hex characters)"
    require_project_match
    CODE=$(fmtg_random_code 6) || die "cannot generate a confirmation code"
    PROJECT=$(pinned_project)
    fmtg_publish_arm "$TASK" "$PROJECT" "$HEAD_REV" "$CODE" "$NOW" \
      "$(( NOW + FMTG_PUBLISH_TTL ))" || die "cannot arm the publish confirmation"
    printf '%s\n' "$CODE"
    ;;

  confirm-publish)
    rev_valid "$HEAD_REV" || die "--head must be a git revision (7-64 hex characters)"
    [ -n "$MESSAGE_FILE" ] || die "confirm-publish requires --message-file <path>"
    require_project_match
    if [ "$MESSAGE_FILE" = - ]; then
      RAW=$(cat)
    else
      [ -f "$MESSAGE_FILE" ] || die "no such message file: $MESSAGE_FILE"
      RAW=$(cat "$MESSAGE_FILE")
    fi
    fmtg_publish_show "$TASK" >/dev/null 2>&1 || {
      printf 'fm-tg-task: nothing armed for %s\n' "$TASK" >&2
      exit 3
    }
    # One attempt per reply, however many candidate codes it contains.
    if ! fmtg_publish_attempt "$TASK"; then
      printf 'fm-tg-task: too many confirmation attempts for %s\n' "$TASK" >&2
      exit 8
    fi
    # Only characters from the code alphabet are read out of the reply; every
    # other byte of that untrusted message is discarded here.
    CANDIDATES=$(printf '%s' "$RAW" \
      | LC_ALL=C tr '[:lower:]' '[:upper:]' \
      | LC_ALL=C tr -c "$FMTG_CODE_ALPHABET" '\n' \
      | grep -E "^[$FMTG_CODE_ALPHABET]{6}$" \
      | head -16) || CANDIDATES=
    RC=5
    while IFS= read -r CANDIDATE; do
      [ -n "$CANDIDATE" ] || continue
      if fmtg_publish_confirm "$TASK" "$CANDIDATE" "$HEAD_REV" "$NOW"; then
        RC=0
        break
      fi
      CODE_RC=$?
      # A non-matching candidate keeps scanning; any other refusal is final.
      [ "$CODE_RC" -eq 5 ] || { RC=$CODE_RC; break; }
    done <<EOF
$CANDIDATES
EOF
    case "$RC" in
      0) printf 'confirmed\n' ;;
      3) printf 'fm-tg-task: nothing armed for %s\n' "$TASK" >&2 ;;
      4) printf 'fm-tg-task: the confirmation for %s expired\n' "$TASK" >&2 ;;
      5) printf 'fm-tg-task: the reply carries no matching confirmation code\n' >&2 ;;
      6) printf 'fm-tg-task: the prepared change moved since the preview; re-preview before publishing\n' >&2 ;;
      7) printf 'fm-tg-task: that confirmation was already used\n' >&2 ;;
      *) printf 'fm-tg-task: confirmation failed\n' >&2 ;;
    esac
    exit "$RC"
    ;;

  clear-publish)
    fmtg_publish_clear "$TASK" || die "cannot clear the armed confirmation"
    ;;
esac
