#!/usr/bin/env bash
# fm-task-priority-check.sh - refuse a new backlog task that carries no priority.
#
# Usage: fm-task-priority-check.sh <tasks-axi command> [tasks-axi args...]
#
# The fork's fm-tasks-axi.sh `add` and fm-captain-hold.sh `hold` (when it creates the row) call this with the
# exact tasks-axi arguments, only when the add-on is installed. Only `add` and `create` are checked; any other
# command exits 0. A new task needs:
#   - --priority 0-3 (0 = most urgent); missing or out of range is refused, exit 1, with the flag to pass;
#   - a target release: a `release: <name>` line in --body or --body-file, defaulting to `later` when absent.
# Stdout: `release: <name>` (the resolved release). Stderr: the one-line refusal.
set -u

case "${1:-}" in add|create) shift ;; *) exit 0 ;; esac

priority='' body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --priority) priority=${2-}; shift ;;
    --priority=*) priority=${1#--priority=} ;;
    --body) body=$body$'\n'${2-}; shift ;;
    --body=*) body=$body$'\n'${1#--body=} ;;
    --body-file) [ -r "${2-}" ] && body=$body$'\n'$(cat "$2"); shift ;;
    --body-file=*) [ -r "${1#--body-file=}" ] && body=$body$'\n'$(cat "${1#--body-file=}") ;;
  esac
  shift
done

case "$priority" in
  [0-3]) ;;
  '') echo "task-priority: this task has no priority; pass --priority 0|1|2|3 (0 is most urgent)" >&2; exit 1 ;;
  *) echo "task-priority: priority '$priority' is not 0-3; pass --priority 0|1|2|3 (0 is most urgent)" >&2; exit 1 ;;
esac

release=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*release:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | head -n 1)
printf 'release: %s\n' "${release:-later}"
