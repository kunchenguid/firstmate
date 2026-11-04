#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement
# (fm_task_inbox_acknowledge, also reachable as the bin/fm-inbox-ack.sh CLI),
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge, and
# bin/fm-inbox-ack.sh performs that acknowledgement on the worker's behalf;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line, which does not need to be reliable because
# ringing it again is free. A duplicated doorbell is a no-op by construction
# (the worker finds the inbox empty or already handled), a swallowed doorbell
# is detected by the absence of the worker's acknowledgement and re-rung on a
# bounded schedule, and a worker that never acknowledges surfaces through the
# ordinary stale wake into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, no-clobber publish
#   <task>.inbox/.unhandled/NNN  a second link to every unhandled record, so a
#                              worker's own cleanup inside its inbox cannot
#                              destroy an instruction (restored below)
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   coalesce=<key>             present only on a coalescing record (below)
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# No steering record can be overwritten or silently dropped, under any number
# of concurrent writers and any lock outcome. Two independent mechanisms carry
# that guarantee, and only the second one is load-bearing:
#   1. .seq.lock serializes sequence allocation, which keeps a collision rare
#      and keeps ordering sane. It is an optimization, not the safety proof: a
#      writer that never takes it, a lock reclaimed after its holder's pid was
#      recycled, and a stale lock all cost ordering only.
#   2. Publishing is a no-clobber hard link: the record's bytes are written to a
#      staging file first, then link(2) creates the sequence name, which fails
#      atomically with EEXIST when that slot is already taken. The writer then
#      re-reads the directory and takes the next free sequence, so a colliding
#      writer costs an ordering bump and can never destroy an existing record.
#      A writer that cannot publish verifies nothing and reports failure: every
#      enqueue returns only after confirming its own record is on disk carrying
#      its own text (fm_task_inbox_verify), and fm-send refuses the send when
#      that confirmation fails.
#   3. Every unhandled record also has a link under the inbox's hidden
#      .unhandled/ directory. A worker that deletes records in its own inbox - a
#      broad `rm`, a tidy-up glob - removes only the visible name, and the next
#      watcher poll restores it (fm_task_inbox_restore_unhandled) with its
#      original mtime, so the re-ring ladder still delivers it. That repair is
#      deliberately at-least-once: a worker that deletes instead of moving a
#      record into handled/ sees the instruction again, which is the safe
#      direction when the alternative is losing it silently. The shadow is
#      retired when the record is acknowledged (moved into handled/) or
#      superseded by a coalescing write. The idempotent re-enqueue dedup reads it
#      too, so a retried request whose visible record a worker deleted lands on
#      that record - linked back into the root - instead of a duplicate beside
#      the original the repair pass is about to restore.
#
# Sequence numbers are never reused within a task: allocation scans the inbox
# root, handled/, and the shadow directory, so a message is processed at most
# once per worker lifetime even if every doorbell is duplicated, and a record
# whose only remaining link is its shadow keeps that sequence instead of having
# the name handed to a different message.
#
# Coalescing (fm_task_inbox_write_coalesced): a periodic idempotent
# instruction - a scheduled lane tick - must not pile up behind a worker that
# has not drained it, because N unhandled copies carry no more information
# than one. A coalescing write records coalesce=<key> and then deletes every
# OTHER unhandled record that carries the same key or whose exact body equals
# the new one (the second rule also drains copies queued before the sender
# marked them). The new record is written first, so at least one copy is
# always present, and it takes a fresh sequence number, so it orders after
# every instruction already queued. Handled records are never touched, a
# fire-and-forget record is never replaced by body match, and a worker that
# loses a race to the deletion only finds its mv target gone. Replacing the
# re-ring ladder's current oldest record must not restart that ladder: the
# record that becomes oldest inherits the superseded one's mtime and its
# .ring-state/.escalated bookkeeping, so a worker that never drains its ticks
# still escalates.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy check (a busy pane just waits - the record is durable and
# the worker reaches a turn boundary) and the wake emission; this library owns
# only the schedule. If attempt bookkeeping cannot be persisted while the record
# remains unhandled, the caller surfaces that failure instead of retrying
# silently; a concurrently removed inbox is a quiet no-op. Escalation
# deliberately queues the wake before writing the
# deduplication marker: normal polls surface a message once, while a crash or
# marker failure may produce a rare duplicate rather than silently lose a wake.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_LOCK_WAIT_SECS  default 15; bounded wait for the sequence and
#                              metadata locks before a send is refused

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
# Bound on publish attempts: every attempt that loses the slot advances to the
# next free sequence, so this only caps the pathological case of an inbox whose
# sequence names keep being taken by other writers.
_FM_TASK_INBOX_PUBLISH_ATTEMPTS=1000
# Hidden home of the second link to each unhandled record. Names carry no .msg
# suffix so no reader, counter, or glob mistake them for inbox records.
FM_TASK_INBOX_SHADOW_DIR='.unhandled'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=15

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

