#!/usr/bin/env bash
# File-appearance adapter for the generic process-to-event runner: wake
# firstmate when an expected file exists and is newer than what this source has
# already emitted.
#
# Usage:
#   fm-procevent-file.sh arm <name> --path-template <template> [--poll-seconds <n>]
#   fm-procevent-file.sh classify <result-file>
#   fm-procevent-file.sh terminal <result-file>
#   fm-procevent-file.sh source-id <name>
#   fm-procevent-file.sh cursor-path <name>
#   fm-procevent-file.sh retire <name>
#   fm-procevent-file.sh poll <cursor-file> <poll-seconds> <path-template>
#
# arm         Register a recurring source through bin/fm-procevent.sh and let
#             the runner own its child. <name> is the caller's short label; the
#             canonical source id is always "file-<name>".
#             --path-template is an ABSOLUTE path whose only supported
#             placeholder is {date}, expanded to the current LOCAL date as
#             YYYY-MM-DD. Any other brace text is refused at arm time rather
#             than polled forever as a literal path.
#             --poll-seconds bounds the child's sleep between checks
#             (default 300, accepted range 1-86400).
# classify    Print what a captured result means: `appeared` for a well-formed
#             emit line, `unknown` for anything else.
# terminal    Always exits nonzero: this source is recurring and never ends
#             itself. The runner therefore keeps the registration armed and
#             starts the next child on its ordinary reconcile cycle, so one
#             arm serves every later day without re-registration.
# source-id   Print the canonical source id for <name>.
# cursor-path Print this source's durable cursor file.
# retire      Drop the registration through bin/fm-procevent.sh. The cursor is
#             deliberately KEPT, so re-arming does not re-emit a file this
#             source already reported; delete the cursor file to reset it.
# poll        The blocking child `arm` registers. Documented because the runner
#             stores and executes it verbatim, not because it is called by hand.
#
# THE CHILD. It expands {date} on EVERY iteration, so a source armed before
# midnight emits for the new day without being re-armed. It sleeps
# <poll-seconds> between checks and never busy-waits. It exits as soon as it
# emits, because the runner captures a child's output on exit; one emit is one
# captured result and one wake. The single emitted line is:
#
#   file-appear <expanded-path>
#
# THE CURSOR. A private record of the path and whole-second mtime this source
# last emitted. The child emits only when the expanded path is a regular file
# AND (no cursor exists, OR the path differs from the cursor's, OR its mtime is
# strictly greater). Whole-second granularity is the mtime resolution this
# comparison uses, so two writes inside one second read as one file. The cursor
# is advanced at emit, immediately before the line is printed; without that a
# restarted child would re-emit the same file on every reconcile cycle.
# An unreadable or malformed cursor stops the child with no output rather than
# being treated as absent, because treating it as absent would re-emit a file
# this source already reported. That is the runner's ordinary "no usable
# result" path: the registration stays armed and nothing is published.
#
# LOSS LIMITATION, stated plainly. Advancing the cursor at emit means a result
# lost after the child exits and before bin/fm-procevent.sh captures its output
# is not re-emitted for that same file: the appearance is missed rather than
# duplicated. This is the same class of source-side window the Lavish adapter
# documents, and it is not closed here. Never describe this adapter as
# at-least-once, no-loss, or lossless. A LATER write to the same path still
# emits, because its mtime moves past the cursor.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CURSOR_DIR="$STATE/file-appear"
DEFAULT_POLL_SECONDS=300
MAX_POLL_SECONDS=86400

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,64p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# The caller's short label. Held to the same path-safe shape as the canonical id
# it becomes, so no name can reach the registry or the cursor directory as a
# path fragment.
validate_name() {
  local name=${1-}
  fm_task_id_path_safe "$name" || die "name must be path-safe: $name"
  fm_procevent_source_id_valid "file-$name" || die "name is too long once prefixed: $name"
}

cmd_source_id() {
  local name=${1-}
  [ -n "$name" ] || usage
  validate_name "$name"
  printf 'file-%s\n' "$name"
}

cmd_cursor_path() {
  local name=${1-}
  [ -n "$name" ] || usage
  validate_name "$name"
  printf '%s/file-%s.cursor\n' "$CURSOR_DIR" "$name"
}

