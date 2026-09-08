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
# a short constant doorbell line. The ring verifies an inconclusive submit and
# retries Enter only while the composer positively holds this record's exact
# doorbell, stops on proven emptiness, and otherwise sends no further key. An
# initial send-failed verdict with an empty composer still reports failure
# because the backend cannot distinguish a landed Enter from text never typed.
# A duplicated doorbell is a no-op by construction (the worker finds the
# inbox empty or already handled), so the absence of acknowledgement still
# drives the bounded watcher re-ring schedule as a backstop. A positively dead
# or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
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
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane waits,
# while a positively dead or missing endpoint skips delivery and the ladder and
# escalates directly. This library owns only the schedule and escalation marker.
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"
# The composer extractor below identifies a swallowed doorbell still sitting in
# the composer. Sourced explicitly rather than relying on a backend adapter
# having pulled it in first.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-composer-lib.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5
# A doorbell gets at most three Enter attempts, spaced 0.4 seconds apart.
_FM_TASK_INBOX_COMMIT_RETRIES=3
_FM_TASK_INBOX_COMMIT_SLEEP=0.4

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
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# fm_task_inbox_composer_holds_doorbell: true only when the composer's OWN
# content carries THIS record's complete doorbell line - the signature of an
# Enter that was swallowed after the line was typed.
#
# Why identity matters: fm_task_inbox_ring defers on a `pending` composer so
# our Enter can never submit someone's real half-typed content. That guard has
# no way to tell foreign text from firstmate's own undelivered doorbell, so a
# single swallowed Enter makes the doorbell itself the thing that blocks every
# later re-ring, and the steer sits unsubmitted until a human presses Enter.
# Identifying our own line is what makes the deferral recoverable without
# weakening the guarantee for text we did not type.
#
# Only the composer REGION is consulted, never the whole capture: an
# already-submitted doorbell stays visible in the transcript above, and
# matching that history would let a human's half-typed text be committed.
# Wrapped rows are rejoined without adding whitespace. Removing all whitespace
# would make a user-edited line look unchanged and could submit their draft.
#
# Every failure - unreadable capture, unidentifiable composer, no exact match -
# returns false, so the caller keeps today's conservative skip.
fm_task_inbox_composer_holds_doorbell() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cap caps row raw content glyph
  local remaining framed left right prompt_seen=0 width
  line=$(fm_task_inbox_doorbell_line "$rec") || return 1
  cap=$(fm_backend_capture "$backend" "$target" "$FM_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) || return 1
  [ -n "$cap" ] || return 1
  # styled=0: a plain capture cannot strip ghost/placeholder text, which can
  # only ever cost a match (a placeholder never carries this record's path).
  caps=$(printf 'styled=0\ncursor=0\nidentity=0\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
  # Run the shared selector in this shell so its selected composer bounds remain
  # available. Its ordinary output trims every row, so compare the visible row
  # cells ourselves. Only proven UI furniture is removed; editable whitespace
  # at the start or at a wrap boundary remains part of the identity check.
  fm_composer_extract_selected_content "$caps" "$cap" >/dev/null 2>&1 || return 1
  remaining=$line
  row=$FM_COMPOSER_SELECTED_FIRST
  while [ "$row" -le "$FM_COMPOSER_SELECTED_LAST" ]; do
    raw=$(_fm_composer_screen_row "$row" "$cap")
    content=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
    fm_composer_normalize_spaces_var content
    case "$FM_COMPOSER_SELECTED_KIND" in
      box)
        # Whitespace outside the paired border and one cell just inside each
        # edge are box geometry. Every other cell is composer content.
        framed=$content
        fm_composer_normalize_trim_var framed
        left=${framed:0:1}; right=${framed: -1}
        case "$left$right" in '││'|'┃┃'|'║║'|'||') ;; *) return 1 ;; esac
        content=${framed:1:${#framed}-2}
        case "$content" in ' '*) content=${content:1} ;; *) return 1 ;; esac
        case "$content" in *' ') content=${content:0:${#content}-1} ;; *) return 1 ;; esac
        if [ "$prompt_seen" = 0 ] \
          && fm_composer_leading_prompt_glyph_var glyph "$content"; then
          content=${content#*"$glyph"}
          case "$content" in ' '*) content=${content:1} ;; esac
          prompt_seen=1
        fi
        ;;
      leftbar)
        framed=$content
        fm_composer_normalize_trim_var framed
        case "$framed" in '┃'*) content=${framed#┃} ;; *) return 1 ;; esac
        case "$content" in ' '*) content=${content:1} ;; esac
        ;;
      bare)
        if [ "$row" -eq "$FM_COMPOSER_SELECTED_FIRST" ]; then
          framed=$content
          framed=${framed#"${framed%%[![:space:]]*}"}
          fm_composer_leading_agent_glyph_var glyph "$framed" || return 1
          content=${framed#*"$glyph"}
          case "$content" in ' '*) content=${content:1} ;; esac
        fi
        ;;
      pi) ;;
      *) return 1 ;;
    esac

    width=${#content}
    if [ "${#remaining}" -ge "$width" ]; then
      [ "$content" = "${remaining:0:$width}" ] || return 1
      remaining=${remaining:$width}
    else
      [ "${content:0:${#remaining}}" = "$remaining" ] || return 1
      content=${content:${#remaining}}
      # A bordered box paints blank cells through its right edge. Unbordered
      # shapes do not provide that geometry, so any trailing cell is editable
      # composer content and must prevent an identity match.
      if [ "$FM_COMPOSER_SELECTED_KIND" = box ]; then
        [ -z "${content// /}" ] || return 1
      else
        [ -z "$content" ] || return 1
      fi
      remaining=
    fi
    row=$((row + 1))
  done
  [ -n "$line" ] || return 1
  [ -z "$remaining" ]
}

# fm_task_inbox_commit_pending_doorbell: submit a doorbell already sitting in
# the composer, with a bounded Enter-only retry. Retyping is never correct
# here - the text is already there, and a second copy would be delivered as
# well as the first. True when the composer is proven empty.
fm_task_inbox_commit_pending_doorbell() {  # <backend> <target> <record-path> [expected-label] [attempts-spent]
  local backend=$1 target=$2 rec=$3 label=${4:-} state i=${5:-0}
  case "$i" in 0|1) ;; *) i=0 ;; esac
  while [ "$i" -lt "$_FM_TASK_INBOX_COMMIT_RETRIES" ]; do
    if ! fm_task_inbox_composer_holds_doorbell "$backend" "$target" "$rec" "$label"; then
      state=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || state=unknown
      [ "$state" = empty ] && return 0
      return 1
    fi
    fm_backend_send_key "$backend" "$target" Enter "$label" || true
    i=$((i + 1))
    sleep "$_FM_TASK_INBOX_COMMIT_SLEEP"
    if fm_task_inbox_composer_holds_doorbell "$backend" "$target" "$rec" "$label"; then
      continue
    fi
    state=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || state=unknown
    [ "$state" = empty ] && return 0
    return 1
  done
  return 1
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# (the watcher re-rings later), 2 the backend send failed, 3 skipped because
# the endpoint is positively dead or missing (nothing typed; recovery owns the
# record). No return value is delivery proof; the acknowledgement move is the
# only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict defers,
# because there our Enter could submit someone's real half-typed content. A
# pending composer that positively holds THIS record's own doorbell is the one
# exception - that text is ours and already typed, so it is committed with an
# Enter-only retry rather than deferred forever (see
# fm_task_inbox_composer_holds_doorbell for why the deferral is otherwise
# self-sustaining, and why every unidentified case still defers).
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
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
      # Our own doorbell sitting here is a swallowed Enter, not someone's
      # half-typed content: commit what is already typed instead of deferring
      # to a re-ring that would defer again on the same text. Anything we
      # cannot positively identify as this record's doorbell still defers.
      if fm_task_inbox_composer_holds_doorbell "$backend" "$target" "$rec" "$label"; then
        fm_task_inbox_commit_pending_doorbell "$backend" "$target" "$rec" "$label" || return 1
        return 0
      fi
      return 1
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  case "$verdict" in
    send-failed)
      if ! fm_task_inbox_composer_holds_doorbell "$backend" "$target" "$rec" "$label"; then
        cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
        # send-failed cannot distinguish an Enter that landed from a literal
        # send that never typed anything without widening the backend contract.
        # Report failure in both cases so an empty composer cannot falsely mark
        # an unsent doorbell delivered. The durable record makes the resulting
        # re-ring safe, and a duplicate doorbell is a no-op after handling.
        [ "$cstate" = empty ] && return 2
        return 1
      fi
      ;;
    pending|pending-unproven|unknown) ;;
    *) return 0 ;;
  esac
  fm_task_inbox_commit_pending_doorbell "$backend" "$target" "$rec" "$label" 1 || return 1
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
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
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
