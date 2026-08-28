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
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line, which does not need to be reliable because
# ringing it again is free. A duplicated doorbell is a no-op by construction
# (the worker finds the inbox empty or already handled), a swallowed doorbell
# is detected by the absence of the worker's acknowledgement and re-rung on a
# bounded schedule, and a worker that never acknowledges surfaces through the
# ordinary stale wake into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/.NNN.resolve  the decision closure NNN.msg's answer owes, held
#                              until the worker acknowledges that record.
#                              Dot-prefixed on purpose: a worker that sweeps
#                              the inbox root with `mv <inbox>/* handled/`
#                              must not carry an uncommitted closure into
#                              handled/, where it would never commit
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement;
#                              a committed .NNN.resolve is filed here too
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder:
#                              "<msg>\t<count>\t<epoch>\t<blocked-count>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.commit-escalated
#                              closure names whose failed commit was already
#                              surfaced, so later polls retry them quietly
#   <task>.inbox/.commit-failed
#                              the closure names the LAST commit pass failed
#                              on for the first time; the caller folds exactly
#                              these into .commit-escalated after queuing its
#                              wake, so a closure acknowledged after that pass
#                              is never marked surfaced before its own first
#                              attempt
#   <task>.inbox/.NNN.resolve.committed
#                              per-sidecar ledger of the decision identities
#                              that sidecar has already durably closed, so a
#                              retry after a partial commit closes each at
#                              most once; removed once the sidecar is filed
#   <task>.inbox/.orphan-escalated
#                              append-only names of orphaned sidecars already
#                              surfaced (the ladder's orphaned cause), so each
#                              escalates exactly once; a name here retires its
#                              sidecar for every reader even while the move
#                              below is still owed, and later polls retry it
#   <task>.inbox/handled/orphaned/NNN.resolve
#                              an escalated orphaned sidecar, set aside there
#                              so it never reads as a pending answer again
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# ACKNOWLEDGEMENT-GATED DECISION CLOSURE (fm_task_inbox_defer_resolution /
# fm_task_inbox_commit_resolutions). A steer that answers an open keyed
# decision must not read as answered until the worker has actually seen it: the
# doorbell can be skipped to protect real pending composer text, so "durably
# enqueued" and "the worker knows" are different facts. The answering caller
# therefore parks the closure next to its record instead of writing it:
#   schema=fm-task-inbox-resolve.v1
#   at=<utc timestamp>
#   status-key=<key>           repeated; closes that key in the task status log
#   hold-id=<task-id>          repeated; fed to the one keyed-answer intake
#   --
#   <single-line capped answer excerpt, exactly as the closing line carries it>
# The closure commits only once NNN.msg has moved into handled/ - the worker's
# own acknowledgement - and both records are then filed together. Until then
# the decision stays open in every durable ledger, which is the truthful and
# the safe direction: the answer re-surfaces instead of a stopped worker
# reading as a moving one. A lost or unwritable sidecar leaves the decision
# open for the same reason.
#
# A commit is idempotent and its failure is bounded. Each identity closes at
# most once: a status key whose exact closing line is already in the status
# log is not appended again, and the keyed-answer intake is itself idempotent
# for a replayed answer while a captain-held task closed through another
# channel in the meantime counts as closed, not failed. A sidecar that still
# cannot commit stays parked as evidence and is retried quietly on later polls;
# the caller surfaces that failure exactly once per sidecar through
# fm_task_inbox_record_commit_escalated, so a permanently failing close can
# neither grow the status log nor wake firstmate on every poll.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. It
# escalates for one of four stated causes, and every one of them is bounded:
#   attempts  FM_TASK_INBOX_RING_MAX delivery attempts produced no
#             acknowledgement (default 3, so ~4 grace periods after enqueue)
#   blocked   FM_TASK_INBOX_BLOCKED_MAX attempts were SKIPPED because the
#             composer provenly holds pending text (default 1, so ~1 grace
#             period plus one poll interval after enqueue, about 90-100s at
#             defaults: fm-send's own initial skip is not in the ladder, the
#             watcher's first attempt happens at >=1 grace, that attempt's
#             own skip is what the blocked count checks, and the check sits
#             before the attempt-spacing check, so the very next poll after
#             the first skipped attempt already escalates). Repeating a skip
#             cannot deliver anything: the composer
#             is occupied by text the worker will not clear itself, so the
#             remaining attempt budget would buy only silence. Escalating on
#             the first proven skip is what turns that condition from a quiet
#             wait into a named, fixable one.
#   overdue   the record has been unhandled for FM_TASK_INBOX_UNHANDLED_MAX_SECS
#             (default 900) whatever the pane is doing. This is the absolute
#             bound, and one of the two causes the caller must surface while
#             the pane reads busy: a busy worker legitimately has not reached
#             a turn boundary yet, but "busy" must never mean "unread forever".
#   orphaned  a parked closure's bound record is in NEITHER the inbox root nor
#             handled/ - a contract violation (the worker removed the record
#             instead of moving it), so the closure can never commit on its
#             own. Surfaced whatever the pane is doing, once per sidecar, and
#             then set aside under handled/orphaned/ so it never reads as a
#             pending answer again (_fm_task_inbox_orphaned_sidecar,
#             fm_task_inbox_record_orphan_escalated); the surfaced marker
#             alone already retires it from every reader, so a retirement
#             that fails leaves nothing reading as pending or unseen.
# The caller owns the busy check (a busy pane just waits for the ring ladder -
# the record is durable and the worker reaches a turn boundary) and the wake
# emission; this library owns only the schedule. If attempt bookkeeping cannot
# be persisted while the record remains unhandled, the caller surfaces that
# failure instead of retrying silently; a concurrently removed inbox is a quiet
# no-op. Escalation deliberately queues the wake before writing the
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
#   FM_TASK_INBOX_BLOCKED_MAX  default 1; composer-blocked skips before escalation
#   FM_TASK_INBOX_UNHANDLED_MAX_SECS
#                              default 900; absolute unhandled bound, escalates
#                              regardless of attempts or a busy pane

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"
# The committed closing line is capped by the ONE owner of that cut, so a
# deferred close and a direct one render identically.
# shellcheck source=bin/fm-line-cap-lib.sh
. "$_FM_TASK_INBOX_LIB_DIR/fm-line-cap-lib.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_RESOLVE_SCHEMA='fm-task-inbox-resolve.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BLOCKED_MAX_DEFAULT=1
FM_TASK_INBOX_UNHANDLED_MAX_DEFAULT=900
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

