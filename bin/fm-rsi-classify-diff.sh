#!/usr/bin/env bash
# Classify an immutable Git diff for the RSI W1 fast lane.
#
# Usage: fm-rsi-classify-diff.sh <repo> <base-sha> <candidate-sha>
#
# Emits one JSON evidence object to stdout and exits zero for every successful
# classification, including a full-lane result. Invalid repositories or refs
# fail non-zero. Fast requires a non-empty diff limited to presentation assets,
# documentation, or additive tests, with no sensitive paths or markup that
# contains a script tag.
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
export GIT_NO_REPLACE_OBJECTS=1

base=$(git -C "$repo" rev-parse --verify --end-of-options "$base_ref^{commit}")
candidate=$(git -C "$repo" rev-parse --verify --end-of-options "$candidate_ref^{commit}")

file_list=$(mktemp "${TMPDIR:-/tmp}/fm-rsi-classify-diff.XXXXXX")
trap 'rm -f "$file_list"' EXIT HUP INT TERM
git -C "$repo" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames \
  --name-only -z "$base" "$candidate" -- > "$file_list"
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

script_presence() {
  perl -0777 -ne 'print "present\n" if /<\/?(?:[^<>\s\/:]+:)?script\b/i'
}

file_at_ref() {
  [ -n "$3" ] || return 0
  git -C "$repo" cat-file blob "$1:$2"
}

mode_at_ref() {
  GIT_LITERAL_PATHSPECS=1 git -C "$repo" ls-tree "$1" -- "$2" | awk 'NR == 1 { print $1 }'
}

is_regular_mode() {
  case "$1" in
    ''|100644|100755) return 0 ;;
    *) return 1 ;;
  esac
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
  base_mode=$(mode_at_ref "$base" "$file")
  candidate_mode=$(mode_at_ref "$candidate" "$file")
  if [ -z "$base_mode" ] && [ -z "$candidate_mode" ]; then
    add_reason "unreadable_entry:$file"
    continue
  fi
  if ! is_regular_mode "$base_mode" || ! is_regular_mode "$candidate_mode"; then
    add_reason "non_regular_entry:$file"
    continue
  fi
  if [ -n "$base_mode" ] && [ -n "$candidate_mode" ] && [ "$base_mode" != "$candidate_mode" ]; then
    add_reason "entry_mode_change:$file"
    continue
  fi

  if is_sensitive_path "$file"; then
    add_reason "sensitive_path:$file"
  fi

  if is_test_path "$file"; then
    test_stats=$(GIT_LITERAL_PATHSPECS=1 git -C "$repo" diff --no-ext-diff --no-textconv \
      --ignore-submodules=none --no-renames --numstat "$base" "$candidate" -- "$file")
    if printf '%s\n' "$test_stats" | awk -F '\t' 'NF >= 2 && $2 != "0" { non_additive=1 } END { exit non_additive ? 0 : 1 }'; then
      add_reason "test_not_additive:$file"
    fi
  elif ! is_fast_content_path "$file"; then
    add_reason "behavior_file:$file"
  fi

  if is_fast_markup_path "$file"; then
    base_script=$(file_at_ref "$base" "$file" "$base_mode" | script_presence)
    candidate_script=$(file_at_ref "$candidate" "$file" "$candidate_mode" | script_presence)
    if [ -n "$base_script" ] || [ -n "$candidate_script" ]; then
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
