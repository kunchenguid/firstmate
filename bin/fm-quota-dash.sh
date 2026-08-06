#!/usr/bin/env bash
# fm-quota-dash.sh - an htop-style console dashboard of fleet resource headroom.
#
# Wraps `quota-axi --json`, which reports a snapshot and has no watch mode of
# its own. This adds the gauges, the table, and the countdown.
#
# Layout follows htop deliberately: a stack of fuel gauges at the top for the
# glance, a detail table below for the answer, and a key bar at the bottom. The
# captain reads the gauges in a second and only drops to the table when one of
# them has gone amber.
#
# Refresh is ONE HOUR by default, not htop's one second. Quota windows are
# weekly, so a fast poll would redraw an unchanged picture while hammering each
# provider's endpoint. The countdown keeps a slow refresh from looking hung.
#
# Three resources, not two: Claude tokens, Codex tokens, and money spent on
# image generation. The image row reads the same state/image-gen-spend.tsv that
# bin/fm-image-gen.sh writes, so the dashboard and the tool's own cap can never
# drift apart.
#
# A provider whose quota cannot be read is shown as UNREADABLE, never as 0%.
# Zero would claim "quota exhausted" - a different and far more alarming fact
# than "we could not ask".
#
# Usage:
#   fm-quota-dash.sh [--interval <seconds>] [--provider <list>] [--once]
# Keys: r = refresh now, q = quit.
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
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fm-quota-dash: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v quota-axi >/dev/null 2>&1 || { echo "fm-quota-dash: quota-axi is not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-quota-dash: jq is required" >&2; exit 2; }

if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; BLUE=$'\033[34m'
  HDR=$'\033[46m\033[30m'; KEY=$'\033[42m\033[30m'; LBL=$'\033[44m\033[37m'
else
  R=; B=; D=; GREEN=; AMBER=; RED=; CYAN=; BLUE=; HDR=; KEY=; LBL=
fi

# Colour follows the captain's own switching rule: below 20% remaining the plan
# is to move work elsewhere, so that is where a gauge stops being calm.
tone_for() {
  awk -v p="$1" -v g="$GREEN" -v a="$AMBER" -v r="$RED" \
    'BEGIN { if (p < 5) printf "%s", r; else if (p < 20) printf "%s", a; else printf "%s", g }'
}

pace_label() {
  case "$1" in
    on_pace) printf '%sв норме%s' "$GREEN" "$R" ;;
    behind)  printf '%sперерасход%s' "$RED" "$R" ;;
    ahead)   printf '%sэкономно%s' "$CYAN" "$R" ;;
    *)       printf '%s-%s' "$D" "$R" ;;
  esac
}

human_until() {
  local t now d
  [ -n "$1" ] && [ "$1" != null ] || { printf '?'; return; }
  t=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null) \
    || t=$(date -d "$1" +%s 2>/dev/null) || { printf '?'; return; }
  now=$(date +%s); d=$(( t - now ))
  [ "$d" -gt 0 ] || { printf 'сейчас'; return; }
  if   [ "$d" -ge 86400 ]; then printf '%dд %dч' $(( d / 86400 )) $(( d % 86400 / 3600 ))
  elif [ "$d" -ge 3600 ];  then printf '%dч %dм' $(( d / 3600 )) $(( d % 3600 / 60 ))
  else printf '%dм' $(( d / 60 ))
  fi
}

# Rows are collected once per refresh into a TSV cache, so the gauge block and
# the detail table below it can never disagree about the same number.
ROWS=

