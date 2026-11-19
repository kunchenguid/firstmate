#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the backend endpoint carries
# only a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# submitted to, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/bundled/       same-kind notices collapsed by a newer notice;
#                              audit trail only: sequence allocation scans it so
#                              a number is never reused, but the worker listing,
#                              the ladder, and the idempotent dedup never see it
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.busy-state   consecutive busy deferrals: "<msg>\t<count>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.retry-ring   name of a fire-and-forget record still owed its
#                              one retry ring (fm_task_inbox_mark_retry)
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   body-terminator=1          present on records written with a synthetic final newline
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#                              (it still gets one retry ring; see below)
#   priority=captain|notice     present only when the record is not an ordinary
#                              request from firstmate: captain names a relayed
#                              captain message, notice a mechanical notice.
#                              Absent means main, so every legacy record reads as
#                              a main-priority request and ordering never changes
#                              for records written before this field existed
#   notice-kind=<kind>          on a notice: the kind whose repetitions collapse
#                              (see bundling below)
#   bundle=<n>                  present only when this record collapsed n earlier
#                              unhandled notices of the same kind at write time;
#                              the body is the NEWEST text, losslessly replacing
#                              the collapsed ones, which move to bundled/ as the
#                              audit copy of what was replaced
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans the inbox
# root, handled/, and bundled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Priority order (reading contract, restated by the doorbell and the brief
# scaffold): captain records first, then main (the default), then notices;
# numeric order within one priority. The worker acts in that order;
# fm_task_inbox_list_ordered is the one implementation of it, and the ladder's
# tracked record (fm_task_inbox_oldest_unhandled) follows the same rule so a
# stale notice escalation never suppresses a captain message's ring.
#
# Notice bundling (fm_task_inbox_write / _write_idempotent with a notice kind):
# a new notice of kind K written while unhandled records of the same kind K sit
# in the root collapses them: the new record is written FIRST with bundle=<sum
# of the collapsed records' own bundle counts plus their number> and the newest
# text, then the collapsed records move to bundled/. Write-before-move means a
# crash mid-bundle can only leave the older copies visible in the root (the
# worker sees a duplicate, never a loss) and the next same-kind write converges.
# Only same-kind notices collapse: requests from firstmate, captain relays, and
# every other notice kind keep their own records, and a record that reached
# handled/ or bundled/ is never resurrected. A collapsed record that carried a
# pending-reply corr is superseded by the caller (bin/fm-send.sh resolves the
# expectation via bin/fm-pending-reply-lib.sh), so a bundled-away request
# cannot keep firing recovery reposts and missed alarms.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect another draft in a proven pending
# composer; an unsubmitted copy of this doorbell is retried. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: due actions deferred
# by the caller's delivery guard consume a separate durable consecutive-poll budget,
# FM_TASK_INBOX_BUSY_MAX. At that bound the same escalation path surfaces a
# stuck-busy reason without submission. An allowed due check or acknowledgement
# resets this budget. fm-busy-lib.sh owns the backend-specific delivery guard.
# Fire-and-forget retries remain outside escalation. A positively
# dead or missing endpoint skips delivery and the ladder and escalates directly.
# This library owns the schedule, durable budgets, and escalation marker.
# If delivery-attempt or busy-deferral bookkeeping fails while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Retry ring (fm_task_inbox_mark_retry): only while config/wait-no-turns is
# present. A fire-and-forget record never enters the ladder, but when
# fm-send's ring at enqueue did not land
# (fm_task_inbox_ring returned 1 or 2) it marks the record, and one grace later
# the due action is `retry`: once the worker has no open decision of its own,
# the watcher rings once more and spends the mark
# whatever the result, so the record never rings a third time and never
# escalates. A waiting worker does not poll its inbox (bin/fm-brief.sh), so
# without this retry the record could sit unread until a checkpoint. A pending ordinary record's
# ladder rings the same inbox, so the retry waits behind it, and an
# acknowledged record drops its mark. The remote steer leg has no watcher
# ladder and owes no retry.
#
# Inbox names containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_BUSY_MAX     default 2; consecutive busy-deferred due polls before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BUSY_MAX_DEFAULT=2
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

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

