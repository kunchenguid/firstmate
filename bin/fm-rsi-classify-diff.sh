#!/usr/bin/env bash
# Classify an immutable Git diff for the RSI W1 fast lane.
#
# Usage: fm-rsi-classify-diff.sh <repo> <base-sha> <candidate-sha>
#
# Emits one JSON evidence object to stdout and exits zero for every successful
# classification, including a full-lane result. Invalid repositories or refs
# fail non-zero. Fast requires a non-empty diff with no behavior-bearing JS/TS
# files, sensitive paths, changed HTML script blocks, or deleted test lines.
set -euo pipefail

usage() {
  sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi

[ "$#" -eq 3 ] || {
  printf 'usage: %s <repo> <base-sha> <candidate-sha>\n' "${0##*/}" >&2
  exit 2
}

repo=$1
base=$2
candidate=$3

git -C "$repo" rev-parse --verify "$base^{commit}" >/dev/null
git -C "$repo" rev-parse --verify "$candidate^{commit}" >/dev/null

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(git -C "$repo" diff --name-only "$base" "$candidate")

if [ "${#files[@]}" -eq 0 ]; then
  jq -cn '{lane: "empty", files: [], reasons: ["no_diff"]}'
  exit 0
fi

reasons=()
full=0

add_reason() {
  reasons+=("$1")
  full=1
}

html_scripts() {
  perl -0777 -MDigest::SHA=sha256_hex -ne 'while (/<script\b[^>]*>.*?<\/script\s*>/gis) { print sha256_hex($&), "\n" }'
}

file_at_ref() {
  git -C "$repo" show "$1:$2" 2>/dev/null || true
}

for file in "${files[@]}"; do
  case "$file" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
      add_reason "behavior_file:$file"
      ;;
  esac
  shopt -s nocasematch
  case "$file" in
    *auth*|*billing*|*sms*|*delete*|*secret*)
      add_reason "sensitive_path:$file"
      ;;
  esac
  shopt -u nocasematch
  case "$file" in
    *.html|*.htm)
      base_scripts=$(file_at_ref "$base" "$file" | html_scripts)
      candidate_scripts=$(file_at_ref "$candidate" "$file" | html_scripts)
      if [ "$base_scripts" != "$candidate_scripts" ]; then
        add_reason "script_touch:$file"
      fi
      ;;
  esac
  case "$file" in
    *.test.*|*.spec.*|*_test.*|test/*|tests/*|*/test/*|*/tests/*)
      if git -C "$repo" diff --unified=0 "$base" "$candidate" -- "$file" | grep -q '^-.'; then
        add_reason "test_not_additive:$file"
      fi
      ;;
  esac
done

if [ "$full" -eq 1 ]; then
  lane=full
else
  lane=fast
fi

files_json=$(jq -cn '$ARGS.positional' --args "${files[@]}")
reasons_json=$(jq -cn '$ARGS.positional' --args "${reasons[@]}")
jq -cn --arg lane "$lane" --argjson files "$files_json" --argjson reasons "$reasons_json" \
  '{lane: $lane, files: $files, reasons: $reasons}'
