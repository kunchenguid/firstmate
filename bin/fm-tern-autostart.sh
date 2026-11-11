#!/usr/bin/env bash
# fm-tern-autostart.sh - bring the omp primary firstmate up in Tern, idempotently.
#
# The Tern counterpart of a Herdr login launcher: run it after Tern opens (a
# login LaunchAgent, or by hand) and it leaves exactly one "First Mate"
# session in the Tern window holding:
#   - a "First Mate" tab whose shell runs the primary harness (omp) at the
#     firstmate workspace, typed at the prompt so Tern lists it as an agent and
#     renders it natively;
#   - a "Quota" tab running quota-axi's live TUI, when quota-axi is installed.
# Re-running it changes nothing that is already right: a primary already
# running at the workspace in any session is adopted (its session renamed to
# "First Mate" and shown), a bare shell left in the First Mate tab is reused,
# and an existing Quota tab is kept.
#
# Usage: fm-tern-autostart.sh [--open] [--no-focus]
#   --open      when Tern's daemon is not reachable, `open -a Tern` (macOS) and
#               wait for it; without it the script only waits.
#   --no-focus  do not show the First Mate session in the window.
# Environment (all optional):
#   FM_TERN_AUTOSTART_WORKSPACE  firstmate workspace (default: this checkout's root)
#   FM_TERN_AUTOSTART_SESSION    session and primary tab name (default "First Mate")
#   FM_TERN_AUTOSTART_PRIMARY    primary command typed into the shell (default "omp")
#   FM_TERN_AUTOSTART_QUOTA      quota command, empty to skip
#                                (default "quota-axi --tui --refresh 1m" when on PATH)
#   FM_TERN_AUTOSTART_WAIT       seconds to wait for Tern (default 120)
#   FM_TERN_AUTOSTART_LOG        log file (default ~/Library/Logs/fm-tern-autostart.log
#                                on macOS, ~/.local/state/fm-tern-autostart.log elsewhere)
# The primary is typed at the prompt with no PI_TUI_NATIVE override: the
# primary keeps Tern-native rendering, while task workers spawned by
# bin/fm-spawn.sh run with PI_TUI_NATIVE=0 (docs/tern-backend.md).
# Installing it at login is documented in docs/tern-backend.md "Autostart";
# this script never installs anything itself.
# Exit status: 0 when the primary is running (or was just started), 1 on failure.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE=${FM_TERN_AUTOSTART_WORKSPACE:-$ROOT}
SESSION=${FM_TERN_AUTOSTART_SESSION:-First Mate}
PRIMARY=${FM_TERN_AUTOSTART_PRIMARY:-omp}
QUOTA_LABEL=Quota
WAIT=${FM_TERN_AUTOSTART_WAIT:-120}
if [ "${FM_TERN_AUTOSTART_QUOTA+set}" = set ]; then
  QUOTA=$FM_TERN_AUTOSTART_QUOTA
elif command -v quota-axi >/dev/null 2>&1; then
  QUOTA="quota-axi --tui --refresh 1m"
else
  QUOTA=
fi
if [ -n "${FM_TERN_AUTOSTART_LOG:-}" ]; then
  LOG=$FM_TERN_AUTOSTART_LOG
elif [ "$(uname 2>/dev/null)" = Darwin ]; then
  LOG="$HOME/Library/Logs/fm-tern-autostart.log"
else
  LOG="$HOME/.local/state/fm-tern-autostart.log"
fi
OPEN=0
FOCUS=1
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --no-focus) FOCUS=0 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "fm-tern-autostart: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
  printf 'fm-tern-autostart: %s\n' "$*" >&2
}

command -v jq >/dev/null 2>&1 || { log "jq not found; giving up"; exit 1; }
TERN=$(command -v tern 2>/dev/null || true)
[ -n "$TERN" ] || [ ! -x /Applications/Tern.app/Contents/MacOS/tern ] || TERN=/Applications/Tern.app/Contents/MacOS/tern
[ -n "$TERN" ] || { log "tern CLI not found; giving up"; exit 1; }
[ -d "$WORKSPACE" ] || { log "workspace $WORKSPACE is not a directory; giving up"; exit 1; }
WORKSPACE=$(cd "$WORKSPACE" && pwd -P)

