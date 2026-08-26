#!/usr/bin/env bash
# Remote-secondmate reply adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-remote-reply.sh arm <secondmate-id>
#   fm-procevent-remote-reply.sh handle <secondmate-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh classify <result-file>
#   fm-procevent-remote-reply.sh terminal <result-file>
#   fm-procevent-remote-reply.sh self-announcing
#   fm-procevent-remote-reply.sh source-id <secondmate-id>
#   fm-procevent-remote-reply.sh retire <secondmate-id>
#
# `arm` registers one blocking, non-destructive delta source for the remote
# home's state/parent-replies.status log. The process-event runner owns blocking,
# capture, publication, and one machine-wide source owner. Each captured delta is
# terminal for that exact registration; `handle` validates and idempotently
# ingests it, acknowledges the captured generation, then registers the next
# cursor-anchored source. A continuity break is escalated and not re-armed.
#
# `autohandle` is the runner's own entry into that same `handle`: it takes the
# canonical source id instead of the secondmate id and is called by the runner
# right after capture, so applying a reply never depends on a handler
# remembering to run it. Ingesting a delta carries no judgement, so it belongs
# in code.
#
# `self-announcing` declares this adapter's one-announcement contract to the
# runner: every byte autohandle applies lands in the parent's state/<id>.status
# stream, whose ordinary signal-scan announcement is durable, so a fully
# autohandled capture needs - and gets - no `check` wake of its own. One remote
# note therefore produces exactly one firstmate wake, through the same signal
# classification a local secondmate's own status append gets, and a replayed
# capture whose every line is already mirrored (the at-most-once append) adds
# no bytes and stays completely quiet. Only a capture autohandle could NOT
# fully apply is published as a `check` wake for the manual handler, and
# running `handle` on that wake is idempotent.
#
# This channel is a status-stream MIRROR, not a correlated-reply channel. A local
# secondmate appends its whole status stream straight into the parent's
# state/<id>.status, and every parent consumer - the open-decision fold, wake
# classification, crew-state reconciliation, and pending-reply resolution - reads
# that one stream. A remote secondmate must present the same model, so ingest
# mirrors every content-bearing line at most once, omits blank separators, and
# leaves every semantic judgement to those same shared consumers. Correlation is
# a per-line property that fm-pending-reply-lib.sh consumes; it is never a gate
# on the stream. Gating on it here made a remote mate's own progress lines and
# newly raised decisions - which carry no corr= by contract - unrepresentable,
# and rejecting one line failed the whole delta, so the cursor could never
# advance past it. No single line can stop or wedge the stream.
#
# What remains here is only what crossing a machine boundary genuinely adds:
#   - cursor continuity and identity (offset plus prefix digest)
#   - data/*.md pointers fetched through the path-confined remote file reader and
#     rewritten to their local copies, because the parent cannot read the remote
#     filesystem
#   - at-most-once append, because a captured generation can be replayed
#   - control-byte normalization, so content-bearing bytes from another machine
#     cannot make the parent's status file unsafe to read
#   - the caught-up watermark this channel publishes for
#     bin/fm-pending-reply-lib.sh, because a report that exists remotely but has
#     not been mirrored yet must not be mistaken for a report the mate never
#     wrote (see WINDOW_CLOSED_EMPTY below)
# Line framing and size bounding belong to bin/fm-remote-delta-read.sh, which
# delivers only whole lines and breaks continuity on an over-long one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CURSOR_DIR="$STATE/remote-replies"
REMOTE_LOG='state/parent-replies.status'
WAIT_SECONDS=${FM_REMOTE_REPLY_WAIT_SECONDS:-55}
MAX_DOC_BYTES=${FM_REMOTE_REPLY_MAX_DOC_BYTES:-262144}
# fm-on.sh returns ssh's status unchanged, so 255 alone means unavailable
# transport or unknown remote completion. Any other nonzero status is the remote
# reader's own refusal and will not change on a retry.
SSH_UNAVAILABLE=255
DOCUMENT_LOCAL_FAILURE=2

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

