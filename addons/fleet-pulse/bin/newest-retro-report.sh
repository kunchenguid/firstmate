#!/usr/bin/env bash
# Print the newest data/*retro*/report.md across the main home and known sibling
# firstmate homes (secondmates.md and ~/.treehouse/firstmate-*/*/firstmate), by
# mtime. No output when none exist. Usage: newest-retro-report.sh <main-home>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: newest-retro-report.sh <main-home>' >&2
  exit 2
fi
main=$(cd "$1" && pwd -P)
treehouse=${FM_TREEHOUSE:-$HOME/.treehouse}

datas=
add_data() {
  local d=$1 resolved
  [ -d "$d" ] || return 0
  resolved=$(cd "$d" && pwd -P)
  case $'\n'"$datas"$'\n' in
    *$'\n'"$resolved"$'\n'*) return 0 ;;
  esac
  datas=${datas:+$datas$'\n'}$resolved
}

add_data "$main/data"
if [ -f "$main/data/secondmates.md" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] && add_data "$hp/data"
  done < <(sed -n 's/.*(home: \([^;]*\);.*/\1/p' "$main/data/secondmates.md")
fi
if [ -d "$treehouse" ]; then
  for hp in "$treehouse"/firstmate-*/*/firstmate; do
    [ -d "$hp" ] && add_data "$hp/data"
  done
fi

newest=
newest_m=0
while IFS= read -r data; do
  [ -n "$data" ] || continue
  for report in "$data"/*retro*/report.md; do
    [ -f "$report" ] || continue
    m=$(stat -c %Y "$report")
    if [ -z "$newest" ] || [ "$m" -gt "$newest_m" ]; then
      newest=$report
      newest_m=$m
    fi
  done
done <<<"$datas"

[ -n "$newest" ] && printf '%s\n' "$newest"
exit 0