# The blessed acknowledgement command (bin/fm-inbox-ack.sh). The doorbell names
# it so a worker acks instead of hand-rolling a move or a cleanup inside the
# inbox; the acknowledgement contract itself stays here.
fm_task_inbox_ack_command() {
  printf '%s/fm-inbox-ack.sh' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

fm_task_inbox_shadow_dir() {  # <inbox-dir>
  printf '%s/%s' "$1" "$FM_TASK_INBOX_SHADOW_DIR"
}

# Create the inbox's own subdirectories. Both are needed before any publish:
# handled/ for the acknowledgement, and the shadow for the deletion repair.
fm_task_inbox_prepare_dirs() {  # <inbox-dir>
  local dir=$1
  mkdir -p "$dir/handled" || return 1
  mkdir -p "$(fm_task_inbox_shadow_dir "$dir")" || return 1
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root, handled/, and the shadow
# directory, so an acknowledged sequence is never reissued and a record that
# survives only as its hidden link still reserves its number. Reserving the
# shadow matters: without it a worker's cleanup followed by the next enqueue
# reuses that name, the repair pass then finds the name present with different
# bytes and skips the deleted record, and acknowledging the new record retires
# the shadow - the deleted instruction is gone with no delivery and no error.
# Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  for f in "$(fm_task_inbox_shadow_dir "$dir")"/*; do
    [ -e "$f" ] || continue
    n=${f##*/}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    n=$((10#$n))
    [ "$n" -le "$max" ] || max=$n
  done
  printf '%03d' "$((max + 1))"
}

# Bounded acquire for the sequence lock and the task metadata lock that
# fm-send and the remote steer leg take around final delivery validation.
# A holder that died is reclaimed by fm_lock_try_acquire; a holder whose pid
# was recycled by an unrelated live process is reaped by fm_lock_reap_stale
# (bin/fm-wake-lib.sh) once its record is old enough. Either reclaim prints
# one stderr line naming the lock and the gone holder, so a recovered send
# leaves evidence instead of silently stealing.
# While a verified live holder keeps the lock, the wait re-reads its pid with
# shell builtins instead of re-running the claim: each claim attempt forks a
# dozen processes, and on a loaded host contending writers spent the whole
# bounded wait in those forks (slowing the holder too) and refused sends that
# a cheaper wait would have delivered.
_fm_task_inbox_lock_live_holder() {  # <lock-path> <own-pid>
  local pid
  [ -e "$1/pid" ] || return 1
  IFS= read -r pid < "$1/pid" 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$2" ] || return 1
  fm_pid_alive "$pid"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe reaped reap_tried=0 self=
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  fm_current_pid self || self=
  deadline=$(( SECONDS + wait ))
  while :; do
    if [ "$reap_tried" -eq 1 ] && _fm_task_inbox_lock_live_holder "$lock" "$self"; then
      [ "$SECONDS" -lt "$deadline" ] || return 1
      sleep 0.05
      continue
    fi
    fm_lock_try_acquire "$lock" && break
    # One reuse probe per acquisition: a record's age cannot cross the reap
    # threshold meaningfully inside this short wait, and probing every spin
    # would tax the very contention it waits out.
    if [ "$reap_tried" -eq 0 ]; then
      reap_tried=1
      if [ -n "${FM_LOCK_HELD_PID:-}" ] && reaped=$(fm_lock_reap_stale "$lock"); then
        echo "fm-task-inbox: reclaimed stale lock: $reaped" >&2
        continue
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
  if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
    echo "fm-task-inbox: reclaimed stale lock: $lock from dead holder pid=$FM_LOCK_RECOVERED_PID" >&2
  fi
  return 0
}

# True when the sequence's record still carries <bytes-file>: either the record
# published in the inbox root, or the acknowledged copy a worker's own mv already
# produced under handled/. An acknowledged record is delivered, not lost.
fm_task_inbox_record_holds() {  # <inbox-dir> <seq> <bytes-file>
  local dir=$1 seq=$2 bytes=$3 rec
  rec="$dir/$seq.msg"
  if [ -e "$rec" ] || [ -L "$rec" ]; then
    cmp -s "$bytes" "$rec"
    return
  fi
  cmp -s "$bytes" "$dir/handled/$seq.msg"
}

# Verify a published record: it is a regular file whose body is exactly <text>,
# or the acknowledged copy of that same sequence is. This is the enqueue's own
# proof, used by the writers below and by callers that report a send as
# delivered (bin/fm-send.sh, the remote steer leg). A worker draining the inbox
# concurrently can move the record into handled/ between the publish and this
# check, which is the acknowledgement, so it confirms delivery rather than
# turning a delivered steer into a reported failure.
fm_task_inbox_verify() {  # <record-path> <text>
  local rec=$1 text=$2 acked
  if [ -f "$rec" ] && [ ! -L "$rec" ]; then
    cmp -s <(printf '%s' "$text") <(fm_task_inbox_body "$rec" 2>/dev/null)
    return
  fi
  acked="${rec%/*}/handled/${rec##*/}"
  [ -f "$acked" ] && [ ! -L "$acked" ] || return 1
  cmp -s <(printf '%s' "$text") <(fm_task_inbox_body "$acked" 2>/dev/null)
}

# Write one record into the next free sequence slot and print its path.
# Publishing is a no-clobber hard link of a fully written staging file: the
# sequence name can only come into existence if it was free, so no writer can
# replace another writer's record no matter how the sequence was chosen. A slot
# taken between the scan and the link costs one re-scan and the next sequence.
# Caller normally holds .seq.lock, which keeps a collision rare; the guarantee
# holds with or without it, because the link is the arbiter.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode] [coalesce-key]
  local dir=$1 text=$2 delivery_mode=${3:-} coalesce=${4:-}
  local seq tmp rec attempt=0
  local attempts=$_FM_TASK_INBOX_PUBLISH_ATTEMPTS
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  if ! {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    [ -z "$coalesce" ] || printf 'coalesce=%s\n' "$coalesce"
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    seq=$(fm_task_inbox_next_seq "$dir") || break
    rec="$dir/$seq.msg"
    if ln "$tmp" "$rec" 2>/dev/null; then
      # The link is the identity proof that this name holds our complete bytes,
      # so a reader never sees a partial record. A worker already draining the
      # inbox may have moved it into handled/ first, which confirms the same
      # publish instead of failing it.
      if ! fm_task_inbox_record_holds "$dir" "$seq" "$tmp"; then
        rm -f "$tmp"
        return 1
      fi
      if [ -e "$rec" ]; then
        # A second link keeps the unhandled record recoverable if the worker's
        # own cleanup deletes it. Its name carries no .msg suffix so nothing
        # mistakes it for an inbox record. Best effort: the record above is
        # already durable, so a shadow that cannot be made must not fail the send.
        ln "$tmp" "$(fm_task_inbox_shadow_dir "$dir")/${seq}" 2>/dev/null || true
      fi
      rm -f "$tmp"
      printf '%s' "$rec"
      return 0
    fi
    # A taken slot is the only expected failure: re-read the directory and let
    # the next sequence be chosen. Anything else is a real refusal, reported by
    # the caller rather than silently retried against a broken inbox.
    [ -e "$rec" ] || [ -L "$rec" ] || break
  done
  rm -f "$tmp"
  return 1
}

# Durably enqueue one steer into the next free sequence slot. Prints the record
# path only after the record is confirmed on disk with this text. Fails without
# a partial record and without replacing any existing record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  fm_task_inbox_prepare_dirs "$dir" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  # Re-confirm after releasing: the inbox can be replaced or retired underneath
  # a writer, and a send that cannot point at its own record must never report
  # delivery. The retry is the caller's business, never a silent success.
  fm_task_inbox_verify "$rec" "$text" || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled in the inbox root, already acknowledged in
# handled/, or surviving only as its hidden link after a worker's cleanup - no
# new record is written and the existing record's path is printed instead. A
# shadow-only match is linked back into the inbox root first, so the re-run
# reports a record that is on disk rather than publishing a duplicate beside the
# deleted original the repair pass is about to restore.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir shadow lock want have f base rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  fm_task_inbox_prepare_dirs "$dir" || return 1
  shadow=$(fm_task_inbox_shadow_dir "$dir")
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg "$shadow"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          # A worker may acknowledge the candidate between the scan and this
          # read; the handled copy of the same sequence carries the same bytes.
          f="$dir/handled/${f##*/}"
          fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
        fi
        cmp -s "$want" "$have" || continue
        base=${f##*/}
        base=${base%.msg}
        # Report the copy that currently holds the record: the inbox root, else
        # the acknowledgement, else the hidden link - which is linked back into
        # the root here, because the caller verifies the path it is handed.
        rec="$dir/$base.msg"
        if [ -e "$rec" ] || [ -L "$rec" ]; then
          :
        elif [ -e "$dir/handled/$base.msg" ]; then
          rec="$dir/handled/$base.msg"
        elif [ -e "$shadow/$base" ]; then
          ln "$shadow/$base" "$rec" 2>/dev/null || true
          if [ ! -e "$rec" ]; then
            rec=''
            continue
          fi
        else
          rec=''
          continue
        fi
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  fm_task_inbox_verify "$rec" "$text" || return 1
  printf '%s' "$rec"
}

# The coalesce key a record carries, or fail when it carries none.
fm_task_inbox_coalesce_key() {  # <record-path>
  [ -f "$1" ] || return 1
  awk '
    $0 == "--" { exit }
    index($0, "coalesce=") == 1 { key = substr($0, 10) }
    END { if (key == "") exit 1; print key }
  ' "$1"
}

# Enqueue one coalescing record, then retire every other unhandled record it
# supersedes (see "Coalescing" above). Prints the new record path on stdout
# and, when it superseded any, one count line on stderr.
fm_task_inbox_write_coalesced() {  # <state-dir> <task-id> <text> <coalesce-key>
  local state=$1 task=$2 text=$3 key=$4 dir lock rec want have f status=0 removed=0
  local oldest='' ref='' heir ladder rec_base='' count last superseded_oldest=0 shadow shadow_name
  case "$key" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  dir=$(fm_task_inbox_dir "$state" "$task")
  fm_task_inbox_prepare_dirs "$dir" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "" "$key") || status=1
  if [ "$status" -eq 0 ] && want=$(mktemp "$dir/.dedup.XXXXXX") \
    && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    printf '%s' "$text" > "$want"
    oldest=$(fm_task_inbox_oldest_unhandled "$state" "$task") || oldest=
    if [ -n "$oldest" ] && [ "$oldest" != "$rec" ] && ref=$(mktemp "$dir/.dedup.XXXXXX"); then
      touch -r "$oldest" "$ref" 2>/dev/null || { rm -f "$ref"; ref=; }
    fi
    # Supersede every record this one replaces - including a tick whose visible
    # name the worker already deleted, which survives only as its hidden link.
    # Skipping that case would let the repair pass resurrect the superseded tick
    # beside its replacement.
    shadow=$(fm_task_inbox_shadow_dir "$dir")
    rec_base=${rec##*/}
    rec_base=${rec_base%.msg}
    for f in "$dir"/*.msg "$shadow"/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      [ "$f" != "$rec" ] || continue
      # The new record's own link is not a supersession candidate.
      [ "$f" != "$shadow/$rec_base" ] || continue
      # A shadow entry with no visible record is judged by the link itself; both
      # carry the same bytes, so the same predicate decides both.
      if [ "$(fm_task_inbox_coalesce_key "$f" 2>/dev/null)" != "$key" ]; then
        fm_task_inbox_is_fire_and_forget "$f" && continue
        fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
        cmp -s "$want" "$have" || continue
      fi
      shadow_name=${f##*/}
      shadow_name=${shadow_name%.msg}
      if [ "$f" = "$shadow/$shadow_name" ]; then
        # A link with no visible record behind it: retire it so the repair pass
        # cannot resurrect it, but do not count it - the record it belongs to is
        # already handled or already counted above, and the count reports the
        # records the worker no longer has to act on.
        rm -f "$shadow/$shadow_name" 2>/dev/null || continue
        continue
      fi
      if rm "$f" 2>/dev/null; then
        rm -f "$shadow/$shadow_name" 2>/dev/null || true
        removed=$((removed + 1))
        [ "$f" != "$oldest" ] || superseded_oldest=1
      fi
    done
    if [ -n "$ref" ] && [ "$superseded_oldest" -eq 1 ] \
      && heir=$(fm_task_inbox_oldest_unhandled "$state" "$task"); then
      touch -c -r "$ref" "$heir" 2>/dev/null || true
      ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
      IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
      if [ "$rec_base" = "${oldest##*/}" ]; then
        printf '%s\t%s\t%s\n' "${heir##*/}" "$count" "$last" > "$dir/.ring-state" 2>/dev/null || true
      fi
      if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "${oldest##*/}" ]; then
        printf '%s\n' "${heir##*/}" > "$dir/.escalated" 2>/dev/null || true
      fi
    fi
    rm -f "$want" "$have" ${ref:+"$ref"}
  else
    rm -f "${want:-}" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  fm_task_inbox_verify "$rec" "$text" || return 1
  [ "$removed" -eq 0 ] \
    || echo "fm-task-inbox: coalesced $removed superseded unhandled record(s) into ${rec##*/}" >&2
  printf '%s' "$rec"
}

