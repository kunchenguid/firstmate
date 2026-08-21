#!/usr/bin/env bash
# fm-promotion-gate-lib.sh - the landing gate for an unanswered routing promotion.
#
# Why this exists: a crewmate that re-resolves its own tier UPWARD mid-task reports
# it with the routing-promotion verb (fm-classify-lib.sh's FM_CLASSIFY_PROMOTION_VERB),
# which opens a durable keyed record in the shared open-decisions fold. Firstmate owes
# that record a re-staff. Nothing else in the system makes that obligation binding:
# the record surfaces, and a firstmate that never loads the skill, restarts mid-task,
# or simply forgets would land the work at the tier its own diff already disproved.
#
# Landing is the last moment stale rigor can still be corrected, so both landing paths
# - bin/fm-pr-merge.sh and bin/fm-merge-local.sh - refuse while a promotion is open.
# This library is the single owner of that check, its refusal text, and the override
# record, so the two paths can never drift apart on what "unanswered" means.
#
# The gate deliberately reads the SAME fold as everything else rather than a private
# marker: an open promoted record IS an unhandled promotion, so answering the crewmate
# through bin/fm-send.sh --resolve-key, or transferring the promotion to a durable
# captain hold through bin/fm-captain-hold.sh, both clear this gate as a side effect
# of doing the real work. Neither route loses the promotion.
#
# The override is an intentional last-resort escape hatch when neither proper closure
# route serves: the crewmate is gone, so it cannot be answered, and this home's backlog
# is set to hand-editing, so the hold route is unavailable. That condition is not
# mechanically enforced. Its protection is a stated reason durably recorded beside the
# task, surviving teardown so use outside that last-resort case remains visible afterwards.
#
# Sourced, not executed. Callers get:
#   fm_promotion_open_records <status-file>            -> key<TAB>note per open promotion
#   fm_promotion_gate <state-dir> <task-id> [<reason>] -> 0 proceed, 1 refused (stderr)
#   fm_promotion_override_record <state-dir> <task-id> <reason>

# shellcheck shell=bash

_FM_PROMOTION_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_PROMOTION_GATE_DIR/fm-classify-lib.sh"

# A task id must be usable as one path component. Kept here rather than reached
# for through the forge library, so the local-only landing path does not source
# the whole of that library to get four lines.
fm_promotion_task_id_safe() {  # <task-id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# Every open promotion in a status file, as key<TAB>note lines.
#
# Exit status carries WHY there are no records, because the three reasons are not
# interchangeable at a landing gate:
#   0  the ledger was read and holds no open promotion (includes a genuinely
#      absent ledger, which legitimately means the worker has reported nothing yet)
#   3  a ledger EXISTS but cannot be trusted - a symlink, or not readable
#
# Case 3 matters: the shared fold answers "no open decisions" for an unreadable
# file, and treating that as permission to land would let an unreadable or
# swapped ledger hide a real promotion. Absence is evidence; unreadable presence
# is not.
#
# Trust boundary: this check and the fold that follows it are two separate reads,
# so a writer who can swap the ledger BETWEEN them defeats the check. That race is
# deliberately not chased here. The ledger lives in this home's private state
# directory, and anyone able to write there can already close a promotion outright
# by appending a keyed resolution line, which needs no race at all. Hardening the
# window would therefore buy no protection the append path does not already give
# away. What this check does buy is the ordinary case: a ledger left unreadable or
# replaced by a link stops the merge instead of reading as consent.
fm_promotion_open_records() {  # <status-file>
  local status_file=$1 open verb_read key rest
  [ -n "$status_file" ] || return 0
  if [ -e "$status_file" ] || [ -L "$status_file" ]; then
    { [ ! -L "$status_file" ] && [ -f "$status_file" ] && [ -r "$status_file" ]; } || return 3
  else
    return 0
  fi
  open=$(status_open_decisions "$status_file") || return 0
  [ -n "$open" ] || return 0
  # The fold emits key<TAB>verb<TAB>note. Splitting into exactly three fields keeps a
  # note that itself contains a tab intact in the third, rather than truncating it.
  while IFS=$'\t' read -r key verb_read rest; do
    [ -n "$key" ] || continue
    [ "$verb_read" = "$FM_CLASSIFY_PROMOTION_VERB" ] || continue
    printf '%s\t%s\n' "$key" "$rest"
  done <<EOF
$open
EOF
}

# An override reason must be a real sentence a later reader can act on. Empty,
# whitespace-only, and flag-shaped values are refused: `--promotion-override --`
# otherwise swallows the separator as its own reason, which records nothing and
# defeats the only reason the override is allowed to exist.
fm_promotion_reason_valid() {  # <reason>
  local reason=${1-}
  case "$reason" in
    ''|-*) return 1 ;;
    # Any control character, not just a newline: a carriage return alone reads as
    # a blank record, and a control character anywhere corrupts a one-line record.
    *[[:cntrl:]]*) return 1 ;;
  esac
  # Whitespace of every kind, so no run of blanks passes as a stated reason.
  [ -n "${reason//[[:space:]]/}" ]
}

