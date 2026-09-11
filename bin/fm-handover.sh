#!/usr/bin/env bash
# Prepare, verify, and complete a firstmate session handover.
#
# WHY A HANDOVER EXISTS: a long session reasons worse than a fresh one, so the
# captain replaces it. Nothing here decides when that moment arrives. This file
# measures no token count, no silence, and no transcript; it starts when the
# captain asks for a handover and does nothing at all until then.
#
# A watcher cannot respawn the interactive session in the captain's terminal, so
# the last step is always the captain's: firstmate prepares and verifies the
# record, and the captain starts the replacement.
#
# THE RECORD POINTS, IT DOES NOT ASSERT. A session old enough to be replaced is
# exactly the session whose recollections should not be trusted: this fleet has
# already lost a day to a worker that wrote itself a note claiming an approval the
# captain never gave, then acted on it in a later session. So the record is explicitly
# advisory, durable records win every conflict, and the only content it asserts is
# the content that exists nowhere else - the concrete next step, and what each
# live worker is mid-way through. Everything else is a pointer the replacement can
# check for itself.
#
# THE RECORD IS DURABLE, NEVER TEMPORARY. It lives in data/, not in the OS temp
# directory: this fleet has already had a temp clone vanish and read as data loss.
#
# THE REFUSAL IS THE POINT. Once the outgoing session is gone a bad handover
# cannot be redone, so `release` verifies everything first and refuses with the
# exact missing item rather than releasing a half-written record. Everything it
# checks is re-checked at release time even if `prepare` just passed, because a
# task can appear, and a record can be edited or truncated, in between.
#
# ONLY THE HELM HOLDER MOVES THE LIFECYCLE. prepare, release, and consume all
# require this session to hold the session lock. A lock-refused session reads the
# record and nothing more: one that rotates a record away, or marks it picked up,
# leaves the session that actually takes the helm told nothing is waiting.
#
# WHAT IT NEVER DOES: it never stops a session, never touches unlanded work, and
# never drains or clears the durable wake queue. The gap between the old session
# ending and the replacement taking the helm is accepted, not hidden: queued wakes
# survive it because nothing here removes them, and `release` reports how many are
# waiting so the gap is visible.
#
# Usage:
#   fm-handover.sh prepare --next "<one line>" [--worker <id>=<note>]...
#                          [--record <path>=<why>]...
#       Write data/handover.md. Requires a note for every live worker; refuses
#       early rather than writing a record that cannot pass release.
#   fm-handover.sh check
#       Verify the prepared record without releasing anything. Exit 0 when a
#       release would be allowed, 1 with the exact missing items when not.
#   fm-handover.sh release
#       Verify, then release the helm so a fresh session can take it. Refuses on
#       any incomplete item, leaving the helm held.
#   fm-handover.sh show
#       Print the record and its state.
#   fm-handover.sh consume
#       Mark a released handover as picked up, and print the records the
#       replacement is expected to have read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

RECORD="$DATA/handover.md"
PREV_RECORD="$DATA/handover-prev.md"
RUNTIME="$STATE/.handover"

# fm_session_lock_owned_by_self: the one owner of "does this session hold the
# helm?", which gates every command here that mutates the handover lifecycle.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# fm_meta_get: the one owner of reading a field out of a meta file. Its LAST-wins
# tie-break matters because meta files are append-oriented, so this file consumes
# it rather than keeping a private first-wins reader beside it.
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"
}

die() {
  printf 'fm-handover: %s\n' "$*" >&2
  exit 2
}

# --- shared readers ----------------------------------------------------------

