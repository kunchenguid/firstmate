#!/usr/bin/env bash
# Classify an immutable Git diff for the RSI W1 fast lane.
#
# Usage: fm-rsi-classify-diff.sh <repo> <base-sha> <candidate-sha>
#
# Emits one JSON evidence object to stdout and exits zero for every successful
# classification, including a full-lane result. Invalid repositories or refs
# fail non-zero. Fast requires a non-empty diff limited to presentation assets,
# documentation, or additive tests, with no sensitive paths or changed script
# blocks.
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
base_ref=$2
candidate_ref=$3

base=$(git -C "$repo" rev-parse --verify --end-of-options "$base_ref^{commit}")
candidate=$(git -C "$repo" rev-parse --verify --end-of-options "$candidate_ref^{commit}")

file_list=$(mktemp "${TMPDIR:-/tmp}/fm-rsi-classify-diff.XXXXXX")
trap 'rm -f "$file_list"' EXIT HUP INT TERM
git -C "$repo" diff --no-renames --name-only -z "$base" "$candidate" -- > "$file_list"
files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < "$file_list"

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

script_fingerprints() {
  perl -0777 -MDigest::SHA=sha256_hex -ne 'while (/<script\b[^>]*>.*?<\/script\s*>|<script\b[^>]*\/\s*>|<script\b[^>]*>.*\z|<\/script\s*>/gis) { print sha256_hex($&), "\n" }'
}

file_at_ref() {
  git -C "$repo" show "$1:$2" 2>/dev/null || true
}

is_test_path() {
  case "$1" in
    *.test.*|*.spec.*|*_test.*|test/*|tests/*|*/test/*|*/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_fast_markup_path() {
  case "$1" in
    *.html|*.htm|*.xhtml|*.svg|*.md|*.rst) return 0 ;;
    *) return 1 ;;
  esac
}

is_fast_content_path() {
  if is_fast_markup_path "$1"; then
    return 0
  fi
  case "$1" in
    *.css|*.scss|*.sass|*.less|*.styl|\
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.ico|\
    *.woff|*.woff2|*.ttf|*.otf|*.eot|\
    *.txt) return 0 ;;
    *) return 1 ;;
  esac
}

is_sensitive_path() {
  case "/$1/" in
    *auth*|*billing*|*payment*|*checkout*|*sms*|*delete*|*secret*|\
    *credential*|*webhook*|*migration*|*database*|*deploy*|\
    */api/*|*/server/*|*/backend/*|*/infra/*|*/.github/workflows/*) return 0 ;;
    *) return 1 ;;
  esac
}

shopt -s nocasematch
for file in "${files[@]}"; do
  if is_sensitive_path "$file"; then
    add_reason "sensitive_path:$file"
  fi

  if is_test_path "$file"; then
    test_stats=$(git -C "$repo" diff --no-renames --numstat "$base" "$candidate" -- "$file")
    if printf '%s\n' "$test_stats" | awk -F '\t' 'NF >= 2 && $2 != "0" { non_additive=1 } END { exit non_additive ? 0 : 1 }'; then
      add_reason "test_not_additive:$file"
    fi
  elif ! is_fast_content_path "$file"; then
    add_reason "behavior_file:$file"
  fi

  if is_fast_markup_path "$file"; then
    base_scripts=$(file_at_ref "$base" "$file" | script_fingerprints)
    candidate_scripts=$(file_at_ref "$candidate" "$file" | script_fingerprints)
    if [ "$base_scripts" != "$candidate_scripts" ]; then
      add_reason "script_touch:$file"
    fi
  fi
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
