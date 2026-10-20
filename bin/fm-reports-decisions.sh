#!/usr/bin/env bash
# fm-reports-decisions.sh - collect this home's recorded captain decisions for
# the reports page.
#
# A decision is recorded where the work is recorded: in the task it gated. That
# makes an answer the captain gave weeks ago effectively unreachable, and it
# leaves a report describing work with no visible trace of the decision that
# allowed it. This command reads those records and prints them as one JSON
# object, which bin/fm-reports-page.sh renders into the page beside the report
# they belong to. bin/fm-reports-decisions.jq owns what counts as a decision and
# which report one belongs to.
#
# Usage:
#   fm-reports-decisions.sh collect
#
# collect    Print one JSON object on stdout:
#              {"sources": [{"name", "state", "note"}], "tasks": [group]}
#            The script's companion jq program documents a group's fields.
#
# TWO SOURCES, THE CONFIGURED STORE FIRST. The contract is to read through the
# configured backlog store, whatever store a home uses:
#   bin/fm-tasks-axi.sh list --fields body,links,hold_kind,hold_reason,closed
# That read is authoritative for every task the store still holds, and it is the
# only source that reports a live captain hold. It cannot be the only source,
# because it returns the living and the most recently finished tasks while most
# recorded decisions sit in the archive files the store has already rotated them
# into. Those files are read second and only fill what the store no longer has;
# a task reached both ways is merged, never shown twice.
#
# `list` abbreviates a long body, so every task it names is then read back with
# `show <id> --full` from that same store. The abbreviation is in the listing
# only, and a decision's text is exactly what lives past it.
#
# NO SOURCE IS REQUIRED AND NONE FAILS THE BUILD. A home on another backlog
# store, with no archive files, or with an unreadable .tasks.toml still gets its
# page; it simply shows fewer decisions or none. Every configured or default
# data source that should have contributed but could not is named in the
# `sources` array. A missing .tasks.toml is not such a source because its
# absence selects the default paths. Only a missing jq or an unusable home is
# refused, because then there is no output at all.
#
# THE HOME IS READ, NEVER WRITTEN. This command writes nothing inside the home;
# its staging file lives under TMPDIR and is removed on every path out.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROGRAM="$SCRIPT_DIR/fm-reports-decisions.jq"
TASKS_AXI="$SCRIPT_DIR/fm-tasks-axi.sh"

# One record of `show <id> --full` never contains a bare line: TOON keeps every
# value on its own `  key: value` line and escapes a line break inside a quoted
# value. So a line that is only this marker cannot come out of a task.
RECORD_MARK='@@fm-record@@'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-reports-decisions: %s\n' "$*" >&2
  exit 1
}

# A note about one source, as a compact JSON object on stdout.
note() {  # <name> <state> <note>
  jq -cn --arg name "$1" --arg state "$2" --arg note "$3" \
    '{name: $name, state: $state, note: $note}'
}

# One `key = "value"` out of .tasks.toml. The keys this command reads are unique
# across that whole file, so the table a key sits under does not have to be
# tracked; docs/configuration.md owns the schema.
toml_value() {  # <file> <key>
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" \
    | head -n 1
}

readable_file() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

# The staging directory is global rather than a local, because the EXIT trap
# that removes it fires after the function that made it has already returned.
STAGE=''
cleanup() { [ -z "$STAGE" ] || rm -rf -- "$STAGE"; }

