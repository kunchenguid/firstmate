#!/usr/bin/env bash
# Orphaned chrome-devtools-axi browser bridge sweep.
#
# chrome-devtools-axi launches its bridge detached (detached: true), so the
# bridge is its own process-group leader, immediately reparented to init, and
# survives the invoking task. Normal bridge exit removes its pid file and
# SIGTERMs the bridge process group, and the chrome-devtools-mcp child closes
# the browser it launched. But the installed bridge has no parent-liveness
# check: when the task that launched it dies without a farewell signal, the
# bridge keeps its chrome-devtools-mcp children and their detached Chrome tree
# (plus the Chrome profile directory) alive indefinitely.
#
# This library is the sweep that clears those orphans. It is owned by
# bin/fm-bootstrap.sh, the single owner of the startup sweep set:
# fm_browser_bridge_sweep mutate runs only from bootstrap's locked path, and
# fm_browser_bridge_sweep report runs on read-only session starts.
#
# A bridge is reaped only when its owning firstmate task is proven dead:
#
#   1. Attribution. The bridge's own environment (ps eww) must name a task via
#      FM_TASK_ID=<id>, or its CHROME_DEVTOOLS_AXI_SESSION name must match a
#      recorded local task id. A bridge whose environment cannot be read, or
#      which names no firstmate task, is never a candidate - the captain's own
#      browser sessions and every other unattributable automation tree are
#      left alone and reported.
#   2. Owner liveness. A live carrier - any process outside the bridge's own
#      tree whose environment carries the same FM_TASK_ID - proves the task is
#      alive and the bridge is never touched. With no carrier, the task's
#      durable state/<id>.meta endpoint (this home and registered local
#      secondmate homes) is asked through fm_backend_agent_state: alive keeps
#      the bridge, dead|missing reaps it, and ambiguous|unreadable|unverified
#      keeps it with a refusal line. No carrier and no meta anywhere means the
#      task is gone and the tree is orphaned.
#
# Reaping signals the bridge first so its own shutdown path (pid-file removal,
# group SIGTERM, browser close) runs, then escalates through every process
# group the orphaned tree leads - the bridge group, the mcp telemetry
# watchdog group, and the puppeteer Chrome group - because a detached
# automation tree spans more than the bridge's own group. The sweep never
# signals this process or any ancestor, re-reads every signalled process's
# live command immediately before each TERM/KILL pass so a recycled pid is
# never hit, and re-checks the owner verdict immediately before the first
# signal.
#
# Every termination reports the process group, age, and profile directory
# first. After the tree is dead, Chrome profile directories named by its
# --user-data-dir arguments are removed - but only directories whose canonical
# path sits under a temporary root, whose basename contains "profile", and
# which no live command line still names; anything else is reported and left.
#
# Stale bridge pid files (~/.chrome-devtools-axi/bridge.pid and
# ~/.chrome-devtools-axi/sessions/<name>/bridge.pid) whose recorded pid is dead
# or reused by a non-bridge process are removed by the same sweep; unreadable
# ones are reported and left.
#
# Environment:
#   FM_CHROME_AXI_STATE_DIR      bridge state dir override (default
#                                ~/.chrome-devtools-axi); test hook.
#   FM_BROWSER_BRIDGE_PROC_TABLE file holding the tab-separated process table
#                                to use in place of the live scan; test hook,
#                                so a fixture run never reads the host's own
#                                process table.

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fm-secondmate-registry-lib.sh"

fm_browser_bridge_ps_bin() {
  if [ -x /bin/ps ]; then printf '/bin/ps\n';
  elif [ -x /usr/bin/ps ]; then printf '/usr/bin/ps\n';
  else return 1; fi
}

# The bridge binary's stable command signature: the installed entry is always
# a path containing chrome-devtools-axi-bridge.<ext> (bridge.js in the
# published package, bridge.ts under tsx). The verdict never rests on this
# match alone - attribution gates every signal.
fm_browser_bridge_is_bridge_command() { # <command>
  case "$1" in *chrome-devtools-axi-bridge.*) return 0 ;; esac
  return 1
}