collect() {
  local json img
  json=$(quota-axi --provider "$PROVIDERS" --json 2>/dev/null)
  ROWS=$(printf '%s' "$json" | jq -r '
    .providers[]? | (.provider) as $p | (.plan // "?") as $plan |
    if (.windows | length) > 0 then
      .windows[] | [$p, $plan, (.label // .id // "window"),
                    ((.percentRemaining // -1) | tostring),
                    (.resetsAt // ""), (.pace.status // "?")] | @tsv
    else [$p, $plan, "-", "-1", "", "?"] | @tsv end' 2>/dev/null)

  img=$(image_row) && ROWS="${ROWS}${ROWS:+$'\n'}${img}"
}

image_row() {
  local home ledger cap spent today pct
  home="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  ledger="${FM_STATE_OVERRIDE:-$home/state}/image-gen-spend.tsv"
  cap=5
  [ ! -f "$home/config/image-daily-usd-cap" ] || cap=$(tr -d '[:space:]' < "$home/config/image-daily-usd-cap")
  case "$cap" in ''|*[!0-9.]*) cap=5 ;; esac
  today=$(date -u +%Y-%m-%d); spent=0
  [ ! -f "$ledger" ] || spent=$(awk -F'\t' -v d="$today" '$1 == d { s += $4 } END { printf "%.4f", s + 0 }' "$ledger" 2>/dev/null)
  case "$spent" in ''|*[!0-9.]*) spent=0 ;; esac
  pct=$(awk -v s="$spent" -v c="$cap" 'BEGIN { r = (c > 0) ? (1 - s / c) * 100 : 0; if (r < 0) r = 0; printf "%.1f", r }')
  # Midnight UTC is a known reset, not an unknown one; emitting it as an ISO
  # timestamp lets the same human_until() render it as every other row.
  printf 'images\tnano-banana\tDaily $%s/$%s\t%s\t%sT00:00:00\tn/a' \
    "$spent" "$cap" "$pct" "$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)"
}

gauge() {  # <n> <pct> <model> <window>
  local n=$1 pct=$2 model=$3 win=$4 width=28 filled tone pipes spaces
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { f = int(p / 100 * w); if (f < 0) f = 0; if (f > w) f = w; print f }')
  tone=$(tone_for "$pct")
  pipes=$(printf '|%.0s' $(seq 1 "$filled") 2>/dev/null)
  spaces=$(printf ' %.0s' $(seq 1 $(( width - filled ))) 2>/dev/null)
  printf '%s%2d%s [%s%s%s%s %s%s%5.1f%%%s%s]%s %s%s%s %s(%s)%s\n' \
    "$CYAN" "$n" "$R" "$tone" "$pipes" "$R" "$spaces" "$B" "$tone" "$pct" "$R" "$CYAN" "$R" \
    "$B" "$model" "$R" "$D" "$win" "$R"
}

draw() {  # <seconds-left>
  local left=$1 n=0
  printf '\033[H\033[J'

  while IFS=$'\t' read -r prov plan win pct resets pace; do
    [ -n "$prov" ] || continue
    n=$(( n + 1 ))
    if awk -v p="$pct" 'BEGIN { exit !(p < 0) }'; then
      printf '%s%2d%s [%sНЕДОСТУПНО - quota-axi --allow-keychain-prompt%s] %s%s%s\n' \
        "$CYAN" "$n" "$R" "$AMBER" "$R" "$B" "$prov" "$R"
    else
      gauge "$n" "$pct" "$prov" "$win"
    fi
  done <<EOF
$ROWS
EOF

  printf '\n%sРесурсов:%s %s%d%s | %sАвто-обновление:%s %02d:%02d\n\n' \
    "$CYAN" "$R" "$B" "$n" "$R" "$CYAN" "$R" $(( left / 60 )) $(( left % 60 ))

  # printf pads by BYTES and Cyrillic is two bytes per character, so %-8s on a
  # Russian header yields half the intended column. The header is padded by
  # hand to match the ASCII data columns below it.
  printf '%s%s%s\n' "$HDR" " ID МОДЕЛЬ   ТАРИФ        ОКНО               ОСТАТОК   СБРОС      ТЕМП        " "$R"

  n=0
  while IFS=$'\t' read -r prov plan win pct resets pace; do
    [ -n "$prov" ] || continue
    n=$(( n + 1 ))
    if awk -v p="$pct" 'BEGIN { exit !(p < 0) }'; then
      printf '%s%3d%s %s%-8s%s %s%-12s%s %-16s %s%9s%s   %-10s %s\n' \
        "$CYAN" "$n" "$R" "$B" "$prov" "$R" "$BLUE" "$plan" "$R" "-" "$AMBER" "н/д" "$R" "-" "$(pace_label "$pace")"
    else
      printf '%s%3d%s %s%-8s%s %s%-12s%s %-16s %s%8.1f%%%s   %s%-10s%s %s\n' \
        "$CYAN" "$n" "$R" "$B" "$prov" "$R" "$BLUE" "$plan" "$R" "$win" \
        "$(tone_for "$pct")" "$pct" "$R" "$D" "$(human_until "$resets")" "$R" "$(pace_label "$pace")"
    fi
  done <<EOF
$ROWS
EOF

  printf '\n%s r %s%sОбновить%s  %s q %s%sВыход%s\n' "$KEY" "$R" "$LBL" "$R" "$KEY" "$R" "$LBL" "$R"
}

if [ "$ONCE" -eq 1 ]; then collect; draw "$INTERVAL"; exit 0; fi

trap 'printf "\033[?25h%s\n" "$R"; exit 0' INT TERM
printf '\033[?25l'

while :; do
  collect
  left=$INTERVAL
  while [ "$left" -gt 0 ]; do
    draw "$left"
    if read -r -s -n 1 -t 1 key 2>/dev/null; then
      case "$key" in
        q|Q) printf '\033[?25h%s\n' "$R"; exit 0 ;;
        r|R) break ;;
      esac
    fi
    left=$(( left - 1 ))
  done
done
