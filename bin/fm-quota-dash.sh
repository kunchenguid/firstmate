#!/usr/bin/env bash
# fm-quota-dash.sh - a live console dashboard of provider quota headroom.
#
# Wraps `quota-axi --json`, which reports a snapshot and has no watch mode of
# its own. This adds the loop, the bars, and the countdown.
#
# Refresh is ONE HOUR by default, deliberately not htop's one second. Quota
# windows are weekly; polling them per second would show a frozen picture while
# hammering each provider's endpoint, so a fast refresh buys nothing and risks
# rate-limiting the very data it displays. The countdown exists so a slow
# refresh still looks alive, and `r` is there for when you cannot wait.
#
# A provider whose quota cannot be read is shown as UNREADABLE with its remedy,
# never as 0%. Zero would mean "quota exhausted", which is a different and much
# more alarming fact than "we could not ask" - and on 2026-08-06 exactly that
# confusion sent a worker to report a dead API key that was working fine.
#
# Alongside the token providers it shows image-generation spend, because that is
# the third consumable in this fleet and the only one billed in money rather
# than in a refilling window. Its numbers come from the same ledger
# bin/fm-image-gen.sh writes, so the dashboard and the tool's own cap can never
# disagree.
#
# Usage:
#   fm-quota-dash.sh [--interval <seconds>] [--provider <list>] [--once]
#
# Keys while running: r = refresh now, q = quit.
set -u

INTERVAL=3600
PROVIDERS=claude,codex
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      [ $# -ge 2 ] || { echo "fm-quota-dash: --interval requires seconds" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*|0*) echo "fm-quota-dash: --interval must be a positive integer" >&2; exit 2 ;; esac
      INTERVAL=$2; shift 2 ;;
    --provider)
      [ $# -ge 2 ] || { echo "fm-quota-dash: --provider requires a list" >&2; exit 2; }
      PROVIDERS=$2; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fm-quota-dash: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v quota-axi >/dev/null 2>&1 || { echo "fm-quota-dash: quota-axi is not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-quota-dash: jq is required" >&2; exit 2; }

if [ -t 1 ]; then
  DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
  GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'
else
  DIM=; BOLD=; RESET=; GREEN=; AMBER=; RED=
fi

# Colour follows the captain's own switching rule: at 20% remaining the plan is
# to move work to another provider, so that is where the bar stops being calm.
tone_for() {  # <percent-remaining>
  if   [ "$1" -le 5 ];  then printf '%s' "$RED"
  elif [ "$1" -le 20 ]; then printf '%s' "$AMBER"
  else printf '%s' "$GREEN"
  fi
}

bar() {  # <percent> <width>
  local pct=$1 width=$2 filled i out=
  filled=$(( pct * width / 100 ))
  [ "$filled" -ge 0 ] || filled=0
  [ "$filled" -le "$width" ] || filled=$width
  i=0; while [ "$i" -lt "$filled" ]; do out="$out█"; i=$((i + 1)); done
  while [ "$i" -lt "$width" ]; do out="$out░"; i=$((i + 1)); done
  printf '%s' "$out"
}

human_until() {  # <iso8601>
  local target now diff
  [ -n "$1" ] && [ "$1" != null ] || { printf 'unknown'; return; }
  target=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null) \
    || target=$(date -d "$1" +%s 2>/dev/null) || { printf 'unknown'; return; }
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { printf 'now'; return; }
  if   [ "$diff" -ge 86400 ]; then printf '%dd %dh' $(( diff / 86400 )) $(( diff % 86400 / 3600 ))
  elif [ "$diff" -ge 3600 ];  then printf '%dh %dm' $(( diff / 3600 )) $(( diff % 3600 / 60 ))
  else printf '%dm' $(( diff / 60 ))
  fi
}

