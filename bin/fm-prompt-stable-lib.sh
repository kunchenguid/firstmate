#!/usr/bin/env bash
# fm-prompt-stable-lib.sh - shared helpers for cache-stable Firstmate renders.
#
# Prompt-cache reuse requires exact prefix matches. Firstmate-controlled digests
# and instruction blocks must therefore:
#   1. emit static sections in a fixed order,
#   2. list multi-entry state with deterministic (LC_ALL=C) id order,
#   3. keep volatile runtime observations after all stable material in the block.
#
# This library owns only the shared listing/ordering primitive. Each caller owns
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