# One env var from a live process's environment, last value wins. Empty output
# means either the var is absent or the environment could not be read at all
# (SIP-protected binaries expose nothing through ps eww); callers treat both
# the same way: the tree stays unattributable.
fm_browser_bridge_env_get() { # <pid> <name>
  local pid=$1 name=$2 ps_bin env
  ps_bin=$(fm_browser_bridge_ps_bin) || return 1
  env=$("$ps_bin" eww -p "$pid" -o command= 2>/dev/null) || return 1
  printf '%s\n' "$env" \
    | tr ' ' '\n' \
    | sed -n "s/^${name}=\\([A-Za-z0-9._-]*\\)\$/\\1/p" \
    | tail -1
}

# A live process's command line, used to re-prove identity before a signal.
fm_browser_bridge_process_command() { # <pid>
  local pid=$1 ps_bin
  ps_bin=$(fm_browser_bridge_ps_bin) || return 1
  "$ps_bin" -p "$pid" -o command= 2>/dev/null
}

# The scan rebuilds a command through awk, which collapses every whitespace run
# and trims both ends; a raw `ps -p -o command=` read must be collapsed the same
# way before the two can be compared. `$1=$1` rebuilds $0 with the output field
# separator, which is exactly that collapse.
fm_browser_bridge_normalize_command() { # <command>
  printf '%s\n' "$1" | awk '{$1=$1; print}'
}

# The pid,ppid,pgid,stat,etime,command process table for this uid, one
# TAB-separated record per line so descendant and group membership queries
# work from a single snapshot. FM_BROWSER_BRIDGE_PROC_TABLE (test hook)
# substitutes a prepared table for the live scan so a fixture never reads the
# host's own processes; a set-but-unreadable table is empty, never a live scan.
fm_browser_bridge_scan() { # echoes the table
  local uid ps_bin
  if [ -n "${FM_BROWSER_BRIDGE_PROC_TABLE:-}" ]; then
    cat "${FM_BROWSER_BRIDGE_PROC_TABLE}" 2>/dev/null || true
    return 0
  fi
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  ps_bin=$(fm_browser_bridge_ps_bin) || return 1
  "$ps_bin" -u "$uid" -o pid=,ppid=,pgid=,stat=,etime=,command= 2>/dev/null \
    | awk '{ pid=$1; ppid=$2; pgid=$3; st=$4; et=$5;
             $1=""; $2=""; $3=""; $4=""; $5=""; sub(/^ +/, "");
             printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, pgid, st, et, $0 }'
}

# The environment table used for carrier attribution: pid plus command+env for
# every process this uid owns. `ps ewwx` is the BSD-flag form that accepts a
# format list on both macOS and Linux (`eww -u` rejects -o); the uid column is
# filtered in awk rather than trusting a user flag alongside eww.
fm_browser_bridge_env_scan() { # echoes "pid<tab>command+env"
  local uid ps_bin
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  ps_bin=$(fm_browser_bridge_ps_bin) || return 1
  "$ps_bin" ewwx -o uid=,pid=,command= 2>/dev/null \
    | awk -v u="$uid" '$1 == u { pid=$2; $1=""; $2=""; sub(/^ +/, "");
                                 printf "%s\t%s\n", pid, $0 }'
}

# A pid is "gone" when it no longer exists or is a zombie waiting on reaping;
# a zombie holds no memory and licenses no kill.
fm_browser_bridge_pid_gone() { # <pid>
  local pid=$1 stat ps_bin
  kill -0 "$pid" 2>/dev/null || return 0
  ps_bin=$(fm_browser_bridge_ps_bin) || return 1
  stat=$("$ps_bin" -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]') || true
  case "$stat" in *Z*) return 0 ;; esac
  return 1
}

# This sweep process plus every ancestor, space separated. Built once per
# sweep; an ancestor chain the sweep cannot fully walk still yields the
# provable prefix, which is the safe direction for both exclusion uses.
fm_browser_bridge_self_chain() { # echoes " pid pid ... "
  local walk=$$ out=" " i=0 ps_bin
  ps_bin=$(fm_browser_bridge_ps_bin) || ps_bin="ps"
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    out="$out$walk "
    walk=$("$ps_bin" -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || break
    case "$walk" in ''|*[!0-9]*) break ;; esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# All descendant pids of <root> in <table>, one per line, root included.
fm_browser_bridge_tree_pids() { # <table> <root>
  local table=$1 root=$2 T=$'	'
  local frontier=" $root " all=" $root " next line pid rest
  while [ "${frontier// /}" != "" ]; do
    next=" "
    while IFS= read -r line; do
      pid=${line%%"$T"*}; rest=${line#*"$T"}
      case "$frontier" in *" ${rest%%"$T"*} "*) ;; *) continue ;; esac
      case "$all" in *" $pid "*) continue ;; esac
      all="$all$pid "; next="$next$pid "
    done <<EOF
