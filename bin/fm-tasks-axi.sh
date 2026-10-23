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
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
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
#   - `rm`/`delete`, `done`/`close`, or `update`/`edit --title` dropping `[captain-ask]`,
#     unless `bin/fm-captain-hold.sh answered <id>` finds an answer or a merged `pr:` link.
#     A raw `hold` is always refused. Done auto-prune, `prune`, and record-delivery/waive
#     refuse only an unanswered ask an archive would move past keep (`--no-prune` skips
#     the done prune).
#   - `add` (or `create`) that the optional task-priority add-on check refuses,
#     e.g. no `--priority 0-3`; its message and exit status are returned and
#     nothing runs. The check is ${XDG_DATA_HOME:-~/.local/share}/fm-task-priority/check.sh
#     (FM_TASK_PRIORITY_CHECK overrides the path); when it is not installed this
#     does nothing.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

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

tasks_axi() { tasks-axi "$@"; }
# shellcheck source=bin/fm-captain-ask-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-captain-ask-lib.sh"
captain_guard() {  # <tasks-axi args>
  local prune_state="done" no_prune=0 keep_arg='' keep_next=0 sub=''
  local verb id='' value=0 title_next=0 state_next=0 has_title=0 new_title='' arg
  [ "${1:-}" = task ] && shift
  verb=${1:-}
  [ "$#" -gt 0 ] && shift
  if [ "$verb" = public-followup ]; then sub=${1:-}; [ "$#" -gt 0 ] && shift; fi
  for arg in "$@"; do
    if [ "$arg" = --json ]; then continue; fi
    if [ "$value" = 1 ]; then value=0; continue; fi
    if [ "$title_next" = 1 ]; then title_next=0; new_title=$arg; continue; fi
    if [ "$state_next" = 1 ]; then state_next=0; prune_state=$arg; continue; fi
    if [ "$keep_next" = 1 ]; then keep_next=0; keep_arg=$arg; continue; fi
    case "$arg" in
      --no-prune) no_prune=1 ;;
      --keep) keep_next=1 ;;
      --keep=*) keep_arg=${arg#--keep=} ;;
      --state) state_next=1 ;;
      --state=*) prune_state=${arg#--state=} ;;
      --title) title_next=1; has_title=1 ;;
      --title=*) has_title=1; new_title=${arg#--title=} ;;
      --pr|--report|--note|--reason|--until|--kind|--repo|--priority|--body|--body-file) value=1 ;;
      -*) ;;
      *) id=${id:-$arg} ;;
    esac
  done
  case "$verb" in
    prune) guard_captain_ask_archive "$prune_state" "$keep_arg" "" ;;
    done|close)
      guard_captain_ask "$id"
      [ "$no_prune" = 1 ] || guard_captain_ask_archive "done" "$keep_arg" "$id"
      ;;
    public-followup)
      case "$sub" in
        record-delivery|waive) guard_captain_ask_archive "done" "" "$id" ;;
      esac
      ;;
    rm|delete) guard_captain_ask "$id" ;;
    hold) guard_captain_ask_hold "$id" ;;
    update|edit)
      if [ "$has_title" = 1 ]; then
        case "$new_title" in
          *'[captain-ask]'*) ;;
          *) guard_captain_ask "$id" ;;
        esac
      fi
      ;;
  esac
}
# Optional task-priority add-on: a new task must carry a priority. No-op when not installed.
case "${1:-}" in
  add|create)
    PRIORITY_CHECK="${FM_TASK_PRIORITY_CHECK:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/fm-task-priority/check.sh}"
    if [ -x "$PRIORITY_CHECK" ]; then
      "$PRIORITY_CHECK" ${ARGS[@]+"${ARGS[@]}"} >/dev/null || exit $?
    fi
    ;;
esac
captain_guard ${ARGS[@]+"${ARGS[@]}"}
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
