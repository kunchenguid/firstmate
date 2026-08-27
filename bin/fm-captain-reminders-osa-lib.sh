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
# THE MARKER IS ENFORCED HERE. `upsert` and `complete` select by the
# `[fm:<task-id>]` body prefix and `list` reports only entries carrying it, so no
# instruction from above can reach a reminder the captain wrote himself.

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
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then return ""
		tell list listName
			set bodies to body of (every reminder whose completed is false)
		end tell
	end tell
	set found to {}
	repeat with b in bodies
		set t to my markerId(b)
		if t is not "" then set end of found to t
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
	if (text 1 thru 4 of s) is not "[fm:" then return ""
	set o to offset of "]" in s
	if o < 6 then return ""
	return text 5 thru (o - 1) of s
end markerId
APPLESCRIPT
      ;;
    upsert)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set pfx to "[fm:" & (item 2 of argv) & "]"
	set nm to item 3 of argv
	set bd to item 4 of argv
	set wantDue to ((item 5 of argv) is "1")
	set outcome to "unchanged"
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then
			make new list with properties {name:listName}
		end if
		tell list listName
			set matches to (every reminder whose completed is false and body begins with pfx)
			if (count of matches) is 0 then
				set r to make new reminder with properties {name:nm, body:bd}
				if wantDue then
					set due date of r to (current date)
					try
						set remind me date of r to (current date)
					end try
				end if
				set outcome to "created"
			else
				set r to item 1 of matches
				if (name of r as text) is not nm then
					set name of r to nm
					set outcome to "updated"
				end if
				if (body of r as text) is not bd then
					set body of r to bd
					set outcome to "updated"
				end if
			end if
		end tell
	end tell
	return outcome
end run
APPLESCRIPT
      ;;
    complete)
      cat <<'APPLESCRIPT'
on run argv
	set listName to item 1 of argv
	set pfx to "[fm:" & (item 2 of argv) & "]"
	set n to 0
	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then return "0"
		tell list listName
			repeat with r in (every reminder whose completed is false and body begins with pfx)
				set completed of r to true
				set n to n + 1
			end repeat
		end tell
	end tell
	return (n as text)
end run
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
