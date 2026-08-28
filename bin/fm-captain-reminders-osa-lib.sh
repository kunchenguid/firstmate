# shellcheck shell=bash
# fm-captain-reminders-osa-lib.sh - the Reminders side of the captain-call
# projection: every AppleScript it runs and every bound around them.
# Usage: . bin/fm-captain-reminders-osa-lib.sh
#
# Sourced, never executed. This is the only place in the repo that talks to the
# Reminders app, so the vendor surface is contained: three verbs, each a whole
# AppleScript, each bounded, each reporting failure in words a captain can act
# on. bin/fm-captain-reminders.sh decides WHAT to project and owns the operator
# contract; this file only carries it out.
#
# The caller must set WORK_DIR to a private directory, TIMEOUT_SECS to a
# positive bound, REMINDERS_EXEC to the test seam or the empty string, and
# provide a `note` reporter, so diagnostics reach the operator the same way the
# rest of the command's output does.
#
# ONE APPLE EVENT PER PHASE-ATTRIBUTE, NEVER ONE PER ENTRY. Talking to the
# Reminders app costs on the order of a second per Apple Event, and that cost is
# almost independent of how much the event carries. A verb that read `body of r`
# in a loop, or that ran one `whose` query per record, therefore cost seconds PER
# ENTRY and blew the operator's deadline on an ordinary list - which on this path
# means the captain silently stops being told what is waiting on him. So every
# verb reads whole columns at once, decides locally, and writes through a single
# predicate; and the two write verbs are BATCH verbs that take every record of
# their phase in one argv item. The number of processes AND the number of Apple
# Events are both fixed per phase, not per entry.
#
# THE MARKER IS ENFORCED HERE. Every verb selects on the `[fm:<task-id>]` body,
# because the captain-facing sentence owns the front of the note
# (bin/fm-captain-reminders-lib.sh) - `list` and `detail` report only entries
# carrying it, and `upsert-batch` and `complete-batch` can only reach entries
# carrying it - so no instruction from above can touch a reminder the captain
# wrote himself. Every write is addressed by a `whose` predicate that names the
# marker, never by a row index this script resolved earlier, so a stale index
# cannot reach another reminder. A `complete-batch` record may also name a
# specific reminder id, and that id is honored ONLY among entries already
# matching the marker, so an id from anywhere else selects nothing. Matching
# accepts the marker at EITHER end of the body - the SUFFIX this version writes,
# or the PREFIX an entry created by a previous version of this script carries -
# so those older entries keep matching until `upsert-batch` rewrites them to the
# suffix form on their next sync; only the suffix form is ever written.
#
# `list <list-name>` reports one TAB-separated record per marked open entry, in
# list order:
#   <task-id>  <title>  <note>
# so a task id appearing twice IS the duplicate signal, and the title and note
# are there so the CALLER can decide what each entry needs without the app being
# asked a second time. Two column reads.
#
# `detail <list-name>` reports one TAB-separated record per marked open entry:
#   <task-id>  <reminder-id>  <has-due 0|1>  <age-seconds>
# where age is relative to the moment of the read, so it is negative and more
# negative means older. Reporting the reminder identity, its alert state, and its
# age is what lets the caller decide which of several entries sharing a marker to
# keep - that choice is deliberately made above this file, where it is testable
# without a Reminders app. It costs four column reads, so the caller asks for it
# only once `list` has shown a marker repeating.
#
# `upsert-batch <list-name> <payload>` takes
# `<task-id> <create|update> <title> <note> <due0|1>` records and answers
# `<task-id>TAB<created|updated>` per record. It performs no read of its own:
# which entries need creating and which need rewriting was already decided above
# this file from the `list` answer, so this verb spends Apple Events only on
# entries that actually change. An entry that needs nothing is simply not sent.
#
# `complete-batch <list-name> <payload>` takes `<task-id> <reminder-id>` records
# - a reminder id of `-` means every entry carrying that marker - and answers
# `<task-id>TAB<ok>` per record. It performs no read either: the marker lives in
# the write predicate, so the entries that must be ticked off can be named
# without asking the app which ones they are.
#
# BATCH WIRE FORMAT. One argv item carries the whole payload, because argv is
# the only channel the bounded runner's backgrounded child shares with its
# caller. Records are separated by ASCII RS (U+001E) and fields within a record
# by ASCII US (U+001F). Neither byte can occur inside a payload: every title and
# note passes through fm_reminders_one_line, which strips the whole C0 range,
# and a task id is a slug. Each verb answers with one line per INPUT record, in
# input order, so the caller maps results back by position without parsing
# content - and a run cut short mid-batch is visible as missing trailing lines
# rather than as a wrong answer.
#
# No field is ever empty, which is why `-` rather than the empty string means
# "every entry with this marker": the caller reads the answers back with TAB as
# the shell field separator, and the shell collapses runs of TAB, so an empty
# field would silently shift every field after it.
# shellcheck disable=SC2034  # both separators are read by the sourcing script.
FM_OSA_RS=$'\036'
FM_OSA_US=$'\037'

