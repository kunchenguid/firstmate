#!/usr/bin/env bash
# fm-owned.sh - the single owner of what a task actually holds: the process
# ids, ports, container names, and filesystem paths a task itself created and
# is therefore entitled to touch or kill later. AGENTS.md HR3' names this file
# by path ("kill targets outside registered ownership are refused by
# bin/fm-kill-pretool-check.sh (state/<task>.owned via bin/fm-owned.sh)"), so
# this registry is the read side of that rule: every guard that needs to tell
# "self-created, registered" apart from "somebody else's" reads it instead of
# guessing from a process name or a port scan.
#
# Usage:
#   fm-owned.sh add <task> <kind> <value>     register one owned identifier
#   fm-owned.sh remove <task> <kind> <value>  drop one owned identifier
#   fm-owned.sh list <task>                   print one task's owned lines
#   fm-owned.sh list-all                      print every task's owned lines,
#                                              each prefixed with its task name
#   fm-owned.sh pid-erlaubt <pid>             exit 0 iff <pid> is itself
#                                              registered as kind=pid in any
#                                              owned file, OR is a descendant
#                                              (child, grandchild, ...) of a
#                                              registered pid; exit 1 otherwise
#   fm-owned.sh --help
#
# kinds: pid | port | container | pfad. pid and port values must be numeric;
# an unknown kind or a non-numeric pid/port is refused loudly (L33) - nothing
# is ever silently accepted as the "closest" kind.
#
# File contract (this header is the single owner):
#   $FM_HOME/state/<task>.owned - one line per identifier:
#     "<kind> <value> <ISO-8601 UTC timestamp>"
#   <value> may itself contain spaces (a filesystem path, kind=pfad); a line
#   is parsed as kind=field 1, value=fields 2..N-1 joined by a single space,
#   ts=the last field, so the timestamp format must stay a single token
#   (date -u +%Y-%m-%dT%H:%M:%SZ). add appends; remove rewrites the file via a
#   temp file + mv. Both run under a per-task flock at
#   $FM_HOME/state/.<task>.owned.lock when flock is available, so two
#   concurrent add/remove calls for the same task cannot interleave; that lock
#   file is internal bookkeeping, not part of the read contract above.
#
# WHY. Broad pattern commands (`pkill -f`, filter deletes) act on whatever
# matches a pattern instead of on what the actor itself created - a training
# run got killed by a neighbour's `pkill -f python3 -`, eleven of the
# captain's logged-in browser tabs closed under a filter meant for one
# (forensics lesson L86, data/forensik-2026-08/lehren-ledger.md). AGENTS.md
# HR3' ("Destruction is mechanically secured, not forbidden") carries that
# lesson forward as the live rule: a task registers here what it started, and
# bin/fm-kill-pretool-check.sh consults this registry before letting a
# `kill <pid>` through - a task can end its own processes but never a
# stranger's by guesswork.
#
# pid-erlaubt walks the process tree from <pid> up through /proc/<pid>/stat's
# ppid field toward pid 0 or a registered pid, whichever comes first (bounded
# to 4096 hops against a corrupt /proc cycling back on itself). When /proc is
# unreadable for a hop it falls back to enumerating descendants of each
# registered pid with `pgrep -P`, breadth-first, same hop bound. Either way, a
# task's own child processes stay killable without each one having to
# self-register - the registration is the task's top-level pid, not every pid
# it ever forks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

