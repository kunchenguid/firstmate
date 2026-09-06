#!/usr/bin/env bash
# fm-pending-reply-lib.sh - parent-owned secondmate missed-report guards.
#
# When the main firstmate delivers a reply-bearing marked from-firstmate request
# to a secondmate, this library records a durable parent-owned pending-reply
# expectation BEFORE delivery, embeds a privacy-safe correlation id in the
# outbound message, and later resolves that expectation only from a correlated
# parent status line or status-pointed document - never from transport success,
# chat content, or unrelated status activity.
#
# Safety property (captain direction 2026-07-22): a secondmate agent may ignore
# the marker and answer only in its visible conversation. The parent must notice
# the missing correlated report without scraping that conversation, send exactly
# one automatic recovery request asking for a repost through the parent channel,
# and escalate once if the recovery turn also completes without a correlated
# report. Never loop, never repeatedly inject, never silently expire unresolved
# records, and never treat wrong-home or structured-home heuristics as
# acknowledgement. A same-basename restatement-copy of the mate home's
# state/<task_id>.status onto the parent channel is a repair of the
# FM_HOME-relative mixup, not acknowledgement of an arbitrary mate-home file.
#
# Record locations (parent FM_HOME):
#   state/pending-replies/<corr_id>          unresolved hot record
#   state/pending-replies/archive/<corr_id>  retained settled record, excluded
#                                            from the watcher tick scan
# Correlation lookup and collision checks cover both locations.
# One more durable input, owned by bin/fm-procevent-remote-reply.sh and read
# here: state/remote-replies/<task_id>.caught-up, the remote reply mirror's
# watermark (see the remote reply-channel freshness section below).
# Each record is a key=value file owned by this library. Schema:
#   schema=fm-pending-reply.v1
#   corr_id=                privacy-safe correlation token
#   task_id=                secondmate task id in the parent home
#   parent_home=            absolute parent FM_HOME
#   parent_status=          absolute path of parent state/<task_id>.status
#   parent_status_scan_signature=
#   request_summary=        short sanitized summary (no secrets by design)
#   created_epoch=          when the expectation was created
#   delivered_epoch=        when the marked request was confirmed delivered
#                           (empty until delivery; delivery never resolves)
#   phase=                  awaiting_report | delivery_unknown | recovery_sending |
#                           recovery_sent | recovery_failed | recovery_unknown |
#                           escalated | resolved
#   turn_seen_busy=         0|1 after delivery for the original request turn
#   request_turn_completed_epoch=
#   recovery_attempted_epoch=
#   recovery_sender_pid=
#   recovery_sender_identity=
#   recovery_sent_epoch=
#   recovery_delivery_outcome=
#   recovery_turn_seen_busy=
#   recovery_turn_completed_epoch=
#   escalated_epoch=
#   escalation_closed_epoch=
#                           when the durable status decision opened by that
#                           escalation was closed again (see the escalation
#                           lifecycle note below); empty until then
#   resolved_epoch=
#   resolved_via=           status | document | helper | empty
#   wrong_home_hits=        count of corr sightings under the secondmate home
#   wrong_home_first_sighting= encoded path:line identity of the first sighting
#   wrong_home_sightings=   comma-separated encoded path:line identities
#   wrong_home_scan_signature=
#   grace_secs=             bounded grace before recovery is eligible
#
# Escalation lifecycle: an escalation is not just a message, it OPENS a durable
# keyed decision in the parent status log, and bin/fm-classify-lib.sh's fold is
# the one owner of what closes it. So this library owns both ends of that
# decision: fm_pending_reply_maybe_escalate opens it under a per-request key, and
# fm_pending_reply_close_escalation closes it once the record resolves. Resolving
# the record alone would leave the decision open forever, re-surfacing a settled
# request in every later OPEN DECISIONS fold.
# That per-request key lives in a namespace the fold reserves to this library, so
# no other writer into the same status stream - a local mate appending directly,
# or a remote mate's mirrored line - can take the key over or clear it; see the
# reserved-key rule in bin/fm-classify-lib.sh.
# The operator-facing close of that same keyed decision is still
# fm-send --resolve-key (bin/fm-send.sh header): it must speak the close note
# owned below (fm_pending_reply_resolved_note), because a bare answered: note is
# not a reserved-key transition and would leave the decision open.
#
# Sourced by bin/fm-send.sh, bin/fm-watch.sh, bin/fm-secondmate-report.sh, and
# tests. No side effects on source. set -u / set -e safe.
#
# Tunables (env):
#   FM_PENDING_REPLY_GRACE_SECS   default 120
#   FM_PENDING_REPLY_DIR_OVERRIDE override the pending-replies directory (tests)
#   FM_PENDING_REPLY_SEND_HOOK    optional command template for recovery delivery
#                                 (tests); receives task_id and full message as args
#   FM_PENDING_REPLY_NOW          optional fixed epoch for deterministic tests

# shellcheck source=bin/fm-marker-lib.sh
_FM_PENDING_REPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PENDING_REPLY_LIB_DIR="."
# shellcheck source=bin/fm-marker-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-timeout-lib.sh"

FM_PENDING_REPLY_SCHEMA='fm-pending-reply.v1'
FM_PENDING_REPLY_CORR_RE='corr=[A-Fa-f0-9]{16}'
FM_PENDING_REPLY_GRACE_DEFAULT=120

fm_pending_reply_now() {
  if [ -n "${FM_PENDING_REPLY_NOW:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_NOW"
    return 0
  fi
  date +%s
}

fm_pending_reply_grace_secs() {
  local g=${FM_PENDING_REPLY_GRACE_SECS:-$FM_PENDING_REPLY_GRACE_DEFAULT}
  case "$g" in
    ''|*[!0-9]*) g=$FM_PENDING_REPLY_GRACE_DEFAULT ;;
  esac
  printf '%s' "$g"
}

# Directory holding durable pending-reply records for <state-dir>.
fm_pending_reply_dir() {  # <state-dir>
  local state=$1
  if [ -n "${FM_PENDING_REPLY_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_DIR_OVERRIDE"
    return 0
  fi
  printf '%s/pending-replies' "$state"
}

# Settled records live here instead of the hot directory the watcher tick scans.
# Adopted, never recreated: this home's archive already exists and already holds
# records moved out of the hot path by hand during the 2026-09-04 incident, so
# the retention below must tolerate a populated archive on its very first run.
fm_pending_reply_archive_dir() {  # <state-dir>
  printf '%s/archive' "$(fm_pending_reply_dir "$1")"
}

fm_pending_reply_path() {  # <state-dir> <corr_id>
  printf '%s/%s' "$(fm_pending_reply_dir "$1")" "$2"
}

# The record for <corr_id> wherever it currently lives: hot first, then the
# archive. Correlation reuse and the wrong-home detector go through here so an
# archived record is still findable by id, which is what lets the tick's working
# set shrink to open records only.
fm_pending_reply_locate() {  # <state-dir> <corr_id>
  local hot archived
  hot=$(fm_pending_reply_path "$1" "$2")
  if [ -f "$hot" ]; then
    printf '%s' "$hot"
    return 0
  fi
  archived="$(fm_pending_reply_archive_dir "$1")/$2"
  if [ -f "$archived" ]; then
    printf '%s' "$archived"
    return 0
  fi
  return 1
}

# Move a settled record out of the hot set. A record that cannot be archived
# stays available for an explicit resolution retry. Returns 0 when the record is
# no longer in the hot directory.
_fm_pending_reply_archive_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 hot archive_dir
  hot=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$hot" ] || return 0
  archive_dir=$(fm_pending_reply_archive_dir "$state")
  mkdir -p "$archive_dir" 2>/dev/null || return 1
  mv -f "$hot" "$archive_dir/$corr" 2>/dev/null || return 1
}