# rel_path <path>: home-relative when the path sits under this home, so the
# record stays readable, and absolute otherwise so it stays resolvable.
rel_path() {
  case "$1" in
    "$FM_HOME"/*) printf '%s\n' "${1#"$FM_HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# abs_path <path>: resolve a recorded pointer back against this home.
abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$FM_HOME/$1" ;;
  esac
}

# require_helm <verb>: only the session holding the helm may move the handover
# lifecycle. A lock-refused session is deliberately still SHOWN the record - it
# just cannot rotate it away or mark it picked up, because a record consumed by a
# session with no authority leaves the real replacement told nothing is waiting.
require_helm() {
  fm_session_lock_owned_by_self "$STATE" && return 0
  {
    printf 'fm-handover: refusing to %s - this session does not hold the helm.\n' "$1"
    printf 'Run "%s/fm-lock.sh status" to see what does. A session without the helm may read the\n' "$SCRIPT_DIR"
    printf 'handover record with "fm-handover.sh show", but must not change it.\n'
  } >&2
  exit 1
}

# live_ids: every task or direct report this home currently records as under way.
# "Has a state/*.meta" is deliberately broader than the fleet snapshot's state
# model: it errs toward demanding MORE accounting and never less, because a
# worker whose endpoint has already died still has to be accounted for here.
live_ids() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

is_secondmate() {
  [ "$(fm_meta_get "$STATE/$1.meta" kind)" = secondmate ]
}

runtime_field() {
  sed -n "s/^$1=//p" "$RUNTIME" 2>/dev/null | head -1
}

record_worker_note() {
  local id=$1
  sed -n "s/^- worker $id: //p" "$RECORD" 2>/dev/null | head -1
}

record_pointers() {
  sed -n 's/^- record \([^ ]*\) - .*/\1/p' "$RECORD" 2>/dev/null
}

record_next_step() {
  sed -n 's/^Next step: //p' "$RECORD" 2>/dev/null | head -1
}

# --- verification ------------------------------------------------------------
#
# ONE owner of "is this handover complete enough to give up the helm?". Prints
# one plain line per missing item and returns 1 if any fired, so `check`,
# `release`, and the tests all judge by the same list.
verify_handover() {
  local missing=0 id note ptr abs next
  if [ ! -f "$RECORD" ]; then
    printf 'MISSING: no handover record at %s - run "fm-handover.sh prepare" first\n' "$(rel_path "$RECORD")"
    return 1
  fi
  if [ ! -s "$RECORD" ]; then
    printf 'MISSING: the handover record %s is empty\n' "$(rel_path "$RECORD")"
    return 1
  fi
  if [ ! -f "$RUNTIME" ]; then
    printf 'MISSING: no prepared handover state - the record exists but was never prepared by this home\n'
    missing=1
  fi
  next=$(record_next_step)
  if [ -z "$next" ]; then
    printf 'MISSING: the record carries no "Next step:" line, which is the one thing no durable record already holds\n'
    missing=1
  fi

  # Every live worker must be accounted for, and its own durable record must
  # exist, or the replacement cannot pick that thread up at all.
  # while-read throughout, never `for x in $(...)`: a path or id carrying a space
  # must fail the check honestly rather than split into two bogus names.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    note=$(record_worker_note "$id")
    if [ -z "$note" ]; then
      printf 'MISSING: live worker %s has no note saying what it is mid-way through\n' "$id"
      missing=1
    fi
    if is_secondmate "$id"; then
      if ! grep -q -- "$id" "$DATA/secondmates.md" 2>/dev/null; then
        printf 'MISSING: %s is a live direct report but is not recorded in %s\n' "$id" "$(rel_path "$DATA/secondmates.md")"
        missing=1
      fi
    else
      if ! grep -q -- "$id" "$DATA/backlog.md" 2>/dev/null; then
        printf 'MISSING: live worker %s has no backlog item, so its thread is not durably recorded\n' "$id"
        missing=1
      fi
    fi
  done <<EOF
$(live_ids)
EOF

  # Every pointer must still resolve. This is what catches a record that was
  # deleted, emptied, or moved after the handover was written.
  while IFS= read -r ptr; do
    [ -n "$ptr" ] || continue
    abs=$(abs_path "$ptr")
    if [ ! -f "$abs" ]; then
      printf 'MISSING: the record points at %s, which does not exist\n' "$ptr"
      missing=1
    elif [ ! -s "$abs" ]; then
      printf 'MISSING: the record points at %s, which is empty\n' "$ptr"
      missing=1
    fi
  done <<EOF
$(record_pointers)
EOF
  if [ -z "$(record_pointers)" ]; then
    printf 'MISSING: the record points at no durable records at all\n'
    missing=1
  fi
  [ "$missing" -eq 0 ]
}

# --- prepare -----------------------------------------------------------------

