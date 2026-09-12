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
#   - a done task with an OPEN PR passing fm-pr-context-watch.sh ready and
#     the same debrief guard; its independent context check survives cleanup
#   - a scout whose last status verb is done and whose report.md is present
# The done check snapshots the status file's byte length and mtime; if either
# changed before retirement, the record is refused as status-moved and left
# for a later cycle.
# Every landed-work refusal still comes from teardown. One status line is
# emitted per successful retirement; teardown retains its telemetry record.
# Transient teardown and debrief-missing refusals retry for five cycles before becoming sticky;
# other refusals are recorded once. Unclassifiable records stay untouched.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TEARDOWN_BIN="${FM_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
MAX_TRANSIENT_ATTEMPTS=5

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
  local path existing_kind
  path=$(sidecar "$1")
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 0
    IFS=$'\t' read -r existing_kind _ < "$path" || return 0
    [ "$existing_kind" = retry ] || return 0
  fi
  printf '%s\t%s\n' "$2" "$3" > "$path"
}

already_marked() {  # <id>
  local path kind
  path=$(sidecar "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS=$'\t' read -r kind _ < "$path" || return 0
  [ "$kind" != retry ]
}

clear_retry_mark() {  # <id>
  local path kind
  path=$(sidecar "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  IFS=$'\t' read -r kind _ < "$path" || return 0
  [ "$kind" != retry ] || rm -f "$path"
}

retry_or_park() {  # <id> <reason> <detail>
  local id=$1 reason=$2 detail=$3 path kind='' count=0
  path=$(sidecar "$id")
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    IFS=$'\t' read -r kind count _ < "$path" || true
    [ "$kind" = retry ] || count=0
    case "$count" in ''|*[!0-9]*) count=$((MAX_TRANSIENT_ATTEMPTS - 1)) ;; esac
  fi
  count=$((count + 1))
  if [ "$count" -ge "$MAX_TRANSIENT_ATTEMPTS" ]; then
    printf 'refused\ttransient-exhausted reason=%s attempts=%s: %s\n' \
      "$reason" "$count" "$detail" > "$path"
    append_status "$id" \
      "note: automatic retirement refused: $reason exhausted after $count attempts: $detail"
    printf 'refused: %s (transient %s exhausted after %s attempts)\n' "$id" "$reason" "$count"
  else
    printf 'retry\t%s\t%s\n' "$count" "$reason" > "$path"
    printf 'refused: %s (transient %s attempt %s/%s)\n' \
      "$id" "$reason" "$count" "$MAX_TRANSIENT_ATTEMPTS"
  fi
}

transient_refusal_reason() {  # <teardown-output>
  case "$1" in
    *"slot allocation or return is in progress"*) printf 'slot-allocation-or-return-in-progress\n' ;;
    *"presentation lock is held"*|*"presentation lock held"*|*"presentation lock is contended"*)
      printf 'presentation-lock-held\n'
      ;;
    *"endpoint is busy"*|*"endpoint busy"*) printf 'endpoint-busy\n' ;;
    *) return 1 ;;
  esac
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

classify() {  # <id> <meta> -> merged|context|scout|skip|unclassified|status-moved
  local id=$1 meta=$2 kind pr last verb report state status fp head copy
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
    OPEN|open)
      head=$(meta_field "$meta" pr_head)
      copy=$(meta_field "$meta" worktree)
      if [ -n "$head" ] && [ -n "$copy" ] &&
          FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
          "$SCRIPT_DIR/fm-pr-context-watch.sh" ready "$id" "$pr" "$head" "$copy" >/dev/null 2>&1; then
        status_unchanged "$fp" "$status" || { printf 'status-moved\n'; return 0; }
        printf 'context\n'
      else
        printf 'skip\n'
      fi
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
  local id=$1 reason=$2 out transient_reason
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_TEARDOWN_GUARD_DONE=1 "$TEARDOWN_BIN" "$id" 2>&1); then
    clear_retry_mark "$id"
    printf 'retired: %s (%s)\n' "$id" "$reason"
    return 0
  fi
  out=$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//' | cut -c1-240)
  if transient_reason=$(transient_refusal_reason "$out"); then
    retry_or_park "$id" "$transient_reason" "$out"
  else
    append_status "$id" "note: automatic retirement refused: $out"
    mark_once "$id" refused "$out"
    printf 'refused: %s\n' "$id"
  fi
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
    merged|context)
      if preserve_ship_debrief "$id" "$meta"; then
        reason="merged PR"
        [ "$class" != context ] || reason="PR context monitor ready"
        retire_one "$id" "$reason"
      else
        retry_or_park "$id" debrief-missing \
          "worktree debrief is absent, empty, or unreadable"
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