fm_pending_reply_require_wake_lib() {
  command -v fm_lock_acquire_wait >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_PENDING_REPLY_LIB_DIR/fm-wake-lib.sh"
}

# Privacy-safe correlation id: 16 lowercase hex chars (64 bits of entropy).
fm_pending_reply_new_id() {
  local raw hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | cksum 2>/dev/null | awk '{print $1}')
    hex=$(printf '%s' "$raw$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

fm_pending_reply_corr_token() {  # <corr_id>
  printf 'corr=%s' "$1"
}

# Extract the first corr=<16hex> token from free text, or empty.
fm_pending_reply_extract_corr() {  # <text>
  local text=$1
  printf '%s' "$text" | grep -oE "$FM_PENDING_REPLY_CORR_RE" 2>/dev/null | head -1 | cut -d= -f2- | tr 'A-F' 'a-f' || true
}

# 0 if <text> carries the exact correlation token for <corr_id>.
fm_pending_reply_text_has_corr() {  # <text> <corr_id>
  local text=$1 corr=$2 token
  token=$(fm_pending_reply_corr_token "$corr")
  case "$text" in
    *"$token"*) return 0 ;;
  esac
  return 1
}

# Sanitize a short request summary: single line, bounded, no control chars.
fm_pending_reply_summarize() {  # <text>
  local text=$1 cleaned
  cleaned=$(printf '%s' "$text" | tr '\t\r\n' '   ' | tr -cd '\11\12\15\40-\176' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Drop an already-present marker/corr prefix so the durable summary stays short.
  cleaned=${cleaned#"$FM_FROMFIRST_MARK"}
  cleaned=$(printf '%s' "$cleaned" | sed -E "s/^corr=[A-Fa-f0-9]{16}[[:space:]]*//")
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

fm_pending_reply_get() {  # <record-path> <key>
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_pending_reply_sighting_encode() {  # <path> <line-number>
  local path=$1 line_no=$2 encoded
  case "$line_no" in ''|*[!0-9]*) return 1 ;; esac
  encoded=$(printf '%s' "$path" | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  [ -n "$encoded" ] || return 1
  printf 'hex:%s:%s' "$encoded" "$line_no"
}

fm_pending_reply_sighting_display() {  # <encoded-sighting>
  local sighting=$1 body encoded line_no path='' pair byte escaped
  case "$sighting" in hex:*:*) ;; *) return 1 ;; esac
  body=${sighting#hex:}
  line_no=${body##*:}
  encoded=${body%:*}
  case "$line_no" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$encoded" ] && [ $(( ${#encoded} % 2 )) -eq 0 ] || return 1
  while [ -n "$encoded" ]; do
    pair=${encoded:0:2}
    case "$pair" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf -v byte '%b' "\\x$pair"
    path=$path$byte
    encoded=${encoded:2}
  done
  printf -v escaped '%q' "$path"
  printf '%s:%s' "$escaped" "$line_no"
}

fm_pending_reply_corr_reusable() {  # <state-dir> <corr_id> <task_id>
  local state=$1 corr=$2 task_id=$3 rec phase delivered
  printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_locate "$state" "$corr") || return 1
  [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending|recovery_sent) return 0 ;;
    delivery_unknown)
      delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
      [ -z "$delivered" ]
      return $?
      ;;
  esac
  return 1
}

# Rewrite one key in a pending-reply record atomically. Other keys preserved.
fm_pending_reply_set() {  # <record-path> <key> <value>
  local rec=$1 key=$2 value=$3 dir base tmp line
  [ -f "$rec" ] || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || return 1
  mv -f "$tmp" "$rec"
}

# Embed or replace a correlation token after the from-firstmate marker.
# Idempotent for the same corr; replaces a different leading corr token.
# Result is assigned to <result-var>.
# Trailing newlines in the request body are preserved: never strip via bare
# $(...) on the body (command substitution removes trailing newlines).
fm_pending_reply_embed_corr() {  # <message> <corr_id> <result-var>
  local message=$1 corr=$2 result_var=$3 body token marked existing
  [ -n "$result_var" ] || return 2
  token=$(fm_pending_reply_corr_token "$corr")
  fm_message_mark_from_firstmate "$message" marked
  body=${marked#"$FM_FROMFIRST_MARK"}
  # Strip a leading corr=<16hex> plus following blanks (space/tab only).
  existing=${body:0:21}
  case "$existing" in
    corr=[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      body=${body:21}
      while [ "${body# }" != "$body" ]; do body=${body# }; done
      while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      ;;
  esac
  printf -v "$result_var" '%s' "${FM_FROMFIRST_MARK}${token} ${body}"
}

# Create a durable pending-reply expectation. Prints corr_id on success.
# Does not deliver anything. Fails if parent paths cannot be prepared.
fm_pending_reply_create() {  # <parent-home> <state-dir> <task_id> <request-text>
  local parent_home=$1 state=$2 task_id=$3 request_text=$4
  local dir archive_dir rec corr now summary status_path tmp
  [ -n "$parent_home" ] && [ -n "$state" ] && [ -n "$task_id" ] || return 2
  dir=$(fm_pending_reply_dir "$state")
  archive_dir=$(fm_pending_reply_archive_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  corr=$(fm_pending_reply_new_id)
  [ "${#corr}" -eq 16 ] || return 1
  rec=$(fm_pending_reply_path "$state" "$corr")
  # Extremely unlikely collision; regenerate once.
  if [ -e "$rec" ] || [ -e "$archive_dir/$corr" ]; then
    corr=$(fm_pending_reply_new_id)
    rec=$(fm_pending_reply_path "$state" "$corr")
    if [ -e "$rec" ] || [ -e "$archive_dir/$corr" ]; then
      return 1
    fi
  fi
  now=$(fm_pending_reply_now)
  summary=$(fm_pending_reply_summarize "$request_text")
  status_path="$state/${task_id}.status"
  # Prefer absolute parent_status when parent_home/state resolve.
  case "$status_path" in
    /*) ;;
    *) status_path="$(cd "$state" 2>/dev/null && pwd)/${task_id}.status" ;;
  esac
  case "$parent_home" in
    /*) ;;
    *) parent_home=$(cd "$parent_home" 2>/dev/null && pwd) || parent_home=$1 ;;
  esac
  tmp="$dir/.${corr}.tmp.$$"
  cat > "$tmp" <<EOF
schema=$FM_PENDING_REPLY_SCHEMA
corr_id=$corr
task_id=$task_id
parent_home=$parent_home
parent_status=$status_path
parent_status_scan_signature=
request_summary=$summary
created_epoch=$now
delivered_epoch=
phase=awaiting_report
turn_seen_busy=0
request_turn_completed_epoch=
recovery_attempted_epoch=
recovery_sender_pid=
recovery_sender_identity=
recovery_sent_epoch=
recovery_delivery_outcome=
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
resolved_epoch=
resolved_via=
wrong_home_hits=0
wrong_home_first_sighting=
wrong_home_sightings=
wrong_home_scan_signature=
grace_secs=$(fm_pending_reply_grace_secs)
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec" || return 1
  printf '%s' "$corr"
}

# Mark delivery success for an existing expectation. Never resolves.
fm_pending_reply_mark_delivered() {  # <state-dir> <corr_id> [confirmed-epoch]
  local state=$1 corr=$2 confirmed_epoch=${3-} rec phase delivered now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|escalated|resolved) ;;
    *) return 1 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    now=${confirmed_epoch:-$(fm_pending_reply_now)}
    fm_pending_reply_set "$rec" delivered_epoch "$now" || return 1
  fi
  if [ "$phase" = delivery_unknown ]; then
    fm_pending_reply_set "$rec" phase awaiting_report || return 1
  fi
  return 0
}

fm_pending_reply_delivery_confirmation_path() {  # <state-dir> <corr_id>
  printf '%s/.delivery-confirmed-%s' "$(fm_pending_reply_dir "$1")" "$2"
}

fm_pending_reply_write_delivery_confirmation() {  # <state-dir> <corr_id> <state> <value>
  local pending_state=$1 corr=$2 delivery_state=$3 value=$4 marker dir tmp
  marker=$(fm_pending_reply_delivery_confirmation_path "$pending_state" "$corr")
  dir=$(dirname "$marker")
  mkdir -p "$dir" || return 1
  tmp="$marker.tmp.$$"
  printf '%s=%s\n' "$delivery_state" "$value" > "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker"
}

fm_pending_reply_prepare_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 0
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -f "$marker" ] && return 0
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" attempted "$now"
}

fm_pending_reply_confirm_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 lock rc=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_confirm_delivery_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

_fm_pending_reply_confirm_delivery_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 now marker
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  if ! fm_pending_reply_prepare_delivery "$state" "$corr"; then
    return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" confirmed "$now" || return 1
  if fm_pending_reply_mark_delivered "$state" "$corr" "$now"; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  return 2
}

# Preserve an expectation when a remote transport disconnect makes delivery
# completion unknowable. This never resolves or retries the request; it moves
# the existing prepared record to the owner's explicit unknown-delivery path.
fm_pending_reply_mark_delivery_unknown() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|delivery_unknown) ;;
    *) return 1 ;;
  esac
  fm_pending_reply_set "$rec" phase delivery_unknown
}

_fm_pending_reply_reconcile_delivery_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker entry delivery_state value epoch
  local grace now age phase
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -n "$delivered" ]; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  [ -f "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  delivery_state=${entry%%=*}
  value=${entry#*=}
  case "$delivery_state" in
    confirmed)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      fm_pending_reply_mark_delivered "$state" "$corr" "$epoch" || return 1
      rm -f "$marker" 2>/dev/null || true
      return 0
      ;;
    attempted)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      grace=$(fm_pending_reply_get "$rec" grace_secs)
      case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
      now=$(fm_pending_reply_now)
      age=$((now - epoch))
      [ "$age" -ge "$grace" ] || return 1
      phase=$(fm_pending_reply_get "$rec" phase)
      [ "$phase" = awaiting_report ] || return 1
      fm_pending_reply_set "$rec" phase delivery_unknown || return 1
      return 0
      ;;
  esac
  return 1
}

fm_pending_reply_reconcile_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 lock rc=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_reconcile_delivery_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

fm_pending_reply_delivery_attempt_unresolved() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker entry
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  case "$entry" in attempted=*) return 0 ;; esac
  return 1
}

# A definitive backend rejection makes the existing correlation retryable again.
# Reconciliation may have aged the same attempted sidecar to delivery_unknown
# while the backend call was in flight, so both undelivered phases converge here
# under the per-correlation lock; a confirmed delivery can never be reset.
fm_pending_reply_reset_known_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 lock rc=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_reset_known_undelivered_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

_fm_pending_reply_reset_known_undelivered_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered phase marker entry
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|delivery_unknown) ;; *) return 1 ;; esac
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -e "$marker" ] || [ -L "$marker" ] || {
    [ "$phase" = awaiting_report ]
    return $?
  }
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  case "$entry" in attempted=*) ;; *) return 1 ;; esac
  [ "$phase" = awaiting_report ] \
    || fm_pending_reply_set "$rec" phase awaiting_report || return 1
  rm -f -- "$marker"
}

# Drop an undelivered expectation after a failed send so transport failure does
# not masquerade as a missed report later.
fm_pending_reply_discard_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  rm -f "$marker" 2>/dev/null || true
  rm -f "$rec"
}

# 0 if a status line is a correlated acknowledgement for <corr_id>.
# Accepts short status replies and status lines that point at a document.
# Unrelated verbs without the token never match. Stale/wrong corr never match.
# The parent's own pending-reply-missed escalation line must not self-resolve:
# it names the request with pending-reply-id= rather than corr=.
fm_pending_reply_line_resolves() {  # <line> <corr_id>
  local line=$1 corr=$2
  [ -n "$line" ] && [ -n "$corr" ] || return 1
  case "$line" in
    *pending-reply-missed*) return 1 ;;
  esac
  fm_pending_reply_text_has_corr "$line" "$corr"
}

# Scan a status file for a correlated resolve. Prints the matching line or empty.
fm_pending_reply_find_resolve_line() {  # <status-file> <corr_id>
  local status_file=$1 corr=$2 line
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if fm_pending_reply_line_resolves "$line" "$corr"; then
      printf '%s' "$line"
      return 0
    fi
  done < "$status_file"
  return 0
}

fm_pending_reply_file_signature() {  # <path>
  local path=$1
  [ -f "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

fm_pending_reply_status_set_signature() {  # <status-dir>
  local status_dir=$1 status_file signature
  {
    for status_file in "$status_dir"/*.status; do
      [ -f "$status_file" ] || continue
      signature=$(fm_pending_reply_file_signature "$status_file")
      printf '%s:%s:%s\n' "${#status_file}" "$status_file" "$signature"
    done
  } | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

# Classify how a resolving line acknowledged the request.
fm_pending_reply_resolve_via_of_line() {  # <line>
  local line=$1
  case "$line" in
    *data/*report*|*report.md*|*document*|*pointer*)
      printf 'document'
      ;;
    *via-helper*|*fm-secondmate-report*)
      printf 'helper'
      ;;
    *)
      printf 'status'
      ;;
  esac
}

# Idempotently resolve an expectation from a correlated parent report.
# Returns 0 when the record is resolved after the call (already or newly).
fm_pending_reply_try_resolve() {  # <state-dir> <corr_id> [status-file-override]
  # Serialized per correlation so a resolution and an escalation cannot interleave.
  # bin/fm-wake-lib.sh owns the lock primitives but assigns its own globals when
  # sourced, so they are declared local here: that contains them to this call
  # instead of leaking into every script that sources this library, without the
  # subshell that would make every later use of them read as a lost write.
  # The lock is released explicitly rather than from an EXIT trap, because a trap
  # in a plain function would clobber the caller's own.
  local state=$1 corr=$2 lock rc=0 settled
  # Already settled and archived: resolution is idempotent, so answer from the
  # archive without taking the lock. Retention moves settled records out of the
  # hot set during a watcher tick, so without this a repeat resolve of the same
  # correlation would read as a failure purely because the record had been filed
  # away.
  settled="$(fm_pending_reply_archive_dir "$state")/$corr"
  if [ ! -f "$(fm_pending_reply_path "$state" "$corr")" ] && [ -f "$settled" ]; then
    [ "$(fm_pending_reply_get "$settled" phase)" = resolved ] && return 0
    return 1
  fi
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_try_resolve_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

_fm_pending_reply_try_resolve_locked() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-}
  local rec phase delivered marker delivery_entry delivery_state status_file signature previous line via now archive_rc
  local unconfirmed=0
  rec=$(fm_pending_reply_locate "$state" "$corr") || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$rec" != "$(fm_pending_reply_path "$state" "$corr")" ]; then
    [ "$phase" = resolved ]
    return $?
  fi
  if [ "$phase" = resolved ]; then
    _fm_pending_reply_close_escalation_locked "$state" "$corr" || true
    if [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] \
      || [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ]; then
      if ! _fm_pending_reply_archive_locked "$state" "$corr"; then
        if [ -n "$(fm_pending_reply_get "$rec" escalated_epoch)" ]; then
          fm_pending_reply_set "$rec" escalation_closed_epoch "" || true
        fi
        return 1
      fi
    fi
    return 0
  fi
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || return 1
    delivery_entry=$(cat "$marker" 2>/dev/null || true)
    delivery_state=${delivery_entry%%=*}
    case "$delivery_state" in attempted|confirmed) ;; *) return 1 ;; esac
    unconfirmed=1
  fi
  status_file=${status_override:-$(fm_pending_reply_get "$rec" parent_status)}
  if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
    signature=$(fm_pending_reply_file_signature "$status_file")
    previous=$(fm_pending_reply_get "$rec" parent_status_scan_signature)
    [ "$signature" != "$previous" ] || return 1
  fi
  line=$(fm_pending_reply_find_resolve_line "$status_file" "$corr")
  if [ -z "$line" ]; then
    if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
      fm_pending_reply_set "$rec" parent_status_scan_signature "$signature" || return 1
    fi
    return 1
  fi
  via=$(fm_pending_reply_resolve_via_of_line "$line")
  now=$(fm_pending_reply_now)
  if [ -z "$delivered" ]; then
    fm_pending_reply_mark_delivered "$state" "$corr" "$now" || return 1
    rm -f "$marker" 2>/dev/null || true
  fi
  fm_pending_reply_set "$rec" resolved_epoch "$now" || return 1
  fm_pending_reply_set "$rec" resolved_via "$via" || return 1
  fm_pending_reply_set "$rec" phase resolved || return 1
  # The record is resolved either way; a failed close stays retryable from the
  # watcher tick rather than turning a settled request back into a failure.
  _fm_pending_reply_close_escalation_locked "$state" "$corr" || true
  if [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] \
    || [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ]; then
    archive_rc=0
    _fm_pending_reply_archive_locked "$state" "$corr" || archive_rc=$?
    if [ "$archive_rc" -ne 0 ]; then
      fm_pending_reply_set "$rec" phase "$phase" || true
      return 2
    fi
  fi
  return 0
}

# Observe backend busy/idle evidence for the active turn without reading chat.
# busy_state must be one of: busy | idle | unknown.
fm_pending_reply_observe_busy() {  # <state-dir> <corr_id> <busy_state>
  local state=$1 corr=$2 busy_state=$3
  local rec phase delivered now seen completed field_seen field_completed
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  if [ "$phase" = awaiting_report ]; then
    field_seen=turn_seen_busy
    field_completed=request_turn_completed_epoch
  else
    field_seen=recovery_turn_seen_busy
    field_completed=recovery_turn_completed_epoch
  fi
  seen=$(fm_pending_reply_get "$rec" "$field_seen")
  completed=$(fm_pending_reply_get "$rec" "$field_completed")
  case "$busy_state" in
    busy)
      if [ "$seen" != 1 ]; then
        fm_pending_reply_set "$rec" "$field_seen" 1 || return 1
      fi
      ;;
    idle)
      if [ -z "$completed" ]; then
        # Prefer a busy->idle transition. Also accept a pure idle after delivery
        # when the first observation already missed the busy window (fast turns).
        if [ "$seen" = 1 ] || [ "$seen" = 0 ]; then
          now=$(fm_pending_reply_now)
          fm_pending_reply_set "$rec" "$field_completed" "$now" || return 1
        fi
      fi
      ;;
    unknown)
      # No independent proof; leave completion unset.
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

fm_pending_reply_fallback_idle_eligible() {  # <record-path>
  local rec=$1 phase start seen grace now age
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report)
      start=$(fm_pending_reply_get "$rec" delivered_epoch)
      seen=$(fm_pending_reply_get "$rec" turn_seen_busy)
      ;;
    recovery_sent)
      start=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
      seen=$(fm_pending_reply_get "$rec" recovery_turn_seen_busy)
      ;;
    *) return 1 ;;
  esac
  [ "$seen" = 1 ] && return 0
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - start))
  [ "$age" -ge "$grace" ]
}

# fm_pending_reply_backend_observation: one busy/idle observation of a
# SECONDMATE endpoint, without ever reading its conversation.
#
# Deliberately NOT the semantic busy-state contract (bin/fm-busy-lib.sh).
# That contract covers ordinary task workers, whose turn lifecycle firstmate
# wires at spawn; a secondmate has no such wiring because an idle secondmate
# pane is healthy and it runs no supervised turn sequence of its own. This
# observation exists only to notice a busy-then-idle transition around one
# delivered request, so it is a delivery-confirmation signal in the same
# category as the submit acknowledgement matcher in bin/fm-composer-lib.sh - never task
# state, and never a source consumers can confuse with semantic state.
#
# It stays harness-scoped (fm_busy_lines_match with the recorded harness, no
# global OR of every vendor signature), so one harness's output cannot make
# another read busy, and a weak rendered idle degrades to `fallback-idle`,
# which the caller accepts as idle only after its grace window.
fm_pending_reply_backend_observation() {  # <backend> <target> [expected-label] [harness]
  local backend=$1 target=$2 expected_label=${3-} harness=${4-} native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy|idle) printf '%s' "$native"; return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 "$expected_label" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'fallback-idle'
  fi
}

fm_pending_reply_backend_observation_bounded() {  # <seconds> <backend> <target> [expected-label] [harness]
  local timeout=$1 backend=$2
  shift
  # Load the selected adapter once in the watcher. The timed child inherits the
  # definitions instead of re-sourcing this complete library for every record.
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  fm_run_function_timed "$timeout" fm_pending_reply_backend_observation "$@"
}

fm_pending_reply_busy_state_from_observation() {  # <record-path> <observation>
  local rec=$1 observation=$2
  case "$observation" in
    busy|idle|unknown) printf '%s' "$observation" ;;
    fallback-idle)
      if fm_pending_reply_fallback_idle_eligible "$rec"; then
        printf 'idle'
      else
        printf 'unknown'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# Explicit turn-completion proof (for tests and turn-end backends that surface
# a completion event without a busy/idle pair).
fm_pending_reply_mark_turn_completed() {  # <state-dir> <corr_id> [which: request|recovery]
  local state=$1 corr=$2 which=${3:-request}
  local rec phase field now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$which" in
    request) field=request_turn_completed_epoch ;;
    recovery) field=recovery_turn_completed_epoch ;;
    *) return 2 ;;
  esac
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" "$field" "$now" || return 1
  # Keep phase consistent with which turn completed.
  if [ "$which" = recovery ] && [ "$phase" = awaiting_report ]; then
    : # recovery completion only meaningful after recovery_sent
  fi
  return 0
}

# --- remote reply-channel freshness -----------------------------------------
#
# A LOCAL secondmate appends its report straight into the parent's
# state/<id>.status, so an absent correlated line there is immediate evidence
# that no report was written. A REMOTE mate's reports reach that same file only
# through the asynchronous mirror in bin/fm-procevent-remote-reply.sh, so the
# same absence proves nothing until that mirror has actually been read past the
# turn that should have produced the report. Without this distinction the guard
# nags a REPOST REQUIRED for a reply the mate did write and the parent simply
# had not received yet - the common case, because the mirror's poll window is
# comparable to the recovery grace.
#
# The mirror therefore publishes one watermark: the epoch at which it last knew
# it had read the remote log through its end. Only that adapter writes it (it
# owns the channel), and only this library reads it. A channel that is behind,
# unarmed, or broken simply never advances the watermark, so the request stays
# durably open and un-nagged; the mirror escalates its own continuity failures.
fm_pending_reply_remote_channel_watermark_path() {  # <state-dir> <task_id>
  printf '%s/remote-replies/%s.caught-up' "$1" "$2"
}

# Record that the mirrored remote reply log for <task_id> was read through its
# end at <epoch> (default now). Called only by the remote reply adapter.
fm_pending_reply_note_remote_channel_caught_up() {  # <state-dir> <task_id> [epoch]
  local state=$1 task_id=$2 epoch=${3-} path dir tmp
  [ -n "$state" ] && [ -n "$task_id" ] || return 2
  case "$epoch" in ''|*[!0-9]*) epoch=$(fm_pending_reply_now) ;; esac
  path=$(fm_pending_reply_remote_channel_watermark_path "$state" "$task_id")
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  [ ! -L "$path" ] || return 1
  tmp="$dir/.caught-up.$task_id.$$"
  printf 'caught_up_epoch=%s\n' "$epoch" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path"
}

# Print the watermark epoch, or nothing when the channel never reported itself
# caught up. Never invents a value.
fm_pending_reply_remote_channel_epoch() {  # <state-dir> <task_id>
  local path epoch
  path=$(fm_pending_reply_remote_channel_watermark_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  epoch=$(sed -n 's/^caught_up_epoch=//p' "$path" 2>/dev/null | head -1)
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$epoch"
}

# 0 when <task_id> is a secondmate whose reports cross a machine boundary.
fm_pending_reply_target_is_remote() {  # <state-dir> <task_id>
  local meta="$1/$2.meta"
  [ -f "$meta" ] || return 1
  [ -n "$(fm_meta_get "$meta" remote_host)" ]
}

# 0 when "no correlated report in the parent status log" is admissible evidence
# that the mate never reported: always for a local target, and for a remote one
# only once the mirror has been read through its end at or after <since-epoch>.
fm_pending_reply_missing_report_is_evidence() {  # <state-dir> <task_id> <since-epoch>
  local state=$1 task_id=$2 since=$3 caught
  fm_pending_reply_target_is_remote "$state" "$task_id" || return 0
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  caught=$(fm_pending_reply_remote_channel_epoch "$state" "$task_id")
  [ -n "$caught" ] || return 1
  [ "$caught" -ge "$since" ]
}

# Build the one automatic recovery message for a pending record.
fm_pending_reply_recovery_message() {  # <record-path>
  local rec=$1 corr summary token msg
  corr=$(fm_pending_reply_get "$rec" corr_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  token=$(fm_pending_reply_corr_token "$corr")
  msg="REPOST REQUIRED: previous marked request had no correlated parent report. Reply on the parent status channel including ${token}. Original request: ${summary}"
  fm_pending_reply_embed_corr "$msg" "$corr" msg
  printf '%s' "$msg"
}

# Deliver the recovery message once. Caller must hold phase awaiting_report with
# turn completed and grace elapsed. Uses FM_PENDING_REPLY_SEND_HOOK when set
# (tests), otherwise invokes fm-send with FM_PENDING_REPLY_EXISTING_CORR so a
# second expectation is not created.
fm_pending_reply_send_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed delivered attempted grace now age task_id msg parent_home send_status=0
  local sender_pid sender_identity
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = awaiting_report ] || return 1
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  if [ -n "$attempted" ]; then
    fm_pending_reply_reconcile_recovery "$state" "$corr" || true
    return 1
  fi
  completed=$(fm_pending_reply_get "$rec" request_turn_completed_epoch)
  [ -n "$completed" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 1
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - delivered))
  [ "$age" -ge "$grace" ] || return 1
  task_id=$(fm_pending_reply_get "$rec" task_id)
  # A remote mate's report may exist and simply not have been mirrored yet.
  fm_pending_reply_missing_report_is_evidence "$state" "$task_id" "$completed" || return 1
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  msg=$(fm_pending_reply_recovery_message "$rec")
  sender_pid=${BASHPID:-$$}
  sender_identity=$(fm_pending_reply_pid_identity "$sender_pid") || return 1
  fm_pending_reply_set "$rec" recovery_sender_pid "$sender_pid" || return 1
  fm_pending_reply_set "$rec" recovery_sender_identity "$sender_identity" || return 1
  fm_pending_reply_set "$rec" recovery_attempted_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase recovery_sending || return 1
  if [ -n "${FM_PENDING_REPLY_SEND_HOOK:-}" ]; then
    # Hook receives: task_id message
    # shellcheck disable=SC2086
    if ! eval "$FM_PENDING_REPLY_SEND_HOOK" "$(printf '%q' "$task_id")" "$(printf '%q' "$msg")"; then
      send_status=1
    fi
  else
    if [ -z "$parent_home" ] || [ ! -d "$parent_home" ]; then
      send_status=1
    elif ! env FM_HOME="$parent_home" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
      "$_FM_PENDING_REPLY_LIB_DIR/fm-send.sh" "$task_id" "$msg"; then
      send_status=1
    fi
  fi
  if [ "$send_status" = 0 ]; then
    fm_pending_reply_finish_recovery "$state" "$corr" confirmed
    return $?
  fi
  fm_pending_reply_finish_recovery "$state" "$corr" failed || return 1
  return 1
}

fm_pending_reply_send_recovery_bounded() {  # <seconds> <state-dir> <corr_id>
  local timeout=$1
  shift
  fm_run_function_timed "$timeout" fm_pending_reply_send_recovery "$@"
}

fm_pending_reply_pid_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s' "$identity"
}

fm_pending_reply_sender_alive() {  # <record-path>
  local rec=$1 pid expected actual
  pid=$(fm_pending_reply_get "$rec" recovery_sender_pid)
  expected=$(fm_pending_reply_get "$rec" recovery_sender_identity)
  [ -n "$expected" ] || return 1
  actual=$(fm_pending_reply_pid_identity "$pid") || return 1
  [ "$actual" = "$expected" ]
}

fm_pending_reply_finish_recovery() {  # <state-dir> <corr_id> <confirmed|failed>
  local state=$1 corr=$2 outcome=$3 rec phase now sent
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = recovery_sending ] || return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome "$outcome" || return 1
  if [ "$outcome" = confirmed ]; then
    sent=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
    if [ -z "$sent" ]; then
      now=$(fm_pending_reply_now)
      fm_pending_reply_set "$rec" recovery_sent_epoch "$now" || return 1
    fi
    fm_pending_reply_set "$rec" recovery_turn_seen_busy 0 || return 1
    fm_pending_reply_set "$rec" recovery_turn_completed_epoch "" || return 1
    fm_pending_reply_set "$rec" phase recovery_sent || return 1
  else
    [ "$outcome" = failed ] || return 1
    fm_pending_reply_set "$rec" phase recovery_failed || return 1
  fi
}

fm_pending_reply_reconcile_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase attempted outcome
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|recovery_sending) ;; *) return 1 ;; esac
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  [ -n "$attempted" ] || return 1
  case "$attempted" in *[!0-9]*) return 1 ;; esac
  outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$outcome" in
    confirmed) fm_pending_reply_finish_recovery "$state" "$corr" confirmed; return $? ;;
    failed) fm_pending_reply_finish_recovery "$state" "$corr" failed; return $? ;;
    unknown)
      fm_pending_reply_set "$rec" phase recovery_unknown || return 1
      return 0
      ;;
  esac
  fm_pending_reply_sender_alive "$rec" && return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome unknown || return 1
  fm_pending_reply_set "$rec" phase recovery_unknown || return 1
}

# The decision key an escalation for <corr_id> opens in the parent status log.
# Per-request rather than the bare default key, so one request's escalation
# neither masks nor is masked by an unrelated decision on the same task.
fm_pending_reply_escalation_key() {  # <corr_id>
  printf 'pending-reply-%s' "$1"
}

# Close-note body the reserved-key fold accepts as this library's resolution.
# The fold's guard (bin/fm-classify-lib.sh _fm_decision_key_transition_allowed)
# requires the note to begin with this namespace's vocabulary token; this is
# that token plus the stable task/id/via fields both the record close and the
# operator --resolve-key path write. Optional <extra> is appended after a space.
fm_pending_reply_resolved_note() {  # <task-id> <corr_id> <via> [extra]
  printf 'pending-reply-resolved: task=%s pending-reply-id=%s via=%s' "$1" "$2" "$3"
  if [ -n "${4:-}" ]; then
    printf ' %s' "$4"
  fi
}

# 0 and prints the close note when <key> is in this library's reserved
# namespace (pending-reply-<corr>). fm-send --resolve-key uses this so an
# operator close speaks the same vocabulary as fm_pending_reply_close_escalation
# instead of writing a silent no-op answered: note.
fm_pending_reply_close_note_for_key() {  # <key> <task-id> <via> [extra]
  case "$1" in
    pending-reply-*)
      fm_pending_reply_resolved_note "$2" "${1#pending-reply-}" "$3" "${4:-}"
      ;;
    *) return 1 ;;
  esac
}

fm_pending_reply_escalation_payload() {  # <record-path> <kind>
  local rec=$1 kind=$2 task_id corr summary outcome token
  task_id=$(fm_pending_reply_get "$rec" task_id)
  corr=$(fm_pending_reply_get "$rec" corr_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  [ -n "$task_id" ] && [ -n "$corr" ] || return 1
  case "$kind" in
    missed)
      token=pending-reply-missed
      ;;
    delivery-unknown)
      token=pending-reply-delivery-unknown
      ;;
    recovery-delivery)
      outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
      case "$outcome" in failed|unknown) ;; *) return 1 ;; esac
      token="pending-reply-recovery-delivery-$outcome"
      ;;
    *) return 1 ;;
  esac
  printf '%s: task=%s pending-reply-id=%s request=%s' "$token" "$task_id" "$corr" "$summary"
}

# The escalation line this library published for <corr_id>, or empty. A legacy
# unkeyed escalation is matched and closed under the shared default key while
# that exact escalation remains open. If an unrelated decision has since taken
# over that key, the close is withheld so the unrelated decision is not cleared.
fm_pending_reply_escalation_line() {  # <status-file> <record-path> <corr_id>
  local status_file=$1 rec=$2 corr=$3 line found='' kind payload own_key
  [ -f "$status_file" ] || return 0
  [ "$(fm_pending_reply_get "$rec" corr_id)" = "$corr" ] || return 0
  own_key=$(fm_pending_reply_escalation_key "$corr")
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = blocked ] || continue
    for kind in missed delivery-unknown recovery-delivery; do
      payload=$(fm_pending_reply_escalation_payload "$rec" "$kind") || continue
      case "$line" in
        "blocked [key=$own_key]: $payload"|"blocked: $payload") found=$line; break ;;
        "blocked [key=$own_key]: $payload "*|"blocked: $payload "*) found=$line; break ;;
      esac
    done
  done < "$status_file"
  printf '%s' "$found"
}

# Close the durable status decision a previous escalation opened for <corr_id>.
# Idempotent, and safe to retry until it succeeds: it appends the closing line
# only while that exact keyed decision is still open in
# bin/fm-classify-lib.sh's fold. Records that never escalated are left untouched.
fm_pending_reply_close_escalation() {  # <state-dir> <corr_id>
  # Serialized per correlation so a resolution and an escalation cannot interleave.
  # bin/fm-wake-lib.sh owns the lock primitives but assigns its own globals when
  # sourced, so they are declared local here: that contains them to this call
  # instead of leaking into every script that sources this library, without the
  # subshell that would make every later use of them read as a lost write.
  # The lock is released explicitly rather than from an EXIT trap, because a trap
  # in a plain function would clobber the caller's own.
  local state=$1 corr=$2 lock rc=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_close_escalation_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

_fm_pending_reply_close_escalation_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec escalated closed parent_status escalation key note
  local open_line open_key open_note now close_line close_rc _task _via
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || return 0
  escalated=$(fm_pending_reply_get "$rec" escalated_epoch)
  [ -n "$escalated" ] || return 0
  closed=$(fm_pending_reply_get "$rec" escalation_closed_epoch)
  [ -z "$closed" ] || return 0
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  [ -n "$parent_status" ] || return 1
  escalation=$(fm_pending_reply_escalation_line "$parent_status" "$rec" "$corr")
  if [ -n "$escalation" ]; then
    key=$(_fm_decision_key "$escalation") || key=''
    note=$(status_line_note "$escalation")
    while IFS= read -r open_line; do
      [ -n "$open_line" ] || continue
      open_key=${open_line%%$'\t'*}
      [ "$open_key" = "$key" ] || continue
      open_note=${open_line#*$'\t'}
      open_note=${open_note#*$'\t'}
      [ "$open_note" = "$note" ] || continue
      # This close is the home's own bookkeeping, written by the same resolve
      # or tick that already consumed the reply, so it uses the guarded
      # self-announced append (bin/fm-wake-lib.sh, sourced by this function's
      # wrappers) and does not wake the home that wrote it; the escalation
      # OPEN above stays a plain append because a new blocker must wake.
      _task=$(fm_pending_reply_get "$rec" task_id)
      _via=$(fm_pending_reply_get "$rec" resolved_via)
      close_line="resolved [key=${key}]: $(fm_pending_reply_resolved_note "$_task" "$corr" "$_via")"
      close_rc=0
      fm_wake_status_append_self_announced "${parent_status%/*}" "$parent_status" "$close_line" \
        2>/dev/null || close_rc=$?
      [ "$close_rc" -ne 2 ] || return 1
      break
    done <<EOF
$(status_open_decisions "$parent_status")
EOF
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" escalation_closed_epoch "$now"
}

# Escalate once after a missed recovery report or failed delivery outcome.
# Retains the durable unresolved record. Never loops.
fm_pending_reply_maybe_escalate() {  # <state-dir> <corr_id>
  # Serialized per correlation so a resolution and an escalation cannot interleave.
  # bin/fm-wake-lib.sh owns the lock primitives but assigns its own globals when
  # sourced, so they are declared local here: that contains them to this call
  # instead of leaking into every script that sources this library, without the
  # subshell that would make every later use of them read as a lost write.
  # The lock is released explicitly rather than from an EXIT trap, because a trap
  # in a plain function would clobber the caller's own.
  local state=$1 corr=$2 lock rc=0
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  STATE=$state
  lock="$state/.pending-reply-$corr.lock"
  fm_pending_reply_require_wake_lib || return 1
  fm_lock_acquire_wait "$lock" || return 1
  _fm_pending_reply_maybe_escalate_locked "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

_fm_pending_reply_maybe_escalate_locked() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed now payload parent_status line kind first display
  local delivered task_id meta sm_home remote_host
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = delivery_unknown ]; then
    _fm_pending_reply_reconcile_delivery_locked "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    [ "$phase" = delivery_unknown ] || return 0
  fi
  case "$phase" in
    recovery_sent)
      completed=$(fm_pending_reply_get "$rec" recovery_turn_completed_epoch)
      [ -n "$completed" ] || return 1
      # Same reply-channel evidence rule the recovery repost obeys: a missing
      # correlated report is not a missed report until the mirror caught up.
      fm_pending_reply_missing_report_is_evidence "$state" \
        "$(fm_pending_reply_get "$rec" task_id)" "$completed" || return 1
      ;;
    delivery_unknown|recovery_failed|recovery_unknown) ;;
    *) return 1 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  task_id=$(fm_pending_reply_get "$rec" task_id)
  meta="$state/${task_id}.meta"
  if [ -n "$delivered" ] && [ -f "$meta" ]; then
    remote_host=$(fm_meta_get "$meta" remote_host)
    sm_home=$(fm_meta_get "$meta" home)
    if [ -z "$remote_host" ] && [ -n "$sm_home" ]; then
      fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
      fm_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home" || true
    fi
  fi
  # Resolve wins if a late report arrived between completion and this call.
  local resolve_rc=0
  _fm_pending_reply_try_resolve_locked "$state" "$corr" || resolve_rc=$?
  [ "$resolve_rc" -eq 0 ] && return 0
  [ "$resolve_rc" -ne 2 ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 1
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  case "$phase" in
    delivery_unknown) kind=delivery-unknown ;;
    recovery_failed|recovery_unknown) kind=recovery-delivery ;;
    *) kind=missed ;;
  esac
  payload=$(fm_pending_reply_escalation_payload "$rec" "$kind") || return 1
  if [ "$kind" = missed ]; then
    first=$(fm_pending_reply_get "$rec" wrong_home_first_sighting)
    if display=$(fm_pending_reply_sighting_display "$first"); then
      payload="$payload token seen in $display; parent channel has no corr="
    fi
  fi
  [ -n "$parent_status" ] || return 1
  mkdir -p "$(dirname "$parent_status")" 2>/dev/null || return 1
  line="blocked [key=$(fm_pending_reply_escalation_key "$corr")]: $payload"
  if ! grep -Fqx "$line" "$parent_status" 2>/dev/null; then
    printf '%s\n' "$line" >> "$parent_status" 2>/dev/null || return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" escalated_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase escalated || return 1
  return 0
}

# Detect a correlated report written under the secondmate home (wrong home)
# without treating it as acknowledgement. A remote route's
# parent-replies.status is its parent channel, not a stranded self-home file.
fm_pending_reply_detect_wrong_home() {  # <state-dir> <corr_id> <secondmate-home>
  local state=$1 corr=$2 sm_home=$3
  local rec delivered hits first sightings snapshot previous status_file line line_no sighting_base sighting_id phase changed=0
  local remote_parent_channel=0
  rec=$(fm_pending_reply_locate "$state" "$corr") || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 0
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  snapshot=$(fm_pending_reply_status_set_signature "$sm_home/state")
  previous=$(fm_pending_reply_get "$rec" wrong_home_scan_signature)
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  first=$(fm_pending_reply_get "$rec" wrong_home_first_sighting)
  if [ "$snapshot" = "$previous" ] && { [ "$hits" = 0 ] || [ -n "$first" ]; }; then
    return 0
  fi
  sightings=$(fm_pending_reply_get "$rec" wrong_home_sightings)
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$_FM_PENDING_REPLY_LIB_DIR/fm-parent-channel-lib.sh"
  if fm_parent_channel_destination "$sm_home" "$sm_home/state" >/dev/null 2>&1 \
    && [ "$FM_PARENT_CHANNEL_ROUTE" = remote ]; then
    remote_parent_channel=1
  fi
  for status_file in "$sm_home"/state/*.status; do
    [ -e "$status_file" ] || continue
    if [ "$remote_parent_channel" = 1 ] \
      && [ "$(basename "$status_file")" = parent-replies.status ]; then
      continue
    fi
    sighting_base=$(fm_pending_reply_sighting_encode "$status_file" 0) || continue
    sighting_base=${sighting_base%:0}
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      fm_pending_reply_line_resolves "$line" "$corr" || continue
      sighting_id="$sighting_base:$line_no"
      [ -n "$first" ] || first=$sighting_id
      case ",$sightings," in
        *",$sighting_id,"*) continue ;;
      esac
      if [ -n "$sightings" ]; then
        sightings="$sightings,$sighting_id"
      else
        sightings=$sighting_id
      fi
      hits=$((hits + 1))
      changed=1
    done < "$status_file"
  done
  if [ -n "$first" ] && [ -z "$(fm_pending_reply_get "$rec" wrong_home_first_sighting)" ]; then
    fm_pending_reply_set "$rec" wrong_home_first_sighting "$first" || return 1
  fi
  if [ "$changed" = 1 ]; then
    fm_pending_reply_set "$rec" wrong_home_sightings "$sightings" || return 1
    fm_pending_reply_set "$rec" wrong_home_hits "$hits" || return 1
  fi
  fm_pending_reply_set "$rec" wrong_home_scan_signature "$snapshot" || return 1
  return 0
}

# Restatement-copy a same-basename self-home corr= line onto the parent channel.
# Only $sm_home/state/<task_id>.status is copied; arbitrary child status files
# stay evidence, not acknowledgement.
fm_pending_reply_restatement_copy_same_basename() {  # <state-dir> <corr_id> <secondmate-home>
  local state=$1 corr=$2 sm_home=$3
  local rec task_id parent_status stranded line
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 1
  task_id=$(fm_pending_reply_get "$rec" task_id)
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  [ -n "$task_id" ] && [ -n "$parent_status" ] || return 1
  stranded="$sm_home/state/${task_id}.status"
  [ -f "$stranded" ] && [ ! -L "$stranded" ] || return 1
  [ "$stranded" != "$parent_status" ] || return 1
  line=$(fm_pending_reply_find_resolve_line "$stranded" "$corr")
  [ -n "$line" ] || return 1
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$_FM_PENDING_REPLY_LIB_DIR/fm-parent-channel-lib.sh"
  fm_parent_channel_append_once "$parent_status" "$line"
}

# One reconciliation tick for a single record: resolve, observe, recover, escalate.
# busy_state is busy|idle|unknown for the secondmate endpoint.
# secondmate_home may be empty when unknown.
fm_pending_reply_tick_one() {  # <state-dir> <corr_id> <busy_state> [secondmate-home]
  local state=$1 corr=$2 busy_state=$3 sm_home=${4-}
  local rec phase delivered
  rec=$(fm_pending_reply_path "$state" "$corr")
  if [ ! -f "$rec" ]; then
    # A settled record has been filed under archive/ during resolution. There is
    # nothing left to observe or escalate for
    # it, so this is inert success rather than a missing record - reporting it as
    # missing would turn every settled correlation into a tick failure.
    [ -f "$(fm_pending_reply_archive_dir "$state")/$corr" ] && return 0
    return 1
  fi
  fm_pending_reply_reconcile_delivery "$state" "$corr" || true
  phase=$(fm_pending_reply_get "$rec" phase)
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    case "$phase" in
      delivery_unknown) fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true ;;
      escalated) fm_pending_reply_try_resolve "$state" "$corr" >/dev/null 2>&1 || true ;;
    esac
    return 0
  fi
  # Correlated parent report always wins and is idempotent.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending)
      if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
        fm_pending_reply_reconcile_recovery "$state" "$corr" || true
        phase=$(fm_pending_reply_get "$rec" phase)
      fi
      ;;
  esac
  case "$phase" in
    resolved) return 0 ;;
    escalated)
      # Unresolved durable record retained; never auto-delete.
      if [ -n "$sm_home" ]; then
        fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
        if fm_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home"; then
          if fm_pending_reply_try_resolve "$state" "$corr"; then
            return 0
          fi
        fi
      fi
      return 0
      ;;
    recovery_sending) return 0 ;;
    recovery_failed|recovery_unknown)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      return 0
      ;;
  esac
  if [ -n "$sm_home" ]; then
    fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
    fm_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home" || true
  fi
  fm_pending_reply_observe_busy "$state" "$corr" "$busy_state" || true
  # Re-check resolve after observation in case a concurrent status write landed.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = awaiting_report ]; then
    if [ -n "${FM_PENDING_REPLY_TICK_TIMEOUT:-}" ]; then
      fm_pending_reply_send_recovery_bounded \
        "$FM_PENDING_REPLY_TICK_TIMEOUT" "$state" "$corr" 2>/dev/null || true
    else
      fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null || true
    fi
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    recovery_sent|recovery_failed|recovery_unknown)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Scan every pending record for this parent state. Safe to call every poll.
# Never scrapes secondmate conversation; uses only parent status, backend busy
# state, and optional secondmate-home wrong-home path checks.
fm_pending_reply_tick() {  # <state-dir>
  local state=$1 dir rec corr task_id phase delivered meta backend target label busy sm_home harness remote_host
  local observation observation_task observation_timeout observation_grace found i
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  local -a observation_tasks=() observation_values=()
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  STATE=$state
  fm_pending_reply_require_wake_lib || return 1
  for rec in "$dir"/*; do
    # The archive subdirectory holds settled records and is deliberately not
    # scanned: it is read lazily by correlation id (fm_pending_reply_locate).
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    # One beat per record. Each record is a unit of progress, so this keeps the
    # watcher's liveness beacon honest across a long tick without ever becoming a
    # wall-clock timer: a tick that hangs on one record stops beating, which is
    # exactly the signal the arm layer needs. The callback runs in the watcher
    # process itself - never inside command substitution - so the invariant that
    # only the watcher touches its beacon still holds.
    if [ -n "${FM_PENDING_REPLY_TICK_BEAT:-}" ]; then
      "$FM_PENDING_REPLY_TICK_BEAT"
    fi
    corr=$(fm_pending_reply_get "$rec" corr_id)
    [ -n "$corr" ] || corr=$(basename "$rec")
    task_id=$(fm_pending_reply_get "$rec" task_id)
    phase=$(fm_pending_reply_get "$rec" phase)
    if [ "$phase" = resolved ]; then
      if [ -n "$(fm_pending_reply_get "$rec" escalated_epoch)" ] \
        && [ -z "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ]; then
        fm_pending_reply_try_resolve "$state" "$corr" || true
      fi
      continue
    fi
    fm_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    if [ -z "$delivered" ]; then
      case "$phase" in
        delivery_unknown|escalated)
          fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
          ;;
      esac
      continue
    fi
    case "$phase" in
      awaiting_report|recovery_sending)
        if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
          fm_pending_reply_reconcile_recovery "$state" "$corr" || true
          phase=$(fm_pending_reply_get "$rec" phase)
        fi
        ;;
    esac
    meta="$state/${task_id}.meta"
    if [ "$phase" = escalated ]; then
      if fm_pending_reply_try_resolve "$state" "$corr"; then
        continue
      fi
      if [ -f "$meta" ]; then
        sm_home=$(fm_meta_get "$meta" home)
        if [ -n "$sm_home" ]; then
          fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
          if fm_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home"; then
            if fm_pending_reply_try_resolve "$state" "$corr"; then
              continue
            fi
          fi
        fi
      fi
      continue
    fi
    case "$phase" in
      recovery_failed|recovery_unknown)
        fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
        continue
        ;;
    esac
    case "$phase" in
      awaiting_report|recovery_sent) ;;
      *) continue ;;
    esac
    backend=tmux
    target=
    busy=unknown
    sm_home=
    harness=
    if [ -f "$meta" ]; then
      remote_host=$(fm_meta_get "$meta" remote_host)
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      sm_home=$(fm_meta_get "$meta" home)
      harness=$(fm_meta_get "$meta" harness)
      if [ -n "$remote_host" ]; then
        target="remote:$task_id"
        sm_home=
      fi
      if [ -n "$target" ]; then
        label="fm-$task_id"
        observation=
        found=0
        for ((i = 0; i < ${#observation_tasks[@]}; i++)); do
          observation_task=${observation_tasks[$i]}
          [ "$observation_task" = "$task_id" ] || continue
          observation=${observation_values[$i]}
          found=1
          break
        done
        if [ "$found" = 0 ]; then
          observation_grace=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
          case "$observation_grace" in ''|*[!0-9]*|0) observation_grace=300 ;; esac
          observation_timeout=$(( observation_grace / 2 ))
          [ "$observation_timeout" -ge 1 ] || observation_timeout=1
          [ "$observation_timeout" -le 30 ] || observation_timeout=30
          if [ -n "${FM_PENDING_REPLY_TICK_BEAT:-}" ]; then
            "$FM_PENDING_REPLY_TICK_BEAT"
          fi
          if [ -n "$remote_host" ]; then
            observation=$(fm_run_timed "$observation_timeout" \
              "$_FM_PENDING_REPLY_LIB_DIR/fm-on.sh" "$task_id" \
              fm-remote-secondmate-control.sh observe "$task_id" < /dev/null 2>/dev/null || printf 'unknown')
            case "$observation" in busy|idle|fallback-idle|unknown) ;; *) observation=unknown ;; esac
          else
            if [ -n "${FM_PENDING_REPLY_TICK_TIMEOUT:-}" ]; then
              observation=$(fm_pending_reply_backend_observation_bounded \
                "$FM_PENDING_REPLY_TICK_TIMEOUT" "$backend" "$target" "$label" "$harness" \
                2>/dev/null || printf 'unknown')
            else
              observation=$(fm_pending_reply_backend_observation \
                "$backend" "$target" "$label" "$harness")
            fi
          fi
          observation_tasks+=("$task_id")
          observation_values+=("$observation")
        fi
        busy=$(fm_pending_reply_busy_state_from_observation "$rec" "$observation")
      fi
    fi
    fm_pending_reply_tick_one "$state" "$corr" "$busy" "$sm_home" || true
  done
  return 0
}

# True when any open (non-resolved) pending reply exists for a task.
fm_pending_reply_task_has_open() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 dir rec phase tid
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(fm_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    [ "$phase" != resolved ] || continue
    return 0
  done
  return 1
}