# One AppleScript per verb, materialized on demand. A file path rather than
# stdin because the bounded runner backgrounds its child, and a backgrounded
# child's stdin is not the caller's.
osa_file() {  # <verb>
  local verb=$1 path
  path="$WORK_DIR/$verb.applescript"
  [ -f "$path" ] || osa_source "$verb" > "$path"
  printf '%s\n' "$path"
}

osa_source() {  # <verb>
  case "$1" in
    list)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set bodies to {}
	set names to {}
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then return ""
		tell list listName
			-- ONE APPLE EVENT PER COLUMN, NEVER ONE PER REMINDER, AND ONLY THE
			-- COLUMNS THIS ANSWER NEEDS. Reading `body of r` inside a repeat
			-- costs seconds PER REMINDER against a real Reminders app, and even
			-- a whole-column read costs a second or two of its own, so this is
			-- deliberately two reads and no more: with the marker, the title,
			-- and the note in hand, the caller can decide what every entry
			-- needs without the app being asked again.
			set bodies to body of (every reminder whose completed is false)
			set names to name of (every reminder whose completed is false)
		end tell
	end tell
	set found to {}
	repeat with i from 1 to (count of bodies)
		set t to my markerId(item i of bodies)
		if t is not "" then
			set end of found to (t & tab & my oneLine(item i of names) & tab & my oneLine(item i of bodies))
		end if
	end repeat
	set AppleScript's text item delimiters to linefeed
	set out to found as text
	set AppleScript's text item delimiters to ""
	return out
end run

on markerId(b)
	try
		set s to b as text
	on error
		return ""
	end try
	if (count of s) < 6 then return ""
	if s ends with "]" then
		set AppleScript's text item delimiters to "[fm:"
		set parts to text items of s
		set AppleScript's text item delimiters to ""
		if (count of parts) < 2 then return ""
		set tailPart to item (count of parts) of parts
		if (count of tailPart) < 2 then return ""
		return text 1 thru -2 of tailPart
	end if
	if s starts with "[fm:" then
		set AppleScript's text item delimiters to "]"
		set parts to text items of s
		set AppleScript's text item delimiters to ""
		if (count of parts) < 2 then return ""
		set headPart to item 1 of parts
		if (count of headPart) < 5 then return ""
		return text 5 thru -1 of headPart
	end if
	return ""
end markerId

-- The answer is TAB-separated and one record per line, so a stray control
-- character in a title or note would split the record rather than travel in it.
-- Only this projection writes these entries and it writes one clean line
-- (bin/fm-captain-reminders-lib.sh), so squeezing here just means an entry that
-- somehow holds one reads as differing and is rewritten clean on this pass.
on oneLine(v)
	try
		set s to (v as text)
	on error
		return ""
	end try
	set AppleScript's text item delimiters to {tab, return, linefeed}
	set parts to text items of s
	set AppleScript's text item delimiters to " "
	set s to parts as text
	set AppleScript's text item delimiters to ""
	return s
