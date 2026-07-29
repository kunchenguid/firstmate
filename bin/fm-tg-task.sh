#!/usr/bin/env bash
# Task-scoped operations for the private Telegram bridge: correlate a task with
# the request that asked for it, and run the two-step publish confirmation.
#
# Usage:
#   fm-tg-task.sh link <task-id> <request-id>
#   fm-tg-task.sh unlink <task-id>
#   fm-tg-task.sh show <task-id>
#   fm-tg-task.sh arm-publish <task-id>
#   fm-tg-task.sh confirm-publish <task-id> --request <request-id>
#   fm-tg-task.sh clear-publish <task-id>
#   fm-tg-task.sh release <task-id> --yes --reason <text>
#   fm-tg-task.sh --help
#
# PROJECT ROUTING IS CHECKED, NOT ASSUMED
#   Pairing pins exactly one project name. Every subcommand that changes a
#   task's link or its publish authorization - link, unlink, arm-publish,
#   confirm-publish, clear-publish - compares the task's own recorded project
#   against that pinned name and refuses on any mismatch (exit 6), so a request
#   from the bridge can only ever move work in the project it was paired for.
#   Widening that is a captain decision made by re-pairing, not something a
#   message can ask for. `show` changes nothing and is a read-only diagnostic
#   over this home's own task records, so it is deliberately not scoped.
#   `release` is the one subcommand a project mismatch does NOT refuse, because
#   a task the bridge can no longer reach is exactly what it exists to recover.
#
# THE EXPLICIT LOCAL RELEASE
#   A task's Telegram origin is immutable, so the landing gate cannot be
#   forgotten. That alone would strand work: once the pairing is revoked there is
#   nobody left to confirm anything, and a task the bridge ever linked could
#   never land again. `release` is the narrow way out, and it is a CAPTAIN
#   action, not something an agent reaches for when a landing refuses.
#
#   It names ONE task - there is deliberately no bulk form - and needs both an
#   affirmative `--yes` and a written `--reason`, which is recorded in the task's
#   own record. Nothing is erased: the release only APPENDS, so the origin and
#   the reason stay readable forever, and a second release on the same task is
#   refused rather than allowed to rewrite the first one's justification.
#
#   It refuses whenever the ordinary path is still available - a pinned peer for
#   this task's project, or a publish confirmation already armed for it - so it
#   can recover a stranded task but can never substitute for a confirmation the
#   paired person could still be asked for. Revoking a pairing never releases
#   anything on its own; each task is a separate, deliberate decision.
#
# release exit codes:
#   0 released        2 bad usage (missing --yes, missing or malformed --reason)
#   6 nothing to release, already released, or the ordinary confirmation path is
#     still available for this task
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
#   THE REVISION IS RESOLVED HERE, NOT ASSERTED BY THE CALLER. Both subcommands
#   read the task's own recorded worktree and take `git rev-parse HEAD` from it,
#   so "they approved what they actually saw" is checkable rather than trusted:
#   an agent cannot arm one revision and confirm against another, and a change
#   rebuilt between preview and confirmation is detected against the real repo.
#   bin/fm-pr-merge.sh and bin/fm-merge-local.sh then require that same record,
#   consumed, matching the revision they are really about to land.
#
#   THE CONFIRMATION IS A REAL MESSAGE, NOT A FILE THE CALLER WROTE. This used
#   to take `--message-file <path>` and scan whatever that path contained, so
#   nothing tied the approval to the paired person having said anything at all
#   and "never arm and confirm in the same turn" was a rule in an agent skill
#   rather than a property of the code - the same shape the outbound side closed
#   by removing `--text-file`. `--request <request-id>` names an inbound message
#   instead: it must be one this home really accepted from the currently pinned
#   peer, still open, carrying text, and RECEIVED AFTER the preview was armed.
#   Only the salted hash of the code is stored, and only the code alphabet is
#   scanned out of that message, so no other part of the untrusted text is ever
#   interpreted.
#
# confirm-publish exit codes:
#   0 confirmed and consumed        6 project mismatch, or the prepared change
#   3 nothing armed for this task     moved since the preview
#   4 the confirmation expired      7 already used
#   5 no matching code in the       8 too many confirmation attempts
#     message                       9 no fresh, authentic message from the
#                                     paired person carries this confirmation
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Arming and consuming a publish confirmation decides whether prepared work may
# land; a no-mistakes gate agent inside a firstmate checkout must not reach it
# (bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

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
  link|unlink|show|arm-publish|confirm-publish|clear-publish|release) ;;
  *) die "unknown command: $COMMAND (see --help)" ;;