empty_hash() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-empty-hash.XXXXXX") || return 1
  : > "$tmp"
  sha256_file "$tmp"
  rm -f -- "$tmp"
}

validate_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac
}

source_id() {
  validate_id "$1"
  printf 'remote-reply-%s\n' "$1"
}

cursor_path() { printf '%s/%s.cursor\n' "$CURSOR_DIR" "$1"; }
ingest_receipt_path() { printf '%s/%s.%s.ingested\n' "$CURSOR_DIR" "$1" "$2"; }

read_cursor() { # <id>; sets CURSOR_OFFSET and CURSOR_HASH
  local path=$1 offset hash schema
  path=$(cursor_path "$path")
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash) || die "cannot establish the empty cursor hash"
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "reply cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path")
  offset=$(sed -n 's/^offset=//p' "$path")
  hash=$(sed -n 's/^prefix_sha256=//p' "$path")
  [ "$schema" = fm-remote-reply-cursor.v1 ] || die "reply cursor has an incompatible schema: $path"
  case "$offset" in ''|*[!0-9]*) die "reply cursor has an invalid offset: $path" ;; esac
  case "$hash" in *[!A-Fa-f0-9]*|'') die "reply cursor has an invalid hash: $path" ;; esac
  [ "${#hash}" -eq 64 ] || die "reply cursor has an invalid hash length: $path"
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
}

write_cursor() { # <id> <offset> <hash>
  local id=$1 offset=$2 hash=$3 path tmp
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  path=$(cursor_path "$id")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-remote-reply-cursor.v1\n'
    printf 'offset=%s\n' "$offset"
    printf 'prefix_sha256=%s\n' "$hash"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

ingest_receipt_matches() { # <id> <sequence> <result>
  local path stored actual count
  path=$(ingest_receipt_path "$1" "$2")
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || die "remote reply ingestion receipt is unsafe: $path"
  count=$(grep -c '^result_sha256=' "$path" 2>/dev/null || true)
  [ "$count" -eq 1 ] || die "remote reply ingestion receipt is malformed: $path"
  stored=$(sed -n 's/^result_sha256=//p' "$path")
  case "$stored" in *[!A-Fa-f0-9]*|'') die "remote reply ingestion receipt is malformed: $path" ;; esac
  [ "${#stored}" -eq 64 ] || die "remote reply ingestion receipt is malformed: $path"
  actual=$(sha256_file "$3") || die "cannot hash remote reply result"
  [ "$stored" = "$actual" ] || die "remote reply generation conflicts with its ingestion receipt"
}

write_ingest_receipt() { # <id> <sequence> <result>
  local id=$1 seq=$2 result=$3 path tmp hash
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  path=$(ingest_receipt_path "$id" "$seq")
  if [ -e "$path" ] || [ -L "$path" ]; then
    ingest_receipt_matches "$id" "$seq" "$result"
    return $?
  fi
  hash=$(sha256_file "$result") || return 1
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.ingested.XXXXXX") || return 1
  printf 'result_sha256=%s\n' "$hash" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

result_field() { # <result> <field>
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$1"
}

classify_result() {
  local file=$1 schema status
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  status=$(result_field "$file" status 2>/dev/null || true)
  [ "$schema" = fm-remote-delta.v1 ] || { printf 'malformed\n'; return 0; }
  case "$status" in
    delta) printf 'delta\n' ;;
    continuity-broken) printf 'continuity-broken\n' ;;
    *) printf 'malformed\n' ;;
  esac
}

remote_route_exists() {
  local id=$1 remote
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  [ "$remote" = 1 ] || die "secondmate $id is not a configured remote route"
}

cmd_arm_locked() {
  local id=${1:-} sid
  validate_id "$id"
  remote_route_exists "$id"
  read_cursor "$id"
  sid=$(source_id "$id")
  "$SCRIPT_DIR/fm-procevent.sh" register remote-reply "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-remote-reply.sh" source "$id" || return 1
  printf 'armed: %s offset=%s\n' "$sid" "$CURSOR_OFFSET"
}

