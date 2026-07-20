#!/usr/bin/env bash
# Shared generated-section helpers for firstmate open-work backlog refreshes.
# Sourced by shell scripts; no side effects on source. set -u / set -e safe.

FM_BACKLOG_PULL_START_MARKER="<!-- fm-backlog-pull:generated:start -->"
FM_BACKLOG_PULL_END_MARKER="<!-- fm-backlog-pull:generated:end -->"

fm_backlog_replace_generated_section() { # <out> <generated> <merged> [default-title]
  local out=$1 generated=$2 merged=$3 title=${4:-Firstmate Backlog} out_dir
  out_dir=$(dirname "$out")
  mkdir -p "$out_dir"

  if [ -f "$out" ] && grep -Fxq "$FM_BACKLOG_PULL_START_MARKER" "$out" && grep -Fxq "$FM_BACKLOG_PULL_END_MARKER" "$out"; then
    awk -v start="$FM_BACKLOG_PULL_START_MARKER" -v end="$FM_BACKLOG_PULL_END_MARKER" -v gen="$generated" '
      $0 == start {
        while ((getline line < gen) > 0) print line
        close(gen)
        skip = 1
        next
      }
      $0 == end {
        skip = 0
        next
      }
      !skip { print }
    ' "$out" > "$merged"
  elif [ -f "$out" ]; then
    {
      cat "$out"
      printf '\n'
      cat "$generated"
    } > "$merged"
  else
    {
      printf '# %s\n\n' "$title"
      cat "$generated"
    } > "$merged"
  fi

  mv "$merged" "$out"
}