$table
EOF
    frontier=$next
  done
  printf '%s\n' "$all" | tr ' ' '\n' | sed '/^$/d'
}

# The process groups a tree leads: pgids whose leader (pid==pgid row) is
# itself a member, one per line.
fm_browser_bridge_tree_pgids() { # <table> <tree-pids-nl>
  local table=$1 members=$2 member_set line pid pgid T=$'	'
  member_set=" $(printf '%s\n' "$members" | tr '\n' ' ')"
  while IFS= read -r line; do
    pid=${line%%"$T"*}; line=${line#*"$T"}; line=${line#*"$T"}
    pgid=${line%%"$T"*}
    [ "$pid" = "$pgid" ] || continue
    case "$member_set" in *" $pid "*) printf '%s\n' "$pgid" ;; esac
  done <<EOF
$table
EOF
}

# Every tree member with the command line recorded for it in <table>, as
# "<pid>\t<command>" lines. The command is captured at scan time so each
# signal pass can re-prove the pid still runs it before being hit.
fm_browser_bridge_tree_members() { # <table> <tree-pids-nl>
  local table=$1 members=$2 member_set line pid T=$'\t'
  member_set=" $(printf '%s\n' "$members" | tr '\n' ' ')"
  while IFS= read -r line; do
    pid=${line%%"$T"*}
    case "$member_set" in *" $pid "*) ;; *) continue ;; esac
    printf '%s\t%s\n' "$pid" "${line#*"$T"*"$T"*"$T"*"$T"*"$T"}"
  done <<EOF
$table
EOF
}

# The command line recorded for <pid> in a "<pid>\t<command>" member list.
fm_browser_bridge_member_command() { # <members-nl> <pid>
  local members=$1 want=$2 line pid T=$'\t'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%%"$T"*}
    [ "$pid" = "$want" ] || continue
    printf '%s\n' "${line#*"$T"}"
    return 0
  done <<EOF
$members
EOF
  return 1
}

# Does <pid> still run exactly the command line recorded for it? A recycled
# pid - or one whose command changed - fails this and is never signalled on
# the strength of the earlier snapshot. Both sides are whitespace-normalized so
# the scan's awk rebuild and a raw ps read compare like for like.
fm_browser_bridge_pid_matches() { # <pid> <command>
  local pid=$1 want=$2 live
  live=$(fm_browser_bridge_process_command "$pid") || return 1
  [ "$(fm_browser_bridge_normalize_command "$live")" \
    = "$(fm_browser_bridge_normalize_command "$want")" ]
}

# Is <pid> still the same live tree member the scan recorded - alive, not a
# zombie, and still running its recorded command? A recycled pid fails this
# and is neither waited on nor signalled.
fm_browser_bridge_member_current() { # <members-nl> <pid>
  local members=$1 pid=$2 cmd
  fm_browser_bridge_pid_gone "$pid" && return 1
  cmd=$(fm_browser_bridge_member_command "$members" "$pid") || return 1
  fm_browser_bridge_pid_matches "$pid" "$cmd"
}

# Every --user-data-dir path named by the tree's command lines, deduplicated.
fm_browser_bridge_profile_dirs() { # reads command lines on stdin
  sed -n \
    -e 's/.*--user-data-dir=\([^ ]*\).*/\1/p' \
    -e 's/.*--user-data-dir[[:space:]][[:space:]]*\([^ ]*\).*/\1/p' \
    | sort -u
}

