# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies.

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" body <<<"$task"
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" present >/dev/null <<<"$task"
}

# The four task fields a ship or scout brief must carry, in the order they
# appear under `# Task`. bin/fm-brief.sh scaffolds each as a required section
# with a fill placeholder; bin/fm-spawn.sh and bin/fm-promote.sh refuse a
# brief whose field is missing, empty, or still a placeholder. This list is
# the single owner of the field set and of the placeholder each field carries.
FM_BRIEF_TASK_FIELDS="## Acceptance criteria|{ACCEPTANCE_CRITERIA}
## Verification path|{VERIFICATION_PATH}
## Required artifact|{REQUIRED_ARTIFACT}
## Out of scope|{OUT_OF_SCOPE}"

# Print the heading of one field, given its "heading|placeholder" token.
fm_brief_task_field_heading() {  # <token>
  printf '%s' "${1%%|*}"
}

# Print the placeholder of one field, given its "heading|placeholder" token.
fm_brief_task_field_placeholder() {  # <token>
  printf '%s' "${1##*|}"
}

# Print the first field that is absent, empty, or still its placeholder.
#
# A brief that carries none of the four field sections predates the contract
# and stays valid, so a task dispatched before the contract landed can still
# be relaunched or recovered. A brief that carries any of them is a brief
# under the contract, and must carry and fill all four: a removed section is
# as unfilled as an untouched placeholder.
fm_brief_task_field_unfilled() {  # <file>
  local file=$1 token heading placeholder body present=0
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    heading=$(fm_brief_task_field_heading "$token")
    if fm_brief_task_heading_present "$file" "$heading"; then
      present=$((present + 1))
    fi
  done <<<"$FM_BRIEF_TASK_FIELDS"
  [ "$present" -gt 0 ] || return 1
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    heading=$(fm_brief_task_field_heading "$token")
    placeholder=$(fm_brief_task_field_placeholder "$token")
    if ! fm_brief_task_heading_present "$file" "$heading"; then
      printf '%s' "$heading"
      return 0
    fi
    body=$(fm_brief_task_heading_body "$file" "$heading")
    if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
      printf '%s' "$heading"
      return 0
    fi
    if [ "$(printf '%s' "$body" | tr -d '[:space:]')" = "$placeholder" ]; then
      printf '%s' "$heading"
      return 0
    fi
  done <<<"$FM_BRIEF_TASK_FIELDS"
  return 1
}

