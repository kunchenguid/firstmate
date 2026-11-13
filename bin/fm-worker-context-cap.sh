#!/usr/bin/env bash
# fm-worker-context-cap.sh - Claude hooks that cap a ship or scout worker's
# context size.
#
# bin/fm-spawn.sh wires two modes into the worker's .claude/settings.local.json:
#   fm-worker-context-cap.sh stop    --id <id> --state <dir> --data <dir> --config <dir>
#   fm-worker-context-cap.sh pretool --id <id> --state <dir> --data <dir> --config <dir>
# Both read the hook payload on stdin. docs/configuration.md "Worker context
# cap" owns the config file and the relaunch handoff. This header owns the
# transcript read, the state file, the allow list, and the messages.
#
# Limits come from config/worker-context-cap: soft=<n> (default 200000),
# hard=<n> (default 300000), enabled=false. Blank lines and lines starting with
# # are ignored. An unusable value keeps its default. A count above 100000000
# is unusable, so the shell comparison stays inside integer range. A soft limit
# at or above the hard limit makes both keep their defaults.
#
# Context size is the same sum the stow guard and warm-cache compaction use:
# input + cache_read + cache_creation on the newest usage object in the last
# 2MB of the transcript.
#
# STOP. At or above the soft limit the hook blocks the turn end once, telling
# the worker to judge whether its work splits cleanly. The state file
# <state>/<id>.context-cap.json records the session as asked. A later read below
# two-thirds of the soft limit clears that record, so the next crossing asks
# again. A continuation stop (stop_hook_active) is handled like any other stop.
# The hook is the only Stop writer of the busy record for its worker: when it
# blocks, the continuation fires no UserPromptSubmit, so a blocked stop is
# recorded as busy and an allowed stop as idle, in the order the spawn wired
# (bin/fm-spawn.sh builds the command around this hook's output).
#
# PRETOOL. At or above the hard limit the hook denies every tool call except:
#   - one simple `git add` or `git commit` command, optionally `git -C <path>`
#   - Write, Edit, or MultiEdit on <data>/<id>/handoff.md exactly
#   - the status-line append from the launch brief, `echo "<text>" >> '<status>'`
#     with the brief's optional fleet-ledger suffix
# A "simple" git command has no unquoted ; & | < > ( ) { } $ backtick or
# backslash, no `$` or backtick or backslash inside double quotes, and no
# newline. The deny follows docs/arm-pretool-check.md: exit 2, one JSON object
# on stderr, nothing on stdout.
#
# FAIL OPEN. A missing jq, an unreadable payload or transcript, an unusable
# argument, an unwritable state file, or any other hook error exits 0 and prints
# nothing, so a worker is never stuck on this hook. The off switch does the same.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-worker-context-cap.sh (stop|pretool) --id <id> --state <dir> --data <dir> --config <dir>

Claude Stop and PreToolUse hook for a ship or scout worker. Reads the hook
payload on stdin. See the script header and docs/configuration.md "Worker
context cap".
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  stop|pretool) MODE=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

ID='' STATE='' DATA='' CONFIG=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) [ "$#" -ge 2 ] || exit 0; ID=$2; shift 2 ;;
    --state) [ "$#" -ge 2 ] || exit 0; STATE=$2; shift 2 ;;
    --data) [ "$#" -ge 2 ] || exit 0; DATA=$2; shift 2 ;;
    --config) [ "$#" -ge 2 ] || exit 0; CONFIG=$2; shift 2 ;;
    *) exit 0 ;;
  esac
done
[ -n "$ID" ] && [ -n "$STATE" ] && [ -n "$DATA" ] && [ -n "$CONFIG" ] || exit 0

if [ -t 0 ]; then
  usage
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat || true)
[ -n "$payload" ] || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0

# Cursor loads the project's Claude settings too and is out of scope.
cursor=$(jq -r '.cursor_version // .cursorVersion // empty' <<<"$payload" 2>/dev/null || true)
[ -z "$cursor" ] || exit 0

SOFT_DEFAULT=200000
HARD_DEFAULT=300000
soft=$SOFT_DEFAULT
hard=$HARD_DEFAULT
enabled=true
config_file="$CONFIG/worker-context-cap"
if [ -f "$config_file" ]; then
  line='' key='' value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      enabled)
        [ "$value" != false ] || enabled=false
        continue
        ;;
      soft|hard) ;;
      *) continue ;;
    esac
    case "$value" in
      ''|*[!0-9]*|0*) continue ;;
    esac
    if [ "${#value}" -gt 9 ] || [ "$value" -gt 100000000 ]; then
      continue
    fi
    case "$key" in
      soft) soft=$value ;;
      hard) hard=$value ;;
    esac
  done < "$config_file"
fi
[ "$enabled" = true ] || exit 0
if [ "$soft" -ge "$hard" ]; then
  soft=$SOFT_DEFAULT
  hard=$HARD_DEFAULT
fi

sid=$(jq -r '.session_id // .sessionId // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$sid" ] || sid=session
transcript=$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

tokens=$(tail -c 2000000 "$transcript" | jq -R -r '
    fromjson? | .message.usage // empty | select(type == "object")
    | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
  ' | awk 'NF { n = $0 } END { if (n == "") print 0; else print n + 0 }') || exit 0
case "$tokens" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$tokens" -gt 0 ] || exit 0

handoff="$DATA/$ID/handoff.md"
status_file="$STATE/$ID.status"
state_path="$STATE/$ID.context-cap.json"

# fm_cap_simple_shell <command>: succeeds when the command has no metacharacter
# that could chain, redirect, substitute, or escape outside the quoted text a
# commit message needs.
fm_cap_simple_shell() {
  local s=$1 i c q=''
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [ "$q" = "'" ]; then
      [ "$c" != "'" ] || q=''
      continue
    fi
    if [ "$q" = '"' ]; then
      case "$c" in
        '"') q='' ;;
        '$'|'`'|"\\") return 1 ;;
      esac
      continue
    fi
    case "$c" in
      "'"|'"') q=$c ;;
      ';'|'&'|'|'|'<'|'>'|'('|')'|'{'|'}'|'$'|'`'|"\\") return 1 ;;
    esac
  done
  [ -z "$q" ]
}