# Canonical absolute path: resolve the deepest existing ancestor's physical
# path and append the remainder.
fm_browser_bridge_canonical() { # <path>
  local path=$1 dir base
  case "$path" in /*) ;; *) return 1 ;; esac
  dir=$path
  while [ ! -d "$dir" ]; do
    dir=$(dirname "$dir")
    case "$dir" in /|.) return 1 ;; esac
  done
  base=${path#"$dir"}
  (CDPATH='' cd "$dir" 2>/dev/null && printf '%s%s\n' "$(pwd -P)" "$base")
}

# May this directory be removed as an orphaned automation profile? Only an
# existing, non-symlink directory whose canonical path sits strictly under a
# temporary root and whose basename marks it as a browser profile; anything
# else is left for a human. Echoes the canonical path on success.
fm_browser_bridge_profile_dir_removable() { # <dir>
  local dir=$1 canon root roots base found=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  case "$dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  canon=$(fm_browser_bridge_canonical "$dir") || return 1
  base=${canon##*/}
  case "$base" in *[Pp]rofile*) ;; *) return 1 ;; esac
  roots="/tmp"$'\n'"${TMPDIR:-/tmp}"$'\n'"/var/tmp"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    root=$(fm_browser_bridge_canonical "$root" 2>/dev/null || true)
    [ -n "$root" ] || continue
    if [ "$canon" != "$root" ]; then
      case "$canon/" in "$root/"*) found=1 ;; esac
    fi
  done <<EOF
$roots
EOF
  [ "$found" -eq 1 ] || return 1
  printf '%s\n' "$canon"
}

# Would deleting <dir> (as named by the tree, or its canonical form) discard a
# profile another live process still names? A stable, reused
# CHROME_DEVTOOLS_AXI_USER_DATA_DIR can belong to a live task as easily as to
# the dead tree being reaped, so the live process table is re-scanned and any
# live, non-zombie command line that names the path refuses the removal. A
# failed scan is treated as in use: never delete on an unproven answer.
fm_browser_bridge_profile_dir_in_use() { # <dir> <canonical-dir>
  local dir=$1 canon=$2 table line stat command T=$'\t'
  table=$(fm_browser_bridge_scan) || return 0
  [ -n "$table" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    stat=${line#*"$T"}; stat=${stat#*"$T"}; stat=${stat#*"$T"}; stat=${stat%%"$T"*}
    case "$stat" in *Z*) continue ;; esac
    command=${line#*"$T"*"$T"*"$T"*"$T"*"$T"}
    case "$command" in
      *"$canon"*|*"$dir"*) return 0 ;;
    esac
  done <<EOF
$table
EOF
  return 1
}

# Carriers of FM_TASK_ID=<id> outside every bridge tree; any such process
# proves the owning task is alive. Echoes carrier pids; empty means none
# found. The match requires a space, tab, or line edge on both sides so
# lookalike variables (MYFM_TASK_ID) cannot count. Members of ANY bridge tree
# are excluded: two orphaned trees sharing one dead task id would otherwise
# count each other's env-inheriting descendants as proof of life and veto
# each other forever.
fm_browser_bridge_task_carriers() { # <env-table> <task-id> <excluded-pids-nl> <self-chain>
  local envtable=$1 id=$2 excluded=$3 self=$4 line pid excluded_set T=$'	'
  excluded_set=" $(printf '%s\n' "$excluded" | tr '\n' ' ')"
  while IFS= read -r line; do
    pid=${line%%"$T"*}
    case "$line" in
      *" FM_TASK_ID=$id "*|*" FM_TASK_ID=$id"|*$'\t'"FM_TASK_ID=$id "*|*$'\t'"FM_TASK_ID=$id") ;; *) continue ;;
    esac
    case "$excluded_set" in *" $pid "*) continue ;; esac
    case "$self" in *" $pid "*) continue ;; esac
    printf '%s\n' "$pid"
  done <<EOF
$envtable
EOF
}