# One instance at a time: a second launch while the first still waits for Tern
# exits quietly.
LOCK="${TMPDIR:-/tmp}/fm-tern-autostart.$(id -u).lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # The pid alone is not proof: this lock dir survives a crash, and macOS recycles
    # pids, so an unrelated live process could block autostart forever with no message.
    if ps -p "$pid" -o command= 2>/dev/null | grep -q 'fm-tern-autostart'; then
      log "another autostart run is already in progress (pid $pid); nothing to do"
      exit 0
    fi
    log "pid $pid holds the lock but is not fm-tern-autostart (recycled pid); treating the lock as stale"
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { log "could not take $LOCK; giving up"; exit 1; }
fi
printf '%s\n' "$$" >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

inventory() { "$TERN" ls --json 2>/dev/null; }

# 1. Wait for Tern's daemon and window.
INV=
opened=0
i=0
while [ "$i" -lt "$WAIT" ]; do
  if INV=$(inventory) && [ -n "$INV" ]; then
    break
  fi
  INV=
  if [ "$OPEN" = 1 ] && [ "$opened" = 0 ] && command -v open >/dev/null 2>&1; then
    open -a Tern >/dev/null 2>&1 && opened=1
  fi
  sleep 1
  i=$((i + 1))
done
[ -n "$INV" ] || { log "Tern never became reachable within ${WAIT}s; giving up"; exit 1; }

primary_word=${PRIMARY%% *}
primary_name=${primary_word##*/}

# block_runs <block> <name>: the block's foreground process is <name>.
block_runs() {
  "$TERN" process "$1" --json 2>/dev/null \
    | jq -e --arg n "$2" '(.foreground.name // "") == $n or ((.foreground.argv[0] // "") | split("/") | last) == $n' >/dev/null 2>&1
}

block_runs_quota() {
  "$TERN" process "$1" --json 2>/dev/null \
    | jq -e '[.foreground.argv[]?] | join(" ") | test("quota-axi")' >/dev/null 2>&1
}

block_cwd() {
  "$TERN" process "$1" --json 2>/dev/null | jq -r '.foreground.cwd // .child.cwd // empty' 2>/dev/null
}

# type_line <block> <text>: type one command line exactly as written, then
# Enter (`tern run` would parse the command's own --flags as its own).
type_line() {
  "$TERN" send "$1" text -- "$2" >/dev/null 2>&1 && "$TERN" send "$1" keys Enter >/dev/null 2>&1
}

# 2. A primary already running at the workspace, in any session, is adopted.
primary=
primary_session=
while IFS=$'\t' read -r sname block; do
  [ -n "$block" ] || continue
  block_runs "$block" "$primary_name" || continue
  cwd=$(block_cwd "$block")
  cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P) || cwd_real=$cwd
  [ "$cwd_real" = "$WORKSPACE" ] || continue
  primary=$block
  primary_session=$sname
  break
done < <(printf '%s' "$INV" | jq -r '.sessions[]? | .name as $s | .tabs[]?.blocks[]? | select(.live != false) | "\($s)\t\(.id)"')

if [ -n "$primary" ]; then
  if [ "$primary_session" != "$SESSION" ]; then
    if printf '%s' "$INV" | jq -e --arg s "$SESSION" 'any(.sessions[]?; .name == $s)' >/dev/null; then
      log "primary runs in block $primary of session '$primary_session'; a separate '$SESSION' session already exists, so leaving names alone"
    else
      "$TERN" rename "$primary_session" "$SESSION" >/dev/null 2>&1 && log "renamed session '$primary_session' to '$SESSION'"
    fi
  fi
  "$TERN" rename "$primary" "$SESSION" >/dev/null 2>&1 || true
  log "primary already running in block $primary"