fm_promotion_override_path() {  # <state-dir> <task-id>
  printf '%s/%s.promotion-override\n' "$1" "$2"
}

# Record a used override beside the task.
#
# The write is a private temp file renamed into place rather than a redirect onto
# the destination. A redirect FOLLOWS a symlink, so a link planted at the record
# path would divert the write out of the state directory, and a check-then-redirect
# only narrows that window instead of closing it. A rename replaces whatever sits
# at the path, symlink included, and never writes through it.
#
# An already-present symlink is still refused before the write. Nothing legitimate
# creates one there, so it means the state directory has been tampered with, and a
# loud refusal surfaces that rather than quietly replacing the evidence.
fm_promotion_override_record() {  # <state-dir> <task-id> <reason>
  local state=$1 id=$2 reason=$3 path tmp
  if ! fm_promotion_reason_valid "$reason"; then
    echo "error: --promotion-override needs a stated reason: a single line of real text, not empty, not whitespace, and not another flag" >&2
    return 1
  fi
  path=$(fm_promotion_override_path "$state" "$id")
  if [ -L "$path" ]; then
    echo "error: refusing to record the override: $path is a symlink" >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$state/.promotion-override.XXXXXX") || return 1
  if ! printf '%s\n' "$reason" > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# The gate itself. Prints nothing and returns 0 when the task has no unanswered
# promotion, or when a reason was supplied and successfully recorded. Prints the
# refusal and returns 1 otherwise.
fm_promotion_gate() {  # <state-dir> <task-id> [<override-reason>]
  local state=$1 id=$2 reason=${3-} records key note rc=0
  if ! fm_promotion_task_id_safe "$id"; then
    echo "REFUSED: '$id' is not a usable task id, so no promotion ledger can be resolved for it." >&2
    return 1
  fi
  records=$(fm_promotion_open_records "$state/$id.status") || rc=$?
  case "$rc" in
    0) ;;
    3)
      echo "REFUSED: task $id has a status ledger that cannot be read safely, so an open promotion cannot be ruled out." >&2
      echo "Inspect $state/$id.status: a status ledger must be a readable regular file, never a symlink." >&2
      return 1
      ;;
    *)
      echo "REFUSED: could not determine whether task $id has an open routing promotion." >&2
      return 1
      ;;
  esac
  [ -n "$records" ] || return 0

  if [ -n "$reason" ]; then
    fm_promotion_override_record "$state" "$id" "$reason" || return 1
    echo "notice: landing $id over an unanswered routing promotion; reason recorded: $reason" >&2
    return 0
  fi

  echo "REFUSED: task $id has an unanswered routing promotion." >&2
  while IFS=$'\t' read -r key note; do
    [ -n "$key" ] || continue
    echo "  [$key] $note" >&2
  done <<EOF
$records
EOF
  echo "The worker re-resolved this task's tier upward, so landing it now lands work at" >&2
  echo "the rigor it was dispatched at, not the rigor its own diff proved it needs." >&2
  echo "Re-staff first, then close the record by doing either of these:" >&2
  echo "  answer the worker:   bin/fm-send.sh <target> --resolve-key <key> '<the re-staff decision>'" >&2
  echo "  or hold it for the captain: bin/fm-captain-hold.sh (see its --help for the exact flags)" >&2
  echo "Last resort: use only when the worker is gone AND the hold path is unavailable." >&2
  echo "This is not mechanically enforced; the stated reason is recorded beside the task" >&2
  echo "and survives teardown so use outside that case remains visible afterwards:" >&2
  echo "  re-run with --promotion-override '<why landing at the dispatched tier is safe>'" >&2
  return 1
}