# State directories that may hold this task's meta: the sweeping home's own
# plus every locally registered secondmate home's. Remote homes never run
# local bridges, so their records are irrelevant here.
fm_browser_bridge_local_state_dirs() { # <own-state> <registry-file-or-empty>
  local state=$1 registry=$2 line
  printf '%s\n' "$state"
  [ -n "$registry" ] && [ -f "$registry" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        if secondmate_registry_parse_line "$line" 2>/dev/null \
          && [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ]; then
          case "$SECONDMATE_REGISTRY_HOME" in
            /*) [ -d "$SECONDMATE_REGISTRY_HOME/state" ] \
                  && printf '%s\n' "$SECONDMATE_REGISTRY_HOME/state" ;;
          esac
        fi ;;
    esac
  done < "$registry"
}

# Task liveness verdict: alive | dead | unknown.
#   alive   - a carrier process exists, or a recorded endpoint is live.
#   dead    - no carrier, and either no meta at all or a meta endpoint proven
#             dead|missing by fm_backend_agent_state.
#   unknown - a meta exists but its endpoint cannot be proven either way; the
#             bridge is refused, never reaped.
# <excluded-pids> is the newline list of pids that cannot prove liveness: the
# union of every detected bridge tree's members plus this sweep and its
# ancestors.
fm_browser_bridge_task_state() { # <env-table> <excluded-pids> <task-id> <own-state> <registry> <self-chain>
  local envtable=$1 excluded=$2 id=$3 state=$4 registry=$5 self=$6
  local carriers dir meta backend target ep_state
  carriers=$(fm_browser_bridge_task_carriers "$envtable" "$id" "$excluded" "$self")
  [ -n "$carriers" ] && { printf 'alive\n'; return 0; }
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    meta="$dir/$id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then printf 'unknown\n'; return 0; fi
    ep_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unverified')
    case "$ep_state" in
      alive) printf 'alive\n' ;;
      dead|missing) printf 'dead\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  done <<EOF
$(fm_browser_bridge_local_state_dirs "$state" "$registry")
EOF
  printf 'dead\n'
}

# Stop an orphaned bridge tree: TERM the bridge pid first so its own shutdown
# path (pid-file removal, group SIGTERM, browser close) runs, then TERM and
# finally KILL every process group the tree still leads. Members are
# "<pid>\t<command>" lines from the scan, and every signal pass re-proves the
# target still runs its recorded command first, so a pid recycled in the
# seconds this takes is never hit. Returns non-zero when any tree member
# survives.
fm_browser_bridge_stop_tree() { # <root-pid> <members: pid\tcmd-nl> <tree-pgids-nl>
  local root=$1 members=$2 pgids=$3 pid cmd pgid i alive T=$'\t'
  fm_browser_bridge_member_current "$members" "$root" \
    && kill -TERM "$root" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ]; do
    alive=0
    while IFS= read -r pid; do
      pid=${pid%%"$T"*}
      [ -n "$pid" ] || continue
      fm_browser_bridge_member_current "$members" "$pid" && alive=1
    done <<EOF
$members
EOF
    [ "$alive" -eq 0 ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  while IFS= read -r pgid; do
    [ -n "$pgid" ] || continue
    cmd=$(fm_browser_bridge_member_command "$members" "$pgid") || continue
    fm_browser_bridge_pid_matches "$pgid" "$cmd" || continue
    kill -0 -- "-$pgid" 2>/dev/null && kill -TERM -- "-$pgid" 2>/dev/null || true
  done <<EOF
$pgids
EOF
  i=0
  while [ "$i" -lt 30 ]; do
    alive=0
    while IFS= read -r pid; do
      pid=${pid%%"$T"*}
      [ -n "$pid" ] || continue
      fm_browser_bridge_member_current "$members" "$pid" && alive=1
    done <<EOF
$members
EOF
    [ "$alive" -eq 0 ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  while IFS= read -r pgid; do
    [ -n "$pgid" ] || continue
    cmd=$(fm_browser_bridge_member_command "$members" "$pgid") || continue
    fm_browser_bridge_pid_matches "$pgid" "$cmd" || continue
    kill -0 -- "-$pgid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null || true
  done <<EOF
$pgids
EOF
  while IFS= read -r pid; do
    pid=${pid%%"$T"*}
    [ -n "$pid" ] || continue
    fm_browser_bridge_member_current "$members" "$pid" || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<EOF
$members
EOF
  i=0
  while [ "$i" -lt 30 ]; do
    alive=0
    while IFS= read -r pid; do
      pid=${pid%%"$T"*}
      [ -n "$pid" ] || continue
      fm_browser_bridge_member_current "$members" "$pid" && alive=1
    done <<EOF
$members
EOF
    [ "$alive" -eq 0 ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

# Stale bridge pid files under the axi state dir: a file is stale only when
# its recorded pid is dead or now belongs to a non-bridge process. Echoes
# "<file>\t<pid|unreadable>[\t<dead|reused>]" entries for the caller to act on.
fm_browser_bridge_stale_pidfiles() { # <state-dir>
  local state_dir=$1 f pid live_cmd
  [ -d "$state_dir" ] || return 0
  for f in "$state_dir/bridge.pid" "$state_dir"/sessions/*/bridge.pid; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
    case "$pid" in
      ''|*[!0-9]*) printf '%s\tunreadable\n' "$f"; continue ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
      live_cmd=$(fm_browser_bridge_process_command "$pid" || true)
      fm_browser_bridge_is_bridge_command "$live_cmd" && continue
      printf '%s\t%s\treused\n' "$f" "$pid"
    else
      printf '%s\t%s\tdead\n' "$f" "$pid"
    fi
  done
}

