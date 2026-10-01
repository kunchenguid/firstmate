#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Safe note rewrite (wrapper-owned commands; they never reach tasks-axi as-is):
#   fm-tasks-axi.sh note-show <id>
#       Print the item's current note exactly, or exit non-zero with nothing on
#       stdout when the read fails. tasks-axi has no JSON reader - `--json` is a
#       mutation flag, and a bare `tasks-axi show <id> --full --json` prints a
#       TOON error on stdout and exits 2 - so this is the supported way to read
#       a note in a script.
#   fm-tasks-axi.sh note-rewrite <id> --body-file <new> --expect-body-file <seen>
#       Replace the note with <new>, archiving the previous one (tasks-axi
#       --archive-body). <seen> is the note the caller read with note-show and
#       composed <new> from; the rewrite refuses (exit 1, nothing written) when
#       the current note cannot be read or differs from <seen>, so a script that
#       ignored a failed read and composed on top of an empty note cannot erase
#       the real one. It also refuses an empty or whitespace-only <new>, an
#       unreadable file, and a tasks-axi without --archive-body (exit 2), and it
#       reads the note back after writing and fails if it does not match <new>.
#       Trailing newlines are ignored in both comparisons.
#   Typical use:
#       fm-tasks-axi.sh note-show "$id" > seen.md || exit 1
#       { cat seen.md; printf '\nNew line\n'; } > new.md
#       fm-tasks-axi.sh note-rewrite "$id" --body-file new.md --expect-body-file seen.md
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - `show` (or its `view` alias) with --json, which tasks-axi rejects with a
#     TOON error a JSON parser then misreads as an empty note; use note-show;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --json)
      case "${1:-}" in
        show|view)
          fail "tasks-axi show has no --json (it is a mutation flag); read a note with note-show <id>, or parse the TOON from show <id> --full"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"

# Read one item's note into NOTE_BODY (trailing newlines dropped); on failure
# print the reason on stderr and return 1, leaving NOTE_BODY empty.
NOTE_BODY=
read_note() {  # <id>
  local id=$1 data out status
  NOTE_BODY=
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-tasks-axi: data directory cannot be resolved: %s\n' "$DATA" >&2
    return 1
  }
  out=$(fm_backlog_row_show "$data" "$id" --full 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'fm-tasks-axi: cannot read the note of %s: %s\n' "$id" "${out%%$'\n'*}" >&2
    return 1
  fi
  NOTE_BODY=$(fm_backlog_show_body "$out") || {
    NOTE_BODY=
    printf 'fm-tasks-axi: cannot decode the note of %s from tasks-axi show\n' "$id" >&2
    return 1
  }
}

note_show() {  # <id>
  [ "$#" -eq 1 ] && [ -n "$1" ] || fail "usage: fm-tasks-axi.sh note-show <id>"
  read_note "$1" || exit 1
  [ -z "$NOTE_BODY" ] || printf '%s\n' "$NOTE_BODY"
}

note_rewrite() {  # <id> --body-file <new> --expect-body-file <seen>
  local id='' new_file='' seen_file='' new seen
  local usage="usage: fm-tasks-axi.sh note-rewrite <id> --body-file <new> --expect-body-file <seen>"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) [ "$#" -ge 2 ] || fail "$usage"; new_file=$2; shift 2 ;;
      --body-file=*) new_file=${1#*=}; shift ;;
      --expect-body-file) [ "$#" -ge 2 ] || fail "$usage"; seen_file=$2; shift 2 ;;
      --expect-body-file=*) seen_file=${1#*=}; shift ;;
      -*) fail "note-rewrite does not take $1; $usage" ;;
      *) [ -z "$id" ] || fail "$usage"; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$new_file" ] && [ -n "$seen_file" ] || fail "$usage"
  [ -f "$new_file" ] && [ -r "$new_file" ] || fail "cannot read the new note at $new_file"
  [ -f "$seen_file" ] && [ -r "$seen_file" ] || fail "cannot read the expected current note at $seen_file"
  new=$(cat -- "$new_file") || fail "cannot read the new note at $new_file"
  seen=$(cat -- "$seen_file") || fail "cannot read the expected current note at $seen_file"
  case "$new" in
    *[![:space:]]*) ;;
    *) fail "the new note for $id is empty; refusing to replace the note with nothing" ;;
  esac
  fm_tasks_axi_update_has_archive_body \
    || fail "this tasks-axi has no update --archive-body; refusing an unrecoverable note rewrite"
  read_note "$id" || {
    printf 'fm-tasks-axi: refusing to rewrite the note of %s without a confirmed read of it\n' "$id" >&2
    exit 1
  }
  if [ "$NOTE_BODY" != "$seen" ]; then
    printf 'fm-tasks-axi: the note of %s is not the one in %s (it changed, or that read failed); refusing to rewrite it - read it again with note-show and recompose\n' \
      "$id" "$seen_file" >&2
    exit 1
  fi
  tasks-axi update "$id" --body-file "$new_file" --archive-body >/dev/null || exit $?
  read_note "$id" || {
    printf 'fm-tasks-axi: wrote the note of %s but cannot read it back; the previous note is in the archive\n' "$id" >&2
    exit 1
  }
  if [ "$NOTE_BODY" != "$new" ]; then
    printf 'fm-tasks-axi: the note of %s reads back differently from %s; the previous note is in the archive\n' \
      "$id" "$new_file" >&2
    exit 1
  fi
  printf 'ok: rewrote the note of %s; the previous note is archived\n' "$id"
}

case "${ARGS[0]:-}" in
  note-show) note_show "${ARGS[@]:1}"; exit 0 ;;
  note-rewrite) note_rewrite "${ARGS[@]:1}"; exit 0 ;;
esac

exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