end oneLine
APPLESCRIPT
      ;;
    detail)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set bodies to {}
	set ids to {}
	set dues to {}
	set births to {}
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then return ""
		tell list listName
			-- Four whole-column reads, each its own Apple Event, because
			-- deciding which of several entries sharing a marker survives is
			-- the one job that needs to tell them apart. `list` answers every
			-- other pass with one column, so this cost is only paid when a
			-- marker actually repeats.
			set bodies to body of (every reminder whose completed is false)
			set ids to id of (every reminder whose completed is false)
			set dues to due date of (every reminder whose completed is false)
			set births to creation date of (every reminder whose completed is false)
		end tell
	end tell
	set rightNow to current date
	set found to {}
	repeat with i from 1 to (count of bodies)
		set t to my markerId(item i of bodies)
		if t is not "" then
			set hasDue to "0"
			if (item i of dues) is not missing value then set hasDue to "1"
			set age to (((item i of births) - rightNow) as integer)
			set end of found to (t & tab & ((item i of ids) as text) & tab & hasDue & tab & (age as text))
		end if
	end repeat
	set AppleScript's text item delimiters to linefeed
	set out to found as text
	set AppleScript's text item delimiters to ""
	return out
end run

on markerId(b)
	try
		set s to b as text
	on error
		return ""
	end try
	if (count of s) < 6 then return ""
	if s ends with "]" then
		set AppleScript's text item delimiters to "[fm:"
		set parts to text items of s
		set AppleScript's text item delimiters to ""
		if (count of parts) < 2 then return ""
		set tailPart to item (count of parts) of parts
		if (count of tailPart) < 2 then return ""
		return text 1 thru -2 of tailPart
	end if
	if s starts with "[fm:" then
		set AppleScript's text item delimiters to "]"
		set parts to text items of s
		set AppleScript's text item delimiters to ""
		if (count of parts) < 2 then return ""
		set headPart to item 1 of parts
		if (count of headPart) < 5 then return ""
		return text 5 thru -1 of headPart
	end if
	return ""
end markerId
APPLESCRIPT
      ;;
    upsert-batch)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set recs to my splitText(item 2 of argv, (character id 30))
	set tb to tab
	set outs to {}
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then
			make new list with properties {name:listName}
		end if
		tell list listName
			-- No read at all: the caller already read this list through `list`
			-- and decided what each record needs, so this verb only writes.
			-- Every Apple Event saved here is a second the projection keeps.
			repeat with rec in recs
				set f to my splitText(rec as text, (character id 31))
				if (count of f) is 5 then
					set tid to item 1 of f
					set act to item 2 of f
					set nm to item 3 of f
					set bd to item 4 of f
					set wantDue to ((item 5 of f) is "1")
					set mk to "[fm:" & tid & "]"
					set outcome to ""
					if act is "create" then
						if wantDue then
							set alertTime to current date
							make new reminder with properties {name:nm, body:bd, due date:alertTime, remind me date:alertTime}
						else
							make new reminder with properties {name:nm, body:bd}
						end if
						set outcome to "created"
					else if act is "update" then
						-- Addressed by the marker, and by nothing else. This
						-- verb never resolved a row of its own, so there is no
						-- index that could have gone stale and pointed at a
						-- reminder the captain wrote himself.
						set properties of (every reminder whose completed is false and (body ends with mk or body starts with mk)) to {name:nm, body:bd}
						set outcome to "updated"
					end if
					if outcome is not "" then set end of outs to (tid & tb & outcome)
				end if
			end repeat
		end tell
	end tell
	return my joinLines(outs)
end run

on splitText(t, sep)
	set AppleScript's text item delimiters to sep
	set parts to text items of (t as text)
	set AppleScript's text item delimiters to ""
	return parts
end splitText

on joinLines(items_)
	set AppleScript's text item delimiters to linefeed
	set out to items_ as text
	set AppleScript's text item delimiters to ""
	return out