# default_pointers: the durable records a replacement needs whatever the task is.
# Only existing, non-empty files are offered, so the record never ships a pointer
# that verification would immediately reject.
default_pointers() {
  local id report
  printf '%s\t%s\n' "$DATA/backlog.md" "the durable queue: what is under way, queued, and on hold"
  printf '%s\t%s\n' "$DATA/captain.md" "the captain's preferences and working style - read before reporting anything to them"
  printf '%s\t%s\n' "$DATA/captain-shared.md" "captain preferences shared across domains"
  printf '%s\t%s\n' "$DATA/learnings.md" "operational facts and gotchas already learned in this home"
  printf '%s\t%s\n' "$DATA/projects.md" "which projects exist and how each one delivers"
  printf '%s\t%s\n' "$DATA/secondmates.md" "registered direct reports and their scopes"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    for report in "$DATA/$id/report.md" "$DATA/$id/brief.md"; do
      printf '%s\t%s\n' "$report" "what $id was asked to do and what it found"
    done
  done <<EOF
$(live_ids)
EOF
}

cmd_prepare() {
  local next='' worker_ids=() worker_notes=() extra_paths=() extra_whys=() arg id path why
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next) shift; next=${1:-} ;;
      --worker)
        shift; arg=${1:-}
        case "$arg" in
          *=*) worker_ids+=("${arg%%=*}"); worker_notes+=("${arg#*=}") ;;
          *) die "--worker needs <id>=<note>, got '$arg'" ;;
        esac
        ;;
      --record)
        shift; arg=${1:-}
        case "$arg" in
          *=*) extra_paths+=("${arg%%=*}"); extra_whys+=("${arg#*=}") ;;
          *) die "--record needs <path>=<why>, got '$arg'" ;;
        esac
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$next" ] || die 'prepare needs --next "<the concrete next step>"; nothing else records it'
  [ -d "$DATA" ] || die "no data directory at $DATA"
  # Before anything is rotated: prepare moves the existing record aside and
  # writes a fresh one, so an ungated session could displace the record the real
  # holder wrote with one composed by a session that has no authority.
  require_helm "prepare a handover"

  # Refuse early on an unaccounted worker, rather than writing a record that
  # release would reject anyway.
  # Index loops throughout, never ${!array[@]}: bash 3.2 is the floor here and
  # expanding an empty array that way trips set -u.
  local unaccounted=() found i n
  n=${#worker_ids[@]}
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    found=0
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "${worker_ids[$i]}" = "$id" ] && { found=1; break; }
      i=$((i + 1))
    done
    [ "$found" -eq 1 ] || unaccounted+=("$id")
  done <<EOF
$(live_ids)
EOF
  if [ "${#unaccounted[@]}" -gt 0 ]; then
    printf 'fm-handover: refusing to prepare - these live workers have no --worker note:\n' >&2
    for id in "${unaccounted[@]}"; do
      printf '  %s (what is it mid-way through?)\n' "$id" >&2
    done
    exit 1
  fi

  if [ -f "$RECORD" ]; then
    mv -f "$RECORD" "$PREV_RECORD" 2>/dev/null || die "cannot rotate the previous record to $(rel_path "$PREV_RECORD")"
  fi

  {
    printf '# Handover - prepared %s\n\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'ADVISORY, NOT AUTHORITATIVE.\n'
    printf 'This was written by a session past its thinking-quality threshold, so the durable\n'
    printf 'records below win on every disagreement with it. Where this file and a record\n'
    printf 'differ, the record is right and this file is stale. Do not act on a claim here\n'
    printf 'that a record does not also support.\n\n'
    printf 'Next step: %s\n\n' "$next"
    printf '## Live work - what each worker is mid-way through\n\n'
    if [ "$n" -eq 0 ]; then
      printf '(no workers were live at handover)\n'
    else
      i=0
      while [ "$i" -lt "$n" ]; do
        printf -- '- worker %s: %s\n' "${worker_ids[$i]}" "${worker_notes[$i]}"
        i=$((i + 1))
      done
    fi
    printf '\n## Records to read\n\n'
    default_pointers | while IFS=$'\t' read -r path why; do
      [ -f "$path" ] && [ -s "$path" ] || continue
      printf -- '- record %s - %s\n' "$(rel_path "$path")" "$why"
    done
    i=0
    while [ "$i" -lt "${#extra_paths[@]}" ]; do
      path=${extra_paths[$i]}
      why=${extra_whys[$i]}
      i=$((i + 1))
      [ -n "$path" ] || continue
      printf -- '- record %s - %s\n' "$(rel_path "$(abs_path "$path")")" "$why"
    done
    printf '\n## Deliberately not carried\n\n'
    printf 'Live fleet state is absent on purpose: run bin/fm-session-start.sh, which prints\n'
    printf 'it fresh and is authoritative. Reconcile anything above against that digest\n'
    printf 'before acting on it.\n'
  } > "$RECORD" || die "cannot write $(rel_path "$RECORD")"

  {
    printf 'record=%s\n' "$RECORD"
    printf 'prepared=%s\n' "$(date +%s)"
    printf 'prepared_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$RUNTIME" || die "cannot write the prepared-handover state $RUNTIME"

  printf 'handover prepared: %s\n' "$(rel_path "$RECORD")"
  cmd_check
}