# One numeric-env reader for every ladder bound: an unset, empty, or
# non-numeric override falls back to the documented default rather than
# disabling the bound it controls.
_fm_task_inbox_bound() {  # <value> <default>
  local v=$1 d=$2
  case "$v" in ''|*[!0-9]*) v=$d ;; esac
  printf '%s' "$v"
}

fm_task_inbox_grace_secs() {
  _fm_task_inbox_bound "${FM_TASK_INBOX_GRACE_SECS:-}" "$FM_TASK_INBOX_GRACE_DEFAULT"
}

fm_task_inbox_ring_max() {
  _fm_task_inbox_bound "${FM_TASK_INBOX_RING_MAX:-}" "$FM_TASK_INBOX_RING_MAX_DEFAULT"
}

fm_task_inbox_blocked_max() {
  _fm_task_inbox_bound "${FM_TASK_INBOX_BLOCKED_MAX:-}" "$FM_TASK_INBOX_BLOCKED_MAX_DEFAULT"
}

fm_task_inbox_unhandled_max_secs() {
  _fm_task_inbox_bound "${FM_TASK_INBOX_UNHANDLED_MAX_SECS:-}" "$FM_TASK_INBOX_UNHANDLED_MAX_DEFAULT"
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

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
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
    [ -e "$lock" ] || [ -L "$lock" ] || return 1
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
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
  printf '%s' "$rec"
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

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  printf 'Firstmate instruction waiting: list %s/*.msg and, in numeric order, read and act on each, then mv each handled file to %s/handled/.' \
    "$abs" "$abs"
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

# --- acknowledgement-gated decision closure ---------------------------------
# See the header contract: an answer's closure is parked next to its record and
# commits only when the worker acknowledges that record.

# Path of the deferred-closure sidecar bound to one inbox record: a dot file
# beside the record, so a glob sweep of the inbox root cannot carry it away.
fm_task_inbox_resolution_path() {  # <record-path>
  local rec=$1 base
  base=${rec##*/}
  printf '%s/.%s.resolve' "${rec%/*}" "${base%.msg}"
}

# The inbox record a sidecar is bound to.
fm_task_inbox_resolution_record() {  # <resolution-path>
  local path=$1 base
  base=${path##*/}
  base=${base#.}
  printf '%s/%s.msg' "${path%/*}" "${base%.resolve}"
}

# Per-sidecar committed-identity ledger: <resolution-path>.committed, one
# already-closed "status-key:K" or "hold-id:K" identity per line. Scoped to
# THIS sidecar, never to the status log's text, so a key legitimately reopened
# and answered again with identical wording is never mistaken for a retry of
# this same sidecar's own earlier append - a global "does this exact line
# already exist anywhere in the status log" check cannot tell the two apart
# and silently orphans the reopened decision. Removed once the sidecar itself
# is filed under handled/, since nothing checks it again after that.
_fm_task_inbox_resolution_committed_path() {  # <resolution-path>
  printf '%s.committed' "$1"
}

_fm_task_inbox_resolution_is_committed() {  # <resolution-path> <identity>
  grep -Fxq -- "$2" "$(_fm_task_inbox_resolution_committed_path "$1")" 2>/dev/null
}

_fm_task_inbox_resolution_mark_committed() {  # <resolution-path> <identity>
  printf '%s\n' "$2" >> "$(_fm_task_inbox_resolution_committed_path "$1")"
}

# Park the closure an answer owes beside its record: temp-write, then atomic
# rename, so a torn write is never mistaken for a committable closure. Prints
# the sidecar path. <status-keys> and <hold-ids> are space-separated and may be
# empty; a sidecar naming neither is refused rather than written as a closure
# that would close nothing.
fm_task_inbox_defer_resolution() {  # <record-path> <note> <status-keys> <hold-ids>
  local rec=$1 note=$2 keys=$3 holds=$4 dir path tmp k status=0
  [ -n "$keys$holds" ] || return 1
  dir=${rec%/*}
  [ -d "$dir" ] || return 1
  path=$(fm_task_inbox_resolution_path "$rec")
  # A non-file already sitting on the sidecar path would swallow the rename
  # into itself and report success for a closure that can never be read back.
  [ ! -e "$path" ] || [ -f "$path" ] || return 1
  tmp=$(mktemp "$dir/.resolve-staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_RESOLVE_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for k in $keys; do printf 'status-key=%s\n' "$k"; done
    for k in $holds; do printf 'hold-id=%s\n' "$k"; done
    printf -- '--\n'
    printf '%s' "$note"
  } > "$tmp" && mv "$tmp" "$path" && [ -f "$path" ] || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$path"
}

# Values of one repeated header field in a resolution record, one per line.
fm_task_inbox_resolution_values() {  # <resolution-path> <field>
  local path=$1 field=$2
  [ -f "$path" ] || return 1
  awk -v f="$field=" '
    $0 == "--" { exit }
    index($0, f) == 1 { print substr($0, length(f) + 1) }
  ' "$path"
}

# 0 when the worker has acknowledged <record-path>: it is in handled/ and no
# longer in the inbox root. Both present is deliberately NOT an
# acknowledgement - the safe reading while a move is in flight.
fm_task_inbox_is_acknowledged() {  # <record-path>
  local rec=$1 dir base
  dir=${rec%/*}
  base=${rec##*/}
  [ ! -e "$dir/$base" ] || return 1
  [ -f "$dir/handled/$base" ]
}

# A CONTRACT VIOLATION, not a race: a sidecar bound to a record that is in
# NEITHER the inbox root NOR handled/. The brief instructs the worker to `mv`
# its acknowledged record into handled/; a worker that `rm`s it instead (or
# any other loss of the .msg between root and handled/) leaves the sidecar in
# a third state fm_task_inbox_is_acknowledged cannot distinguish from "still
# pending": not pending in the sense the ladder can act on, because
# fm_task_inbox_oldest_unhandled only ever globs *.msg files and so can never
# see a sidecar whose .msg is simply gone, and not acknowledged either, so
# fm_task_inbox_commit_resolutions's acknowledged-only scan never reaches it.
# Left undetected, such a sidecar never commits (its answer never actually
# closes) and never escalates (the ladder finds nothing left to watch), so an
# already-delivered answer would read open in every durable record forever
# with no path back to firstmate's attention - exactly the silent failure this
# whole change exists to eliminate. Once surfaced, the sidecar is set aside
# under handled/orphaned/ (fm_task_inbox_record_orphan_escalated) so a closure
# firstmate then settles by hand cannot keep feeding
# fm_task_inbox_pending_answer_keys and mislabel the same key, reopened later,
# as already answered. A sidecar already surfaced
# (_fm_task_inbox_sidecar_is_surfaced_orphan) is skipped here, in the scan
# itself: an orphan whose marker was written but whose retirement into
# handled/orphaned/ failed would otherwise stay the oldest match forever and
# hide every later orphan behind it. Oldest by sequence; empty when none.
_fm_task_inbox_orphaned_sidecar() {  # <state-dir> <task-id>
  local dir f rec best='' best_n=0 n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/.*.resolve; do
    [ -e "$f" ] || continue
    ! _fm_task_inbox_sidecar_is_surfaced_orphan "$f" || continue
    rec=$(fm_task_inbox_resolution_record "$f")
    [ ! -e "$rec" ] || continue
    [ ! -f "$dir/handled/${rec##*/}" ] || continue
    n=$(fm_task_inbox_seq_of "${rec##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# 0 when <sidecar-path> is an orphan the ladder has already surfaced: its name
# is in the inbox's .orphan-escalated marker. The marker, not the move into
# handled/orphaned/, is what retires the sidecar: every reader treats a
# surfaced orphan as neither pending nor acknowledged from the moment the
# marker is durable, so a retirement whose move failed cannot leave the
# sidecar reading as a still-unread answer for its keys.
_fm_task_inbox_sidecar_is_surfaced_orphan() {  # <sidecar-path>
  grep -Fxq -- "${1##*/}" "${1%/*}/.orphan-escalated" 2>/dev/null
}

# Sidecars in this task's inbox, in sequence order, filtered by whether their
# record has been acknowledged. A surfaced orphan is neither: it is skipped
# whether or not its retirement out of the root has succeeded yet. One path per
# line; silent when there are none.
_fm_task_inbox_resolutions() {  # <state-dir> <task-id> <acknowledged|pending>
  local dir want=$3 f rec
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/.*.resolve; do
    [ -e "$f" ] || continue
    ! _fm_task_inbox_sidecar_is_surfaced_orphan "$f" || continue
    rec=$(fm_task_inbox_resolution_record "$f")
    if fm_task_inbox_is_acknowledged "$rec"; then
      [ "$want" = acknowledged ] || continue
    else
      [ "$want" = pending ] || continue
    fi
    printf '%s\n' "$f"
  done
}

fm_task_inbox_acknowledged_resolutions() {  # <state-dir> <task-id>
  _fm_task_inbox_resolutions "$1" "$2" acknowledged
}

fm_task_inbox_pending_resolutions() {  # <state-dir> <task-id>
  _fm_task_inbox_resolutions "$1" "$2" pending
}

# The decision identities whose answer is durably enqueued for this task but
# NOT yet acknowledged, deduplicated, one per line. Both an OPEN DECISIONS
# annotation and a stale escalation use this to name what a swallowed doorbell
# is actually holding up. Defaults to both fields; pass status-key alone to
# match against the status-log fold's own keys.
fm_task_inbox_pending_answer_keys() {  # <state-dir> <task-id> [field...]
  local state=$1 task=$2 f field
  shift 2
  [ "$#" -gt 0 ] || set -- status-key hold-id
  {
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      for field in "$@"; do
        fm_task_inbox_resolution_values "$f" "$field" 2>/dev/null || true
      done
    done <<EOF
$(fm_task_inbox_pending_resolutions "$state" "$task")
EOF
  } | awk 'NF && !seen[$0]++'
}

# Commit every deferred closure whose record the worker has acknowledged: the
# closing resolved line for each status key, then each captain-held task id fed
# to the ONE keyed-answer intake, then the sidecar filed beside its record.
# This is the only writer of a deferred closure, so a decision reads answered
# exactly when the worker has seen the answer.
#
# Idempotent per SIDECAR identity (see the header and
# _fm_task_inbox_resolution_is_committed): a status key this exact sidecar has
# already durably appended is skipped, not appended again, so a retry after a
# partial failure closes each key at most once - scoped to this sidecar, never
# to whether matching text happens to already sit in the status log, so a key
# legitimately reopened and re-answered still closes. A captain-held task the
# intake reports already closed counts as closed.
#
# Prints one "<key>" line per closed decision identity so a caller can log or
# surface it. Returns nonzero after naming on stderr every closure it could NOT
# commit for the first time; the sidecar is left in place so the next poll
# retries, and exactly those first-time names are handed back through
# .commit-failed for fm_task_inbox_record_commit_escalated - never recomputed
# from whatever is acknowledged later, because a closure acknowledged between
# this pass and the caller's marker write has not had its first attempt yet.
# A sidecar whose failure the caller already surfaced
# (fm_task_inbox_record_commit_escalated) is retried quietly: it neither fails
# the call nor repeats its diagnostic, which is what bounds a permanently
# failing close to one wake. Returns 2 when that .commit-failed handoff itself
# cannot be written while the inbox still exists: the caller then has no way
# to mark anything surfaced, so it must treat the pass like any other marker
# write failure and stop rather than re-wake on every poll. A missing inbox is
# a quiet no-op.
fm_task_inbox_commit_resolutions() {  # <state-dir> <task-id> <status-file>
  local state=$1 task=$2 status_file=$3
  local dir f rec note keys holds k line rc=0 failed append_rc surfaced quiet unresolved ident newly_failed=''
  dir=$(fm_task_inbox_dir "$state" "$task")
  [ -d "$dir" ] || return 0
  surfaced=$(cat "$dir/.commit-escalated" 2>/dev/null || true)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    rec=$(fm_task_inbox_resolution_record "$f")
    quiet=0
    ! printf '%s\n' "$surfaced" | grep -Fxq -- "${f##*/}" || quiet=1
    note=$(fm_task_inbox_body "$f" 2>/dev/null) || note=
    keys=$(fm_task_inbox_resolution_values "$f" status-key 2>/dev/null) || keys=
    holds=$(fm_task_inbox_resolution_values "$f" hold-id 2>/dev/null) || holds=
    failed=0
    for k in $keys; do
      ident="status-key:$k"
      if _fm_task_inbox_resolution_is_committed "$f" "$ident"; then
        printf '%s\n' "$k"
        continue
      fi
      fm_cap_line_var "resolved [key=$k]: answered: $note"
      line=$FM_LINE_CAP_LINE
      append_rc=0
      fm_wake_status_append_self_announced "$state" "$status_file" "$line" || append_rc=$?
      if [ "$append_rc" -eq 2 ]; then
        [ "$quiet" = 1 ] \
          || echo "error: $task acknowledged the answer in $rec, but decision key '$k' could not be closed in $status_file" >&2
        failed=1
        continue
      fi
      _fm_task_inbox_resolution_mark_committed "$f" "$ident"
      printf '%s\n' "$k"
    done
    if [ -n "$holds" ]; then
      if unresolved=$(_fm_task_inbox_feed_holds "$task" "$note" "$holds"); then
        for k in $holds; do printf '%s\n' "$k"; done
      else
        [ "$quiet" = 1 ] \
          || echo "error: $task acknowledged the answer in $rec, but these captain-held tasks could not be closed: $unresolved" >&2
        failed=1
      fi
    fi
    if [ "$failed" = 1 ]; then
      [ "$quiet" = 1 ] || { rc=1; newly_failed="${newly_failed}${f##*/}"$'\n'; }
      continue
    fi
    if ! mv "$f" "$dir/handled/${f##*/}" 2>/dev/null; then
      [ "$quiet" = 1 ] \
        || { echo "error: $task closed the answered decision in ${f##*/}, but the committed closure could not be filed under $dir/handled" >&2; rc=1; newly_failed="${newly_failed}${f##*/}"$'\n'; }
    else
      rm -f "$(_fm_task_inbox_resolution_committed_path "$f")" 2>/dev/null || true
    fi
  done <<EOF
$(fm_task_inbox_acknowledged_resolutions "$state" "$task")
EOF
  if [ -n "$newly_failed" ]; then
    if ! { printf '%s' "$newly_failed" > "$dir/.commit-failed"; } 2>/dev/null; then
      [ -d "$dir" ] || return 0
      echo "error: $task has closures that failed to commit, but their escalation handoff $dir/.commit-failed could not be written" >&2
      return 2
    fi
  else
    rm -f "$dir/.commit-failed" 2>/dev/null || true
  fi
  return "$rc"
}

# Feed answered captain-held task ids to the one keyed-answer intake, as the
# same "<task-id>\t<answer>\t<label>" lines every other channel sends. This
# library decides nothing about what the intake does with them; it only reads
# the intake's per-id verdict back. An id the intake reports closed - or
# already closed, because the captain settled it through another channel
# while the answer sat unread - is done. Prints the ids that are neither, with
# the intake's own wording, and fails when there are any.
_fm_task_inbox_feed_holds() {  # <task-id> <note> <hold-ids>
  local task=$1 note=$2 holds=$3 k lines='' out verdict unresolved=''
  for k in $holds; do
    lines="${lines}${k}"$'\t'"${note}"$'\t'$'\n'
  done
  out=$(printf '%s' "$lines" | "$_FM_TASK_INBOX_LIB_DIR/fm-captain-hold.sh" answers \
    --source "a firstmate answer acknowledged by $task" 2>&1) || true
  for k in $holds; do
    if printf '%s\n' "$out" | grep -Fxq -- "closed: $k" \
      || printf '%s\n' "$out" | grep -Fxq -- "skipped: $k (already closed)"; then
      continue
    fi
    verdict=$(printf '%s\n' "$out" | grep -F -- "skipped: $k " | head -1)
    [ -n "$verdict" ] || verdict="$k ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200))"
    unresolved="${unresolved}${unresolved:+; }$verdict"
  done
  [ -z "$unresolved" ] || { printf '%s' "$unresolved"; return 1; }
}

# Mark the closures the last commit pass failed on for the first time - the
# names it left in .commit-failed, and only those - as surfaced, after the
# caller has durably queued its wake. Later polls retry them quietly. Scoped to
# that pass's own failures on purpose: a closure the worker acknowledged after
# the pass returned is still owed its own first, loud attempt, so recomputing
# the set from what is acknowledged now would silence it before it ever ran.
# Append-with-dedupe, since sequence names are never reused within a task.
# The same wake-before-marker ordering as fm_task_inbox_record_escalated: a
# crash in between can cost a rare duplicate wake, never a lost one. A
# concurrently removed inbox is a successful no-op.
fm_task_inbox_record_commit_escalated() {  # <state-dir> <task-id>
  local dir name
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -Fxq -- "$name" "$dir/.commit-escalated" 2>/dev/null && continue
    if ! { printf '%s\n' "$name" >> "$dir/.commit-escalated"; } 2>/dev/null; then
      [ -d "$dir" ] || return 0
      return 1
    fi
  done < <(cat "$dir/.commit-failed" 2>/dev/null || true)
  rm -f "$dir/.commit-failed" 2>/dev/null || true
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

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <count> <cause> <record-path>
#                             surface as stale; <cause> is attempts|blocked|
#                             overdue|orphaned exactly as the header defines
#                             them (orphaned: see _fm_task_inbox_orphaned_sidecar).
# The cause and count lead so a record path containing spaces still parses.
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base age now grace max ladder rec_base count last blocked orphan
  dir=$(fm_task_inbox_dir "$1" "$2")
  _fm_task_inbox_retire_surfaced_orphans "$dir"
  # Checked before the .msg-based scan below, and independently of it: an
  # orphaned sidecar's bound .msg is gone, so fm_task_inbox_oldest_unhandled
  # can never see it even while it is the only unresolved thing in this inbox
  # (see _fm_task_inbox_orphaned_sidecar's header for why that would otherwise
  # go quiet forever).
  if orphan=$(_fm_task_inbox_orphaned_sidecar "$1" "$2"); then
    printf 'escalate 0 orphaned %s' "$orphan"
    return 0
  fi
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  age=$(fm_path_age "$oldest")
  # A record that vanished between the glob and the stat leaves no age; treat
  # it as brand new so the next poll re-reads a settled inbox instead of
  # escalating on a race.
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  count=0
  last=0
  blocked=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last blocked <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    # A different (or first) oldest message: the previous ladder is stale.
    count=0
    last=0
    blocked=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$blocked" in ''|*[!0-9]*) blocked=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  # The absolute bound is checked before the delivery grace, so it holds even
  # when no attempt was ever due - a busy pane suppresses attempts, and an
  # unread instruction must still stop being silent at a stated time.
  if [ "$age" -ge "$(fm_task_inbox_unhandled_max_secs)" ]; then
    printf 'escalate %s overdue %s' "$count" "$oldest"
    return 0
  fi
  grace=$(fm_task_inbox_grace_secs)
  if [ "$age" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  # A composer-protected skip delivered nothing and the composer will not clear
  # itself, so spending the rest of the attempt budget on identical skips only
  # buys silence. Name the condition instead.
  if [ "$blocked" -ge "$(fm_task_inbox_blocked_max)" ]; then
    printf 'escalate %s blocked %s' "$count" "$oldest"
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s attempts %s' "$count" "$oldest"
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
# blocked composer can retry silently forever, and a skip additionally advances
# the blocked counter its own faster escalation reads. <result> is
# rang|blocked|failed (default rang). A concurrently removed inbox is a
# successful no-op; otherwise failure means the caller must surface the
# unwritable ladder while the record remains unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path> [result]
  local dir base result=${4:-rang} ladder rec_base count last blocked
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  blocked=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last blocked <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    count=0
    blocked=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$blocked" in ''|*[!0-9]*) blocked=0 ;; esac
  [ "$result" != blocked ] || blocked=$((blocked + 1))
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" "$blocked" > "$dir/.ring-state"; } 2>/dev/null; then
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

# Same wake-before-marker contract as fm_task_inbox_record_escalated, for an
# orphaned sidecar instead: append-only (there may be more than one orphan
# over a task's lifetime, unlike the single current-oldest .msg the other
# marker tracks) so each sidecar identity escalates exactly once. Once the
# marker is durable the sidecar is retired out of the inbox root into
# handled/orphaned/<NNN>.resolve: it can never commit, firstmate has been told
# to settle it by hand, and left in the root it would keep reading as a
# pending answer for its keys - so a later, genuine reopening of the same key
# would be annotated as already answered and still unread. The marker stays
# the dedupe of record and already retires the sidecar from every reader: if
# the retirement itself fails, the orphan is still surfaced exactly once, the
# failure is returned so the caller can name it, and fm_task_inbox_due_action
# retries the move on later polls so the inbox root heals on its own.
fm_task_inbox_record_orphan_escalated() {  # <state-dir> <task-id> <sidecar-path>
  local dir sidecar=$3
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${sidecar##*/}" >> "$dir/.orphan-escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
  _fm_task_inbox_retire_orphan "$dir" "$sidecar"
}

# Move a surfaced orphan out of the inbox root into handled/orphaned/ and drop
# its committed-identity ledger. A sidecar already gone is a quiet no-op, as
# is a concurrently removed inbox; any other failure is returned.
_fm_task_inbox_retire_orphan() {  # <inbox-dir> <sidecar-path>
  local dir=$1 sidecar=$2 base
  base=${sidecar##*/}
  [ -e "$sidecar" ] || return 0
  if ! mkdir -p "$dir/handled/orphaned" 2>/dev/null \
    || ! mv "$sidecar" "$dir/handled/orphaned/${base#.}" 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
  rm -f "$(_fm_task_inbox_resolution_committed_path "$sidecar")" 2>/dev/null || true
}

# Retry the retirement of every surfaced orphan still in the inbox root. The
# marker already retired each one from every reader and its failure was
# surfaced when first attempted, so a retry that fails again stays quiet.
_fm_task_inbox_retire_surfaced_orphans() {  # <inbox-dir>
  local dir=$1 f
  for f in "$dir"/.*.resolve; do
    [ -e "$f" ] || continue
    _fm_task_inbox_sidecar_is_surfaced_orphan "$f" || continue
    _fm_task_inbox_retire_orphan "$dir" "$f" || true
  done
}
