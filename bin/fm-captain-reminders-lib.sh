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

FM_REMINDERS_TRUNCATION_NOTICE=' [已截断，请回到 Firstmate 会话查看完整原因]'

# Collapse to one clean line: a note and a reminder title are both single-line
# surfaces, and a stray tab would also split this library's own TAB-separated
# output.
fm_reminders_one_line() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

# The configured target list. Presence of the file IS the switch; its content,
# trimmed, is the list name, and an empty file selects the default.
#
# Three outcomes, deliberately distinct:
#   0  the list name, on stdout
#   1  no such file - this home never opted in
#   2  the file exists but could not be read
# An unreadable file is not an empty one. Collapsing the two would silently file
# the captain's hold reasons into the default list instead of the one he chose,
# which on a synced account means publishing them somewhere he is not looking.
fm_reminders_list_name() {  # <config-dir>
  local file=$1/captain-reminders name
  [ -f "$file" ] || return 1
  name=$(head -1 "$file" 2>/dev/null) || return 2
  name=$(fm_reminders_one_line "$name")
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || name=$FM_REMINDERS_DEFAULT_LIST
  printf '%s\n' "$name"
}

# The note body for one captain call, written for the captain rather than for
# this script: the sentence the captain has to read comes first and the
# `[fm:<id>]` marker sits at the very end, because the note is what a phone
# shows under the title and a machine tag in that position was the first thing
# he read every time.
#
# The marker keeps both of its jobs from that tail position: it is how a rerun
# recognizes what it already created, and it is the hard limit on what this
# projection may touch - bin/fm-captain-reminders.sh reads, updates, and
# completes ONLY entries carrying it, so a reminder the captain wrote by hand is
# never matched, changed, or completed. Only the tail placement is written now;
# fm_reminders_marker_id still reads a leading placement too, because an entry
# a previous version of this script wrote that way must keep matching until the
# next sync rewrites it to this form.
#
# The optional project name is appended before the marker, so one glance answers
# "where" as well as "what", without the caller having to write it into every
# hold reason.
fm_reminders_note() {  # <task-id> <reason> [project]
  local id=$1 reason project
  reason=$(fm_reminders_one_line "$2")
  if [ "${#reason}" -gt "$FM_REMINDERS_NOTE_LIMIT" ]; then
    reason="${reason:0:$FM_REMINDERS_NOTE_LIMIT}$FM_REMINDERS_TRUNCATION_NOTICE"
  fi
  # A call with no recorded reason still has to say what it wants from him.
  [ -n "$reason" ] || reason='等你定夺，具体情况回 Firstmate 会话看。'
  project=$(fm_reminders_one_line "${3:-}")
  [ -z "$project" ] || reason="${reason}（项目：${project}）"
  printf '%s [fm:%s]\n' "$reason" "$id"
}

# The task id a note claims, or nonzero for any note this projection must not
# touch. Deliberately strict: an id that is not a privacy-safe slug is treated
# as unmarked rather than repaired. fm_reminders_note now puts the marker at
# the tail, but a note written by a version of this script before that change
# carries it at the head instead, so both placements are recognized when
# reading - an entry that version created must keep working here rather than
# being treated as unmarked and orphaned. Only the tail placement is written.
fm_reminders_marker_id() {  # <note>
  local note=$1 id
  case "$note" in
    *'[fm:'*']')
      id=${note%']'}
      id=${id##*'[fm:'}
      case "$id" in
        ''|*[!A-Za-z0-9._-]*) ;;
        *) printf '%s\n' "$id"; return 0 ;;
      esac
      ;;
  esac
  case "$note" in
    '[fm:'*']'*)
      id=${note#'[fm:'}
      id=${id%%']'*}
      case "$id" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      printf '%s\n' "$id"
      return 0
      ;;
  esac
  return 1
}

# Every unresolved captain call that is due now, one `<id>TAB<title>TABnote`
# record per line, in backlog order. Captain-hold annotations survive a date
# gate, so a future hold_until defers the entry and the live held bit is not the
# ownership test.
fm_reminders_desired() {
  local ids id show state hold_kind hold_until title reason project today raw rc
  ids=$(fm_open_task_ids) || { rc=$?; return "$rc"; }
  today=$(date +%F) || return 1
  case "$today" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(fm_task_show "$id") || { rc=$?; return "$rc"; }
    state=$(fm_show_field "$show" state)
    case "$state" in queued|in_flight) ;; done) continue ;; *) return 1 ;; esac
    raw=$(fm_show_field "$show" hold_kind)
    [ -n "$raw" ] || return 1
    hold_kind=$(fm_decode_shown_value "$raw") || return 1
    [ "$hold_kind" = captain ] || continue
    raw=$(fm_show_field "$show" hold_until)
    [ -n "$raw" ] || return 1
    hold_until=$(fm_decode_shown_value "$raw") || return 1
    [ "$hold_until" != '-' ] || hold_until=''
    if [ -n "$hold_until" ]; then
      case "$hold_until" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
      [[ "$hold_until" > "$today" ]] && continue
    fi
    raw=$(fm_show_field "$show" title)
    [ -n "$raw" ] || return 1
    title=$(fm_decode_shown_value "$raw") || return 1
    title=$(fm_reminders_one_line "$title") || return 1
    # Never fall back to the task id: the id is exactly the internal spelling
    # this surface must not put in front of the captain.
    [ -n "$title" ] || title='一件等你处理的事'
    raw=$(fm_show_field "$show" hold_reason)
    [ -n "$raw" ] || return 1
    reason=$(fm_decode_shown_value "$raw") || return 1
    [ "$reason" != '-' ] || reason=''
    # The project is context, not identity: an older record that never carried
    # one simply projects without it rather than failing the whole snapshot.
    project=$(fm_show_field_value "$show" repo)
    printf '%s\t%s\t%s\n' "$id" "$title" "$(fm_reminders_note "$id" "$reason" "$project")"
  done <<EOF
$ids
EOF
}