else
  # 3. Reuse a bare shell left in the First Mate tab, else create the tab.
  target=
  if printf '%s' "$INV" | jq -e --arg s "$SESSION" 'any(.sessions[]?; .name == $s)' >/dev/null; then
    target=$(printf '%s' "$INV" | jq -r --arg s "$SESSION" '
      first(.sessions[]? | select(.name == $s) | .tabs[]? | select(.name == $s) | .blocks[]? | select(.live != false) | .id) // empty')
    if [ -n "$target" ]; then
      fg=$("$TERN" process "$target" --json 2>/dev/null | jq -r '.foreground.pid == .child.pid' 2>/dev/null)
      [ "$fg" = true ] || target=
    fi
    if [ -z "$target" ]; then
      target=$("$TERN" new tab "$SESSION" --cwd "$WORKSPACE" --json 2>/dev/null | jq -r '.block // empty')
    fi
  else
    target=$("$TERN" new session "$SESSION" --cwd "$WORKSPACE" --json 2>/dev/null | jq -r '.block // empty')
  fi
  [ -n "$target" ] || { log "could not create the '$SESSION' tab; giving up"; exit 1; }
  "$TERN" rename "$target" "$SESSION" >/dev/null 2>&1 || true
  if [ "$(block_cwd "$target")" != "$WORKSPACE" ]; then
    type_line "$target" "cd '$WORKSPACE'" || true
  fi
  type_line "$target" "$PRIMARY" || { log "could not type '$PRIMARY' into block $target; giving up"; exit 1; }
  primary=$target
  j=0
  while [ "$j" -lt 30 ]; do
    block_runs "$primary" "$primary_name" && break
    sleep 1
    j=$((j + 1))
  done
  if block_runs "$primary" "$primary_name"; then
    log "started $primary_name in block $primary"
  else
    log "typed '$PRIMARY' into block $primary but it is not running yet"
  fi
fi

# 4. The Quota tab, in the primary's session.
if [ -n "$QUOTA" ]; then
  INV=$(inventory) || INV=
  qsession=$(printf '%s' "$INV" | jq -r --arg b "$primary" 'first(.sessions[]? | .name as $s | select(any(.tabs[]?.blocks[]?; (.id | tostring) == $b)) | $s) // empty')
  [ -n "$qsession" ] || qsession=$SESSION
  quota=
  while IFS= read -r block; do
    [ -n "$block" ] || continue
    if block_runs_quota "$block"; then
      quota=$block
      break
    fi
  done < <(printf '%s' "$INV" | jq -r --arg s "$qsession" '.sessions[]? | select(.name == $s) | .tabs[]? | .blocks[]? | select(.live != false) | .id')
  if [ -n "$quota" ]; then
    log "quota tab present in block $quota"
  else
    # A Quota tab whose shell sits idle (quota-axi exited) is reused.
    quota=$(printf '%s' "$INV" | jq -r --arg s "$qsession" --arg l "$QUOTA_LABEL" '
      first(.sessions[]? | select(.name == $s) | .tabs[]? | select(.name == $l) | .blocks[]? | select(.live != false) | .id) // empty')
    if [ -n "$quota" ] && [ "$("$TERN" process "$quota" --json 2>/dev/null | jq -r '.foreground.pid == .child.pid' 2>/dev/null)" != true ]; then
      quota=
    fi
    [ -n "$quota" ] || quota=$("$TERN" new tab "$qsession" --cwd "$WORKSPACE" --json 2>/dev/null | jq -r '.block // empty')
    if [ -n "$quota" ]; then
      "$TERN" rename "$quota" "$QUOTA_LABEL" >/dev/null 2>&1 || true
      if type_line "$quota" "$QUOTA"; then
        log "quota tab started in block $quota"
      else
        log "quota tab created in block $quota but its command could not be typed"
      fi
    else
      log "quota tab could not be created"
    fi
  fi
fi

if [ "$FOCUS" = 1 ]; then
  "$TERN" focus "$primary" >/dev/null 2>&1 || log "could not show block $primary"
fi
exit 0
