#!/usr/bin/env bash
# Remote-secondmate reply adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-remote-reply.sh arm <secondmate-id>
#   fm-procevent-remote-reply.sh handle <secondmate-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh classify <result-file>
#   fm-procevent-remote-reply.sh terminal <result-file>
#   fm-procevent-remote-reply.sh source-id <secondmate-id>
#   fm-procevent-remote-reply.sh cursor-rebase <secondmate-id> <offset> <prefix-sha256>
#   fm-procevent-remote-reply.sh retire <secondmate-id>
#
# `arm` registers one blocking, non-destructive delta source for the remote
# home's state/parent-replies.status log. The process-event runner owns blocking,
# capture, publication, and one machine-wide source owner. Each captured delta is
# terminal for that exact registration; `handle` validates and idempotently
# ingests it, acknowledges the captured generation, then registers the next
# cursor-anchored source. A continuity break is escalated and not re-armed.
# `autohandle` is the runner's source-id entry into that same handler, so a
# captured reply is applied and acknowledged without relying on a later manual
# dispatch. A continuity escalation is considered fully handled here.
#
# Ingest handles each bounded line independently. Printable UTF-8 status lines
# with an allowed lifecycle verb and strict corr=<16hex> are accepted, while an
# invalid line or a line whose referenced document cannot be fetched is retained
# in a private, provenance-bound quarantine and cannot block surrounding lines.
# Each distinct captured result body that quarantined a line announces that fact
# once on the durable wake queue, before the cursor advances, so a dropped reply
# is never silently invisible; the announcement carries no line bytes and never
# reaches a task status stream.
# Legacy lines without corr= remain accepted only in the byte-zero compatibility
# prefix. Exact accepted lines and quarantine artifacts are each committed at
# most once. A data/*.md pointer is fetched through the path-confined remote file
# reader and rewritten to its local private copy before append.
#
# `cursor-rebase` is the cursor owner's deliberate recovery command. It accepts
# only a bounded complete-line boundary whose supplied prefix hash matches the
# configured remote home's log, refuses while that source is armed, and reports
# both the prior and target cursor. It never accepts a quarantined line as valid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CURSOR_DIR="$STATE/remote-replies"
REMOTE_LOG='state/parent-replies.status'
WAIT_SECONDS=${FM_REMOTE_REPLY_WAIT_SECONDS:-55}
MAX_LINE_BYTES=${FM_REMOTE_REPLY_MAX_LINE_BYTES:-2048}
MAX_DOC_BYTES=${FM_REMOTE_REPLY_MAX_DOC_BYTES:-262144}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Print the whole leading comment header, so help never drifts from the block
# it documents when that block grows.
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
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
quarantine_dir_path() { printf '%s/quarantine/%s\n' "$CURSOR_DIR" "$1"; }

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
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
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