esac

TASK=${1:-}
[ -n "$TASK" ] || die "$COMMAND requires a task id"
shift 2>/dev/null || true

REQUEST=
HEAD_REV=
REASON=
RELEASE_YES=0
case "$COMMAND" in
  link)
    REQUEST=${1:-}
    [ -n "$REQUEST" ] || die "link requires a request id"
    shift 2>/dev/null || true
    ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      die "--head was removed: the prepared revision is resolved from the task's own worktree, not asserted by the caller"
      ;;
    --message-file)
      die "--message-file was removed: a confirmation must be carried by a real message from the paired person, so confirm-publish reads it from that message's own stored record with --request <request-id>"
      ;;
    --request)
      [ "$COMMAND" = confirm-publish ] || die "--request is only meaningful for confirm-publish"
      [ "$#" -gt 1 ] || die "--request requires a request id"
      REQUEST=$2
      shift 2
      ;;
    --yes)
      [ "$COMMAND" = release ] || die "--yes is only meaningful for release"
      RELEASE_YES=1
      shift
      ;;
    --reason)
      [ "$COMMAND" = release ] || die "--reason is only meaningful for release"
      [ "$#" -gt 1 ] || die "--reason requires text"
      REASON=$2
      shift 2
      ;;
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

# The exact revision this task has prepared, read from the task's own recorded
# worktree. This is what makes the confirmation a statement about the change the
# person actually previewed rather than about a string the caller supplied.
#
# It RETURNS its refusal rather than exiting. Callers invoke it through a command
# substitution, where `exit` ends only the subshell: this script runs under
# `set -u` without `-e`, so an exiting refusal printed its message and then let
# both subcommands carry on with an empty revision - arming a record no landing
# could ever match, and scanning a confirmation against nothing. Every caller
# therefore checks the status and exits with it.
prepared_revision() {
  local worktree rev
  worktree=$(fmtg_meta_get "$META" worktree) || {
    printf 'fm-tg-task: task %s has no recorded worktree, so its prepared revision cannot be resolved\n' "$TASK" >&2
    return 6
  }
  [ -d "$worktree" ] || {
    printf 'fm-tg-task: the recorded worktree for task %s is missing, so its prepared revision cannot be resolved\n' "$TASK" >&2
    return 6
  }
  rev=$(git -C "$worktree" rev-parse --verify --quiet HEAD) || rev=
  rev_valid "$rev" || {
    printf 'fm-tg-task: cannot resolve a prepared revision for task %s\n' "$TASK" >&2
    return 6
  }
  printf '%s' "$rev"
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
    require_project_match
    fmtg_meta_link_clear "$META" || die "cannot clear the link"
    ;;

  show)
    [ -f "$META" ] || die "no task record at $META"
    printf 'task: %s\n' "$TASK"
    printf 'project: %s\n' "$(fmtg_meta_get "$META" project || printf '<none>')"
    printf 'linked request: %s\n' "$(fmtg_meta_get "$META" tg_request || printf '<none>')"
    printf 'linked chat: %s\n' "$(fmtg_meta_get "$META" tg_chat || printf '<none>')"
    printf 'telegram origin: %s\n' "$(fmtg_meta_get "$META" tg_origin || printf '<none>')"
    printf 'released at: %s\n' "$(fmtg_meta_get "$META" tg_released_at || printf '<never>')"
    printf 'release reason: %s\n' "$(fmtg_meta_get "$META" tg_release_reason || printf '<none>')"
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
    require_project_match
    HEAD_REV=$(prepared_revision) || exit $?
    CODE=$(fmtg_random_code 6) || die "cannot generate a confirmation code"
    PROJECT=$(pinned_project)
    fmtg_publish_arm "$TASK" "$PROJECT" "$HEAD_REV" "$CODE" "$NOW" \
      "$(( NOW + FMTG_PUBLISH_TTL ))" || die "cannot arm the publish confirmation"
    printf '%s\n' "$CODE"
    ;;

  confirm-publish)
    [ -n "$REQUEST" ] || die "confirm-publish requires --request <request-id>"
    fmtg_request_id_valid "$REQUEST" || die "invalid request id: $REQUEST"
    require_project_match
    HEAD_REV=$(prepared_revision) || exit $?
    RECORD=$(fmtg_publish_show "$TASK" 2>/dev/null) || {
      printf 'fm-tg-task: nothing armed for %s\n' "$TASK" >&2
      exit 3
    }
    ARMED_AT=$(printf '%s' "$RECORD" | jq -r '.armed_at // 0')
    case "$ARMED_AT" in ''|*[!0-9]*) ARMED_AT=0 ;; esac

    # The confirming message must be one this home really accepted from the
    # currently pinned peer, and the exchange must still be open. This is the
    # same single-owner check the outbound path uses, so an invented request id
    # is as inert here as it is there.
    PEER=$(fmtg_peer_get) || die "no paired peer"
    PEER_CHAT=$(printf '%s' "$PEER" | jq -r '.chat_id // empty')
    fmtg_chat_id_valid "$PEER_CHAT" || die "the pinned peer record has no usable chat id"
    AUTH_RC=0
    fmtg_request_authentic "$REQUEST" "$PEER_CHAT" || AUTH_RC=$?
    case "$AUTH_RC" in
      0) ;;
      4)
        printf 'fm-tg-task: %s is not a message this home accepted from the paired person; refusing\n' "$REQUEST" >&2
        exit 9
        ;;
      6)
        printf 'fm-tg-task: request %s came from a chat that is no longer the paired peer; refusing\n' "$REQUEST" >&2
        exit 9
        ;;
      7)
        printf 'fm-tg-task: request %s was already closed by a final reply; refusing\n' "$REQUEST" >&2
        exit 9
        ;;
      *) die "cannot verify request $REQUEST" ;;
    esac

    # The words themselves come from the stored inbound record, which is the
    # only place the person's own text exists. A message that arrived BEFORE the
    # preview was armed cannot be the answer to it, which is what stops arming
    # and confirming inside a single turn.
    ENTRY=$(fmtg_inbox_get "$REQUEST" 2>/dev/null) || {
      printf 'fm-tg-task: no stored message for %s; a confirmation is read from the message that carried it, not from a file\n' \
        "$REQUEST" >&2
      exit 9
    }
    ENTRY_CHAT=$(printf '%s' "$ENTRY" | jq -r '.chat_id // empty')
    if [ "$ENTRY_CHAT" != "$PEER_CHAT" ]; then
      printf 'fm-tg-task: message %s came from a chat that is no longer the paired peer; refusing\n' "$REQUEST" >&2
      exit 9
    fi
    ENTRY_KIND=$(printf '%s' "$ENTRY" | jq -r '.kind // empty')
    if [ "$ENTRY_KIND" != text ]; then
      printf 'fm-tg-task: message %s carries no text (kind=%s), so it cannot carry a confirmation\n' \
        "$REQUEST" "${ENTRY_KIND:-<none>}" >&2
      exit 9
    fi
    RECEIVED=$(printf '%s' "$ENTRY" | jq -r '.received_at // 0')
    case "$RECEIVED" in ''|*[!0-9]*) RECEIVED=0 ;; esac
    if [ "$RECEIVED" -lt "$ARMED_AT" ]; then
      printf 'fm-tg-task: message %s arrived before the preview for %s was armed, so it cannot confirm it\n' \
        "$REQUEST" "$TASK" >&2
      exit 9
    fi
    RAW=$(printf '%s' "$ENTRY" | jq -r '.text // ""')

    # One attempt per message, however many candidate codes it contains.
    if ! fmtg_publish_attempt "$TASK"; then
      printf 'fm-tg-task: too many confirmation attempts for %s\n' "$TASK" >&2
      exit 8
    fi
    # Only characters from the code alphabet are read out of the message; every
    # other byte of that untrusted text is discarded here.
    CANDIDATES=$(printf '%s' "$RAW" \
      | LC_ALL=C tr '[:lower:]' '[:upper:]' \
      | LC_ALL=C tr -c "$FMTG_CODE_ALPHABET" '\n' \
      | grep -E "^[$FMTG_CODE_ALPHABET]{6}$" \
      | head -16) || CANDIDATES=
    RC=5
    while IFS= read -r CANDIDATE; do
      [ -n "$CANDIDATE" ] || continue
      CODE_RC=0
      fmtg_publish_confirm "$TASK" "$CANDIDATE" "$HEAD_REV" "$NOW" "$REQUEST" || CODE_RC=$?
      if [ "$CODE_RC" -eq 0 ]; then
        RC=0
        break
      fi
      # A non-matching candidate keeps scanning; any other refusal is final.
      if [ "$CODE_RC" -ne 5 ]; then
        RC=$CODE_RC
        break
      fi
    done <<EOF
