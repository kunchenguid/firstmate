#!/usr/bin/env bash
# fm-blocker-sweep.sh - list every still-open blocked key, and close only
# keys whose task is provably terminal.
#
# Usage:
#   fm-blocker-sweep.sh                  List open blocked keys (dry-run)
#   fm-blocker-sweep.sh --close-terminal Append resolved [key=...] for
#                                        done, pr-merged, dead-endpoint, and
#                                        failed tasks. Never writes a live or
#                                        unknown key.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

path_mtime() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

meta_field() {  # <meta> <name>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

status_path_readable() {
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ]
}

# live | dead-endpoint | done | pr-merged | failed | unknown
classify_task_state() {  # <meta> <status>
  local meta=$1 status=$2 kind window pr last verb note
  kind=$(meta_field "$meta" kind)
  window=$(meta_field "$meta" window)
  pr=$(meta_field "$meta" pr)
  last=$(last_status_line "$status")
  verb=$(status_line_verb "$last")
  note=$(status_line_note "$last")
  case "$verb" in
    done)
      if [ -n "$pr" ] || printf '%s' "$note" | grep -qi 'merged'; then
        printf 'pr-merged'
      else
        printf 'done'
      fi
      ;;
    failed) printf 'failed' ;;
    *)
      if [ "$kind" = secondmate ]; then
        printf 'live'
      elif [ -n "$window" ]; then
        printf 'live'
      elif [ -f "$meta" ]; then
        printf 'dead-endpoint'
      else
        printf 'unknown'
      fi
      ;;
  esac
}

close_allowed() {
  case "$1" in
    done|pr-merged|dead-endpoint|failed) return 0 ;;
    *) return 1 ;;
  esac
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

main() {
  local close=0 meta id status open key verb summary
  local liveness event_epoch age now home kind clean_summary evidence
  case "${1:-}" in
    '' ) ;;
    --close-terminal) close=1 ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  now=$(date +%s)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    if ! status_path_readable "$status"; then
      if [ -e "$status" ] || [ -L "$status" ]; then
        printf 'open-blocked %s [key=unknown] age=unknown home=unknown state=unknown unreadable status\n' "$id"
      fi
      continue
    fi
    if ! open=$(status_open_decisions "$status"); then
      printf 'open-blocked %s [key=unknown] age=unknown home=unknown state=unknown unreadable status\n' "$id"
      continue
    fi
    kind=$(meta_field "$meta" kind)
    if [ "$kind" = secondmate ]; then
      home=$id
    else
      home=primary
    fi
    liveness=$(classify_task_state "$meta" "$status")
    event_epoch=$(path_mtime "$status" 2>/dev/null || true)
    case "$event_epoch" in ''|*[!0-9]*) age=unknown ;; *)
      age=$((now - event_epoch))
      [ "$age" -ge 0 ] || age=0
      age=${age}s
      ;;
    esac
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = blocked ] || continue
      clean_summary=$(printf '%s' "$summary" | clean_field)
      printf 'open-blocked %s [key=%s] age=%s home=%s state=%s %s\n' \
        "$id" "$key" "$age" "$home" "$liveness" "$clean_summary"
      if [ "$close" -eq 1 ] && close_allowed "$liveness"; then
        evidence=$(printf 'blocker-sweep: state=%s' "$liveness")
        printf 'resolved [key=%s]: %s\n' "$key" "$evidence" >> "$status"
        printf 'closed %s [key=%s] state=%s %s\n' "$id" "$key" "$liveness" "$evidence"
      fi
    done <<EOF
$open
EOF
  done
}

main "$@"