command_collect() {
  local notes records files reports home toml backend backlog archive notearch
  local list ids id count missing name path
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -n "${FM_HOME:-}" ] || fail "FM_HOME is not set"
  [ -d "$FM_HOME" ] || fail "FM_HOME is not a directory: $FM_HOME"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$PROGRAM" ] && [ ! -L "$PROGRAM" ] || fail "program is missing: $PROGRAM"
  home=$FM_HOME

  trap cleanup EXIT
  STAGE=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-reports-decisions.XXXXXX") \
    || fail "cannot stage the collection"
  notes="$STAGE/notes.jsonl"
  records="$STAGE/records.toon"
  files="$STAGE/files.jsonl"
  : > "$notes"
  : > "$records"
  : > "$files"

  # --- the configured store, first -------------------------------------------
  if [ ! -x "$TASKS_AXI" ]; then
    note 'task store' 'missing' 'the command that reads the store is not here' >> "$notes"
  elif ! list=$("$TASKS_AXI" list --fields body,links,hold_kind,hold_reason,closed 2>/dev/null); then
    note 'task store' 'unreadable' 'the store could not be read' >> "$notes"
  else
    # The row count comes from the TOON header, and exactly that many following
    # lines are rows, so no prose line of a wrapped value can be mistaken for an
    # id. The id is a row's first field and never carries a comma.
    ids=$(printf '%s\n' "$list" | awk '
      !n && match($0, /^tasks\[[0-9]+\]\{/) {
        s = substr($0, RSTART + 6); sub(/\].*/, "", s); n = s + 0; next
      }
      n && seen < n { seen++; sub(/^  /, ""); sub(/,.*$/, ""); print }
    ')
    count=0
    missing=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if "$TASKS_AXI" show "$id" --full 2>/dev/null >> "$records"; then
        count=$((count + 1))
        printf '%s\n' "$RECORD_MARK" >> "$records"
      else
        missing=$((missing + 1))
      fi
    done <<< "$ids"
    if [ "$missing" -gt 0 ]; then
      note 'task store' 'partial' \
        "$count tasks read, $missing unreadable" >> "$notes"
    else
      note 'task store' 'ok' "$count tasks" >> "$notes"
    fi
  fi

  # --- the archive files, second ---------------------------------------------
  toml="$home/.tasks.toml"
  backend=markdown
  backlog='data/backlog.md'
  archive='data/done-archive.md'
  if readable_file "$toml"; then
    backend=$(toml_value "$toml" backend)
    [ -n "$backend" ] || backend=markdown
    path=$(toml_value "$toml" path); [ -z "$path" ] || backlog=$path
    path=$(toml_value "$toml" archive); [ -z "$path" ] || archive=$path
  elif [ -e "$toml" ]; then
    note 'store configuration' 'unreadable' \
      '.tasks.toml could not be read, the default paths apply' >> "$notes"
  fi

  if [ "$backend" != markdown ]; then
    note 'store files' 'skipped' \
      "the store runs on $backend, so there are no markdown files to read" >> "$notes"
  else
    notearch='data/note-archive.md'
    for name in "$backlog" "$archive" "$notearch"; do
      case "$name" in
        /*) path=$name ;;
        *) path="$home/$name" ;;
      esac
      if ! readable_file "$path"; then
        if [ -e "$path" ]; then
          note "$name" 'unreadable' 'present, but could not be read' >> "$notes"
        else
          note "$name" 'absent' 'not present in this home' >> "$notes"
        fi
        continue
      fi
      if ! jq -cn --arg source "$name" --rawfile text "$path" \
           '{source: $source, text: $text}' >> "$files"; then
        fail "cannot stage $name"
      fi
      note "$name" 'ok' 'read' >> "$notes"
    done
  fi

  # --- the reports that exist, for assigning a decision to one ---------------
  reports=$(
    for path in "$home"/data/*; do
      [ -d "$path" ] && [ ! -L "$path" ] || continue
      id=${path%/}; id=${id##*/}
      readable_file "$path/report.md" || continue
      printf '%s\n' "$id"
    done | jq -Rsc 'split("\n") | map(select(. != ""))'
  ) || fail "cannot list this home's reports"

  # One JSON string per record, so --slurpfile reads them as an array.
  jq -Rs --arg mark "$RECORD_MARK" \
    'split("\n" + $mark + "\n")[] | select(test("(?m)^  id: "))' "$records" \
    > "$STAGE/records.jsonl" || fail "cannot read the store records"

  jq -c -f "$PROGRAM" -n \
    --slurpfile notes "$notes" \
    --slurpfile files "$files" \
    --slurpfile store "$STAGE/records.jsonl" \
    --argjson reports "$reports" \
    || fail "cannot assemble the decisions"
}

case "${1-}" in
  collect) shift; command_collect "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
