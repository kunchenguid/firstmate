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
#   <task>.inbox/NNN.resolve   the decision closure NNN.msg's answer owes, held
#                              until the worker acknowledges that record
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement;
#                              a committed NNN.resolve is filed here too
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder:
#                              "<msg>\t<count>\t<epoch>\t<blocked-count>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
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
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. It
# escalates for one of three stated causes, and every one of them is bounded:
#   attempts  FM_TASK_INBOX_RING_MAX delivery attempts produced no
#             acknowledgement (default 3, so ~4 grace periods after enqueue)
#   blocked   FM_TASK_INBOX_BLOCKED_MAX attempts were SKIPPED because the
#             composer provenly holds pending text (default 1, so ~1 grace
#             period). Repeating a skip cannot deliver anything: the composer
#             is occupied by text the worker will not clear itself, so the
#             remaining attempt budget would buy only silence. Escalating on
#             the first proven skip is what turns that condition from a quiet
#             wait into a named, fixable one.
#   overdue   the record has been unhandled for FM_TASK_INBOX_UNHANDLED_MAX_SECS
#             (default 900) whatever the pane is doing. This is the absolute
#             bound, and the only cause the caller must surface while the pane
#             reads busy: a busy worker legitimately has not reached a turn
#             boundary yet, but "busy" must never mean "unread forever".
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

# Path of the deferred-closure sidecar bound to one inbox record.
fm_task_inbox_resolution_path() {  # <record-path>
  printf '%s.resolve' "${1%.msg}"
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
  tmp=$(mktemp "$dir/.resolve.XXXXXX") || return 1
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

# Sidecars in this task's inbox, in sequence order, filtered by whether their
# record has been acknowledged. One path per line; silent when there are none.
_fm_task_inbox_resolutions() {  # <state-dir> <task-id> <acknowledged|pending>
  local dir want=$3 f rec
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.resolve; do
    [ -e "$f" ] || continue
    rec="${f%.resolve}.msg"
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
# Prints one "<key>" line per closed decision identity so a caller can log or
# surface it. Returns nonzero after naming on stderr every closure it could NOT
# commit; the sidecar is left in place so the next poll retries, and a repeated
# resolved line for an already-closed key is a harmless no-op in the fold. A
# missing inbox is a quiet no-op.
fm_task_inbox_commit_resolutions() {  # <state-dir> <task-id> <status-file>
  local state=$1 task=$2 status_file=$3
  local dir f note keys holds k line rc=0 failed append_rc
  dir=$(fm_task_inbox_dir "$state" "$task")
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    note=$(fm_task_inbox_body "$f" 2>/dev/null) || note=
    keys=$(fm_task_inbox_resolution_values "$f" status-key 2>/dev/null) || keys=
    holds=$(fm_task_inbox_resolution_values "$f" hold-id 2>/dev/null) || holds=
    failed=0
    for k in $keys; do
      fm_cap_line_var "resolved [key=$k]: answered: $note"
      line=$FM_LINE_CAP_LINE
      append_rc=0
      fm_wake_status_append_self_announced "$state" "$status_file" "$line" || append_rc=$?
      if [ "$append_rc" -eq 2 ]; then
        echo "error: $task acknowledged the answer in ${f%.resolve}.msg, but decision key '$k' could not be closed in $status_file" >&2
        failed=1
        continue
      fi
      printf '%s\n' "$k"
    done
    if [ -n "$holds" ]; then
      if _fm_task_inbox_feed_holds "$task" "$note" "$holds"; then
        for k in $holds; do printf '%s\n' "$k"; done
      else
        echo "error: $task acknowledged the answer in ${f%.resolve}.msg, but these captain-held tasks could not be closed: $(printf '%s' "$holds" | tr '\n' ' ')" >&2
        failed=1
      fi
    fi
    if [ "$failed" = 1 ]; then
      rc=1
      continue
    fi
    if ! mv "$f" "$dir/handled/${f##*/}" 2>/dev/null; then
      echo "error: $task closed the answered decision in ${f##*/}, but the committed closure could not be filed under $dir/handled" >&2
      rc=1
    fi
  done <<EOF
$(fm_task_inbox_acknowledged_resolutions "$state" "$task")
EOF
  return "$rc"
}

# Feed answered captain-held task ids to the one keyed-answer intake, as the
# same "<task-id>\t<answer>\t<label>" lines every other channel sends. This
# library decides nothing about what the intake does with them.
_fm_task_inbox_feed_holds() {  # <task-id> <note> <hold-ids>
  local task=$1 note=$2 holds=$3 k lines=''
  for k in $holds; do
    lines="${lines}${k}"$'\t'"${note}"$'\t'$'\n'
  done
  printf '%s' "$lines" | "$_FM_TASK_INBOX_LIB_DIR/fm-captain-hold.sh" answers \
    --source "a firstmate answer acknowledged by $task" >/dev/null 2>&1
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
#                             overdue exactly as the header defines them.
# The cause and count lead so a record path containing spaces still parses.
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base age now grace max ladder rec_base count last blocked
  dir=$(fm_task_inbox_dir "$1" "$2")
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
