#!/usr/bin/env bash
# fm-learning-recurrence-lib.sh - shared counting helper for
# bin/fm-learning-recurrence.sh and its test. No side effects on source.

# introductions_for_path <repo> <path> <pattern>: prints one "<date> <sha>"
# line per commit whose diff adds a line matching the POSIX-ERE <pattern> to
# <path> in the git repository at <repo>, newest first (git's `--follow`
# only walks renames correctly in its default, newest-first order - combined
# with `--reverse` it silently stops after the first renamed revision, so
# this deliberately does not pass `--reverse`). Added lines whose content
# starts with '#' (source comments, never emitted to a worker) are excluded.
# A commit that touches the pattern on more than one line still counts once.
introductions_for_path() {
  local repo="$1" path="$2" pattern="$3"
  git -C "$repo" log --follow --format='@@COMMIT@@%H@@%ad' --date=short -p -- "$path" \
    | awk -v pat="$pattern" '
        /^@@COMMIT@@/ {
          split($0, parts, "@@")
          commit = parts[3]
          date = parts[4]
          next
        }
        /^\+/ && !/^\+\+\+/ {
          line = substr($0, 2)
          if (line ~ /^[ \t]*#/) next
          if (line ~ pat && !(commit in seen)) {
            seen[commit] = 1
            print date, commit
          }
        }
      '
}
