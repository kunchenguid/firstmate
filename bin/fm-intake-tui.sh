#!/usr/bin/env bash
# fm-intake-tui.sh - read-only terminal view over state/intake/snapshot.json.
#
# The intake poll shim owns all source polling and rewrites snapshot.json.
# This TUI only re-reads that local file and local fleet metadata on a timer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT="${FM_INTAKE_SNAPSHOT:-$STATE/intake/snapshot.json}"
CREW_STATE_CMD="${FM_INTAKE_TUI_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}"
INTERVAL="${FM_INTAKE_TUI_INTERVAL:-5}"
COLOR_MODE="${FM_INTAKE_TUI_COLOR:-auto}"
ONCE=0

usage() {
  cat <<'EOF'
usage: fm-intake-tui.sh [--once] [--interval seconds] [--snapshot path] [--color auto|always|never]

Read-only TUI over state/intake/snapshot.json. The TUI never polls intake
sources; run bin/fm-intake-poll.sh or the watcher shim to refresh the snapshot.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --interval)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      INTERVAL=$2
      shift 2
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SNAPSHOT=$2
      shift 2
      ;;
    --color)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      COLOR_MODE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$INTERVAL" in
  ''|*[!0-9]*) INTERVAL=5 ;;
  0) INTERVAL=1 ;;
esac

case "$COLOR_MODE" in
  auto|always|never) : ;;
  *) COLOR_MODE=auto ;;
esac

USE_COLOR=0
case "$COLOR_MODE" in
  always) USE_COLOR=1 ;;
  auto)
    if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || printf '0')" -ge 8 ]; then
      USE_COLOR=1
    fi
    ;;
esac

if [ "$USE_COLOR" -eq 1 ]; then
  RED=$(printf '\033[31m')
  YELLOW=$(printf '\033[33m')
  CYAN=$(printf '\033[36m')
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  RESET=$(printf '\033[0m')
else
  RED=
  YELLOW=
  CYAN=
  BOLD=
  DIM=
  RESET=
fi
FIELD_SEP=$(printf '\037')

NOW_EPOCH="${FM_INTAKE_TUI_NOW_EPOCH:-}"
now_epoch() {
  case "$NOW_EPOCH" in
    ''|*[!0-9]*) date +%s 2>/dev/null || printf '0' ;;
    *) printf '%s' "$NOW_EPOCH" ;;
  esac
}

redact_text() {
  sed -E \
    -e 's/(gh[pousr]_[A-Za-z0-9_]{6})[A-Za-z0-9_]+/\1.../g' \
    -e 's/(xox[baprs]-[A-Za-z0-9-]{8})[A-Za-z0-9-]+/\1.../g' \
    -e 's/(AKIA[0-9A-Z]{4})[0-9A-Z]{12}/\1.../g' \
    -e 's/(secret-)[A-Za-z0-9._-]+/\1.../g' \
    -e 's/((api|access|refresh|auth)[_-]?[Tt]oken[=:][A-Za-z0-9._-]{4})[A-Za-z0-9._-]+/\1.../g'
}

print_line() {
  printf '%s\n' "$*" | redact_text
}

trim_text() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

human_duration() {
  local secs=$1 days hours mins
  case "$secs" in
    ''|*[!0-9-]*) printf 'unknown'; return ;;
  esac
  if [ "$secs" -lt 0 ]; then
    secs=$(( -secs ))
  fi
  days=$(( secs / 86400 ))
  hours=$(( (secs % 86400) / 3600 ))
  mins=$(( (secs % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    printf '%dd%02dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh%02dm' "$hours" "$mins"
  else
    [ "$mins" -lt 1 ] && mins=1
    printf '%dm' "$mins"
  fi
}

breach_countdown() {
  local secs=$1 duration
  if [ -z "$secs" ] || [ "$secs" = "null" ]; then
    printf 'no SLA'
    return
  fi
  duration=$(human_duration "$secs")
  if [ "$secs" -lt 0 ]; then
    printf 'breached %s ago' "$duration"
  else
    printf 'breach in %s' "$duration"
  fi
}

snapshot_valid() {
  [ -s "$SNAPSHOT" ] || return 1
  jq -e 'type == "object" and ((.items // []) | type == "array")' "$SNAPSHOT" >/dev/null 2>&1
}

snapshot_has_items() {
  jq -e '(.items // []) | length > 0' "$SNAPSHOT" >/dev/null 2>&1
}

section_title() {
  print_line "${BOLD}${CYAN}$1${RESET}"
}

render_items() { # <title> <jq-select-filter>
  local title=$1 filter=$2 now rows row id priority state secs level title_text countdown color
  now=$(now_epoch)
  section_title "$title"
  rows=$(jq -r --argjson now "$now" "$filter" "$SNAPSHOT" 2>/dev/null) || rows=
  if [ -z "$rows" ]; then
    print_line "  ${DIM}_No items._${RESET}"
    print_line ""
    return
  fi
  printf '%s\n' "$rows" | while IFS="$FIELD_SEP" read -r id priority state secs level title_text; do
    countdown=$(breach_countdown "$secs")
    color=
    case "$level" in
      breach) color=$RED ;;
      warn) color=$YELLOW ;;
    esac
    row=$(printf '  %-18s %-10s %-14s %-18s %s' "$id" "$priority" "$state" "$countdown" "$title_text")
    print_line "${color}${row}${RESET}"
  done
  print_line ""
}