$CANDIDATES
EOF
    case "$RC" in
      0) printf 'confirmed\n' ;;
      3) printf 'fm-tg-task: nothing armed for %s\n' "$TASK" >&2 ;;
      4) printf 'fm-tg-task: the confirmation for %s expired\n' "$TASK" >&2 ;;
      5) printf 'fm-tg-task: message %s carries no matching confirmation code\n' "$REQUEST" >&2 ;;
      6) printf 'fm-tg-task: the prepared change moved since the preview; re-preview before publishing\n' >&2 ;;
      7) printf 'fm-tg-task: that confirmation was already used\n' >&2 ;;
      *) printf 'fm-tg-task: confirmation failed\n' >&2 ;;
    esac
    exit "$RC"
    ;;

  clear-publish)
    require_project_match
    fmtg_publish_clear "$TASK" || die "cannot clear the armed confirmation"
    ;;

  release)
    [ "$RELEASE_YES" -eq 1 ] \
      || die "release needs --yes: it lets one task of Telegram origin land without the paired person's confirmation"
    [ -n "$REASON" ] || die "release requires --reason <text> saying why the confirmation can no longer be obtained"
    fmtg_release_reason_valid "$REASON" \
      || die "the release reason must be one line of plain text, 1-200 characters, with no control characters"
    [ -f "$META" ] || die "no task record at $META"
    fmtg_meta_is_linked "$META" || {
      printf 'fm-tg-task: task %s did not come from the Telegram bridge, so there is nothing to release\n' "$TASK" >&2
      exit 6
    }
    if fmtg_meta_released "$META"; then
      printf 'fm-tg-task: task %s was already released (%s); a release is recorded once and never rewritten\n' \
        "$TASK" "$(fmtg_meta_get "$META" tg_release_reason || printf '<no reason recorded>')" >&2
      exit 6
    fi
    if fmtg_publish_show "$TASK" >/dev/null 2>&1; then
      printf 'fm-tg-task: a publish confirmation is armed for %s, so the ordinary path is still open; finish it, or clear-publish it first\n' \
        "$TASK" >&2
      exit 6
    fi
    if PINNED=$(pinned_project) && [ -n "$PINNED" ]; then
      RELEASE_PROJECT=$(fmtg_meta_get "$META" project) || RELEASE_PROJECT=
      RELEASE_PROJECT=$(basename "${RELEASE_PROJECT:-}")
      if [ "$RELEASE_PROJECT" = "$PINNED" ]; then
        printf 'fm-tg-task: the bridge is still paired for "%s", so ask that person to confirm publishing %s instead of releasing it\n' \
          "$PINNED" "$TASK" >&2
        exit 6
      fi
    fi
    fmtg_meta_release_set "$META" "$REASON" "$NOW" || die "cannot record the release"
    printf 'released %s\n' "$TASK"
    ;;
esac
