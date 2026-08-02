#!/usr/bin/env bash
# Render a backlog-format Markdown file as machine-readable TSV.
#
# The backlog format itself is owned by AGENTS.md section 10; this script only
# reads it. It accepts every item form that format allows - "- [ ] <id> ...",
# "- [x] <id> ...", and the bold in-flight "- **<id>** ..." - and it also reads
# data/done-archive.md, whose "## Archived <date>" sections carry the Done
# entries tasks-axi pruned out of the backlog.
#
# Usage: fm-backlog-tsv.sh <file> [<file>...]
#
# One row per item, columns:
#   1 state    in_flight | queued | done
#   2 id
#   3 title    the one-liner with trailing bookkeeping annotations stripped
#   4 link     the PR URL or report path recorded on a Done entry, else empty
#   5 blocked  comma-separated blocked-by ids, else empty
#   6 body     the indented note block with "\" and newlines backslash-escaped,
#              so one item is always exactly one line (decode with printf '%b')
#
# Later files never overwrite an id seen in an earlier file, so passing
# backlog.md before done-archive.md keeps the live entry authoritative.
set -eu

if [ $# -lt 1 ]; then
  echo "usage: fm-backlog-tsv.sh <file> [<file>...]" >&2
  exit 2
fi

for f in "$@"; do
  [ -f "$f" ] || continue
  cat "$f"
  printf '\n\036\n'   # a record separator guarantees the last item flushes
done | awk '
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

  # Drop the free-text tail the backlog format appends after the one-liner. A
  # hold reason can itself contain parentheses and the recorded link, so it goes
  # first and in one cut rather than by balanced-paren matching.
  function strip_tail(s) {
    sub(/[[:space:]]+\(hold[^\n]*$/, "", s)
    sub(/[[:space:]]+blocked-by:[^\n]*$/, "", s)
    return s
  }

  # Strip the trailing "(key: value)" / "(since <date>)" annotations. Only two
  # shapes exist in the format: colon-bearing keys, and bare date keys.
  function strip_annotations(s,   prev) {
    do {
      prev = s
      sub(/[[:space:]]*\((repo|kind|hold-kind):[^()]*\)[[:space:]]*$/, "", s)
      sub(/[[:space:]]*\((since|merged|reported|done|added)[^()]*\)[[:space:]]*$/, "", s)
    } while (s != prev)
    return s
  }

  # The one-liner with its recorded link and annotations removed. The link is
  # only ever stripped from the END, where the Done format puts it, so a path or
  # URL that is genuinely part of the sentence survives.
  function clean_title(s) {
    s = strip_annotations(strip_tail(s))
    sub(/[[:space:]]*-?[[:space:]]*(https?:\/\/[^[:space:]]+|data\/[^[:space:]]+\.md)[[:space:]]*$/, "", s)
    s = strip_annotations(s)
    sub(/[[:space:]]*-[[:space:]]*$/, "", s)
    return trim(s)
  }

  # The recorded link, matched only at the end of the one-liner (optionally
  # followed by its "(merged <date>)" style annotation).
  function item_link(s) {
    s = strip_annotations(strip_tail(s))
    if (match(s, /(https?:\/\/[^[:space:]]+|data\/[^[:space:]]+\.md)[[:space:]]*$/))
      return trim(substr(s, RSTART, RLENGTH))
    return ""
  }

  # Escape so one item is always exactly one TSV line: backslash first (so the
  # escapes below are unambiguous), then newline and tab.
  function esc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/\n/, "\\n", s)
    gsub(/\t/, " ", s)
    return s
  }

  function flush() {
    if (id != "" && !(id in seen)) {
      seen[id] = 1
      sub(/\n+$/, "", body)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", state, id, esc(title), link, blocked, esc(body)
    }
    id = ""; title = ""; link = ""; blocked = ""; body = ""
  }

  /^## / {
    flush()
    h = tolower(trim(substr($0, 4)))
    if (h ~ /^in flight/)      state = "in_flight"
    else if (h ~ /^queued/)    state = "queued"
    else if (h ~ /^done/)      state = "done"
    else if (h ~ /^archived/)  state = "done"
    else                       state = ""
    next
  }

  /^\036$/ { flush(); next }

  /^- / {
    flush()
    if (state == "") next
    line = substr($0, 3)
    # item id: "[ ] <id> - rest", "[x] <id> - rest", or "**<id>** - rest"
    if (line ~ /^\[[ xX]\][[:space:]]+/) {
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
    } else if (line ~ /^\*\*/) {
      sub(/^\*\*/, "", line)
      sub(/\*\*/, "", line)
    } else {
      next
    }
    if (match(line, /^[A-Za-z0-9._\/-]+/) == 0) next
    id = substr(line, 1, RLENGTH)
    rest = substr(line, RLENGTH + 1)
    sub(/^[[:space:]]*-[[:space:]]*/, "", rest)
    link = item_link(rest)
    blocked = ""
    tmp = rest
    while (match(tmp, /blocked-by:[[:space:]]*[A-Za-z0-9._\/-]+/)) {
      dep = substr(tmp, RSTART, RLENGTH)
      sub(/blocked-by:[[:space:]]*/, "", dep)
      blocked = (blocked == "" ? dep : blocked "," dep)
      tmp = substr(tmp, RSTART + RLENGTH)
    }
    title = clean_title(rest)
    body = ""
    next
  }

  {
    if (id == "") next
    if ($0 ~ /^[[:space:]]*$/) { if (body != "") body = body "\n"; next }
    if ($0 !~ /^[[:space:]][[:space:]]/) next
    l = $0
    sub(/^[[:space:]][[:space:]]/, "", l)
    body = (body == "" ? l : body "\n" l)
  }

  END { flush() }
'