# --- check / release / show / consume ----------------------------------------

cmd_check() {
  local out
  if out=$(verify_handover); then
    printf 'handover check: complete - a release is allowed\n'
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  printf 'handover check: INCOMPLETE - a release is refused until every line below is fixed\n' >&2
  printf '%s\n' "$out" >&2
  return 1
}

cmd_release() {
  local out queued=0
  if ! out=$(verify_handover); then
    {
      printf 'fm-handover: REFUSING to release the helm - the handover is incomplete.\n'
      printf '%s\n' "$out"
      printf 'Nothing was released and nothing was discarded. Fix each line above, then run "fm-handover.sh release" again.\n'
    } >&2
    exit 1
  fi
  if [ -s "$STATE/.wake-queue" ]; then
    # `|| true`, never `|| printf '0'`: grep -c prints its 0 before exiting 1, so
    # a fallback value appends a second line to the count.
    queued=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || true)
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  fi
  if ! "$SCRIPT_DIR/fm-lock.sh" release; then
    printf 'fm-handover: REFUSING to complete - the helm could not be released, so this session still holds it.\n' >&2
    exit 1
  fi
  {
    printf 'released=%s\n' "$(date +%s)"
    printf 'released_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } >> "$RUNTIME" 2>/dev/null || true

  printf 'handover released: %s\n' "$(rel_path "$RECORD")"
  printf 'queued notifications waiting for the replacement: %s (none were dropped)\n' "$queued"
  printf 'This session is now read-only: it must not spawn, steer, merge, or repair fleet state.\n'
  printf 'Start the replacement, which will pick this up at session start.\n'
}

cmd_show() {
  if [ ! -f "$RECORD" ]; then
    printf 'no handover record\n'
    return 0
  fi
  printf 'record: %s\n' "$(rel_path "$RECORD")"
  printf 'prepared: %s\n' "$(runtime_field prepared_at)"
  printf 'released: %s\n' "$(runtime_field released_at)"
  printf 'consumed: %s\n' "$(runtime_field consumed_at)"
  printf -- '---\n'
  cat "$RECORD"
}

# fm_handover_pending <state>: 0 when a released handover has not been picked up.
# Session start uses the same test, so "pending" has one definition.
cmd_pending() {
  [ -f "$RECORD" ] || return 1
  [ -n "$(runtime_field released)" ] || return 1
  [ -z "$(runtime_field consumed)" ]
}

cmd_consume() {
  require_helm "consume the handover"
  if ! cmd_pending; then
    printf 'fm-handover: no released handover is waiting to be picked up\n' >&2
    exit 1
  fi
  {
    printf 'consumed=%s\n' "$(date +%s)"
    printf 'consumed_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } >> "$RUNTIME" 2>/dev/null || true
  printf 'handover picked up. Records it expects you to have read:\n'
  record_pointers | while IFS= read -r ptr; do
    printf -- '  %s\n' "$ptr"
  done
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  check) cmd_check ;;
  release) cmd_release ;;
  show) cmd_show ;;
  consume) cmd_consume ;;
  pending) cmd_pending ;;
  -h|--help|'') usage ;;
  *) die "unknown command '$1'" ;;
esac