fm_task_inbox_busy_max() {
  local m=${FM_TASK_INBOX_BUSY_MAX:-$FM_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  # Check the length before numeric comparison so oversized input cannot overflow.
  if [ "${#m}" -gt 9 ] || [ "$m" -eq 0 ]; then
    m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT
  fi
  printf '%s' "$m"
}

# Persist before returning the new count, so a fresh watcher continues the same
# bounded wait. A removed or acknowledged record is a quiet no-op.
fm_task_inbox_record_busy() {  # <state-dir> <task-id> <record-path>
  local dir base previous count
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  { IFS=$(printf '\t') read -r previous count < "$dir/.busy-state"; } 2>/dev/null || true
  [ "${previous:-}" = "$base" ] || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ -f "$3" ] || { printf '0'; return 0; }
  count=$((count + 1))
  if ! { printf '%s\t%s\n' "$base" "$count" > "$dir/.busy-state"; } 2>/dev/null; then
    [ -f "$3" ] || { printf '0'; return 0; }
    return 1
  fi
  printf '%s' "$count"
}

fm_task_inbox_clear_busy() {  # <state-dir> <task-id>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  rm -f "$dir/.busy-state" 2>/dev/null
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root, handled/, AND bundled/ so an
# acknowledged or collapsed sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled" "$dir/bundled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Validate a notice kind. The charset matches decision keys so a kind can
# never forge or break a header line.
fm_task_inbox_valid_notice_kind() {  # <kind>
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Phase 1 of a bundle, before the new record is written: count the unhandled
# same-kind notices the new record will replace and list their root paths in
# _FM_TASK_INBOX_BUNDLE_COUNT / _FM_TASK_INBOX_BUNDLE_CANDIDATES. No record is
# touched, so a crash here changes nothing. Each existing bundle record counts
# itself plus what it had collapsed, so the new count is the true number of
# notices the one new record replaces. Caller must hold .seq.lock.
_fm_task_inbox_scan_kind_locked() {  # <inbox-dir> <kind>
  local dir=$1 kind=$2 f n
  _FM_TASK_INBOX_BUNDLE_COUNT=0
  _FM_TASK_INBOX_BUNDLE_CANDIDATES=''
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    [ "$(fm_task_inbox_notice_kind "$f")" = "$kind" ] || continue
    n=$(fm_task_inbox_bundle_count "$f")
    _FM_TASK_INBOX_BUNDLE_COUNT=$((_FM_TASK_INBOX_BUNDLE_COUNT + n + 1))
    _FM_TASK_INBOX_BUNDLE_CANDIDATES="${_FM_TASK_INBOX_BUNDLE_CANDIDATES}${_FM_TASK_INBOX_BUNDLE_CANDIDATES:+$'\n'}$f"
  done
}

# Phase 2 of a bundle, after the new record is durably written: move the
# scanned candidates into bundled/ and name the moved paths in
# _FM_TASK_INBOX_BUNDLED_RECS (one path per collapsed record) for the caller's
# corr supersession. Write-before-move means a crash can only leave an old copy
# visible in the root (a duplicate the worker simply also handles), never a
# loss; a move that fails mid-list leaves the unmoved copies in the root, where
# the next same-kind write converges by bundling them too. Caller must hold
# .seq.lock.
_fm_task_inbox_move_bundled_locked() {  # <inbox-dir>
  local dir=$1 f moved=''
  _FM_TASK_INBOX_BUNDLED_RECS=''
  [ -n "${_FM_TASK_INBOX_BUNDLE_CANDIDATES:-}" ] || return 0
  mkdir -p "$dir/bundled" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || continue
    if mv -- "$f" "$dir/bundled/" 2>/dev/null; then
      moved="${moved}${moved:+$'\n'}$dir/bundled/${f##*/}"
    fi
  done <<EOF
$_FM_TASK_INBOX_BUNDLE_CANDIDATES
EOF
  _FM_TASK_INBOX_BUNDLED_RECS=$moved
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
# <notice-kind> is empty for every non-notice write; <bundle-count> is written
# only when a same-kind bundling collapsed earlier records for this one;
# <priority> captain names a relayed captain message (main needs no header,
# notice is implied by a notice kind and never passed separately).
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode] [notice-kind] [bundle-count] [priority]
  local dir=$1 text=$2 delivery_mode=${3:-} notice_kind=${4:-} bundle_count=${5:-0} priority=${6:-}
  local seq tmp rec status=0
  case "$bundle_count" in '' | *[!0-9]*) bundle_count=0 ;; esac
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$text" in
      *$'\n') : ;;
      *) printf 'body-terminator=1\n' ;;
    esac
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    if [ -n "$notice_kind" ]; then
      printf 'priority=notice\n'
      printf 'notice-kind=%s\n' "$notice_kind"
      [ "$bundle_count" -le 0 ] || printf 'bundle=%s\n' "$bundle_count"
    elif [ "$priority" = captain ]; then
      printf 'priority=captain\n'
    fi
    printf -- '--\n'
    case "$text" in
      *$'\n') printf '%s' "$text" ;;
      *) printf '%s\n' "$text" ;;
    esac
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
# With a notice kind, first bundles the unhandled same-kind notices (see the
# header) and sets _FM_TASK_INBOX_BUNDLED_RECS / _FM_TASK_INBOX_BUNDLE_INTO for
# the caller's corr supersession; both are empty strings when nothing collapsed.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode] [notice-kind] [priority]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} notice_kind=${5:-} priority=${6:-}
  local dir lock rec status=0 bundle=0
  _FM_TASK_INBOX_BUNDLED_RECS=''
  _FM_TASK_INBOX_BUNDLE_INTO=''
  _FM_TASK_INBOX_BUNDLE_COUNT=0
  _FM_TASK_INBOX_BUNDLE_CANDIDATES=''
  if [ -n "$notice_kind" ]; then
    fm_task_inbox_valid_notice_kind "$notice_kind" || return 1
    priority=notice
  else
    case "$priority" in
      '' | main) priority='' ;;
      captain) ;;
      *) return 1 ;;
    esac
  fi
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if [ -n "$notice_kind" ]; then
    _fm_task_inbox_scan_kind_locked "$dir" "$notice_kind"
    bundle=$_FM_TASK_INBOX_BUNDLE_COUNT
  fi
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode" "$notice_kind" "$bundle" "$priority") || status=1
  if [ "$status" -eq 0 ] && [ -n "$notice_kind" ]; then
    _fm_task_inbox_move_bundled_locked "$dir" || true
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  if [ -n "${_FM_TASK_INBOX_BUNDLED_RECS:-}" ]; then
    _FM_TASK_INBOX_BUNDLE_INTO=$rec
  fi
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body and delivery mode already exists, unhandled or acknowledged in handled/,
# no new record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
# With a notice kind, the dedup scan deliberately does NOT look at bundled/:
# a collapsed record is superseded, so an exact retry after a bundle writes a
# fresh record and re-delivers (a duplicate, never a loss).
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode] [notice-kind] [priority]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} notice_kind=${5:-} priority=${6:-}
  local dir lock want have f rec='' status=0 bundle=0
  local first_line=${3%%$'\n'*} scan_dir
  _FM_TASK_INBOX_BUNDLED_RECS=''
  _FM_TASK_INBOX_BUNDLE_INTO=''
  _FM_TASK_INBOX_BUNDLE_COUNT=0
  _FM_TASK_INBOX_BUNDLE_CANDIDATES=''
  if [ -n "$notice_kind" ]; then
    fm_task_inbox_valid_notice_kind "$notice_kind" || return 1
    priority=notice
  else
    case "$priority" in
      '' | main) priority='' ;;
      captain) ;;
      *) return 1 ;;
    esac
  fi
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      # One grep per directory replaces per-record parsing of unrelated history.
      # Header/other-line hits are harmless: mode and exact body still decide.
      # Empty bodies also match the separator, including empty legacy records.
      [ -n "$text" ] || first_line=--
      while IFS= read -r -d '' f; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done < <(
        # Expand handled/ only AFTER scanning pending records: an acknowledgement
        # racing grep must remain visible even if its original path disappeared.
        for scan_dir in "$dir" "$dir/handled"; do
          # A read/argument-limit error must not turn an exact retry into a new
          # request. Fall back to the original scan only on error, not no-match.
          LC_ALL=C grep -lFx --null -- "$first_line" "$scan_dir"/*.msg 2>/dev/null || {
            [ "$?" -eq 1 ] || printf '%s\0' "$scan_dir"/*.msg
          }
        done
      )
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    if [ -n "$notice_kind" ]; then
      _fm_task_inbox_scan_kind_locked "$dir" "$notice_kind"
      bundle=$_FM_TASK_INBOX_BUNDLE_COUNT
    fi
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode" "$notice_kind" "$bundle" "$priority") || status=1
    if [ "$status" -eq 0 ] && [ -n "$notice_kind" ]; then
      _fm_task_inbox_move_bundled_locked "$dir" || true
    fi
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  if [ -n "${_FM_TASK_INBOX_BUNDLED_RECS:-}" ]; then
    _FM_TASK_INBOX_BUNDLE_INTO=$rec
  fi
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local meta body_offset synthetic total count
  [ -f "$1" ] || return 1
  meta=$(LC_ALL=C awk '
    $0 == "body-terminator=1" { synthetic=1 }
    { bytes += length($0) + 1 }
    $0 == "--" { printf "%d\t%d\n", bytes, synthetic; exit }
  ' "$1") || return 1
  IFS=$(printf '\t') read -r body_offset synthetic <<EOF
$meta
EOF
  case "$body_offset" in ''|*[!0-9]*) return 1 ;; esac
  total=$(wc -c < "$1") || return 1
  count=$((total - body_offset))
  if [ "$synthetic" = 1 ]; then
    [ "$count" -gt 0 ] || return 1
    count=$((count - 1))
  fi
  dd if="$1" bs=1 skip="$body_offset" count="$count" 2>/dev/null
}

# The constant self-describing doorbell line for the inbox containing a record.
# It names the inbox by the literal "$FM_TASK_INBOX", which bin/fm-spawn.sh
# exports into every launch as the inbox's absolute path, so the worker can
# resolve it from its own environment even after losing its brief context.
# The short `<task>.inbox` name follows as the fallback for a worker launched
# before that export, whose brief carries the full path (bin/fm-dod-lib.sh
# role contract, bin/fm-brief.sh inbox section). No absolute path is printed,
# so the line's length never grows with the home's depth: a long line wraps
# past what a harness composer read can prove, and a Herdr submit then reports
# it did not reach the pane on every re-ring. The leading `: ` is the POSIX
# shell no-op, so the same line typed into a pane whose agent has exited (a
# bare shell) runs nothing; see the dead-pane note in the header. A
# non-printable inbox name fails without output so terminal controls never
# reach the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs name quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  name=${abs##*/}
  case "$name" in
    ''|*[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$name" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your '%s' steering inbox, act by priority - captain, main, notices, numeric order within one - then mv each into handled/." \
    "$quoted"
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# other than our own doorbell (the watcher re-rings later), 2 the backend send
# failed, 3 skipped because the endpoint is positively dead or missing (nothing
# typed; recovery owns the record). No return value is delivery proof; the
# acknowledgement move is the only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict can defer,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
# A pending composer holding exactly our own doorbell line is a previous ring
# whose Enter never landed, so on an agent not reported busy it is submitted
# rather than skipped; skipping it would block every later ring. On both paths
# a lost first Enter gets one confirmed retry.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" \
        && [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != busy ] \
        || return 1
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 0
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      return 0
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 2 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

# Whether the composer's content, ignoring line wrapping, is exactly <line>.
fm_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local cap held
  fm_backend_source "$1" || return 1
  cap=$(fm_backend_capture "$1" "$2" "$FM_COMPOSER_CAPTURE_LINES" "${4:-}" 2>/dev/null) || return 1
  held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
  [ -n "$held" ] && [ "$(printf '%s' "$held" | tr -d '[:space:]')" = "$(printf '%s' "$3" | tr -d '[:space:]')" ]
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

# The priority class of one record: captain, main, or notice. Absent or an
# unreadable header means main, so every legacy record and every write that
# does not name a priority is an ordinary request from firstmate.
fm_task_inbox_priority() {  # <record-path>
  local p
  p=$(awk '
    $0 == "--" { exit }
    $0 == "priority=captain" || $0 == "priority=main" || $0 == "priority=notice" { print substr($0, 10); exit }
  ' "$1" 2>/dev/null) || p=''
  case "$p" in
    captain | main | notice) printf '%s' "$p" ;;
    *) printf 'main' ;;
  esac
}