# Acknowledge one or more records: each leaves the inbox root for handled/ and
# its hidden link is retired, so the repair pass can never bring it back. This is
# the one owner of the acknowledgement rule; bin/fm-inbox-ack.sh is a thin CLI
# over it, so the layout and the rule cannot drift apart.
# A record that survives only as its hidden link - a worker deleted the visible
# name and acknowledges it anyway, which is the incident this plane tolerates -
# is acknowledged from that link instead of being reported missing.
# Acknowledging an already acknowledged record is a successful no-op, so a re-run
# after a lost reply is harmless. Prints one line per record on stdout and one
# per refusal on stderr, and fails when anything was refused.
fm_task_inbox_acknowledge() {  # <state-dir> <task-id> <record>...
  local state=$1 task=$2 dir shadow arg base src refused=0
  case "$task" in ''|*/*|.|..) printf 'fm-task-inbox: not a task id: %s\n' "$task" >&2; return 1 ;; esac
  dir=$(fm_task_inbox_dir "$state" "$task")
  shadow=$(fm_task_inbox_shadow_dir "$dir")
  fm_task_inbox_prepare_dirs "$dir" || return 1
  shift 2
  for arg in "$@"; do
    base=${arg##*/}
    base=${base%.msg}
    case "$base" in
      ''|*[!0-9]*)
        printf 'fm-task-inbox: not a record sequence: %s (expected a number such as 035)\n' "$arg" >&2
        refused=$((refused + 1))
        continue
        ;;
    esac
    base=$(printf '%03d' "$((10#$base))")
    src="$dir/$base.msg"
    if [ -e "$src" ] || [ -L "$src" ]; then
      if mv -f "$src" "$dir/handled/$base.msg" 2>/dev/null; then
        rm -f "$shadow/$base" 2>/dev/null || true
        printf 'acknowledged: %s\n' "$dir/handled/$base.msg"
      else
        printf 'fm-task-inbox: could not move %s into %s/handled\n' "$src" "$dir" >&2
        refused=$((refused + 1))
      fi
      continue
    fi
    if [ -e "$dir/handled/$base.msg" ]; then
      # Retiring the link is part of acknowledging: a handled record whose link
      # survived would be restored if the worker clears handled/.
      rm -f "$shadow/$base" 2>/dev/null || true
      printf 'already acknowledged: %s\n' "$dir/handled/$base.msg"
      continue
    fi
    if [ -e "$shadow/$base" ]; then
      if ln "$shadow/$base" "$dir/handled/$base.msg" 2>/dev/null; then
        rm -f "$shadow/$base" 2>/dev/null || true
        printf 'acknowledged: %s (from its hidden link)\n' "$dir/handled/$base.msg"
      else
        printf 'fm-task-inbox: could not acknowledge %s.msg from %s\n' "$base" "$shadow" >&2
        refused=$((refused + 1))
      fi
      continue
    fi
    printf 'fm-task-inbox: no record %s.msg in %s (never delivered, or already acknowledged)\n' "$base" "$dir" >&2
    refused=$((refused + 1))
  done
  [ "$refused" -eq 0 ]
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# Quote one word for a line a worker will run as a shell command. A home path
# may contain spaces, and an unquoted acknowledgement command would then be
# unrunnable exactly where the record lives.
fm_task_inbox_quote() {  # <word>
  printf '%q' "$1"
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The plain rename
# into handled/ comes first because it is the acknowledgement every backend's
# granted paths permit; the helper comes second because it acknowledges the same
# way and retires the hidden link immediately.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs task state ack inbox
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  # A record the worker already acknowledged sits in handled/; the inbox it
  # belongs to is one level up, and the command must name that inbox rather than
  # a "<id>.inbox/handled.inbox" that cannot exist.
  case "${abs##*/}" in
    handled) abs=${abs%/*} ;;
  esac
  task=${abs##*/}
  task=${task%.inbox}
  state=${abs%/*}
  ack=$(fm_task_inbox_ack_command)
  inbox=$(fm_task_inbox_quote "$abs")
  printf 'Firstmate instruction waiting: list %s/*.msg and, in numeric order, read and act on each, then acknowledge each handled record by moving it into %s/handled/. The plain form is mv %s/NNN.msg %s/handled/. Where that helper path is reachable, %s %s %s NNN acknowledges the same way and also retires the hidden link. Never delete or clear the inbox, because deleting is not acknowledging.' \
    "$inbox" "$inbox" "$inbox" "$inbox" \
    "$(fm_task_inbox_quote "$ack")" "$(fm_task_inbox_quote "$state")" \
    "$(fm_task_inbox_quote "$task")"
}

# Ring the doorbell, best-effort: one advisory composer pre-check, then the
# backend's submit machinery with a minimal retry budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# (the watcher re-rings later), 2 the backend send failed. No return value is
# delivery proof; the acknowledgement move is the only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict defers,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  line=$(fm_task_inbox_doorbell_line "$rec")
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Repair the unhandled records a worker's own cleanup may have deleted, and
# retire the shadows of records that are now acknowledged or superseded. The
# inbox root is what the worker reads, so the shadow is not an archive: a record
# present in neither the root nor handled/ was deleted rather than handled, and
# is linked back with its original mtime so the ladder still ages it correctly.
# Prints one line per repaired record so the watcher's log shows the repair.
fm_task_inbox_restore_unhandled() {  # <state-dir> <task-id>
  local state=$1 task=$2 dir shadow s base restored=0 adopted=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  shadow=$(fm_task_inbox_shadow_dir "$dir")
  [ -d "$dir" ] || return 0
  # An inbox that predates this repair has no link directory yet; creating it is
  # what lets the adoption below protect its existing unread records.
  mkdir -p "$shadow" 2>/dev/null || return 0
  # Adopt an unread record that predates this repair - a record queued by an
  # earlier version has no link yet, and a link only created at publish time
  # would leave exactly the oldest, most likely-deleted records unprotected.
  for s in "$dir"/*.msg; do
    [ -e "$s" ] || continue
    base=${s##*/}
    base=${base%.msg}
    [ -e "$shadow/$base" ] && continue
    if ln "$s" "$shadow/$base" 2>/dev/null; then
      adopted=$((adopted + 1))
    fi
  done
  [ "$adopted" -eq 0 ] \
    || printf 'fm-task-inbox: adopted %s pre-existing unread record(s) in %s for deletion repair\n' \
      "$adopted" "$dir" >&2
  for s in "$shadow"/*; do
    [ -e "$s" ] || continue
    base=${s##*/}
    if [ -e "$dir/$base.msg" ] || [ -L "$dir/$base.msg" ]; then
      continue
    fi
    if [ -e "$dir/handled/$base.msg" ]; then
      rm -f "$s"
      continue
    fi
    if ln "$s" "$dir/$base.msg" 2>/dev/null; then
      restored=$((restored + 1))
      printf 'fm-task-inbox: restored unread record %s.msg deleted from %s\n' "$base" "$dir" >&2
    fi
  done
  return 0
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  # A worker may delete records in its own inbox; repair them before the ladder
  # reads, so a deleted instruction still rings and escalates as unhandled.
  fm_task_inbox_restore_unhandled "$1" "$2" || true
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    # A different (or first) oldest message: the previous ladder is stale.
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither a dead pane nor permanently
# blocked composer can retry silently forever. A concurrently removed inbox is
# a successful no-op; otherwise failure means the caller must surface the
# unwritable ladder while the record remains unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