validate_task() { # <task>
  local t="$1"
  [ -n "$t" ] || die "task must not be empty"
  case "$t" in
    */*) die "task must not contain '/': $t" ;;
    .|..) die "task must not be '.' or '..': $t" ;;
    *[[:space:]]*) die "task must not contain whitespace: $t" ;;
  esac
}

validate_kind() { # <kind>
  case "$1" in
    pid|port|container|pfad) return 0 ;;
    "") die "kind must not be empty" ;;
    *) die "unknown kind (must be pid|port|container|pfad): $1" ;;
  esac
}

validate_value() { # <kind> <value>
  local kind="$1" value="$2"
  [ -n "$value" ] || die "value must not be empty"
  case "$kind" in
    pid|port)
      [[ "$value" =~ ^[0-9]+$ ]] || die "$kind value must be numeric: $value"
      ;;
  esac
}

# Run "$@" under a per-task flock; without flock, run unlocked (best effort -
# single-writer callers such as tests still get a correct result).
fm_owned_with_lock() { # <task> <cmd...>
  local task="$1"
  shift
  mkdir -p "$STATE" || return 1
  local lockfile="$STATE/.${task}.owned.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 10 9 || exit 1
      "$@"
    ) 9>"$lockfile"
  else
    "$@"
  fi
}

append_line() { # <line> <file>
  printf '%s\n' "$1" >> "$2"
}

remove_line() { # <kind> <value> <file>
  local kind="$1" value="$2" file="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  awk -v k="$kind" -v v="$value" '
    {
      n = NF
      val = ""
      for (i = 2; i < n; i++) { val = (val == "" ? $i : val " " $i) }
      if ($1 == k && val == v) next
      print
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

cmd_add() { # <task> <kind> <value>
  local task="$1" kind="$2" value="$3"
  validate_task "$task"
  validate_kind "$kind"
  validate_value "$kind" "$value"
  local file="$STATE/$task.owned"
  local line
  line="$kind $value $(utc_now)"
  fm_owned_with_lock "$task" append_line "$line" "$file"
}

cmd_remove() { # <task> <kind> <value>
  local task="$1" kind="$2" value="$3"
  validate_task "$task"
  validate_kind "$kind"
  [ -n "$value" ] || die "value must not be empty"
  local file="$STATE/$task.owned"
  [ -f "$file" ] || return 0
  fm_owned_with_lock "$task" remove_line "$kind" "$value" "$file"
}

cmd_list() { # <task>
  local task="$1"
  validate_task "$task"
  local file="$STATE/$task.owned"
  [ -f "$file" ] || return 0
  cat "$file"
}

cmd_list_all() {
  [ -d "$STATE" ] || return 0
  local f task line
  for f in "$STATE"/*.owned; do
    [ -e "$f" ] || continue
    task="$(basename "$f" .owned)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s %s\n' "$task" "$line"
    done < "$f"
  done
}

# owned_pgrep_descendant <target-pid> <root-pid> - breadth-first fallback used
# only when /proc is unreadable: is <target-pid> anywhere in <root-pid>'s
# descendant tree?
owned_pgrep_descendant() {
  command -v pgrep >/dev/null 2>&1 || return 1
  local target="$1" frontier="$2" next child depth=0
  while [ -n "$frontier" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 4096 ] || return 1
    for child in $frontier; do
      [ "$child" = "$target" ] && return 0
    done
    next=""
    for child in $frontier; do
      next="$next $(pgrep -P "$child" 2>/dev/null || true)"
    done
    frontier="$(printf '%s' "$next" | tr -s '[:space:]' ' ')"
    frontier="${frontier# }"
    frontier="${frontier% }"
  done
  return 1
}

# owned_pid_is_ancestor_of <pid> <ancestor> - is <ancestor> somewhere on
# <pid>'s parent chain (including <pid> itself)?
owned_pid_is_ancestor_of() {
  local pid="$1" ancestor="$2" cur="$1" hops=0
  local stat rest ppid
  while [ -n "$cur" ] && [ "$cur" != "0" ]; do
    [ "$cur" = "$ancestor" ] && return 0
    hops=$((hops + 1))
    [ "$hops" -le 4096 ] || return 1
    if [ -r "/proc/$cur/stat" ]; then
      stat="$(cat "/proc/$cur/stat" 2>/dev/null)" || return 1
      # Fields after the last ")" (comm may itself contain spaces/parens):
      # state ppid pgrp ... - so field 2 of the remainder is ppid.
      rest="${stat##*) }"
      ppid="$(printf '%s\n' "$rest" | awk '{print $2}')"
      [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
      cur="$ppid"
    else
      owned_pgrep_descendant "$pid" "$ancestor"
      return $?
    fi
  done
  return 1
}

cmd_pid_erlaubt() { # <pid>
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -d "$STATE" ] || return 1
  local f kind value ts
  for f in "$STATE"/*.owned; do
    [ -e "$f" ] || continue
    # Default IFS on purpose here (not "IFS= read"): this splits the line
    # into its whitespace-delimited fields instead of reading it whole.
    # shellcheck disable=SC2034 # ts completes the 3-field read; only kind/value matter here.
    while read -r kind value ts; do
      [ "$kind" = "pid" ] || continue
      [ -n "$value" ] || continue
      if [ "$value" = "$pid" ]; then return 0; fi
      if owned_pid_is_ancestor_of "$pid" "$value"; then return 0; fi
    done < "$f"
  done
  return 1
}

cmd="${1:-}"
case "$cmd" in
  add)
    shift
    [ "$#" -eq 3 ] || die "add requires: <task> <kind> <value>"
    cmd_add "$1" "$2" "$3"
    ;;
  remove)
    shift
    [ "$#" -eq 3 ] || die "remove requires: <task> <kind> <value>"
    cmd_remove "$1" "$2" "$3"
    ;;
  list)
    shift
    [ "$#" -eq 1 ] || die "list requires: <task>"
    cmd_list "$1"
    ;;
  list-all)
    cmd_list_all
    ;;
  pid-erlaubt)
    shift
    [ "$#" -eq 1 ] || die "pid-erlaubt requires: <pid>"
    cmd_pid_erlaubt "$1"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    die "unknown subcommand: '$cmd' (see --help)"
    ;;
esac