# Reading-order rank of a priority class: 0 captain, 1 main, 2 notice.
fm_task_inbox_priority_rank() {  # <class>
  case "$1" in
    captain) printf '0' ;;
    notice) printf '2' ;;
    *) printf '1' ;;
  esac
}

# The notice kind of one record, or empty when it is not a bundling notice.
# A malformed kind header reads as absent: the record then sorts as its
# priority says (notice) but never takes part in a bundle.
fm_task_inbox_notice_kind() {  # <record-path>
  local k
  k=$(awk '
    $0 == "--" { exit }
    $0 ~ /^notice-kind=/ { print substr($0, 13); exit }
  ' "$1" 2>/dev/null) || k=''
  case "$k" in
    '' | *[!A-Za-z0-9._-]*) printf '' ;;
    *) printf '%s' "$k" ;;
  esac
}

# How many earlier same-kind notices this record replaced at write time.
fm_task_inbox_bundle_count() {  # <record-path>
  local n
  n=$(awk '
    $0 == "--" { exit }
    $0 ~ /^bundle=/ { print substr($0, 8); exit }
  ' "$1" 2>/dev/null) || n=''
  case "$n" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$((10#$n))" ;;
  esac
}

# All unhandled records in reading order: priority rank first (captain, main,
# notice), then numeric sequence within one priority - the order the doorbell
# names and the brief scaffold tells the worker to act in. Handled and bundled
# records are not listed; nothing here reads them.
fm_task_inbox_list_ordered() {  # <state-dir> <task-id>
  local dir f
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    printf '%s\t%s\t%s\n' \
      "$(fm_task_inbox_priority_rank "$(fm_task_inbox_priority "$f")")" \
      "$(fm_task_inbox_seq_of "${f##*/}" 2>/dev/null || printf '0')" \
      "$f"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n | cut -f3-
}

# The ladder's tracked unhandled record: the first in reading order - highest
# priority first, then oldest sequence within it - skipping fire-and-forget
# records, or fail when none exists. The name keeps "oldest" because within one
# priority that is exactly what it is.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local f
  while IFS= read -r f; do
    fm_task_inbox_is_fire_and_forget "$f" && continue
    printf '%s' "$f"
    return 0
  done < <(fm_task_inbox_list_ordered "$1" "$2")
  return 1
}

# Owe a fire-and-forget record its one retry ring (see the header). A newer
# mark replaces an older one: a ring names the whole inbox, not one record.
fm_task_inbox_mark_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  { printf '%s\n' "${3##*/}" > "$dir/.retry-ring"; } 2>/dev/null
}

# Spend the retry mark after its ring, only while it still names that record:
# a newer mark written meanwhile is owed its own retry and survives. Fails only
# when the processed record's mark stays behind.
fm_task_inbox_clear_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.retry-ring" 2>/dev/null)" = "${3##*/}" ] || return 0
  rm -f "$dir/.retry-ring" 2>/dev/null
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   retry <record-path>       a fire-and-forget record's one retry ring is due
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last f any=0
  dir=$(fm_task_inbox_dir "$1" "$2")
  grace=$(fm_task_inbox_grace_secs)
  # The ladder tracks the record first in reading order among those past grace:
  # priority rank decides which unhandled record a ring or escalation is FOR,
  # while the grace check stays per-record, so a fresh captain message never
  # starves an older notice's re-ring and a stale notice's escalation never
  # suppresses a captain message. Equal priority keeps numeric order.
  oldest=''
  while IFS= read -r f; do
    fm_task_inbox_is_fire_and_forget "$f" && continue
    any=1
    [ "$(fm_path_age "$f")" -ge "$grace" ] || continue
    oldest=$f
    break
  done < <(fm_task_inbox_list_ordered "$1" "$2")
  if [ "$any" = 0 ]; then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" 2>/dev/null || true
    # The one retry ring exists only while config/wait-no-turns is present.
    # Absent, a mark is left untouched and the inbox stays quiet, as before.
    if [ -e "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! fm_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(fm_path_age "$dir/.retry-ring")" -ge "$(fm_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  if [ -z "$oldest" ]; then
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
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
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
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
