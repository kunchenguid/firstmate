#!/usr/bin/env bash
# bin/fm-browser-reaper.sh - identify, report, and reap leaked chrome-devtools-axi
# browser stacks.
#
# THE LEAK
# chrome-devtools-axi runs its bridge as a DETACHED background server: the
# bridge reparents to init (ppid 1), so it is never a child of the worker that
# started it and no "kill my children" sweep can find it. One bridge serves one
# SESSION NAME for the whole machine, not one invocation: a second
# `chrome-devtools-axi` call with the same session name - from any directory -
# reuses the same bridge pid and port, and the bridge's working directory stays
# frozen to whichever directory happened to start it first. A stack is ten
# processes deep (bridge -> npm exec -> chrome-devtools-mcp -> node -> Chrome
# --headless=new -> its gpu/network/storage/renderer helpers), and the
# gpu-process helper can spin a full core indefinitely once the page that
# created it is gone. Nothing in the fleet closed one, so they accumulated:
# stacks 16 hours and 6 days old were found alive with no worker behind them.
#
# WHY CWD IS NOT OWNERSHIP
# bin/fm-teardown.sh's leaked-descendant sweep finds processes whose cwd is
# under the task's worktree. The bridge's cwd matches only by the coincidence of
# who called first. That makes the sweep both unsafe (it would kill a bridge a
# still-live task is sharing) and insufficient (a bridge started from a
# directory that is already gone is never matched). Ownership has to be
# declared, not inferred, so bin/fm-spawn.sh exports
# CHROME_DEVTOOLS_AXI_SESSION=fm-<home-tag>-<task-id> into every crewmate pane.
# Every stack a worker launches then carries its task id in the session name,
# and that name is the attribution this script reaps by.
#
# The home tag is required, not decoration. chrome-devtools-axi's session
# registry is ONE machine-wide namespace, so two firstmate homes sharing a
# machine would otherwise read each other's sessions - and a home that cannot
# find a task id in its own state/ would report a sibling home's LIVE browser as
# leaked and offer to kill it. bin/fm-backend-hometag-lib.sh owns the same
# per-installation tag the cmux and zellij adapters use against the identical
# shared-namespace hazard. A session carrying another home's tag is recognized
# by shape and skipped entirely, because that home reports its own.
#
# POSITIVE IDENTIFICATION (the safety property)
# An unknown is never a licence to kill. A process is a reapable firstmate
# browser stack only when TWO INDEPENDENT signals agree:
#   1. chrome-devtools-axi's own on-disk registry - a parseable
#      <sessions-root>/<name>/bridge.pid naming a numeric pid > 1 - a file this
#      repo never writes.
#   2. That live pid's own argv contains "chrome-devtools-axi-bridge".
# Both are required, and the conjunction is deliberate. The registry alone
# would trust a recycled pid; the argv alone would be the name-pattern matching
# that makes `Google Chrome` look reapable. Anything failing either signal is
# REFUSED and left alone.
#
# The seven-plus `npm exec chrome-devtools-mcp@latest --autoConnect
# --no-usage-statistics --no-performance-crux` servers belonging to Antigravity
# IDE fail both signals: they have no chrome-devtools-axi registry entry, and
# their argv is chrome-devtools-mcp, never chrome-devtools-axi-bridge. They can
# never be identified and therefore can never be reaped. The captain's own
# Chrome fails both signals for the same reasons.
#
# Reaping prefers the tool's own supported shutdown
# (`CHROME_DEVTOOLS_AXI_SESSION=<name> chrome-devtools-axi stop`), which closes
# the browser and clears the registry record. Only if the identified bridge
# survives that - or the tool is not installed - does it escalate to signalling
# the bridge's own process subtree, leaf-first TERM then KILL, re-verifying each
# pid's identity immediately before every signal so a recycled pid is never hit.
# Descent into that subtree is not on its own permission to signal: a descendant
# must also carry a stack argv marker (see BROWSER_STACK_ARGV_MARKERS), because a
# subtree can transiently hold an unrelated reparented process. A stack whose
# Chrome runs on a caller-supplied CHROME_DEVTOOLS_AXI_USER_DATA_DIR instead of
# the isolated puppeteer profile keeps its bridge and server members reapable but
# leaves those Chrome processes to the tool's own stop; that is the deliberate
# conservative side of the refusal.
#
# Usage:
#   bin/fm-browser-reaper.sh [--report]
#       List every positively identified stack with its owner classification.
#   bin/fm-browser-reaper.sh --detect
#       Print one "BROWSER_LEAK: ..." line per leaked stack and NOTHING when
#       there is none. Cheap enough for the session-start detect phase: a few
#       small file reads plus one bounded `ps -p` over the registered pids, never
#       a process-table scan or a filesystem walk.
#   bin/fm-browser-reaper.sh --reap <task-id>
#       Reap only the stack owned by session fm-<task-id>. Silent no-op when
#       that session has no stack. Never touches any other session.
#   bin/fm-browser-reaper.sh --identify <pid>
#       Print the positive-identification verdict for one pid. Exit 0 when the
#       pid is an identified firstmate bridge, 1 when it is refused.
#   bin/fm-browser-reaper.sh --session-name <task-id>
#       Print the CHROME_DEVTOOLS_AXI_SESSION value this home binds to that
#       task, the same value bin/fm-spawn.sh exports into its pane.
#
# What counts as leaked (--detect):
#   - One of THIS home's task sessions whose state/<task-id>.meta is gone: the
#     task is gone and its browser outlived it. Owned, so the line names the
#     exact reap command. A FM_BROWSER_OWNED_GRACE_SECS floor (default 60)
#     keeps a stack that a just-spawned task has not yet recorded from being
#     called leaked.
#   - Any session carrying ANOTHER firstmate home's tag is skipped in silence at
#     every age: that home owns it and reports it itself.
#   - Any remaining session older than FM_BROWSER_LEAK_AGE_SECS (default 14400,
#     4h). These cannot be attributed to a task at all - the session name is the
#     only ownership signal chrome-devtools-axi offers, and an operator or a
#     worker that overrode CHROME_DEVTOOLS_AXI_SESSION chose a name of its own.
#     Age is the honest rule for that remainder, so these are REPORTED ONLY and
#     are never reaped by --reap, which acts on this home's exact session name.
#
# Environment:
#   FM_HOME                       firstmate home (defaults to the repo root).
#   FM_STATE_OVERRIDE             state directory (defaults to $FM_HOME/state).
#   FM_BROWSER_SESSIONS_ROOT      chrome-devtools-axi session registry root
#                                 (defaults to $HOME/.chrome-devtools-axi/sessions).
#   FM_BROWSER_LEAK_AGE_SECS      age floor for reporting an unattributed stack
#                                 (default 14400).
#   FM_BROWSER_OWNED_GRACE_SECS   age floor before an owned stack with no task
#                                 counts as leaked (default 60).
#   FM_BROWSER_REAP_GRACE_SECS    wait between TERM and KILL when escalating
#                                 (default 2).
#
# Exit codes:
#   0  Success (report printed, detection complete, or reap finished/no-op).
#   1  --identify refused the pid, or a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SESSIONS_ROOT="${FM_BROWSER_SESSIONS_ROOT:-$HOME/.chrome-devtools-axi/sessions}"
LEAK_AGE_SECS="${FM_BROWSER_LEAK_AGE_SECS:-14400}"
OWNED_GRACE_SECS="${FM_BROWSER_OWNED_GRACE_SECS:-60}"
REAP_GRACE_SECS="${FM_BROWSER_REAP_GRACE_SECS:-2}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"

