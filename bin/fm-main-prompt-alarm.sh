#!/usr/bin/env bash
# fm-main-prompt-alarm.sh - alert the captain when firstmate's own Claude main
# session waits on a permission prompt.
#
# Usage:
#   fm-main-prompt-alarm.sh hook claude     the tracked Claude PermissionRequest
#                                           hook (.claude/settings.json); reads
#                                           the hook payload on stdin
#   fm-main-prompt-alarm.sh check <token>   the delayed check the hook starts
#
# WHY. A main tool call parked on a permission prompt, such as the one a
# PreToolUse hook's "ask" decision opens, stops supervision: main handles no
# wake until someone answers it. The watcher cannot report it, because it
# watches worker panes, and it exits on its first actionable wake, which main
# is then not there to take.
#
# HOOK. Claude runs PermissionRequest hooks just before it shows a permission
# dialog, with the tool and its input in the payload (live on Claude Code
# 2.1.306, including a hook "ask"). This hook prints nothing, so it never
# decides the prompt and the dialog is shown as usual. It acts only for the
# lock-owning primary session of a genuine primary checkout, the scope
# bin/fm-host-mirror.sh's writers use, never in a second mate's home, whose
# outcomes reach the captain through its parent channel, and never for a
# Cursor payload. It
# replaces state/.main-permission-prompt with this prompt's record, starts one
# detached delayed check for it, and exits.
#
# CHECK. After FM_MAIN_PROMPT_ALARM_SECS (default 300) the check alerts once,
# through the configured wedge-alarm channels (bin/fm-wedge-alarm-lib.sh,
# config/wedge-alarm), only when all of these still hold:
#   - the record is still the one the check was started for; a later prompt
#     replaces it, and that prompt's own check takes over;
#   - the session lock still names the same live process;
#   - the session transcript has not changed since the prompt: Claude writes
#     nothing there while a prompt waits, and writes the tool result or the
#     interruption once the prompt is answered or cancelled;
#   - when the main pane can be read (tmux or herdr, found from the hook's own
#     environment by bin/fm-supervisor-target-lib.sh), it still shows a
#     permission prompt (bin/fm-composer-lib.sh's fm_composer_permission_prompt).
#     An approved command that is still running leaves the transcript unchanged
#     too; the pane is what tells the two apart.
# When the pane cannot be read, the transcript decides alone, so an approved
# command that runs past the delay can raise a false alert. Nothing here
# answers the prompt. Each alert, and each check that found the prompt
# resolved, is logged to state/.main-permission-prompt.log.
#
# The hook always exits 0. Its record is key=value lines: token, epoch, lock,
# transcript, mtime, backend, target, tool, subject.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RECORD="$STATE/.main-permission-prompt"
LOG="$STATE/.main-permission-prompt.log"
DELAY=${FM_MAIN_PROMPT_ALARM_SECS:-}
case "$DELAY" in ''|*[!0-9]*) DELAY=300 ;; esac

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || true; }

