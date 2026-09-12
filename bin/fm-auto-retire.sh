#!/usr/bin/env bash
# Retire finished tasks through ordinary teardown during a supervision cycle.
#
# Usage:
#   fm-auto-retire.sh
#   fm-auto-retire.sh -h
#
# Selects a record that is safe to hand to fm-teardown.sh without --force:
#   - a non-scout, non-secondmate task with pr= whose forge state is MERGED,
#     whose last status verb is done, and whose worktree data/<id>/debrief.md
#     is copied to $FM_HOME/data/<id>/debrief.md before teardown; an absent or
#     empty debrief is refused as debrief-missing and left for a later cycle
#   - a scout whose last status verb is done and whose report.md is present
# The done check snapshots the status file's byte length and mtime; if either
# changed before retirement, the record is refused as status-moved and left
# for a later cycle.
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
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ponytail: size+mtime, content hash if same-second same-size rewrite matters
status_fingerprint() {  # <file> -> bytes<TAB>mtime
  local bytes mtime
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  bytes=$(wc -c < "$1" | tr -d '[:space:]')
  mtime=$(/usr/bin/stat -f '%m' "$1" 2>/dev/null) || mtime=$(stat -c '%Y' "$1" 2>/dev/null) || return 1
  printf '%s\t%s\n' "$bytes" "$mtime"
}

status_unchanged() {  # <fingerprint> <file>
  local now
  now=$(status_fingerprint "$2") || return 1
  [ "$1" = "$now" ]
}

forge_state() {  # <pr-url>
  local state
  state=$(gh pr view "$1" --json state -q .state 2>/dev/null) || return 1
  printf '%s\n' "$state"
}

classify() {  # <id> <meta> -> merged|scout|skip|unclassified|status-moved
  local id=$1 meta=$2 kind pr last verb report state status fp
  kind=$(meta_field "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    secondmate) printf 'skip\n'; return 0 ;;
  esac
  status="$STATE/$id.status"
  last=$(last_status_line "$status")
  verb=$(status_line_verb "$last")
  [ "$verb" = "done" ] || { printf 'skip\n'; return 0; }
  fp=$(status_fingerprint "$status") || { printf 'status-moved\n'; return 0; }
  if [ "$kind" = scout ]; then
    report="$DATA/$id/report.md"
    if [ -f "$report" ] && [ ! -L "$report" ]; then
      status_unchanged "$fp" "$status" || { printf 'status-moved\n'; return 0; }
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
    MERGED|merged)
      status_unchanged "$fp" "$status" || { printf 'status-moved\n'; return 0; }
      printf 'merged\n'
      ;;
    *) printf 'skip\n' ;;
  esac
}

# Copy the ship's worktree debrief into the home before teardown. Absent,
# empty, or unreadable files refuse with debrief-missing so a later cycle can
# retry. Scouts and secondmates do not use this path.
preserve_ship_debrief() {  # <id> <meta>
  local id=$1 meta=$2 wt src dest
  wt=$(meta_field "$meta" worktree)
  src="${wt%/}/data/$id/debrief.md"
  dest="$DATA/$id/debrief.md"
  [ -n "$wt" ] && [ -f "$src" ] && [ ! -L "$src" ] && [ -s "$src" ] || return 1
  mkdir -p "$DATA/$id" || return 1
  cp "$src" "$dest" || return 1
}

retire_one() {  # <id> <reason>
  local id=$1 reason=$2 out rc
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_TEARDOWN_GUARD_DONE=1 "$TEARDOWN_BIN" "$id" 2>&1); then
    "$SLACK_BIN" message "retired $id ($reason)" >/dev/null 2>&1 || true
    printf 'retired: %s (%s)\n' "$id" "$reason"
    return 0
  fi
  rc=$?
  out=$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//' | cut -c1-240)
  append_status "$id" "note: automatic retirement refused: $out"
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
    merged)
      if preserve_ship_debrief "$id" "$meta"; then
        retire_one "$id" "merged PR"
      else
        printf 'refused: %s (debrief-missing)\n' "$id"
      fi
      ;;
    scout) retire_one "$id" "done scout with report" ;;
    status-moved) printf 'refused: %s (status-moved)\n' "$id" ;;
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