cmd_source() {
  local id=${1:-}
  validate_id "$id"
  read_cursor "$id"
  exec "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-delta-read.sh \
    "$REMOTE_LOG" "$CURSOR_OFFSET" "$CURSOR_HASH" "$WAIT_SECONDS" < /dev/null
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

fetch_document() { # <id> <remote-relative> <result-var>
  local id=$1 rel=$2 result_var=$3 base destination parent parent_real tmp local_rel
  safe_doc_path "$rel" || return 1
  base="$DATA/remote-secondmates/$id"
  destination="$base/$rel"
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return 1
  [ ! -L "$base" ] && [ ! -L "$parent" ] || return 1
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  case "$parent_real" in "$base"|"$base"/*) ;; *) return 1 ;; esac
  [ ! -L "$destination" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.remote-doc.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$rel" "$MAX_DOC_BYTES" < /dev/null > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
  local_rel="data/remote-secondmates/$id/$rel"
  printf -v "$result_var" '%s' "$local_rel"
}

prepare_quarantine_dir() { # <id>; prints the private directory
  local id=$1 root dir
  mkdir -p "$CURSOR_DIR" || return 1
  [ -d "$CURSOR_DIR" ] && [ ! -L "$CURSOR_DIR" ] || return 1
  chmod 700 "$CURSOR_DIR" || return 1
  root="$CURSOR_DIR/quarantine"
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    mkdir "$root" || return 1
  fi
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  chmod 700 "$root" || return 1
  dir=$(quarantine_dir_path "$id")
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir "$dir" || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 700 "$dir" || return 1
  printf '%s\n' "$dir"
}

write_line_quarantine() { # <id> <result> <payload> <line-no> <reason> <detail> <from> <to> <from-hash> <to-hash>
  local id=$1 result=$2 payload=$3 line_no=$4 quarantine_reason=$5 detail=$6
  local from=$7 to=$8 from_hash=$9 to_hash=${10}
  local dir raw line_hash line_bytes result_hash path tmp
  dir=$(prepare_quarantine_dir "$id") || return 1
  raw=$(umask 077; mktemp "$dir/.raw.XXXXXX") || return 1
  FM_QUARANTINE_LINE_NUMBER=$line_no perl -ne '
    print if $. == $ENV{FM_QUARANTINE_LINE_NUMBER};
  ' "$payload" > "$raw" || { rm -f -- "$raw"; return 1; }
  line_bytes=$(LC_ALL=C wc -c < "$raw" | tr -d ' ')
  [ "$line_bytes" -gt 0 ] || { rm -f -- "$raw"; return 1; }
  line_hash=$(sha256_file "$raw") || { rm -f -- "$raw"; return 1; }
  result_hash=$(sha256_file "$result") || { rm -f -- "$raw"; return 1; }
  path="$dir/$from.$line_no.$line_hash.$result_hash.quarantine"
  tmp=$(umask 077; mktemp "$dir/.quarantine.XXXXXX") \
    || { rm -f -- "$raw"; return 1; }
  {
    printf 'schema=fm-remote-reply-quarantine.v1\n'
    printf 'reason=%s\n' "$quarantine_reason"
    [ -z "$detail" ] || printf 'detail=%s\n' "$detail"
    printf 'secondmate_id=%s\n' "$id"
    printf 'source_path=%s\n' "$REMOTE_LOG"
    printf 'from_offset=%s\n' "$from"
    printf 'to_offset=%s\n' "$to"
    printf 'from_prefix_sha256=%s\n' "$from_hash"
    printf 'to_prefix_sha256=%s\n' "$to_hash"
    printf 'result_sha256=%s\n' "$result_hash"
    printf 'line_number=%s\n' "$line_no"
    printf 'line_bytes=%s\n' "$line_bytes"
    printf 'line_sha256=%s\n\n' "$line_hash"
    cat "$raw"
  } > "$tmp" || { rm -f -- "$raw" "$tmp"; return 1; }
  rm -f -- "$raw"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ ! -f "$path" ] || [ -L "$path" ] || ! cmp -s "$tmp" "$path"; then
      rm -f -- "$tmp"
      return 1
    fi
    rm -f -- "$tmp"
    return 0
  fi
  mv -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
}

quarantine_notice_receipt_path() { # <id> <result-hash>
  printf '%s/%s.notice\n' "$(quarantine_dir_path "$1")" "$2"
}

write_quarantine_notice_receipt() { # <path> <state> <count> <reasons>
  local path=$1 notice_state=$2 count=$3 reasons=$4 tmp dir
  dir=$(dirname "$path")
  tmp=$(umask 077; mktemp "$dir/.notice.XXXXXX") || return 1
  {
    printf 'schema=fm-remote-reply-quarantine-notice.v1\n'
    printf 'state=%s\n' "$notice_state"
    printf 'lines=%s\n' "$count"
    printf 'reasons=%s\n' "$reasons"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
}

# Announce this generation's quarantined lines to the durable wake queue exactly
# once. The quarantine artifacts stay the authority and the only place the bytes
# live; this is the bounded event line that keeps a dropped reply from being
# silently invisible, which is the same failure the ingest isolation exists to
# prevent. It never touches a task status stream.
#
# Durability: the receipt is claimed before the announcement and confirmed after
# it, so a replay after a crash between the two resolves the unproven claim
# against the queue itself rather than announcing a second time.
notify_quarantine_once() { # <id> <result-hash> <count> <reasons>
  local id=$1 result_hash=$2 count=$3 reasons=$4 dir receipt key payload notice_state queued status=0
  dir=$(prepare_quarantine_dir "$id") || return 1
  receipt=$(quarantine_notice_receipt_path "$id" "$result_hash")
  key="remote-reply-quarantine:$id:$result_hash"
  payload="check: remote secondmate $id sent $count reply line(s) that could not be correlated ($reasons); the valid lines were applied and the invalid ones are kept privately under state/remote-replies/quarantine/$id"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    if ! [ -f "$receipt" ] || [ -L "$receipt" ]; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    fi
    notice_state=$(sed -n 's/^state=//p' "$receipt")
    if [ "$notice_state" = notified ]; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
    fi
    queued=$(fm_wake_queued_keys_locked check 2>/dev/null || true)
    if printf '%s\n' "$queued" | grep -Fqx -- "$key"; then
      write_quarantine_notice_receipt "$receipt" notified "$count" "$reasons" || status=$?
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return "$status"
    fi
  else
    write_quarantine_notice_receipt "$receipt" claimed "$count" "$reasons" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    fm_wake_append_locked check "$key" "$payload" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    write_quarantine_notice_receipt "$receipt" notified "$count" "$reasons" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

line_bytes_bounded_printable() { # <line>
  local line=$1 bytes
  [ -n "$line" ] || return 1
  bytes=$(printf '%s' "$line" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le "$MAX_LINE_BYTES" ] || return 1
  printf '%s' "$line" | perl -0777 -ne '
    use Encode qw(decode FB_CROAK);
    my $decoded;
    eval { $decoded = decode("UTF-8", $_, Encode::FB_CROAK); 1 } or exit 1;
    exit 1 if $decoded =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F]/;
    exit 0;
  ' || return 1
}

payload_line_bounded_printable() { # <payload> <line-number>
  FM_REMOTE_REPLY_LINE_NUMBER=$2 FM_REMOTE_REPLY_MAX_LINE_BYTES=$MAX_LINE_BYTES \
    perl -MEncode=decode,FB_CROAK -ne '
      next unless $. == $ENV{FM_REMOTE_REPLY_LINE_NUMBER};
      s/\n\z//;
      exit 1 if length($_) == 0 || length($_) > $ENV{FM_REMOTE_REPLY_MAX_LINE_BYTES};
      my $decoded;
      eval { $decoded = decode("UTF-8", $_, Encode::FB_CROAK); 1 } or exit 1;
      exit 1 if $decoded =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F]/;
      exit 0;
    ' "$1"
}

line_status_valid() { # <line>
  local line=$1
  line_bytes_bounded_printable "$line" || return 1
  printf '%s' "$line" | grep -Eq '^(working|needs-decision|blocked|paused|done|failed|resolved)([[:space:]]+\[[^]]+\])*:' || return 1
}

validate_sha256() { # <value>
  case "$1" in *[!A-Fa-f0-9]*|'') return 1 ;; esac
  [ "${#1}" -eq 64 ] || return 1
}

remote_log_prefix_hash() { # <id> <offset>; return 2 when offset splits a line
  local id=$1 offset=$2 tmp size prefix_hash boundary_byte
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  [ "$offset" -le "$MAX_DOC_BYTES" ] || return 1
  if [ "$offset" -eq 0 ]; then
    empty_hash
    return
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-remote-reply-prefix.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$REMOTE_LOG" "$MAX_DOC_BYTES" < /dev/null > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  size=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
  if [ "$size" -lt "$offset" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  boundary_byte=$(head -c "$offset" "$tmp" | tail -c 1 | LC_ALL=C od -An -tu1 | tr -d ' ')
  if [ "$boundary_byte" != 10 ]; then
    rm -f -- "$tmp"
    return 2
  fi
  prefix_hash=$(head -c "$offset" "$tmp" | sha256_stdin)
  rm -f -- "$tmp"
  [ -n "$prefix_hash" ] || return 1
  printf '%s\n' "$prefix_hash"
}

line_has_valid_corr() { # <line>
  local corr_count
  printf '%s' "$1" \
    | grep -Eq '^(working|needs-decision|blocked|paused|done|failed|resolved)([[:space:]]+\[[^]]+\])*[[:space:]]+\[corr=[A-Fa-f0-9]{16}\]([[:space:]]+\[[^]]+\])*:' \
    || return 1
  corr_count=$(printf '%s' "$1" | grep -Eo 'corr=' | wc -l | tr -d ' ')
  [ "$corr_count" -eq 1 ]
}

line_has_corr_token() { # <line>
  printf '%s' "$1" | grep -Eq 'corr='
}

cmd_ingest() {
  local id=${1:-} result=${2:-} seq=${3:-} class blank payload schema status path from to from_hash to_hash payload_hash payload_bytes reason
  local actual_bytes actual_hash line doc local_doc rewritten appended=0 quarantined=0 cursor_already=0 lock status_file tmp legacy_prefix=1
  local line_number=0 quarantine_reason quarantine_detail doc_failed accepted_corrs
  local result_hash quarantine_reasons quarantine_reason_list
  validate_id "$id"
  remote_route_exists "$id"
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
  blank=$(grep -n -m 1 '^$' "$result" | cut -d: -f1)
  case "$blank" in ''|*[!0-9]*) die "result has no payload boundary" ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-reply-ingest.XXXXXX") || die "cannot create ingest staging directory"
  trap 'rm -rf -- "$tmp"' EXIT
  payload="$tmp/payload"
  tail -n "+$((blank + 1))" "$result" > "$payload"
  actual_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  actual_hash=$(sha256_file "$payload")
  [ "$actual_bytes" -eq "$payload_bytes" ] && [ "$actual_hash" = "$payload_hash" ] \
    || die "result payload bytes do not match its committed digest"
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
    if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
      printf '%s\n' "$line" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append continuity escalation"; }
    fi
    fm_lock_release "$lock"
    printf 'continuity-broken: %s (%s)\n' "$id" "$reason"
    return 3
  fi
  [ "$status" = delta ] && [ "$payload_bytes" -gt 0 ] || { fm_lock_release "$lock"; die "delta result has no payload"; }
  accepted_corrs="$tmp/accepted-corrs"
  : > "$accepted_corrs"
  quarantine_reasons="$tmp/quarantine-reasons"
  : > "$quarantine_reasons"
  result_hash=$(sha256_file "$result") || { fm_lock_release "$lock"; die "cannot hash remote reply result"; }
  # shellcheck disable=SC2094 # Helpers read this payload but write only separate private artifacts.
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    quarantine_reason=
    quarantine_detail=
    if ! payload_line_bounded_printable "$payload" "$line_number" \
      || ! line_status_valid "$line"; then
      quarantine_reason=invalid-status
    elif ! line_has_valid_corr "$line"; then
      if [ "$from" -eq 0 ] && [ "$legacy_prefix" -eq 1 ] && ! line_has_corr_token "$line"; then
        if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
          printf '%s\n' "$line" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append legacy remote reply"; }
          appended=$((appended + 1))
        fi
        continue
      fi
      if line_has_corr_token "$line"; then
        quarantine_reason=invalid-correlation
      else
        quarantine_reason=missing-correlation
      fi
    fi
    if [ -n "$quarantine_reason" ]; then
      write_line_quarantine "$id" "$result" "$payload" "$line_number" \
        "$quarantine_reason" "$quarantine_detail" "$from" "$to" "$from_hash" "$to_hash" \
        || { fm_lock_release "$lock"; die "cannot preserve invalid remote reply line"; }
      printf '%s\n' "$quarantine_reason" >> "$quarantine_reasons"
      quarantined=$((quarantined + 1))
      legacy_prefix=0
      continue
    fi
    legacy_prefix=0
    rewritten=$line
    doc_failed=0
    while IFS= read -r doc; do
      [ -n "$doc" ] || continue
      if ! fetch_document "$id" "$doc" local_doc; then
        doc_failed=1
        quarantine_detail=$doc
        break
      fi
      rewritten=${rewritten//"$doc"/"$local_doc"}
    done < <(printf '%s\n' "$line" | grep -Eo 'data/[A-Za-z0-9._/-]+\.md' | awk '!seen[$0]++')
    if [ "$doc_failed" -eq 1 ]; then
      write_line_quarantine "$id" "$result" "$payload" "$line_number" \
        referenced-document-unfetchable "$quarantine_detail" "$from" "$to" "$from_hash" "$to_hash" \
        || { fm_lock_release "$lock"; die "cannot preserve remote reply line with an unavailable document"; }
      printf 'referenced-document-unfetchable\n' >> "$quarantine_reasons"
      quarantined=$((quarantined + 1))
      continue
    fi
    if ! grep -Fqx -- "$rewritten" "$status_file" 2>/dev/null; then
      printf '%s\n' "$rewritten" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append remote reply"; }
      appended=$((appended + 1))
    fi
    printf '%s\n' "$line" | grep -Eo '\[corr=[A-Fa-f0-9]{16}\]' \
      | sed 's/^\[corr=//;s/\]$//' | tr 'A-F' 'a-f' >> "$accepted_corrs"
  done < "$payload"
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    fm_pending_reply_try_resolve "$STATE" "$corr" "$status_file" >/dev/null 2>&1 || true
  done < <(awk '!seen[$0]++' "$accepted_corrs")
  if [ "$quarantined" -gt 0 ]; then
    quarantine_reason_list=$(sort -u "$quarantine_reasons" | tr '\n' ',' | sed 's/,$//')
    notify_quarantine_once "$id" "$result_hash" "$quarantined" "$quarantine_reason_list" \
      || { fm_lock_release "$lock"; die "cannot surface quarantined remote reply lines"; }
  fi
  if [ "$cursor_already" -eq 0 ]; then
    write_cursor "$id" "$to" "$to_hash" || { fm_lock_release "$lock"; die "cannot commit remote reply cursor"; }
  fi
  if [ -n "$seq" ]; then
    write_ingest_receipt "$id" "$seq" "$result" \
      || { fm_lock_release "$lock"; die "cannot commit remote reply ingestion receipt"; }
  fi
  fm_lock_release "$lock"
  trap - EXIT
  rm -rf -- "$tmp"
  printf 'ingested: %s appended=%s quarantined=%s offset=%s\n' "$id" "$appended" "$quarantined" "$to"
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

cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} id rc=0
  case "$sid" in
    remote-reply-?*) id=${sid#remote-reply-} ;;
    *) die "not a remote reply source: $sid" ;;
  esac
  validate_id "$id"
  [ "$(source_id "$id")" = "$sid" ] \
    || die "source id does not identify one secondmate: $sid"
  cmd_handle "$id" "$seq" "$result" || rc=$?
  [ "$rc" -eq 3 ] && rc=0
  return "$rc"
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

cmd_cursor_rebase_locked() {
  local id=${1:-} offset=${2:-} hash=${3:-} actual actual_rc lock sid source current_offset current_hash
  validate_id "$id"
  remote_route_exists "$id"
  case "$offset" in ''|*[!0-9]*) die "cursor rebase offset must be a nonnegative integer" ;; esac
  validate_sha256 "$hash" || die "cursor rebase prefix hash must be a 64-character SHA-256 value"
  hash=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
  sid=$(source_id "$id")
  source="$STATE/procevent/$sid.source"
  if [ -e "$source" ] || [ -L "$source" ]; then
    die "cursor rebase target is ambiguous while the remote reply source is armed"
  fi
  actual=$(remote_log_prefix_hash "$id" "$offset")
  actual_rc=$?
  [ "$actual_rc" -ne 2 ] || die "cursor rebase target is not a complete-line boundary"
  [ "$actual_rc" -eq 0 ] || die "remote reply log prefix could not be validated for $id"
  [ "$actual" = "$hash" ] || die "cursor rebase prefix hash does not match the remote reply log"
  lock="$STATE/.remote-reply-ingest-$id.lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock remote reply ingest for $id"
  read_cursor "$id"
  current_offset=$CURSOR_OFFSET
  current_hash=$CURSOR_HASH
  write_cursor "$id" "$offset" "$hash" || { fm_lock_release "$lock"; die "cannot commit remote reply cursor"; }
  fm_lock_release "$lock"
  printf 'cursor-rebased: %s from_offset=%s from_prefix_sha256=%s to_offset=%s to_prefix_sha256=%s\n' \
    "$id" "$current_offset" "$current_hash" "$offset" "$hash"
}

cmd_cursor_rebase() {
  local id=${1:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_cursor_rebase_locked "$@"
  )
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
  cursor-rebase|rebase) shift; [ "$#" -eq 3 ] || usage; cmd_cursor_rebase "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; [ -s "$1" ] ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  retire-quiesce-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_quiesce_locked "$@" ;;
  retire-finalize-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_finalize_locked "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