# fm_cap_status_append <command>: succeeds for the launch brief's status-line
# append, with or without its fleet-ledger suffix.
fm_cap_status_append() {
  local cmd=$1 rest msg append ledger given given_dir
  case "$cmd" in
    'echo "'*) ;;
    *) return 1 ;;
  esac
  rest=${cmd#'echo "'}
  case "$rest" in
    *'"'*) ;;
    *) return 1 ;;
  esac
  msg=${rest%%'"'*}
  rest=${rest#*'"'}
  case "$msg" in
    *'`'*|*'$'*|*"\\"*) return 1 ;;
  esac
  # The brief may spell the state directory through a symlink while the hook
  # holds the physical path, so resolve the brief's path before comparing.
  case "$rest" in
    " >> '"*) ;;
    *) return 1 ;;
  esac
  given=${rest#" >> '"}
  given=${given%%"'"*}
  case "$given" in
    /*/"$ID.status") ;;
    *) return 1 ;;
  esac
  given_dir=$(cd "${given%/*}" 2>/dev/null && pwd -P) || return 1
  [ "$given_dir/$ID.status" = "$status_file" ] || return 1
  rest=${rest//"'$given'"/"'$status_file'"}
  append=" >> '$status_file'"
  ledger=" && { [ ! -e '$CONFIG/fleet-ledger' ] || '$SCRIPT_DIR/fm-fleet-ledger.sh' appended '$CONFIG' '$status_file' >/dev/null 2>&1 || true; }"
  [ "$rest" = "$append" ] || [ "$rest" = "$append$ledger" ]
}

fm_cap_git_commit() {
  local cmd=$1
  local re="^git( -C ('[^']*'|\"[^\"]*\"|[^ '\"]+))? (add|commit)( |\$)"
  [[ $cmd =~ $re ]] || return 1
  fm_cap_simple_shell "$cmd"
}

fm_cap_tool_allowed() {
  local cmd path
  case "$tool" in
    Bash)
      cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || return 1
      [ -n "$cmd" ] || return 1
      case "$cmd" in
        *$'\n'*|*$'\r'*) return 1 ;;
      esac
      fm_cap_git_commit "$cmd" || fm_cap_status_append "$cmd"
      ;;
    Write|Edit|MultiEdit)
      path=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || return 1
      [ "$path" = "$handoff" ]
      ;;
    *) return 1 ;;
  esac
}

case "$MODE" in
  pretool)
    [ "$tokens" -ge "$hard" ] || exit 0
    tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
    [ -n "$tool" ] || exit 0
    fm_cap_tool_allowed && exit 0
    now=$(date +%s 2>/dev/null) || now=
    reason="fm-worker-context-cap: context is ${tokens} tokens, at or above the hard limit of ${hard}. Hand off now. This call is denied. Only three actions run. One: a single git add or git commit command with no unquoted ; & | < > ( ) { } \$ or backtick. Two: Write or Edit on ${handoff}. Three: the status append from your instructions, echo \"<text>\" >> '${status_file}'. Use ${now} as the [at=<epoch>] value, because date is denied. Commit, write the handoff note (done, open, exact next step, launch line), append a paused status line naming the note, then stop."
    jq -nc --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny"},systemMessage:$reason}' >&2 || exit 0
    exit 2
    ;;
  stop)
    rearm_below=$((soft * 2 / 3))
    fired='{}'
    if [ -f "$state_path" ]; then
      fired=$(jq -c '.fired // {}' "$state_path" 2>/dev/null || echo '{}')
    fi
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$fired" || fired='{}'
    if [ "$tokens" -lt "$rearm_below" ]; then
      fired=$(jq -c --arg sid "$sid" 'del(.[$sid])' <<<"$fired") || exit 0
    fi
    has_fired=$(jq -r --arg sid "$sid" 'if .[$sid] == true then "1" else "0" end' <<<"$fired") || exit 0
    reason=
    if [ "$tokens" -ge "$soft" ] && [ "$has_fired" -eq 0 ]; then
      reason="fm-worker-context-cap: context is ${tokens} tokens, at or above the soft limit of ${soft}. Judge now whether your work splits cleanly. If it does, commit your work and write a handoff note to ${handoff}. The note lists what is done, what is open, the exact next step, and this launch line: bin/fm-control.sh ${ID} relaunch --note-file '${handoff}'. Then append a paused status line naming the note, or a done line if the task is complete, and stop. If it cannot split, append a working status line that says why and continue. If your work is already complete and reported, end your turn. At ${hard} tokens every tool except git add, git commit, the note, and the status append is denied."
      fired=$(jq -c --arg sid "$sid" '.[$sid] = true' <<<"$fired") || exit 0
    fi
    tmp=$(mktemp "$STATE/.$ID.context-cap.json.XXXXXX" 2>/dev/null) || exit 0
    jq -n --argjson fired "$fired" '{fired:$fired}' > "$tmp" || { rm -f "$tmp"; exit 0; }
    mv -f "$tmp" "$state_path" || { rm -f "$tmp"; exit 0; }
    if [ -n "$reason" ]; then
      jq -nc --arg reason "$reason" '{decision:"block", reason:$reason}'
    fi
    exit 0
    ;;
esac
exit 0