cmd_arm() {
  local id=${1:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_arm_locked "$id"
  )
}

# The reader's exit when its wait window closed with no complete new line. That
# is the one moment this channel can prove it is not behind: the window opened
# with the remote log matching the committed cursor exactly (any pending bytes
# would have returned a delta at once), so the parent had read that log through
# its end at window START. The window start, not its close, is therefore the
# honest watermark, and bin/fm-pending-reply-lib.sh consumes it so a missing
# correlated report is judged only against a channel known to have caught up.
WINDOW_CLOSED_EMPTY=75

cmd_source() {
  local id=${1:-} started rc=0
  validate_id "$id"
  read_cursor "$id"
  started=$(fm_pending_reply_now)
  "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-delta-read.sh \
    "$REMOTE_LOG" "$CURSOR_OFFSET" "$CURSOR_HASH" "$WAIT_SECONDS" < /dev/null || rc=$?
  if [ "$rc" -eq "$WINDOW_CLOSED_EMPTY" ]; then
    fm_pending_reply_note_remote_channel_caught_up "$STATE" "$id" "$started" || true
  fi
  return "$rc"
}

safe_doc_path() {
  case "$1" in
    data/*.md) ;;
    *) return 1 ;;
  esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'//'*) return 1 ;; esac
  return 0
}

# Fetch one referenced remote document. Returns 0 on success, 1 when the remote
# reader refused the path or size, DOCUMENT_LOCAL_FAILURE when local storage
# failed, and SSH_UNAVAILABLE when transport completion is unknown.
fetch_document() { # <id> <remote-relative> <result-var>
  local id=$1 rel=$2 result_var=$3 base destination parent parent_real tmp local_rel rc=0
  safe_doc_path "$rel" || return 1
  base="$DATA/remote-secondmates/$id"
  destination="$base/$rel"
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return "$DOCUMENT_LOCAL_FAILURE"
  [ ! -L "$base" ] && [ ! -L "$parent" ] || return "$DOCUMENT_LOCAL_FAILURE"
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return "$DOCUMENT_LOCAL_FAILURE"
  case "$parent_real" in "$base"|"$base"/*) ;; *) return "$DOCUMENT_LOCAL_FAILURE" ;; esac
  [ ! -L "$destination" ] || return "$DOCUMENT_LOCAL_FAILURE"
  tmp=$(umask 077; mktemp "$parent/.remote-doc.XXXXXX") || return "$DOCUMENT_LOCAL_FAILURE"
  "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$rel" "$MAX_DOC_BYTES" < /dev/null > "$tmp" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$tmp"
    [ "$rc" -ne "$SSH_UNAVAILABLE" ] || return "$SSH_UNAVAILABLE"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return "$DOCUMENT_LOCAL_FAILURE"; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; return "$DOCUMENT_LOCAL_FAILURE"; }
  local_rel="data/remote-secondmates/$id/$rel"
  printf -v "$result_var" '%s' "$local_rel"
}

# The one adaptation a machine boundary forces on the mirrored bytes: NUL and
# every other C0 control except tab and newline, plus DEL, become '?'. Printable
# ASCII and every high byte pass through untouched, so ordinary UTF-8 notes
# mirror exactly as a local secondmate would have written them. Newlines remain
# framing rather than payload bytes, and blank separators are not carried into
# the parent status stream.
normalize_payload() { # <source> <destination>
  LC_ALL=C tr '\000-\010\013-\037\177' '?' < "$1" > "$2"
}

# The one place a line enters the parent status stream. A captured generation can
# be replayed, so every append - a mirrored line or an escalation this adapter
# raises itself - is at most once on exact bytes.
# Returns 0 appended, 1 already present, 2 the write itself failed.
append_status_once() { # <status-file> <line>
  grep -Fqx -- "$2" "$1" 2>/dev/null && return 1
  printf '%s\n' "$2" >> "$1" || return 2
  return 0
}

cmd_ingest() {
  local id=${1:-} result=${2:-} seq=${3:-} class blank payload normalized_payload schema status path from to from_hash to_hash payload_hash payload_bytes reason
  local actual_bytes actual_hash line doc local_doc rewritten appended=0 cursor_already=0 lock status_file tmp
  local fetch_rc append_rc undelivered=''
  validate_id "$id"
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file is unavailable or unsafe: $result"
  class=$(classify_result "$result")
  [ "$class" != malformed ] || die "remote reply result is malformed"
  schema=$(result_field "$result" schema) || die "result schema is ambiguous"
  status=$(result_field "$result" status) || die "result status is ambiguous"
  path=$(result_field "$result" path) || die "result path is ambiguous"
  from=$(result_field "$result" from_offset) || die "result start offset is ambiguous"
  to=$(result_field "$result" to_offset) || die "result end offset is ambiguous"
  from_hash=$(result_field "$result" from_prefix_sha256) || die "result start hash is ambiguous"
  to_hash=$(result_field "$result" to_prefix_sha256) || die "result end hash is ambiguous"
  payload_hash=$(result_field "$result" payload_sha256) || die "result payload hash is ambiguous"
  payload_bytes=$(result_field "$result" payload_bytes) || die "result payload size is ambiguous"
  reason=$(result_field "$result" reason) || die "result reason is ambiguous"
  [ "$schema" = fm-remote-delta.v1 ] && [ "$path" = "$REMOTE_LOG" ] || die "result identifies the wrong source"
  case "$from$to$payload_bytes" in *[!0-9]*) die "result carries a nonnumeric size or offset" ;; esac
  for hash in "$from_hash" "$to_hash" "$payload_hash"; do
    case "$hash" in *[!A-Fa-f0-9]*|'') die "result carries an invalid SHA-256 value" ;; esac
    [ "${#hash}" -eq 64 ] || die "result carries an invalid SHA-256 length"
  done
  blank=$(LC_ALL=C awk '$0 == "" { print NR; exit }' "$result")
  case "$blank" in ''|*[!0-9]*) die "result has no payload boundary" ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-reply-ingest.XXXXXX") || die "cannot create ingest staging directory"
  trap 'rm -rf -- "$tmp"' EXIT
  payload="$tmp/payload"
  tail -n "+$((blank + 1))" "$result" > "$payload"
  actual_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  actual_hash=$(sha256_file "$payload")
  [ "$actual_bytes" -eq "$payload_bytes" ] && [ "$actual_hash" = "$payload_hash" ] \
    || die "result payload bytes do not match its committed digest"
  normalized_payload="$tmp/normalized-payload"
  normalize_payload "$payload" "$normalized_payload" || die "cannot normalize remote reply payload"
  status_file="$STATE/$id.status"
  mkdir -p "$STATE" || die "cannot create parent state directory"
  [ ! -L "$status_file" ] || die "parent status log is a symlink"
  lock="$STATE/.remote-reply-ingest-$id.lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock remote reply ingest for $id"
  read_cursor "$id"
  if [ "$CURSOR_OFFSET" -eq "$to" ] && [ "$CURSOR_HASH" = "$to_hash" ]; then
    cursor_already=1
  elif [ "$CURSOR_OFFSET" -ne "$from" ] || [ "$CURSOR_HASH" != "$from_hash" ]; then
    die "result does not continue the current cursor for $id"
  fi
  if [ "$class" = continuity-broken ]; then
    line="blocked [key=remote-reply-continuity-$id]: remote reply continuity broke for $id ($reason)"
    append_rc=0
    append_status_once "$status_file" "$line" || append_rc=$?
    [ "$append_rc" -ne 2 ] || { fm_lock_release "$lock"; die "cannot append continuity escalation"; }
    fm_lock_release "$lock"
    printf 'continuity-broken: %s (%s)\n' "$id" "$reason"
    return 3
  fi
  [ "$status" = delta ] && [ "$payload_bytes" -gt 0 ] || { fm_lock_release "$lock"; die "delta result has no payload"; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    rewritten=$line
    while IFS= read -r doc; do
      [ -n "$doc" ] || continue
      fetch_rc=0
      fetch_document "$id" "$doc" local_doc || fetch_rc=$?
      if [ "$fetch_rc" -eq 1 ]; then
        # The remote reader refused this document and always will. Mirror the
        # mate's line with its own pointer intact rather than inventing a local
        # path or stalling the stream, and name the gap once for this delta.
        undelivered="${undelivered}${undelivered:+, }$doc"
        continue
      fi
      [ "$fetch_rc" -ne "$SSH_UNAVAILABLE" ] \
        || { fm_lock_release "$lock"; die "remote transport was unavailable while fetching $doc"; }
      [ "$fetch_rc" -eq 0 ] \
        || { fm_lock_release "$lock"; die "could not store referenced remote document: $doc"; }
      rewritten=${rewritten//"$doc"/"$local_doc"}
    done < <(printf '%s\n' "$line" | grep -Eo 'data/[A-Za-z0-9._/-]+\.md' | awk '!seen[$0]++')
    append_rc=0
    append_status_once "$status_file" "$rewritten" || append_rc=$?
    [ "$append_rc" -ne 2 ] || { fm_lock_release "$lock"; die "cannot append remote reply"; }
    [ "$append_rc" -ne 0 ] || appended=$((appended + 1))
  done < "$normalized_payload"
  if [ -n "$undelivered" ]; then
    line="blocked [key=remote-reply-document-$id]: remote documents did not transfer for $id ($undelivered)"
    append_rc=0
    append_status_once "$status_file" "$line" || append_rc=$?
    [ "$append_rc" -ne 2 ] || { fm_lock_release "$lock"; die "cannot append document escalation"; }
    [ "$append_rc" -ne 0 ] || appended=$((appended + 1))
  fi
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    fm_pending_reply_try_resolve "$STATE" "$corr" "$status_file" >/dev/null 2>&1 || true
  done < <(grep -Eo 'corr=[A-Fa-f0-9]{16}' "$normalized_payload" | cut -d= -f2- | tr 'A-F' 'a-f' | awk '!seen[$0]++')
  if [ -n "$seq" ]; then
    write_ingest_receipt "$id" "$seq" "$result" \
      || { fm_lock_release "$lock"; die "cannot commit remote reply ingestion receipt"; }
  fi
  if [ "$cursor_already" -eq 0 ]; then
    write_cursor "$id" "$to" "$to_hash" || { fm_lock_release "$lock"; die "cannot commit remote reply cursor"; }
  fi
  fm_lock_release "$lock"
  trap - EXIT
  rm -rf -- "$tmp"
  printf 'ingested: %s appended=%s offset=%s\n' "$id" "$appended" "$to"
}

cmd_handle_locked() {
  local id=${1:-} seq=${2:-} result=${3:-} sid class rc=0 to
  validate_id "$id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  sid=$(source_id "$id")
  class=$(classify_result "$result")
  [ "$class" != malformed ] || die "remote reply result is malformed"
  if ingest_receipt_matches "$id" "$seq" "$result"; then
    to=$(result_field "$result" to_offset) || die "result end offset is ambiguous"
    printf 'ingested: %s appended=0 offset=%s\n' "$id" "$to"
  else
    cmd_ingest "$id" "$result" "$seq" || rc=$?
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
  if [ "$class" = delta ]; then
    cmd_arm_locked "$id" || return 1
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  return "$rc"
}

# The runner's entry into cmd_handle, keyed by canonical source id. An escalated
# continuity break is fully handled too, so its distinct exit 3 is a success
# here; only a genuine handling failure leaves the result for the handler.
cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} id rc=0
  case "$sid" in
    remote-reply-?*) id=${sid#remote-reply-} ;;
    *) die "not a remote reply source: $sid" ;;
  esac
  validate_id "$id"
  [ "$(source_id "$id")" = "$sid" ] || die "source id does not identify one secondmate: $sid"
  cmd_handle "$id" "$seq" "$result" || rc=$?
  [ "$rc" -eq 3 ] && rc=0
  return "$rc"
}

cmd_handle() {
  local id=${1:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_handle_locked "$@"
  )
}

retirement_capture_scan() {
  local id=$1 sid inbox path base seq pending=0
  sid=$(source_id "$id")
  inbox="$STATE/procevent-inbox"
  [ -e "$inbox" ] || return 1
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || die "remote reply inbox is unsafe"
  for path in "$inbox/$sid".*.result "$inbox/$sid".*.adapter "$inbox/$sid".*.handled; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "remote reply capture is unsafe: $path"
  done
  for path in "$inbox/$sid".*.result; do
    [ -e "$path" ] || continue
    base=${path%.result}
    seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) die "remote reply capture has an invalid generation: $path" ;; esac
    [ -f "$base.adapter" ] && [ ! -L "$base.adapter" ] \
      || die "remote reply capture has no safe adapter record: $path"
    [ -e "$base.handled" ] || pending=$((pending + 1))
  done
  RETIREMENT_PENDING=$pending
  RETIREMENT_INBOX=$inbox
  return 0
}

cmd_retire_quiesce_locked() {
  local id=${1:-} force=${2:-} sid
  validate_id "$id"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  sid=$(source_id "$id")
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || return 1
  RETIREMENT_PENDING=0
  retirement_capture_scan "$id" || true
  if [ "$force" != --force ] && [ "$RETIREMENT_PENDING" -gt 0 ]; then
    die "remote reply retirement refused with $RETIREMENT_PENDING unhandled captured result(s)"
  fi
}

cmd_retire_finalize_locked() {
  local id=${1:-} force=${2:-} sid path
  validate_id "$id"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  sid=$(source_id "$id")
  RETIREMENT_PENDING=0
  if retirement_capture_scan "$id"; then
    if [ "$force" != --force ] && [ "$RETIREMENT_PENDING" -gt 0 ]; then
      die "remote reply retirement refused with $RETIREMENT_PENDING unhandled captured result(s)"
    fi
    if [ "$force" = --force ]; then
      for path in "$RETIREMENT_INBOX/$sid".*.result "$RETIREMENT_INBOX/$sid".*.adapter "$RETIREMENT_INBOX/$sid".*.handled; do
        [ -e "$path" ] || continue
        rm -f -- "$path" || die "cannot discard remote reply capture: $path"
      done
    fi
  fi
  rm -f -- "$(cursor_path "$id")"
  rm -f -- "$CURSOR_DIR/$id".*.ingested
  rm -f -- "$(fm_pending_reply_remote_channel_watermark_path "$STATE" "$id")"
}

cmd_retire() {
  local id=${1:-} force=${2:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_retire_quiesce_locked "$id" "$force" || return 1
    cmd_retire_finalize_locked "$id" "$force"
  )
}

require_parent_lifecycle_lock() {
  local id=$1 lock owner pid
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  if [ -L "$lock" ]; then
    owner=$(fm_lock_link_owner "$lock" 2>/dev/null || true)
    [ -n "$owner" ] || die "remote reply lifecycle lock ownership is invalid"
  else
    owner=$lock
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  [ "$pid" = "$PPID" ] || die "remote reply lifecycle lock is not held by the caller"
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$@" ;;
  arm-locked) shift; [ "$#" -eq 1 ] || usage; require_parent_lifecycle_lock "$1"; cmd_arm_locked "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$@" ;;
  handle) shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  ingest) shift; [ "$#" -eq 2 ] || usage; cmd_ingest "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; [ -s "$1" ] ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  retire-quiesce-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_quiesce_locked "$@" ;;
  retire-finalize-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_finalize_locked "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