# An absolute template whose only placeholder is {date}. Refusing every other
# brace text here is what keeps an unsupported placeholder a loud arm-time
# error instead of a source that blocks forever on a literal path.
validate_template() {
  local template=${1-} residue
  [ -n "$template" ] || die "--path-template is required"
  case "$template" in
    /*) ;;
    *) die "--path-template must be an absolute path: $template" ;;
  esac
  case "$template" in *$'\n'*) die "--path-template cannot contain newlines" ;; esac
  residue=${template//'{date}'/}
  case "$residue" in
    *'{'*|*'}'*) die "--path-template supports only the {date} placeholder: $template" ;;
  esac
}

validate_poll_seconds() {
  local seconds=${1-}
  case "$seconds" in
    ''|*[!0-9]*) die "--poll-seconds must be a positive integer: $seconds" ;;
  esac
  [ "$seconds" -ge 1 ] || die "--poll-seconds must be at least 1: $seconds"
  [ "$seconds" -le "$MAX_POLL_SECONDS" ] \
    || die "--poll-seconds must be at most $MAX_POLL_SECONDS: $seconds"
}

expand_template() {  # <template>
  local today
  today=$(date +%Y-%m-%d) || return 1
  case "$today" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${1//'{date}'/$today}"
}

# Whole-second mtime through perl, because stat's flags differ across the
# supported platforms and this adapter must not depend on either spelling.
file_mtime() {  # <path>
  perl -e 'my @s = stat($ARGV[0]) or exit 1; print $s[9], "\n"' "$1" 2>/dev/null
}

cmd_arm() {
  local name=${1-} template='' seconds=$DEFAULT_POLL_SECONDS cursor id
  [ -n "$name" ] || usage
  shift
  validate_name "$name"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path-template)
        [ "$#" -ge 2 ] || die "--path-template needs a value"
        template=$2
        shift 2
        ;;
      --poll-seconds)
        [ "$#" -ge 2 ] || die "--poll-seconds needs a value"
        seconds=$2
        shift 2
        ;;
      *) die "unknown arm option: $1" ;;
    esac
  done
  validate_template "$template"
  validate_poll_seconds "$seconds"
  expand_template "$template" >/dev/null || die "cannot resolve the current local date"
  id=$(cmd_source_id "$name") || exit 1
  cursor=$(cmd_cursor_path "$name") || exit 1
  (umask 077; mkdir -p "$CURSOR_DIR") || die "cannot create the cursor directory"
  [ -d "$CURSOR_DIR" ] && [ ! -L "$CURSOR_DIR" ] || die "cursor directory is unsafe: $CURSOR_DIR"
  [ ! -L "$cursor" ] || die "cursor file is unsafe: $cursor"
  "$SCRIPT_DIR/fm-procevent.sh" register file "$id" -- \
    "$SCRIPT_DIR/fm-procevent-file.sh" poll "$cursor" "$seconds" "$template" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'template: %s\n' "$template"
  printf 'poll-seconds: %s\n' "$seconds"
}

cmd_retire() {
  local name=${1-} id
  [ -n "$name" ] || usage
  id=$(cmd_source_id "$name") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read the cursor into CURSOR_FILE_PATH and CURSOR_FILE_MTIME. An absent cursor
# means nothing has been emitted yet; an unreadable or malformed one is a hard
# error, because silently treating it as absent would re-emit an already
# reported file.
read_cursor() {  # <cursor-file>
  local path=$1 schema
  CURSOR_FILE_PATH=''
  CURSOR_FILE_MTIME=''
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = fm-file-appear-cursor.v1 ] || die "cursor has an incompatible schema: $path"
  CURSOR_FILE_MTIME=$(sed -n 's/^mtime=//p' "$path" | head -1)
  CURSOR_FILE_PATH=$(sed -n 's/^path=//p' "$path" | head -1)
  case "$CURSOR_FILE_MTIME" in ''|*[!0-9]*) die "cursor has an invalid mtime: $path" ;; esac
  [ -n "$CURSOR_FILE_PATH" ] || die "cursor has no recorded path: $path"
}

write_cursor() {  # <cursor-file> <path> <mtime>
  local cursor=$1 path=$2 mtime=$3 dir tmp
  dir=${cursor%/*}
  (umask 077; mkdir -p "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ ! -L "$cursor" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-file-appear-cursor.v1\n'
    printf 'path=%s\n' "$path"
    printf 'mtime=%s\n' "$mtime"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$cursor" || { rm -f -- "$tmp"; return 1; }
}

# True when this exact path and mtime is something the source has not emitted.
newer_than_cursor() {  # <path> <mtime>
  [ -n "$CURSOR_FILE_PATH" ] || return 0
  [ "$1" = "$CURSOR_FILE_PATH" ] || return 0
  [ "$2" -gt "$CURSOR_FILE_MTIME" ]
}

cmd_poll() {
  local cursor=${1-} seconds=${2-} template=${3-} path mtime
  [ -n "$cursor" ] && [ -n "$seconds" ] && [ -n "$template" ] || usage
  case "$cursor" in /*) ;; *) die "cursor file must be an absolute path: $cursor" ;; esac
  validate_poll_seconds "$seconds"
  validate_template "$template"
  while :; do
    path=$(expand_template "$template") || die "cannot resolve the current local date"
    if [ -f "$path" ]; then
      read_cursor "$cursor"
      mtime=$(file_mtime "$path") || mtime=''
      if [ -n "$mtime" ] && newer_than_cursor "$path" "$mtime"; then
        write_cursor "$cursor" "$path" "$mtime" || die "cannot commit the file-appearance cursor"
        printf 'file-appear %s\n' "$path"
        return 0
      fi
    fi
    sleep "$seconds"
  done
}

# What a captured result means. The emit line is this adapter's own bounded
# construction, so anything else - an empty capture, a truncated line, a
# non-absolute path - is `unknown` rather than a guessed appearance.
cmd_classify() {
  local file=${1-} first
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  first=$(head -1 -- "$file" 2>/dev/null || true)
  case "$first" in
    'file-appear /'*) printf 'appeared\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Never terminal. A file-appearance source is recurring by design: today's
# report ending does not end tomorrow's, so the runner must keep the
# registration armed and start the next child itself.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  return 1
}

case "${1-}" in
  arm)         shift; cmd_arm "$@" ;;
  poll)        shift; [ "$#" -eq 3 ] || usage; cmd_poll "$@" ;;
  classify)    shift; [ "$#" -eq 1 ] || usage; cmd_classify "$@" ;;
  terminal)    shift; [ "$#" -eq 1 ] || usage; cmd_terminal "$@" ;;
  source-id)   shift; [ "$#" -eq 1 ] || usage; cmd_source_id "$@" ;;
  cursor-path) shift; [ "$#" -eq 1 ] || usage; cmd_cursor_path "$@" ;;
  retire)      shift; [ "$#" -eq 1 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
