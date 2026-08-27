# shellcheck shell=bash
# fm-captain-reminders-lib.sh - what the captain-reminders projection should
# contain, derived from the backlog alone.
# Usage: . bin/fm-captain-reminders-lib.sh
#
# Sourced, never executed. This half deliberately knows nothing about Reminders,
# AppleScript, or macOS: it answers "which captain calls exist right now, and
# what should each one read like", so that question stays testable on a host
# with no Reminders app at all. bin/fm-captain-reminders.sh owns the projection
# itself and every osascript call.
#
# The backlog is read through bin/fm-tasks-show-lib.sh, the same path
# bin/fm-captain-hold.sh reads, so there is no second understanding of what
# "held for the captain" looks like.

# The list name used when config/captain-reminders is present but empty.
FM_REMINDERS_DEFAULT_LIST=Firstmate

# How much of a hold reason a note carries. A reason is a one-line summary by
# the tasks-axi hold contract, so this bound is a guard against an unusually
# long one rather than a routine cut; when it fires the note says so instead of
# silently ending mid-sentence.
FM_REMINDERS_NOTE_LIMIT=900

FM_REMINDERS_TRUNCATION_NOTICE=' [truncated - the full reason is on the task]'

# Collapse to one clean line: a note and a reminder title are both single-line
# surfaces, and a stray tab would also split this library's own TAB-separated
# output.
fm_reminders_one_line() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

# The configured target list, or nonzero when this home has not opted in.
# Presence of the file IS the switch; its content, trimmed, is the list name.
fm_reminders_list_name() {  # <config-dir>
  local file=$1/captain-reminders name
  [ -f "$file" ] || return 1
  name=$(fm_reminders_one_line "$(head -1 "$file" 2>/dev/null || true)")
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || name=$FM_REMINDERS_DEFAULT_LIST
  printf '%s\n' "$name"
}

# The note body for one captain call. The leading `[fm:<id>]` marker is what
# makes the projection idempotent and what bounds it: bin/fm-captain-reminders.sh
# reads, updates, and completes ONLY entries carrying it, so a reminder the
# captain wrote by hand is never matched, changed, or completed.
fm_reminders_note() {  # <task-id> <reason>
  local id=$1 reason
  reason=$(fm_reminders_one_line "$2")
  if [ "${#reason}" -gt "$FM_REMINDERS_NOTE_LIMIT" ]; then
    reason="${reason:0:$FM_REMINDERS_NOTE_LIMIT}$FM_REMINDERS_TRUNCATION_NOTICE"
  fi
  printf '[fm:%s] %s\n' "$id" "$reason"
}

# The task id a note claims, or nonzero for any note this projection must not
# touch. Deliberately strict: an id that is not a privacy-safe slug is treated
# as unmarked rather than repaired.
fm_reminders_marker_id() {  # <note>
  local note=$1 id
  case "$note" in
    '[fm:'*']'*) ;;
    *) return 1 ;;
  esac
  id=${note#'[fm:'}
  id=${id%%']'*}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Every captain call this home is currently holding, one `<id>TAB<title>TABnote`
# record per line, in backlog order. This is the whole data source of the
# projection: `held=yes` plus `hold_kind=captain`, nothing inferred from prose.
fm_reminders_desired() {
  local id show title reason
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(fm_task_show "$id") || continue
    [ "$(fm_show_field "$show" held)" = yes ] || continue
    [ "$(fm_show_field_value "$show" hold_kind)" = captain ] || continue
    title=$(fm_reminders_one_line "$(fm_show_field_value "$show" title)")
    [ -n "$title" ] || title=$id
    reason=$(fm_show_field_value "$show" hold_reason)
    printf '%s\t%s\t%s\n' "$id" "$title" "$(fm_reminders_note "$id" "$reason")"
  done <<EOF
$(fm_open_task_ids --state held)
EOF
}
