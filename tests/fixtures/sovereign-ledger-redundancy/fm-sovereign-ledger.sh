#!/usr/bin/env bash
# Fixture ledger verifier for the redundancy mechanism's public dependency boundary.
set -euo pipefail

ledger_dir=${LEDGER_DIR:?LEDGER_DIR is required}
ledger=$ledger_dir/ledger.tsv

verify() {
  [ -f "$ledger" ] || exit 1
  [ "$(awk 'END { print NR }' "$ledger")" = 4 ] || exit 1
  awk -F '\t' '
    NF != 3 { exit 1 }
    $1 !~ /^ruling-[1-4]$/ { exit 1 }
    seen[$1]++ != 0 { exit 1 }
    END { exit length(seen) == 4 ? 0 : 1 }
  ' "$ledger"
}

recheck() {
  local key source count=0 bad=0
  while IFS=$'\t' read -r key source _; do
    count=$((count + 1))
    if [ ! -f "$source" ]; then
      printf 'SOURCE_GONE   %s (%s)\n' "$key" "$source"
      bad=$((bad + 1))
    fi
  done < "$ledger"
  printf 'recheck: %s entries, %s divergent\n' "$count" "$bad"
  [ "$bad" -eq 0 ]
}

text() {
  awk -F '\t' -v key="$1" '$1 == key { print $3; found = 1 } END { exit found ? 0 : 1 }' "$ledger" | base64 -d
}

case "${1:-}" in
  verify) verify ;;
  recheck) recheck ;;
  text) text "${2:?ruling key}" ;;
  *) exit 2 ;;
esac