# The sweep. mode=mutate reaps and removes; mode=report only prints findings.
# Prints BROWSER_BRIDGES lines; silence means nothing needed doing. Always
# returns 0 once the scan ran - a sweep failure must never fail session start.
#
# Two passes over one process snapshot: pass 1 collects every bridge-signature
# row and unions each tree's pids into the bridge world; pass 2 evaluates each
# candidate. The world set is the carrier-exclusion set - no member of any
# bridge tree may testify that a task is alive, or two orphaned trees sharing
# one dead task id would keep each other running forever.
fm_browser_bridge_sweep() { # <mutate|report> [own-state] [registry]
  local mode=$1 state=${2:-${STATE:-}} registry=${3:-${DATA:-}/secondmates.md} T=$'	'
  local table envtable state_dir self line pid pgid stat etime command
  local session task_id tree tree_members tree_pgids profiles verdict live_cmd
  local joined_profiles f fp fstale d tp
  local candidates world_nl
  table=$(fm_browser_bridge_scan) || {
    echo "BROWSER_BRIDGES: process scan failed; sweep did not run"
    return 1
  }
  self=$(fm_browser_bridge_self_chain)
  state_dir=${FM_CHROME_AXI_STATE_DIR:-$HOME/.chrome-devtools-axi}
  candidates=
  world_nl=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%%"$T"*}
    stat=${line#*"$T"}; stat=${stat#*"$T"}; stat=${stat#*"$T"}
    stat=${stat%%"$T"*}
    case "$stat" in
      *Z*) world_nl="$world_nl$pid"$'\n' ;;  # a zombie testifies to nothing
    esac
    command=${line#*"$T"}; command=${command#*"$T"}; command=${command#*"$T"}
    command=${command#*"$T"}; command=${command#*"$T"}
    fm_browser_bridge_is_bridge_command "$command" || continue
    candidates="$candidates$line"$'\n'
    world_nl="$world_nl$(fm_browser_bridge_tree_pids "$table" "$pid")"$'\n'
  done <<EOF
$table
EOF
  # The environment table is only needed once a candidate exists; scanning the
  # whole env table on every startup is wasted work when no bridge runs.
  if [ -n "$candidates" ]; then envtable=$(fm_browser_bridge_env_scan) || envtable=; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%%"$T"*}; line=${line#*"$T"}
    line=${line#*"$T"}
    pgid=${line%%"$T"*}; line=${line#*"$T"}
    stat=${line%%"$T"*}; line=${line#*"$T"}
    etime=${line%%"$T"*}; line=${line#*"$T"}
    command=$line
    case "$stat" in *Z*) continue ;; esac
    case "$self" in *" $pid "*) continue ;; esac
    session=$(fm_browser_bridge_env_get "$pid" CHROME_DEVTOOLS_AXI_SESSION 2>/dev/null || true)
    task_id=$(fm_browser_bridge_env_get "$pid" FM_TASK_ID 2>/dev/null || true)
    tree=$(fm_browser_bridge_tree_pids "$table" "$pid")
    # Session-name fallback: a named session matching a recorded local task id
    # attributes the bridge when FM_TASK_ID itself is unreadable.
    if [ -z "$task_id" ] && [ -n "$session" ]; then
      while IFS= read -r d; do
        if [ -f "$d/$session.meta" ] && [ ! -L "$d/$session.meta" ]; then task_id=$session; break; fi
      done <<EOF
$(fm_browser_bridge_local_state_dirs "$state" "$registry")
EOF
    fi
    if [ -z "$task_id" ]; then
      echo "BROWSER_BRIDGES: left bridge pid=$pid pgid=$pgid session=${session:-?} age=$etime running - owner is not attributable to a firstmate task"
      continue
    fi
    verdict=$(fm_browser_bridge_task_state "$envtable" "$world_nl" "$task_id" "$state" "$registry" "$self")
    case "$verdict" in
      alive) continue ;;
      unknown)
        echo "BROWSER_BRIDGES: left bridge pid=$pid pgid=$pgid session=${session:-?} task=$task_id age=$etime running - owner could not be proven dead"
        continue ;;
      dead) ;; *) continue ;;
    esac
    tree_pgids=$(fm_browser_bridge_tree_pgids "$table" "$tree")
    profiles=$(while IFS= read -r tp; do
      [ -n "$tp" ] && fm_browser_bridge_process_command "$tp"
    done <<EOF2 | fm_browser_bridge_profile_dirs
$tree
EOF2
)
    joined_profiles=$(printf '%s\n' "$profiles" | paste -sd, - 2>/dev/null)
    [ -n "$joined_profiles" ] || joined_profiles=-
    if [ "$mode" = report ]; then
      echo "BROWSER_BRIDGES: orphaned bridge pid=$pid pgid=$pgid session=${session:-?} task=$task_id age=$etime profile=$joined_profiles - not reaped (report-only run)"
      continue
    fi
    echo "BROWSER_BRIDGES: reaping orphaned bridge pid=$pid pgid=$pgid session=${session:-?} task=$task_id age=$etime profile=$joined_profiles"
    # Last-instant rechecks: the bridge must still be the same live bridge,
    # and a task carrier that appeared since the scan cancels the reap.
    live_cmd=$(fm_browser_bridge_process_command "$pid" || true)
    if ! fm_browser_bridge_is_bridge_command "$live_cmd"; then
      echo "BROWSER_BRIDGES: bridge pid=$pid vanished or changed before signalling - skipped"
      continue
    fi
    envtable=$(fm_browser_bridge_env_scan) || envtable=
    if [ "$(fm_browser_bridge_task_state "$envtable" "$world_nl" "$task_id" "$state" "$registry" "$self")" != dead ]; then
      echo "BROWSER_BRIDGES: bridge pid=$pid owner state changed before signalling - skipped"
      continue
    fi
    tree_members=$(fm_browser_bridge_tree_members "$table" "$tree")
    if fm_browser_bridge_stop_tree "$pid" "$tree_members" "$tree_pgids"; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if fp=$(fm_browser_bridge_profile_dir_removable "$f" 2>/dev/null); then
          if fm_browser_bridge_profile_dir_in_use "$f" "$fp"; then
            echo "BROWSER_BRIDGES: left profile dir $fp - a live process still names it (task=$task_id)"
          elif rm -rf -- "$fp" 2>/dev/null; then
            echo "BROWSER_BRIDGES: removed browser profile dir $fp (task=$task_id)"
          else
            echo "BROWSER_BRIDGES: could not remove browser profile dir $fp (task=$task_id) - left for a human"
          fi
        else
          echo "BROWSER_BRIDGES: left profile dir $f - outside the removable rules (task=$task_id)"
        fi
      done <<EOF
$profiles
EOF
    else
      echo "BROWSER_BRIDGES: warning: orphaned bridge pid=$pid tree partially survived the sweep - left running"
    fi
  done <<EOF
$candidates
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f=${line%%"$T"*}; line=${line#*"$T"}
    fstale=${line%%"$T"*}
    case "$fstale" in
      unreadable)
        echo "BROWSER_BRIDGES: unreadable bridge pid file $f - left alone" ;;
      *)
        if [ "$mode" = report ]; then
          echo "BROWSER_BRIDGES: stale bridge pid file $f (recorded pid $fstale ${line##*"$T"}) - left for a mutating run"
        elif rm -f -- "$f" 2>/dev/null; then
          echo "BROWSER_BRIDGES: removed stale bridge pid file $f (recorded pid $fstale ${line##*"$T"})"
        else
          echo "BROWSER_BRIDGES: could not remove stale bridge pid file $f"
        fi ;;
    esac
  done <<EOF
$(fm_browser_bridge_stale_pidfiles "$state_dir")
EOF
  return 0
}
