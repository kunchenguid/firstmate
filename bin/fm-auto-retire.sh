#!/usr/bin/env bash
# Retire finished tasks through ordinary teardown during a supervision cycle.
#
# Usage:
#   fm-auto-retire.sh
#   fm-auto-retire.sh -h
#
# Selects a record that is safe to hand to fm-teardown.sh without --force:
#   - a non-scout, non-secondmate task with pr= whose forge state is MERGED
#     and whose last status verb is done
#   - a scout whose last status verb is done and whose report.md is present
# Every landed-work refusal still comes from teardown. One status line and one
# Slack line are emitted per successful retirement. A refused retirement is
# recorded once on the task status and is not retried. Unclassifiable records
# are reported once and left untouched.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TEARDOWN_BIN="${FM_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
SLACK_BIN="${FM_SLACK_POST_BIN:-$SCRIPT_DIR/fm-slack-post.sh}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "error: fm-auto-retire.sh accepts no arguments" >&2; exit 2 ;;
esac

[ -d "$STATE" ] || exit 0

meta_field() {  # <meta> <name>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

sidecar() {  # <id>
  printf '%s/%s.auto-retire\n' "$STATE" "$1"
}

append_status() {  # <id> <line>
  local status="$STATE/$1.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  printf '%s\n' "$2" >> "$status"
}

mark_once() {  # <id> <kind> <detail>
  local path
  path=$(sidecar "$1")
  [ -e "$path" ] && return 0
  printf '%s\t%s\n' "$2" "$3" > "$path"
}

already_marked() {  # <id>
  local path
  path=$(sidecar "$1")
  [ -f "$path" ] && [ ! -L "$path" ]
}

forge_state() {  # <pr-url>
  local state
  state=$(gh pr view "$1" --json state -q .state 2>/dev/null) || return 1
  printf '%s\n' "$state"
}

classify() {  # <id> <meta> -> merged|scout|skip|unclassified
  local id=$1 meta=$2 kind pr last verb report state
  kind=$(meta_field "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    secondmate) printf 'skip\n'; return 0 ;;
  esac
  last=$(last_status_line "$STATE/$id.status")
  verb=$(status_line_verb "$last")
  [ "$verb" = "done" ] || { printf 'skip\n'; return 0; }
  if [ "$kind" = scout ]; then
    report="$DATA/$id/report.md"
    if [ -f "$report" ] && [ ! -L "$report" ]; then
      printf 'scout\n'
    else
      printf 'skip\n'
    fi
    return 0
  fi
  pr=$(meta_field "$meta" pr)
  if [ -z "$pr" ]; then
    printf 'skip\n'
    return 0
  fi
  if ! fm_pr_url_parse "$pr" 2>/dev/null; then
    printf 'unclassified\n'
    return 0
  fi
  state=$(forge_state "$pr") || { printf 'unclassified\n'; return 0; }
  case "$state" in
    MERGED|merged) printf 'merged\n' ;;
    *) printf 'skip\n' ;;
  esac
}

retire_one() {  # <id> <reason>
  local id=$1 reason=$2 out rc
  append_status "$id" "done: auto-retired ($reason)"
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_TEARDOWN_GUARD_DONE=1 "$TEARDOWN_BIN" "$id" 2>&1); then
    "$SLACK_BIN" message "retired $id ($reason)" >/dev/null 2>&1 || true
    printf 'retired: %s (%s)\n' "$id" "$reason"
    return 0
  fi
  rc=$?
  out=$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//' | cut -c1-240)
  append_status "$id" "blocked: automatic retirement refused: $out"
  mark_once "$id" refused "$out"
  printf 'refused: %s\n' "$id"
  return 0
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  fm_task_id_path_safe "$id" || {
    printf 'unclassified: %s (unsafe id)\n' "$id" >&2
    continue
  }
  already_marked "$id" && continue
  class=$(classify "$id" "$meta") || class=unclassified
  case "$class" in
    merged) retire_one "$id" "merged PR" ;;
    scout) retire_one "$id" "done scout with report" ;;
    skip) ;;
    unclassified)
      printf 'unclassified: %s\n' "$id" >&2
      mark_once "$id" unclassified "could not classify"
      ;;
    *)
      printf 'unclassified: %s\n' "$id" >&2
      mark_once "$id" unclassified "unexpected class $class"
      ;;
  esac
done

exit 0