end joinLines
APPLESCRIPT
      ;;
    complete-batch)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set recs to my splitText(item 2 of argv, (character id 30))
	set tb to tab
	set outs to {}
	tell application "Reminders"
		-- A missing list is not an error here: nothing marked can exist in it,
		-- so every record is simply answered without a write.
		set haveList to ((count of (lists whose name is listName)) is not 0)
		repeat with rec in recs
			set f to my splitText(rec as text, (character id 31))
			if (count of f) is 2 then
				set tid to item 1 of f
				set rid to item 2 of f
				set mk to "[fm:" & tid & "]"
				if haveList then
					-- No read of its own, and one event per record: the marker
					-- lives inside the predicate rather than in an index this
					-- script resolved, so a named reminder id can still only
					-- ever reach an entry carrying that marker.
					tell list listName
						if rid is "-" then
							set completed of (every reminder whose completed is false and (body ends with mk or body starts with mk)) to true
						else
							set completed of (every reminder whose completed is false and id is rid and (body ends with mk or body starts with mk)) to true
						end if
					end tell
				end if
				set end of outs to (tid & tb & "ok")
			end if
		end repeat
	end tell
	return my joinLines(outs)
end run


on splitText(t, sep)
	set AppleScript's text item delimiters to sep
	set parts to text items of (t as text)
	set AppleScript's text item delimiters to ""
	return parts
end splitText

on joinLines(items_)
	set AppleScript's text item delimiters to linefeed
	set out to items_ as text
	set AppleScript's text item delimiters to ""
	return out
end joinLines
APPLESCRIPT
      ;;
    *) return 1 ;;
  esac
}

# One Reminders step. The verb's own output lands in OSA_OUT rather than on
# stdout, because a step that fails has a diagnostic to print and a caller that
# captured this in a command substitution would swallow exactly that.
OSA_OUT=
OSA_TIMED_OUT=0
OSA_TIMEOUT_SECS=
# shellcheck disable=SC2034  # OSA_OUT and OSA_TIMED_OUT are read by the sourcing script.
osa() {  # <verb> <args...>; sets OSA_OUT
  local verb=$1 rc err out timeout
  shift
  err="$WORK_DIR/stderr"
  out="$WORK_DIR/stdout"
  : > "$err"
  : > "$out"
  OSA_OUT=
  OSA_TIMED_OUT=0
  timeout=${OSA_TIMEOUT_SECS:-$TIMEOUT_SECS}
  case "$timeout" in ''|*[!0-9]*|0) timeout=$TIMEOUT_SECS ;; esac
  if [ -n "$REMINDERS_EXEC" ]; then
    fm_run_timed "$timeout" "$REMINDERS_EXEC" "$verb" "$@" >"$out" 2>"$err"
  else
    fm_run_timed "$timeout" osascript "$(osa_file "$verb")" "$@" >"$out" 2>"$err"
  fi
  rc=$?
  OSA_OUT=$(cat "$out" 2>/dev/null || true)
  [ "$rc" -eq 0 ] && return 0
  OSA_OUT=
  [ "$rc" -ne 124 ] || OSA_TIMED_OUT=1
  osa_diagnose "$verb" "$rc" "$err" "$timeout"
  return 1
}

# Say what the captain can act on. An AppleScript error number is not that.
osa_diagnose() {  # <verb> <rc> <stderr-file> <timeout-seconds>
  local verb=$1 rc=$2 text timeout=$4
  text=$(tr '\n' ' ' < "$3" 2>/dev/null | cut -c1-300)
  if [ "$rc" -eq 124 ]; then
    note "the Reminders step '$verb' hit its ${timeout}s bound and was abandoned."
    note "if macOS is waiting on a first-time automation prompt, approve it in System Settings > Privacy & Security > Automation (allow this terminal to control Reminders), then run this command again."
    return 0
  fi
  case "$text" in
    *-1743*|*"Not authorized"*|*"not authorised"*)
      note "macOS has not authorized this terminal to control Reminders; nothing was projected."
      note "approve it in System Settings > Privacy & Security > Automation (allow this terminal to control Reminders), then run this command again."
      return 0
      ;;
  esac
  note "the Reminders step '$verb' failed (exit $rc)${text:+: $text}"
}