# This home's session-name prefix. The tag ends in an 8-hex digest of the
# resolved FM_ROOT, which is also what lets another home's session be recognized
# by shape below.
BROWSER_SESSION_PREFIX="fm-$(fm_backend_hometag)-"

# The argv marker that proves a live process is a chrome-devtools-axi bridge.
# The bridge always runs as `node <prefix>/chrome-devtools-axi/dist/bin/
# chrome-devtools-axi-bridge.js`. chrome-devtools-mcp servers (Antigravity's
# included) and Chrome itself never carry it.
BRIDGE_ARGV_MARKER='chrome-devtools-axi-bridge'

# The escalation path signals a subtree, and a subtree can transiently hold a
# bystander: a reparented `GoogleUpdater --wake-all` was observed under the
# stack's Chrome. Descent alone is therefore not enough to signal a process.
# Every genuine member of a stack carries one of three argv markers - the
# bridge's own, chrome-devtools-mcp for the server and its telemetry watchdog,
# and the isolated puppeteer profile that EVERY Chrome process in the stack is
# launched with, browser and helpers alike. A descendant matching none of them
# is refused rather than signalled.
BROWSER_STACK_ARGV_MARKERS='chrome-devtools-axi-bridge chrome-devtools-mcp puppeteer_dev_chrome_profile-'

usage() {
  echo "usage: fm-browser-reaper.sh [--report|--detect|--reap <task-id>|--identify <pid>|--session-name <task-id>]" >&2
}