render() {
  local json rows
  json=$(quota-axi --provider "$PROVIDERS" --json 2>/dev/null)

  printf '\033[H\033[2J'
  printf '%sfm-quota-dash%s   %s%s%s\n\n' "$BOLD" "$RESET" "$DIM" "$(date '+%Y-%m-%d %H:%M')" "$RESET"

  if [ -z "$json" ]; then
    printf '  %squota-axi returned nothing - is it installed and authenticated?%s\n' "$AMBER" "$RESET"
    return
  fi

  # One line per provider/window. A provider with no readable window still gets
  # a row, because silence about a provider is worse than an honest "unknown".
  rows=$(printf '%s' "$json" | jq -r '
    .providers[]? |
    (.provider) as $p | (.plan // "?") as $plan |
    if (.windows | length) > 0 then
      .windows[] | [$p, $plan, (.label // .id // "window"),
                    (.percentRemaining // -1 | tostring),
                    (.resetsAt // ""), (.pace.status // "?")] | @tsv
    else
      [$p, $plan, "-", "-1", "", "unreadable"] | @tsv
    end' 2>/dev/null)

  [ -n "$rows" ] || { printf '  %sno providers reported%s\n' "$AMBER" "$RESET"; return; }

  while IFS=$'\t' read -r prov plan label pct resets pace; do
    [ -n "$prov" ] || continue
    if [ "$pct" -lt 0 ] 2>/dev/null; then
      printf '  %-8s %s%-12s%s  %sUNREADABLE%s  %s\n' \
        "$prov" "$DIM" "$plan" "$RESET" "$AMBER" "$RESET" "${DIM}quota-axi --allow-keychain-prompt${RESET}"
      continue
    fi
    printf '  %-8s %s%-12s%s %s%s%s %3s%%\n' \
      "$prov" "$DIM" "$plan" "$RESET" "$(tone_for "$pct")" "$(bar "$pct" 28)" "$RESET" "$pct"
    printf '           %s%s window - resets in %s - pace: %s%s\n' \
      "$DIM" "$label" "$(human_until "$resets")" "$pace" "$RESET"
  done <<EOF
$rows
EOF

  render_image_spend
}

# Image generation is billed in money against a daily cap rather than in a
# window that refills, so it gets its own row with the cap as the denominator.
render_image_spend() {
  local home ledger cap spent today pct
  home="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  ledger="${FM_STATE_OVERRIDE:-$home/state}/image-gen-spend.tsv"
  cap=5
  [ ! -f "$home/config/image-daily-usd-cap" ] || cap=$(tr -d '[:space:]' < "$home/config/image-daily-usd-cap")
  case "$cap" in ''|*[!0-9.]*) cap=5 ;; esac

  today=$(date -u +%Y-%m-%d)
  spent=0
  [ ! -f "$ledger" ] || spent=$(awk -F'\t' -v d="$today" '$1 == d { s += $4 } END { printf "%.4f", s + 0 }' "$ledger" 2>/dev/null)
  case "$spent" in ''|*[!0-9.]*) spent=0 ;; esac

  # Percent REMAINING, so the bar reads the same direction as the token rows
  # above: full and green means plenty left, not plenty spent.
  pct=$(awk -v s="$spent" -v c="$cap" 'BEGIN { if (c <= 0) { print 0; exit } r = (1 - s / c) * 100; if (r < 0) r = 0; printf "%d", r }')

  printf '\n  %-8s %s%-12s%s %s%s%s %3s%%\n' \
    "images" "$DIM" "nano-banana" "$RESET" "$(tone_for "$pct")" "$(bar "$pct" 28)" "$RESET" "$pct"
  printf '           %sspent $%s of $%s today (UTC) - resets at midnight UTC%s\n' \
    "$DIM" "$spent" "$cap" "$RESET"
}

[ "$ONCE" -eq 0 ] || { render; exit 0; }

trap 'printf "\033[?25h\n"; exit 0' INT TERM
printf '\033[?25l'

while :; do
  render
  left=$INTERVAL
  while [ "$left" -gt 0 ]; do
    printf '\r  %snext refresh in %02d:%02d   -   r refresh now   -   q quit%s ' \
      "$DIM" $(( left / 60 )) $(( left % 60 )) "$RESET"
    if read -r -s -n 1 -t 1 key 2>/dev/null; then
      case "$key" in
        q|Q) printf '\033[?25h\n'; exit 0 ;;
        r|R) break ;;
      esac
    fi
    left=$(( left - 1 ))
  done
done
