#!/usr/bin/env bash
# JSONL-tail adapter for the generic process-to-event runner: wake firstmate
# when a local append-only JSONL (or any line-oriented) file grows.
#
# Usage:
#   fm-procevent-jsonl-tail.sh arm <file>
#   fm-procevent-jsonl-tail.sh wait <file>
#   fm-procevent-jsonl-tail.sh terminal <result-file>
#   fm-procevent-jsonl-tail.sh source-id <file>
#   fm-procevent-jsonl-tail.sh retire <file>
#
# arm       Register the file as a source with bin/fm-procevent.sh; the runner
#           then supervises `wait` as the blocking child. The file does not
#           need to exist yet.
# wait      Block until the file holds complete lines past this source's
#           durable cursor, print exactly those lines, advance the cursor,
#           exit. Poll interval: FM_JSONL_TAIL_POLL_SECONDS (default 30).
# terminal  Always exits 1: a growing file never ends, so the runner keeps
#           the source armed until an explicit retire.
#
# The cursor is a count of complete (newline-terminated) lines, stored under
# $FM_HOME/state/procevent-jsonl-tail/. A partial trailing line a writer is
# mid-appending is never emitted; it is picked up once its newline lands. A
# file that shrinks (replaced or truncated) resets the cursor to zero and is
# re-read from the start.
#
# DELIVERY BOUNDARY, stated plainly. The cursor advances when `wait` prints,
# which is before the runner durably captures that output, so a runner that
# dies inside that narrow window loses those lines from this wake path - they
# stay in the source file itself, but no wake will re-announce them. This
# path is at-most-once per line and must never be described as at-least-once
# or lossless. Use it for signals whose current state survives elsewhere
# (the next change still wakes you), not as the only copy of anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CURSOR_DIR="$FM_HOME/state/procevent-jsonl-tail"
POLL_SECONDS="${FM_JSONL_TAIL_POLL_SECONDS:-30}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

resolve_path() {  # <file> -> absolute path with resolved parent; the file itself may not exist yet
  perl -MCwd=realpath -MFile::Basename -e '
    my $p = $ARGV[0];
    if (my $r = realpath($p)) { print "$r\n"; exit 0 }
    my $dir = realpath(dirname($p)); defined($dir) or exit 1;
    print $dir . "/" . basename($p) . "\n"' "$1" 2>/dev/null
}

path_hash() {  # <text> -> 16 hex chars
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  fi
}

cmd_source_id() {
  local file=${1-} real
  [ -n "$file" ] || usage
  case "$file" in *$'\n'*) die "file paths cannot contain newlines" ;; esac
  real=$(resolve_path "$file") || die "cannot resolve the file path: $file"
  printf 'jsonl-tail-%s\n' "$(path_hash "$real")"
}

cmd_arm() {
  local file=${1-} id real
  [ -n "$file" ] || usage
  id=$(cmd_source_id "$file") || exit 1
  real=$(resolve_path "$file") || die "cannot resolve the file path: $file"
  "$SCRIPT_DIR/fm-procevent.sh" register jsonl-tail "$id" -- \
    "$SCRIPT_DIR/fm-procevent-jsonl-tail.sh" wait "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'file: %s\n' "$real"
}

cmd_retire() {
  local file=${1-} id
  [ -n "$file" ] || usage
  id=$(cmd_source_id "$file") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

read_cursor() {  # <cursor-file>
  local val
  val=$(cat "$1" 2>/dev/null || true)
  case "$val" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$val" ;;
  esac
}

cmd_wait() {
  local file=${1-} real id cursor_file tmp cursor total
  [ -n "$file" ] || usage
  case "$file" in *$'\n'*) die "file paths cannot contain newlines" ;; esac
  real=$(resolve_path "$file") || die "cannot resolve the file path: $file"
  mkdir -p "$CURSOR_DIR" || die "cannot create cursor directory: $CURSOR_DIR"
  id=$(path_hash "$real")
  cursor_file="$CURSOR_DIR/$id.cursor"
  while :; do
    cursor=$(read_cursor "$cursor_file")
    total=0
    [ -f "$real" ] && total=$(wc -l < "$real" | tr -d ' ')
    if [ "$total" -lt "$cursor" ]; then
      cursor=0
    fi
    if [ "$total" -gt "$cursor" ]; then
      sed -n "$((cursor + 1)),${total}p" "$real" || die "cannot read: $real"
      tmp="$cursor_file.tmp"
      printf '%s\n' "$total" > "$tmp" || die "cannot write cursor: $tmp"
      mv "$tmp" "$cursor_file" || die "cannot promote cursor: $cursor_file"
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
}

cmd_terminal() {
  # A growing file has no notion of ending; only an explicit retire stops it.
  local file=${1-}
  [ -n "$file" ] || usage
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  wait)      shift; cmd_wait "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
