#!/usr/bin/env bash
# fm-prompt-stable-lib.sh - shared helpers for cache-stable Firstmate renders.
#
# Prompt-cache reuse requires exact prefix matches. Firstmate-controlled digests
# and instruction blocks must therefore:
#   1. emit static sections in a fixed order,
#   2. list multi-entry state with deterministic (LC_ALL=C) id order,
#   3. keep volatile runtime observations after the stable material they annotate.
#
# This library owns only the shared listing/ordering primitives. Each caller owns
# its section layout and which fields are treated as volatile.
#
# Sourced only. Not a CLI.

# fm_prompt_stable_list_ids <dir> <suffix>
# Print basenames under <dir> matching *.<suffix>, one per line, sorted with
# LC_ALL=C. Missing directories and empty matches print nothing.
fm_prompt_stable_list_ids() {
  local dir=$1 suffix=$2
  local path id
  [ -d "$dir" ] || return 0
  # Prefer find for stable enumeration; fall back to a sorted glob when find is
  # unavailable in tightly faked PATH fixtures.
  if command -v find >/dev/null 2>&1; then
    # -print0 / sort -z keep odd characters safe; strip the dotted suffix after.
    while IFS= read -r -d '' path; do
      id=$(basename "$path")
      id=${id%."$suffix"}
      printf '%s\n' "$id"
    done < <(find "$dir" -maxdepth 1 -type f -name "*.${suffix}" -print0 2>/dev/null | LC_ALL=C sort -z)
    return 0
  fi
  local old_nullglob
  old_nullglob=$(shopt -p nullglob || true)
  shopt -s nullglob
  for path in "$dir"/*."$suffix"; do
    id=$(basename "$path")
    id=${id%."$suffix"}
    printf '%s\n' "$id"
  done | LC_ALL=C sort
  eval "$old_nullglob" 2>/dev/null || true
}

# fm_prompt_stable_split_prefix_suffix <full-text-file> <volatile-marker-regex>
# Print two records to stdout as:
#   PREFIX_BYTES=<n>
#   SUFFIX_BYTES=<n>
#   PREFIX_SHA256=<hex>
#   SUFFIX_SHA256=<hex>
# The first line matching the extended regex starts the volatile suffix; when no
# line matches, the whole file is prefix.
fm_prompt_stable_split_stats() {
  local file=$1 marker_re=$2
  local prefix_file suffix_file line hit=0
  prefix_file=$(mktemp) || return 1
  suffix_file=$(mktemp) || { rm -f "$prefix_file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$hit" -eq 0 ] && printf '%s\n' "$line" | grep -E -q -- "$marker_re"; then
      hit=1
    fi
    if [ "$hit" -eq 1 ]; then
      printf '%s\n' "$line" >> "$suffix_file"
    else
      printf '%s\n' "$line" >> "$prefix_file"
    fi
  done < "$file"
  printf 'PREFIX_BYTES=%s\n' "$(wc -c < "$prefix_file" | tr -d ' ')"
  printf 'SUFFIX_BYTES=%s\n' "$(wc -c < "$suffix_file" | tr -d ' ')"
  if command -v shasum >/dev/null 2>&1; then
    printf 'PREFIX_SHA256=%s\n' "$(shasum -a 256 "$prefix_file" | awk '{print $1}')"
    printf 'SUFFIX_SHA256=%s\n' "$(shasum -a 256 "$suffix_file" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    printf 'PREFIX_SHA256=%s\n' "$(sha256sum "$prefix_file" | awk '{print $1}')"
    printf 'SUFFIX_SHA256=%s\n' "$(sha256sum "$suffix_file" | awk '{print $1}')"
  else
    printf 'PREFIX_SHA256=\n'
    printf 'SUFFIX_SHA256=\n'
  fi
  rm -f "$prefix_file" "$suffix_file"
}