# shellcheck disable=SC2016 # This is a literal jq program; $now is jq state.
item_filter_prefix='
  def clean: if . == null then "" else tostring | gsub("[\r\n\t\u001f]+"; " ") end;
  def epoch($v): if $v == null then null else try ($v | fromdateiso8601) catch null end;
  def level($now):
    epoch(.sla_warn_at) as $warn
    | epoch(.sla_breach_at) as $breach
    | if $breach != null and $now >= $breach then "breach"
      elif $warn != null and $now >= $warn then "warn"
      else "ok" end;
  def secs_to_breach($now):
    epoch(.sla_breach_at) as $breach
    | if $breach == null then "" else (($breach - $now) | tostring) end;
  def row($now):
    [(.id | clean), (.priority | clean), (.state | clean), secs_to_breach($now), level($now), (.title | clean)] | join("\u001f");
'

render_fleet() {
  local meta id output state source detail
  section_title "FLEET LANES"
  if ! find "$STATE" -maxdepth 1 -type f -name '*.meta' -print -quit 2>/dev/null | grep . >/dev/null 2>&1; then
    print_line "  ${DIM}_No fleet lanes._${RESET}"
    print_line ""
    return
  fi
  find "$STATE" -maxdepth 1 -type f -name '*.meta' -print 2>/dev/null | sort | while IFS= read -r meta; do
    id=${meta##*/}
    id=${id%.meta}
    output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE_CMD" "$id" 2>/dev/null || true)
    state=$(printf '%s\n' "$output" | sed -n 's/^state: \([^·]*\).*$/\1/p' | head -1 | trim_text)
    source=$(printf '%s\n' "$output" | sed -n 's/^.*source: \([^·]*\).*$/\1/p' | head -1 | trim_text)
    detail=${output#*source: }
    detail=${detail#*· }
    [ -n "$state" ] || state=unknown
    [ -n "$source" ] || source=none
    print_line "$(printf '  %-18s %-10s %-12s %s' "$id" "$state" "$source" "$detail")"
  done
  print_line ""
}

render_once() {
  local generated item_count now oncall_filter normal_filter pr_filter
  now=$(now_epoch)
  print_line "${BOLD}Firstmate Intake${RESET}"
  if ! snapshot_valid; then
    print_line "no intake data yet - is config/intake.env enabled?"
    print_line ""
    render_fleet
    return
  fi
  generated=$(jq -r '.generated_at // "unknown generated time"' "$SNAPSHOT" 2>/dev/null)
  item_count=$(jq -r '(.items // []) | length' "$SNAPSHOT" 2>/dev/null)
  print_line "${DIM}generated: $generated · items: $item_count · snapshot: $SNAPSHOT${RESET}"
  print_line ""
  if ! snapshot_has_items; then
    print_line "no intake data yet - is config/intake.env enabled?"
    print_line ""
    render_fleet
    return
  fi

  oncall_filter="$item_filter_prefix
    [(.items // [])[] | select(.lane == \"oncall\")]
    | sort_by((epoch(.sla_breach_at) // 9999999999), .id)
    | .[]
    | row(\$now)
  "
  normal_filter="$item_filter_prefix
    [(.items // [])[] | select(.lane == \"normal\")]
    | sort_by(.priority // \"\", .id)
    | .[]
    | row(\$now)
  "
  pr_filter="$item_filter_prefix
    [(.items // [])[] | select(.lane == \"pr\" or .lane == \"review\")]
    | sort_by(.lane, .id)
    | .[]
    | row(\$now)
  "
  render_items "ONCALL tickets" "$oncall_filter"
  render_items "NORMAL tickets" "$normal_filter"
  render_items "MY PRs / REVIEW queue" "$pr_filter"
  render_fleet
}

if [ "$ONCE" -eq 1 ]; then
  render_once
  exit 0
fi

while :; do
  if [ -t 1 ]; then
    tput clear 2>/dev/null || printf '\033[H\033[2J'
  fi
  render_once
  sleep "$INTERVAL"
done