usage() {
  sed -n '/^# Usage:/,/^# WHY/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

file_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

record_field() {  # <name>
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -n 1
}

hook() {
  local payload parsed tool subject transcript mtime lock_pid target='' backend='' token tmp
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$STATE" ] || return 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  ! fm_hook_payload_is_foreign_host "$payload" || return 0
  # One line per field: tool, transcript path, then the subject.
  parsed=$(printf '%s' "$payload" | jq -r '
    if type == "object" and .hook_event_name == "PermissionRequest" then
      ((.tool_name // "") | tostring) as $tool
      | ((.tool_input // {}) | if type == "object" then (.command // .file_path // .url // .pattern // "") else "" end
         | tostring | split("\n") | map(select(test("\\S"))) | (.[0] // "")) as $subject
      | "\($tool | gsub("[\\t\\n\\r]"; " "))\n\((.transcript_path // "") | tostring | gsub("\\n"; ""))\n\($subject)"
    else empty end' 2>/dev/null) || return 0
  [ -n "$parsed" ] || return 0
  tool=$(printf '%s\n' "$parsed" | sed -n '1p')
  transcript=$(printf '%s\n' "$parsed" | sed -n '2p')
  subject=$(printf '%s\n' "$parsed" | sed -n '3p' | LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C tr '\t' ' ' | cut -c1-160)
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE" || return 0
  # A second mate reaches the captain only through its parent channel.
  ! fm_root_is_secondmate_home "$FM_ROOT" || return 0
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  mtime=
  [ -z "$transcript" ] || mtime=$(file_mtime "$transcript" || true)
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  if target=$(discover_supervisor_target); then
    backend=$(discover_supervisor_backend) || backend=
  else
    target=
  fi
  token="$(date +%s)-$$-$RANDOM"
  tmp=$(mktemp "$RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! printf 'token=%s\nepoch=%s\nlock=%s\ntranscript=%s\nmtime=%s\nbackend=%s\ntarget=%s\ntool=%s\nsubject=%s\n' \
      "$token" "$(date +%s)" "$lock_pid" "$transcript" "$mtime" "$backend" "$target" "$tool" "$subject" > "$tmp" \
    || ! mv -f "$tmp" "$RECORD"; then
    rm -f "$tmp"
    return 0
  fi
  # Its own process group, no inherited descriptors: Claude waits on the hook's
  # output, and the check must outlive the hook.
  set -m
  nohup "$SCRIPT_DIR/fm-main-prompt-alarm.sh" check "$token" < /dev/null > /dev/null 2>&1 &
  return 0
}

# The main pane, read once: 0 with the prompt on it, 1 without it, 2 when it
# could not be read.
pane_shows_prompt() {  # <backend> <target>
  local screen
  [ -n "$1" ] && [ -n "$2" ] || return 2
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || return 2
  # shellcheck source=bin/fm-composer-lib.sh
  . "$SCRIPT_DIR/fm-composer-lib.sh" 2>/dev/null || return 2
  screen=$(fm_backend_capture "$1" "$2" 40 2>/dev/null) || return 2
  [ -n "$screen" ] || return 2
  fm_composer_permission_prompt "$screen" >/dev/null
}

check() {  # <token>
  local token=$1 epoch lock_pid transcript mtime backend target tool subject now pane summary
  sleep "$DELAY"
  [ "$(record_field token)" = "$token" ] || return 0
  epoch=$(record_field epoch); lock_pid=$(record_field lock)
  transcript=$(record_field transcript); mtime=$(record_field mtime)
  backend=$(record_field backend); target=$(record_field target)
  tool=$(record_field tool); subject=$(record_field subject)
  case "$lock_pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(cat "$STATE/.lock" 2>/dev/null || true)" = "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null || return 0
  if [ -n "$transcript" ] && [ "$(file_mtime "$transcript" || true)" != "$mtime" ]; then
    log "resolved: the session moved on after the ${tool:-tool} prompt"
    return 0
  fi
  pane_shows_prompt "$backend" "$target"
  pane=$?
  if [ "$pane" -eq 1 ]; then
    log "resolved: the main pane no longer shows the ${tool:-tool} prompt"
    return 0
  fi
  now=$(date +%s)
  case "$epoch" in ''|*[!0-9]*) epoch=$now ;; esac
  summary="firstmate's main session has waited $((now - epoch))s on a permission prompt"
  summary="$summary${tool:+ for $tool}${subject:+: $subject}; supervision is paused until it is answered"
  [ "$pane" -eq 0 ] || summary="$summary (main pane unreadable; an approved command still running looks the same)"
  log "alert: $summary"
  # shellcheck source=bin/fm-wedge-alarm-lib.sh
  . "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"
  WEDGE_ALARM_TITLE="firstmate: main session waiting on a permission prompt"
  wedge_alarm_notify "$summary" "$LOG"
}

case "${1:-}" in
  hook)
    [ "${2:-}" = claude ] || usage
    hook
    exit 0
    ;;
  check)
    [ "$#" -eq 2 ] || usage
    check "$2"
    exit 0
    ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
