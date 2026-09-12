#!/usr/bin/env bash
# fm-secondmate-liveness.sh - MAIN's read of every registered home's watcher
# beat and primary-agent liveness.
#
# Usage:
#   fm-secondmate-liveness.sh [-h|--help]
#   fm-secondmate-liveness.sh [--recover]
#
# For every home in data/secondmates.md, print one line:
#   <id> beat=<age>s grace=<n>s agent=<live|dead|unknown> verdict=<ok|stale|dead>
#
# Beat age is state/.last-watcher-beat in that home. Agent liveness is the
# recorded primary endpoint through fm_backend_agent_alive (the same helper
# session-start liveness uses). Grace is FM_GUARD_GRACE, else the shared
# fm_poll_derived_grace default.
#
# Read-only by default. --recover re-arms a stale beat with a live agent
# through that home's fm-watch-arm.sh --restart (the verified arm wrapper,
# never a duplicate watcher cycle), and restarts a dead agent through
# bin/fm-secondmate-restart.sh (persist-before-restart preserved). Each
# recovery appends one line to this home's state/<id>.status and posts one
# Slack line through bin/fm-slack-post.sh message.
# Anything this scan cannot classify is refused with a reason on stderr
# (never a silent default).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-secondmate-liveness.sh" | sed 's/^# \{0,1\}//; $d'
}

RECOVER=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --recover) RECOVER=1; shift ;;
  '') ;;
  *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
esac
[ $# -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2; }

# A nested home supervises itself; this scan is the parent home's job.
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  exit 0
fi

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REGISTRY="$FM_HOME/data/secondmates.md"
if [ ! -e "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
  exit 0
fi
if [ -L "$REGISTRY" ] || [ ! -f "$REGISTRY" ]; then
  echo "error: cannot classify: secondmate registry is unavailable or unsafe: $REGISTRY" >&2
  exit 1
fi

GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
case "$GRACE" in
  ''|*[!0-9]*|0)
    echo "error: cannot classify: invalid grace '$GRACE'" >&2
    exit 1
    ;;
esac

now=${FM_SECONDMATE_LIVENESS_NOW:-$(date +%s)}
case "$now" in
  ''|*[!0-9]*)
    echo "error: cannot classify: invalid clock '$now'" >&2
    exit 1
    ;;
esac

ARM=${FM_SECONDMATE_LIVENESS_ARM:-$SCRIPT_DIR/fm-watch-arm.sh}
RESTART=${FM_SECONDMATE_LIVENESS_RESTART:-$SCRIPT_DIR/fm-secondmate-restart.sh}
SLACK=${FM_SECONDMATE_LIVENESS_SLACK:-$SCRIPT_DIR/fm-slack-post.sh}

failed=0

refuse() {  # <id> <why>
  echo "error: $1: cannot classify: $2" >&2
  failed=1
}

classify_agent() {  # <id> -> sets CLASS_AGENT
  local id=$1 meta window backend target raw
  CLASS_AGENT=
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    CLASS_AGENT=dead
    return 0
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    CLASS_AGENT=dead
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$window
  raw=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || raw=unknown
  case "$raw" in
    alive) CLASS_AGENT=live ;;
    dead) CLASS_AGENT=dead ;;
    unknown) CLASS_AGENT=unknown ;;
    *)
      refuse "$id" "agent liveness helper returned '$raw'"
      return 1
      ;;
  esac
  return 0
}

verdict_for() {  # <age> <agent> -> sets CLASS_VERDICT or returns 1
  local age=$1 agent=$2
  CLASS_VERDICT=
  case "$agent" in
    dead)
      CLASS_VERDICT=dead
      return 0
      ;;
    live)
      if [ "$age" -ge "$GRACE" ]; then
        CLASS_VERDICT=stale
      else
        CLASS_VERDICT=ok
      fi
      return 0
      ;;
    unknown)
      if [ "$age" -lt "$GRACE" ]; then
        CLASS_VERDICT=ok
        return 0
      fi
      return 1
      ;;
  esac
  return 1
}

append_status() {  # <id> <line>
  printf '%s\n' "$2" >> "$STATE/$1.status"
}

post_slack() {  # <text>
  "$SLACK" message "$1"
}

recover_arm() {  # <home>
  local home=$1
  if [ "$ARM" != "$SCRIPT_DIR/fm-watch-arm.sh" ]; then
    FM_HOME="$home" "$ARM" --restart
    return $?
  fi
  # Detach the real wrapper so this scan does not inherit that home's wakes.
  if command -v setsid >/dev/null 2>&1; then
    setsid env FM_HOME="$home" FM_ROOT="$FM_ROOT" "$ARM" --restart </dev/null >/dev/null 2>&1 &
  else
    nohup env FM_HOME="$home" FM_ROOT="$FM_ROOT" "$ARM" --restart </dev/null >/dev/null 2>&1 &
    disown $! 2>/dev/null || true
  fi
  return 0
}

recover_one() {  # <id> <home> <verdict>
  local id=$1 home=$2 verdict=$3 rc=0
  case "$verdict" in
    stale)
      recover_arm "$home" || rc=$?
      append_status "$id" "working: recovered $id watcher (stale beat; re-armed)"
      post_slack "home $id: watcher beat stale; re-armed" || rc=$?
      ;;
    dead)
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$RESTART" "$id" || rc=$?
      append_status "$id" "working: recovered $id agent (dead; guarded restart)"
      post_slack "home $id: agent dead; guarded restart" || rc=$?
      ;;
    *)
      return 0
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    echo "error: $id: recovery failed" >&2
    failed=1
  fi
}

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-liveness.XXXXXX") || {
  echo "error: cannot classify: could not create temp file" >&2
  exit 1
}
trap 'rm -f -- "$TMP"' EXIT
grep '^- ' "$REGISTRY" > "$TMP" 2>/dev/null || : > "$TMP"

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  if ! secondmate_registry_parse_line "$line"; then
    echo "error: cannot classify: malformed secondmate registry entry: $line" >&2
    failed=1
    continue
  fi
  id=$SECONDMATE_REGISTRY_ID
  home=$SECONDMATE_REGISTRY_HOME
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    refuse "$id" "home is remote; watcher beat is not readable on this host"
    continue
  fi
  if [ ! -d "$home" ]; then
    refuse "$id" "home path does not exist: $home"
    continue
  fi
  beat="$home/state/.last-watcher-beat"
  if [ ! -e "$beat" ]; then
    refuse "$id" "no watcher beat at $beat"
    continue
  fi
  mtime=$(fm_path_mtime "$beat") || mtime=
  case "$mtime" in
    ''|*[!0-9]*)
      refuse "$id" "watcher beat mtime is unreadable"
      continue
      ;;
  esac
  age=$((now - mtime))
  if [ "$age" -lt 0 ]; then
    refuse "$id" "watcher beat is in the future"
    continue
  fi
  classify_agent "$id" || continue
  if ! verdict_for "$age" "$CLASS_AGENT"; then
    refuse "$id" "stale beat with agent=$CLASS_AGENT (need live or dead)"
    continue
  fi
  printf '%s beat=%ss grace=%ss agent=%s verdict=%s\n' \
    "$id" "$age" "$GRACE" "$CLASS_AGENT" "$CLASS_VERDICT"
  if [ "$RECOVER" -eq 1 ]; then
    recover_one "$id" "$home" "$CLASS_VERDICT"
  fi
done < "$TMP"

exit "$failed"
