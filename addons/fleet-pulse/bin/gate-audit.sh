#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: gate-audit.sh <checks-gate.log> <pr-url>..." >&2
  exit 2
fi
log=$1
shift

for url in "$@"; do
  number=${url##*/}
  verdict=$(awk -v url="$url" -v number="$number" '
    $2 == url || $2 == number { if ($4 != "card") verdict=$4 }
    END { print verdict }
  ' "$log")
  if [ "$verdict" = pass ]; then
    printf '%s pass\n' "$url"
  else
    printf '%s bypass\n' "$url"
  fi
done
exit 0
