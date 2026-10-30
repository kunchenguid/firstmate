# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies.

# The line rules every brief reader shares, as awk functions. brief_scan_line
# strips up to three leading spaces into `scan` and tracks fences: `is_fence`
# is any fence-shaped line, `was_fenced` says the line began inside a fence, and
# a fence closes only on the same marker, at least as long, with nothing after
# it. brief_closes_section says `scan` is a heading at <level> or higher.
# shellcheck disable=SC2016  # an awk program, expanded by awk, not the shell
FM_BRIEF_LINE_AWK='
  function brief_scan_line(line,    spaces, marker, marker_len, rest) {
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
  }
  function brief_heading_level(heading,    level) {
    level = 0
    while (substr(heading, level + 1, 1) == "#") level++
    return level
  }
  function brief_closes_section(target_level,    level) {
    level = brief_heading_level(scan)
    return level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/
  }
'

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
  awk -v heading="$heading" -v mode="$mode" "$FM_BRIEF_LINE_AWK"'
    BEGIN { target_level = brief_heading_level(heading) }
    {
      line = $0
      brief_scan_line(line)

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

      if (brief_closes_section(target_level)) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

# Print <file> with the heading's whole section, heading included, replaced by
# the contents of <section-file>; a blank line separates it from what follows.
fm_brief_heading_replace() {  # <file> <heading> <section-file>
  awk -v heading="$2" -v section_file="$3" "$FM_BRIEF_LINE_AWK"'
    BEGIN {
      target_level = brief_heading_level(heading)
      while ((getline l < section_file) > 0) section = section l "\n"
    }
    {
      brief_scan_line($0)
      if (!replaced && !was_fenced && $0 == heading) {
        printf "%s", section
        replaced = 1
        skipping = 1
        next
      }
      if (skipping && !is_fence && !was_fenced && brief_closes_section(target_level)) {
        skipping = 0
        print ""
      }
      if (!skipping) print
    }
  ' "$1"
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