# browser_etime_secs: convert a ps etime field ([[dd-]hh:]mm:ss) to seconds.
# Prints -1 for anything unparseable so callers fail closed on an unknown age.
browser_etime_secs() {  # <etime>
  printf '%s\n' "$1" | awk -F'[-:]' '
    NF == 4 { print ((($1 * 24 + $2) * 60) + $3) * 60 + $4; next }
    NF == 3 { print (($1 * 60) + $2) * 60 + $3; next }
    NF == 2 { print ($1 * 60) + $2; next }
    { print -1 }'
}

# browser_ps_snapshot: one bounded `ps` over the given pids. Emits
# "<pid> <etime-secs> <argv>" per LIVE pid; dead pids are simply absent.
# Bounded by the number of registered sessions, never by the process table.
browser_ps_snapshot() {  # <pid>...
  local list line p etime rest
  list=$(printf '%s\n' "$@" | grep -E '^[0-9]+$' | sort -un | paste -sd, -)
  [ -n "$list" ] || return 0
  # `ps` right-aligns pid, so every field is read after collapsing whitespace
  # rather than by fixed offset. The command is the remainder of the line and
  # keeps its own internal spacing.
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    p=${line%%[[:space:]]*}; line=${line#"$p"}
    line=${line#"${line%%[![:space:]]*}"}
    etime=${line%%[[:space:]]*}; rest=${line#"$etime"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    printf '%s %s %s\n' "$p" "$(browser_etime_secs "$etime")" "$rest"
  done < <(ps -ww -p "$list" -o pid=,etime=,command= 2>/dev/null || true)
  return 0
}

# browser_pid_identity: a pid's start time, used to prove the pid was not
# recycled between identification and signalling.
browser_pid_identity() {  # <pid>
  local out
  out=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) || return 1
  out=$(printf '%s' "$out" | awk '{$1=$1; print}')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

browser_pid_identity_matches() {  # <pid> <identity>
  local now
  now=$(browser_pid_identity "$1") || return 1
  [ "$now" = "$2" ]
}

# browser_session_record_pid: signal 1 - chrome-devtools-axi's own registry.
# Prints the recorded pid, or fails when the record is absent or unparseable.
browser_session_record_pid() {  # <session-name>
  local rec=$SESSIONS_ROOT/$1/bridge.pid pid
  [ -f "$rec" ] || return 1
  [ -L "$rec" ] && return 1
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$rec" 2>/dev/null | head -n 1)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  printf '%s\n' "$pid"
}

# browser_argv_is_bridge: signal 2 - the live process's own argv.
browser_argv_is_bridge() {  # <argv>
  case "$1" in
    *"$BRIDGE_ARGV_MARKER"*) return 0 ;;
  esac
  return 1
}

# browser_argv_is_stack_member: may this descendant of an identified bridge be
# signalled? A process whose argv carries no stack marker is a bystander that
# merely happens to sit in the subtree, and is refused.
browser_argv_is_stack_member() {  # <argv>
  local marker
  for marker in $BROWSER_STACK_ARGV_MARKERS; do
    case "$1" in
      *"$marker"*) return 0 ;;
    esac
  done
  return 1
}

# browser_pid_argv: one process's full argv, or failure when it is gone.
browser_pid_argv() {  # <pid>
  local out
  out=$(ps -ww -p "$1" -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

browser_list_sessions() {
  local dir name
  [ -d "$SESSIONS_ROOT" ] || return 0
  for dir in "$SESSIONS_ROOT"/*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [ -f "$dir/bridge.pid" ] || continue
    printf '%s\n' "$name"
  done
}

# browser_identified_stacks: the single owner of the two-signal rule. Emits
# "<session> <pid> <age-secs>" for every session whose registry record AND live
# argv both agree, and nothing at all for any session that fails either.
browser_identified_stacks() {
  local name pid age argv line p i sessions=() pids=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    pid=$(browser_session_record_pid "$name") || continue
    sessions+=("$name")
    pids+=("$pid")
  done < <(browser_list_sessions)
  [ "${#pids[@]}" -gt 0 ] || return 0
  # One ps call for every candidate, then match each live row back to its
  # session. A row whose argv fails the bridge marker is dropped here: that is
  # the second signal, and without it the registry record alone would be
  # trusted against a recycled pid.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p=${line%% *}; line=${line#* }
    age=${line%% *}; argv=${line#* }
    browser_argv_is_bridge "$argv" || continue
    for i in "${!pids[@]}"; do
      [ "${pids[$i]}" = "$p" ] || continue
      printf '%s %s %s\n' "${sessions[$i]}" "$p" "$age"
    done
  done < <(browser_ps_snapshot "${pids[@]}")
  return 0
}

# browser_classify_session: the attribution rule, and the single owner of the
# three-way split. Sets BROWSER_SESSION_CLASS to one of:
#   mine         - this home's own task; BROWSER_SESSION_TASK holds the task id
#   other-home   - carries a firstmate home tag that is not ours; not our business
#   unattributed - no firstmate ownership evidence at all; age rule applies
BROWSER_SESSION_CLASS=
BROWSER_SESSION_TASK=
browser_classify_session() {  # <session-name>
  BROWSER_SESSION_TASK=
  case "$1" in
    "$BROWSER_SESSION_PREFIX"?*)
      BROWSER_SESSION_CLASS=mine
      BROWSER_SESSION_TASK=${1#"$BROWSER_SESSION_PREFIX"}
      ;;
    fm-*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-?*)
      # The fm-<prefix>-<8hex>-<task-id> shape a firstmate home stamps, with a
      # digest that is not ours: another installation's task.
      BROWSER_SESSION_CLASS=other-home
      ;;
    *)
      BROWSER_SESSION_CLASS=unattributed
      ;;
  esac
}

browser_task_is_live() {  # <task-id>
  [ -f "$STATE/$1.meta" ]
}

cmd_report() {
  local name pid age found=0
  while read -r name pid age; do
    [ -n "$name" ] || continue
    found=1
    browser_classify_session "$name"
    case "$BROWSER_SESSION_CLASS" in
      mine)
        if browser_task_is_live "$BROWSER_SESSION_TASK"; then
          echo "stack $name (pid $pid, ${age}s) - owned by live task $BROWSER_SESSION_TASK"
        else
          echo "stack $name (pid $pid, ${age}s) - LEAKED: task $BROWSER_SESSION_TASK is gone"
        fi
        ;;
      other-home)
        echo "stack $name (pid $pid, ${age}s) - another firstmate home's task; not ours to report or reap"
        ;;
      *)
        echo "stack $name (pid $pid, ${age}s) - unattributed (no firstmate session name)"
        ;;
    esac
  done < <(browser_identified_stacks)
  [ "$found" -eq 1 ] || echo "no identified chrome-devtools-axi browser stacks"
  return 0
}

cmd_detect() {
  local name pid age
  while read -r name pid age; do
    [ -n "$name" ] || continue
    case "$age" in ''|*[!0-9]*) continue ;; esac
    browser_classify_session "$name"
    case "$BROWSER_SESSION_CLASS" in
      mine)
        browser_task_is_live "$BROWSER_SESSION_TASK" && continue
        [ "$age" -ge "$OWNED_GRACE_SECS" ] || continue
        echo "BROWSER_LEAK: task $BROWSER_SESSION_TASK is gone but its browser is still running (session $name, pid $pid, up ${age}s); reap it with: bin/fm-browser-reaper.sh --reap $BROWSER_SESSION_TASK"
        ;;
      other-home)
        # That home reports and reaps its own; saying anything here would invite
        # killing a live sibling's browser.
        continue
        ;;
      *)
        [ "$age" -ge "$LEAK_AGE_SECS" ] || continue
        echo "BROWSER_LEAK: unattributed browser stack (session $name, pid $pid, up ${age}s); if nothing is using it, stop it with: CHROME_DEVTOOLS_AXI_SESSION=$name chrome-devtools-axi stop"
        ;;
    esac
  done < <(browser_identified_stacks)
  return 0
}

cmd_identify() {  # <pid>
  local want=$1 name pid age
  case "$want" in ''|*[!0-9]*)
    echo "refused: '$want' is not a pid" >&2
    return 1
    ;;
  esac
  while read -r name pid age; do
    if [ "$pid" = "$want" ]; then
      echo "identified: pid $want is the chrome-devtools-axi bridge for session $name (up ${age}s)"
      return 0
    fi
  done < <(browser_identified_stacks)
  echo "refused: pid $want is not a positively identified chrome-devtools-axi bridge (needs both a chrome-devtools-axi session record naming it and '$BRIDGE_ARGV_MARKER' in its own argv)" >&2
  return 1
}

# browser_descendants: every descendant pid of <root>, deepest first, from one
# process-table read. Only ever called with a root that already passed the
# two-signal identification, so the subtree is the identified stack's own.
browser_descendants() {  # <root-pid>
  local root=$1 table frontier next found=() parent child idx
  table=$(ps -eo pid=,ppid= 2>/dev/null) || return 0
  frontier=$root
  while [ -n "$frontier" ]; do
    next=""
    while IFS= read -r parent; do
      [ -n "$parent" ] || continue
      while IFS= read -r child; do
        [ -n "$child" ] || continue
        next="$next$child"$'\n'
        found+=("$child")
      done < <(printf '%s\n' "$table" | awk -v p="$parent" '$2 == p { print $1 }')
    done <<EOF
$frontier
EOF
    frontier=$(printf '%s' "$next" | grep -E '^[0-9]+$' || true)
  done
  # Deepest first so a parent never gets the chance to respawn a reaped child.
  for ((idx = ${#found[@]} - 1; idx >= 0; idx--)); do
    printf '%s\n' "${found[$idx]}"
  done
  return 0
}

# browser_kill_stack: escalation path. Signals the identified bridge's own
# subtree, leaf-first, re-verifying each pid's start time immediately before
# every signal so a recycled pid is never hit.
browser_kill_stack() {  # <bridge-pid>
  local root=$1 pid targets=() identities=() ident argv i
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$pid" != "$root" ]; then
      argv=$(browser_pid_argv "$pid") || continue
      if ! browser_argv_is_stack_member "$argv"; then
        echo "browser reap: SKIP pid $pid - in the stack's process tree but carries no stack marker; not ours to signal" >&2
        continue
      fi
    fi
    ident=$(browser_pid_identity "$pid") || continue
    targets+=("$pid")
    identities+=("$ident")
  done < <(browser_descendants "$root"; printf '%s\n' "$root")
  [ "${#targets[@]}" -gt 0 ] || return 0
  for i in "${!targets[@]}"; do
    browser_pid_identity_matches "${targets[$i]}" "${identities[$i]}" || continue
    kill -TERM "${targets[$i]}" 2>/dev/null || true
  done
  sleep "$REAP_GRACE_SECS"
  for i in "${!targets[@]}"; do
    browser_pid_identity_matches "${targets[$i]}" "${identities[$i]}" || continue
    kill -KILL "${targets[$i]}" 2>/dev/null || true
  done
  return 0
}

cmd_reap() {  # <task-id>
  local id=$1 name pid age s p a identity
  case "$id" in ''|*/*|.|..)
    echo "usage: fm-browser-reaper.sh --reap <task-id>" >&2
    return 1
    ;;
  esac
  name="$BROWSER_SESSION_PREFIX$id"
  pid=""
  age=""
  while read -r s p a; do
    if [ "$s" = "$name" ]; then
      pid=$p
      age=$a
      break
    fi
  done < <(browser_identified_stacks)
  if [ -z "$pid" ]; then
    # Either no stack at all, or one this script refuses to identify. A refusal
    # must be visible: an unidentified record is exactly the case where killing
    # would be a guess.
    if browser_session_record_pid "$name" >/dev/null 2>&1; then
      echo "browser reap: REFUSED $name - a session record exists but no live process matching '$BRIDGE_ARGV_MARKER' backs it; leaving it alone" >&2
    fi
    return 0
  fi
  identity=$(browser_pid_identity "$pid") || {
    echo "browser reap: REFUSED $name - cannot read pid $pid identity; leaving it alone" >&2
    return 0
  }
  echo "browser reap: closing browser stack $name (pid $pid, up ${age}s)" >&2
  if command -v chrome-devtools-axi >/dev/null 2>&1; then
    CHROME_DEVTOOLS_AXI_SESSION="$name" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  if ! browser_pid_identity_matches "$pid" "$identity"; then
    echo "browser reap: $name closed" >&2
    return 0
  fi
  echo "browser reap: $name did not stop cleanly; signalling its process tree" >&2
  browser_kill_stack "$pid"
  if browser_pid_identity_matches "$pid" "$identity"; then
    echo "browser reap: WARNING $name bridge pid $pid survived; left for manual inspection" >&2
  else
    echo "browser reap: $name closed" >&2
  fi
  return 0
}

cmd_session_name() {  # <task-id>
  case "${1:-}" in ''|*/*|.|..)
    echo "usage: fm-browser-reaper.sh --session-name <task-id>" >&2
    return 1
    ;;
  esac
  printf '%s%s\n' "$BROWSER_SESSION_PREFIX" "$1"
}

case "${1:---report}" in
  --report|'') cmd_report ;;
  --detect) cmd_detect ;;
  --reap) cmd_reap "${2:-}" ;;
  --identify) cmd_identify "${2:-}" ;;
  --session-name) cmd_session_name "${2:-}" ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    usage
    exit 1
    ;;
esac
