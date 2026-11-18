#!/usr/bin/env bash
# ak47/guards/agent-reclaim.sh - reclaim resident agents nobody is using.
#
# Why: on 2026-11-17 ak47 reached load 121 on 32 threads with 218-232 resident
# pi agents. The load came from per-agent polling (Orca terminal polls, per-task
# /proc scans), which scales with how many agents are resident, not with how
# much work they do. Dozens were leftovers: agents whose task record no home
# still had, agents silent for a day, and secondmate homes far over their cap.
# Nothing removed them, so the box got slower every day. This is that monitor.
#
# One census pass over every resident agent process (pi, pi-signed, claude,
# codex, opencode, grok, kimi, rovo, muse, cursor-agent, gemini), matched by
# exact process name or argv[0] basename. Firstmate's own process vocabulary is
# fm_backend_tmux_classify_process_name (bin/backends/tmux.sh); this list is
# deliberately narrower (exact names, no globs, no bare node) because the guard
# also runs from an installed copy with no firstmate checkout, and a process it
# cannot name with certainty is simply never touched. Each agent is mapped to
# its owning home by its working directory against the worktree= of every
# task record (state/<id>.meta) in every registered home: the main home and
# every local home in data/secondmates.md. Each agent lands in exactly one class:
#
#   chair     a home's session-lock holder, an agent working in a home's own
#             directory, or a secondmate's own agent. Never touched.
#   task      a live task record owns it. Stopped only when IDLE or over a cap.
#   orphan    no record in any home owns it, it works inside a task worktree
#             root, and it is older than reclaim_orphan_min (default 120).
#   unowned   none of the above (an interactive session, a pipeline agent under
#             ~/.no-mistakes). Counted, reported, never touched.
#   nested    a descendant of another agent; it lives and dies with its parent.
#
# IDLE means the task's status log has not been written for reclaim_idle_min
# (default 1440 = 24 h). A cap stop may take a task whose status has been quiet
# for reclaim_cap_idle_min (default 360 = 6 h), oldest status first.
#
# WORKING is a hard veto on every action, checked from the kernel, not from any
# status line: an agent with a child process (a running tool) or whose own CPU
# time advanced by more than reclaim_busy_ticks (default 5) clock ticks across a
# reclaim_sample_secs (default 20) sample is working. Measured on ak47: an idle
# pi agent uses 0 ticks in 20 s, a working one tens to thousands. A task whose
# state/<id>.busy-state reads busy is working too, even with a quiet process,
# and so is a task with an armed state/<id>.check.sh: something still monitors
# it, and stopping its agent would leave that monitor's next result unowned.
# A task with an unread steering message (state/<id>.inbox/*.msg) is kept, so
# an instruction is never stranded on a stopped agent, and so is a task whose
# branch has a no-mistakes validation that is not finished: the worker owns that
# run's gates. The validation read is one bounded `no-mistakes runs --limit 200`
# per repository, and the branch's newest row alone decides because older rows
# are history. A repository no-mistakes does not manage has no validation, and a
# read that fails any other way - including no usable no-mistakes binary - keeps
# every task in that repository, because it cannot prove none is running.
# A task that still holds unfinished work for someone is kept too, because a
# stop is now permanent (see Actions): an open decision from the shared status
# classifier (status_open_decisions in bin/fm-classify-lib.sh); a last status
# line that is
# needs-decision, blocked, waiting, or paused, or that says it awaits a review,
# approval, decision, or merge; a GitHub PR the task names (the record's pr= and
# every GitHub PR URL in its last status line, because the two can disagree and
# only one of them may say the live PR) that `gh pr view` reads as open, or
# cannot read at all, or a
# PR on another forge, which is kept unread; and a worktree whose HEAD has
# commits on no pushed branch (skipped once the PR reads merged), or uncommitted
# changes to tracked files, or whose git state cannot be read.
# Cap stops take tasks whose last report is done or failed before quiet live
# ones.
# A task listed in $AK47_CONFIG/reclaim-keep (one id per line) or whose record
# carries reclaim=keep is never stopped: that is how a resident monitor lane
# that legitimately sits quiet for a day stays up.
#
# Actions, each only with --apply, at most reclaim_max_stops (default 20) agents
# per run, oldest first, orphans before idle tasks before cap stops:
#   orphan          SIGTERM the agent by its exact pid, after re-checking that
#                   the pid still has the start time the census saw.
#   idle / cap      bin/fm-control.sh <task> exit in the owning home, which stops
#                   the agent and keeps its endpoint, worktree, and every change.
#                   Orca cannot deliver the exit keys, so an Orca task, or any
#                   task whose exit does not complete, falls back to SIGTERM of
#                   the agent's exact pid. Every stopped task is then marked
#                   left stopped through bin/fm-leave-stopped.sh in its home
#                   (state/<id>.stopped), which the fleet watchdog and watcher
#                   honour, so it is never relaunched behind the reclaim. No
#                   task is stopped when that script is missing, and a stop
#                   whose mark fails is a finding. Revert: fm-leave-stopped.sh
#                   <id> clear, then fm-control.sh <id> relaunch.
#   status archive  a home's state/<id>.status with no <id>.meta, older than
#                   reclaim_orphan_min, moves (never deletes) to that home's
#                   data/orphan-status-archive-<date>/. Revert: move it back.
#   dead watcher    a home whose chair is dead on two runs at least 10 min apart
#                   but whose watcher is still running: that watcher alone is
#                   stopped by the pid its own state/.watch.lock records, after
#                   the lock's recorded identity matches the live process. Never
#                   a pattern kill, never while that home's chair is alive.
#
# Never: delete a worktree, tear down a task, discard work, touch a *.check.sh
# monitor, send SIGKILL, or touch a home's chair or watcher while its chair is
# alive. An agent that ignores SIGTERM is reported, not escalated.
#
# Caps come from ak47/budget.conf: agent_count (box-wide, every resident agent)
# and home_children (per secondmate home, overridden by the first positive
# whole number in that home's config/*-cap file). Over a cap the guard stops the
# oldest idle agents first and never a working one; whatever it cannot settle
# is a finding, filed through ak47_deliver_findings as a check wake.
#
# Usage: agent-reclaim.sh [--dry-run | --apply] [--print]
#        agent-reclaim.sh --stop-watcher <home> [--dry-run]
#   --dry-run       (default) census and report what --apply would do
#   --apply         act on the report (the 15-minute unit runs this)
#   --print         print the per-agent report after the run
#   --stop-watcher  stop one registered home's watcher by its recorded pid, only
#                   when that home's chair is not alive; the operator path for a
#                   dead home, and the only watcher stop that needs no second run
#
# Outputs, under $AK47_STATE (default ~/.local/state/ak47):
#   agent-reclaim.log        one line per run, always
#   agent-reclaim-latest.md  the per-agent report of the last run
#   agent-reclaim.line       the last run's one line, which health-latest.md shows
#   agent-reclaim.children   the largest secondmate child count (budget metric)
#   reap.log                 one line per action, with its revert
#
# Knobs live in $AK47_CONFIG/devops.conf (parsed, never sourced):
#   reclaim_orphan_min reclaim_idle_min reclaim_cap_idle_min reclaim_max_stops
#   reclaim_sample_secs reclaim_busy_ticks reclaim_term_wait reclaim_max_archive
#   reclaim_run_budget (default 600 s; stops left when it runs out wait a run)
#   reclaim_worktree_roots   colon list (default ~/.treehouse:~/orca/workspaces)
# AK47_RECLAIM_SCOPE (tests only) restricts the census to agents working under
# one directory, so a test never sees the box's real agents.
# AK47_NO_MISTAKES (tests only) points the validation read at a fake binary;
# AK47_LEAVE_STOPPED, AK47_GH, and AK47_CLASSIFY_LIB do the same for the
# left-stopped mark, the PR state read, and the status classifier.
#
# Exit: 0 the run completed (a finding or a stop that did not take is not a
# failure), 1 a step failed, 2 bad usage or a malformed knob.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=../lib/common.sh
. "$AK47_ROOT/lib/common.sh"

APPLY=0; PRINT=0; STOP_WATCHER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) APPLY=0; shift ;;
    --apply) APPLY=1; shift ;;
    --print) PRINT=1; shift ;;
    --stop-watcher) STOP_WATCHER=${2:?--stop-watcher needs a home directory}; shift 2 ;;
    -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "agent-reclaim.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# The firstmate code that owns lifecycle and lock identity. A checkout runs the
# bin/ next to ak47/; an installed copy (~/.local/lib/ak47) uses the main home's.
if [ -x "$AK47_ROOT/../bin/fm-control.sh" ]; then
  FM_CODE=$(cd "$AK47_ROOT/.." && pwd -P)
else
  FM_CODE=$FM_HOME
fi
FM_CONTROL=${AK47_FM_CONTROL:-$FM_CODE/bin/fm-control.sh}
FM_LOCK=$FM_CODE/bin/fm-lock.sh
LEAVE_STOPPED=${AK47_LEAVE_STOPPED:-$FM_CODE/bin/fm-leave-stopped.sh}
GH=${AK47_GH:-gh}
FM_WAKE_LIB=$FM_CODE/bin/fm-wake-lib.sh
CLASSIFY_LIB=${AK47_CLASSIFY_LIB:-$FM_CODE/bin/fm-classify-lib.sh}
CLASSIFY_OK=0
if [ -r "$CLASSIFY_LIB" ]; then
  # shellcheck source=../../bin/fm-classify-lib.sh
  # shellcheck disable=SC1090
  if . "$CLASSIFY_LIB" >/dev/null 2>&1; then
    declare -F status_open_decisions >/dev/null && CLASSIFY_OK=1
  fi
fi

ORPHAN_MIN=$(ak47_conf reclaim_orphan_min 120)
IDLE_MIN=$(ak47_conf reclaim_idle_min 1440)
CAP_IDLE_MIN=$(ak47_conf reclaim_cap_idle_min 360)
MAX_STOPS=$(ak47_conf reclaim_max_stops 20)
SAMPLE_SECS=$(ak47_conf reclaim_sample_secs 20)
BUSY_TICKS=$(ak47_conf reclaim_busy_ticks 5)
TERM_WAIT=$(ak47_conf reclaim_term_wait 10)
MAX_ARCHIVE=$(ak47_conf reclaim_max_archive 500)
RUN_BUDGET=$(ak47_conf reclaim_run_budget 600)
ROOTS=$(ak47_conf reclaim_worktree_roots "$HOME/.treehouse:$HOME/orca/workspaces")
SCOPE=${AK47_RECLAIM_SCOPE:-}
HARNESS_NAMES="pi pi-signed claude codex opencode grok kimi rovo muse cursor-agent gemini"

LOG=$AK47_STATE/agent-reclaim.log
REPORT=$AK47_STATE/agent-reclaim-latest.md
LINE_FILE=$AK47_STATE/agent-reclaim.line
CHILDREN_FILE=$AK47_STATE/agent-reclaim.children
REAP_LOG=$AK47_STATE/reap.log
FIND_LOG=$AK47_STATE/findings.log
CHAIR_SEEN=$AK47_STATE/reclaim-chair-dead
MODE=$([ "$APPLY" = 1 ] && echo apply || echo dry-run)
NOW=$(ak47_epoch)

budget_cap() {  # <key> <default>
  local v
  v=$(awk -F'|' -v k="$1" '$1==k{print $2; exit}' "$AK47_BUDGET" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}
BOX_CAP=$(budget_cap agent_count 96)
HOME_CAP=$(budget_cap home_children 6)

for v in ORPHAN_MIN IDLE_MIN CAP_IDLE_MIN MAX_STOPS SAMPLE_SECS BUSY_TICKS TERM_WAIT MAX_ARCHIVE RUN_BUDGET; do
  case "${!v}" in ''|*[!0-9]*) echo "agent-reclaim.sh: devops.conf value for $v is not a whole number: ${!v}" >&2; exit 2 ;; esac
done

# One run at a time: a slow stop must never overlap the next timer firing.
exec 9>"$AK47_STATE/.agent-reclaim.lock" || exit 1
flock -n 9 || { echo "agent-reclaim.sh: another run holds $AK47_STATE/.agent-reclaim.lock" >&2; exit 0; }

findings=()
finding() { findings+=("$1|$2"); }
reap() { ak47_log "$REAP_LOG" "agent-reclaim $*"; }
# A readable, collision-free key: the tail of the name plus a checksum of the
# whole of it, so two long paths that share a prefix never share a key.
key_of() {
  local sum
  sum=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s-%s' "$(printf '%s' "${1##*/}" | tr -c 'A-Za-z0-9' '-' | cut -c1-60)" "$sum"
}

# ---- homes ---------------------------------------------------------------------
# The main home plus every local secondmate home that has a state/ directory.
# A remote route (host:path) is not a local directory and is skipped.
declare -a HOMES=()
declare -A HOME_SEEN=()
add_home() {
  local h
  h=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  [ -d "$h/state" ] || return 0
  [ -n "${HOME_SEEN[$h]:-}" ] && return 0
  HOME_SEEN[$h]=1
  HOMES+=("$h")
}
add_home "$FM_HOME"
MAIN_HOME=${HOMES[0]:-}
if [ -r "$FM_HOME/data/secondmates.md" ]; then
  while IFS= read -r h; do
    [ -n "$h" ] && add_home "$h"
  done < <(sed -n 's/.*(home: \([^;)]*\)[;)].*/\1/p' "$FM_HOME/data/secondmates.md")
fi

# A home's chair is alive when its session lock names a live harness process;
# bin/fm-lock.sh is the one owner of that decision.
chair_alive() {  # <home>
  local out
  [ -x "$FM_LOCK" ] || return 0   # cannot prove it dead: treat as alive
  out=$(FM_HOME=$1 FM_STATE_OVERRIDE=$1/state "$FM_LOCK" status 2>/dev/null) || return 0
  case "$out" in "lock: held by live harness pid"*) return 0 ;; "lock: free"|"lock: stale"*) return 1 ;; esac
  return 0
}

# Stop one home's watcher by the pid its own lock records, after the lock's
# recorded identity matches the live process (bin/fm-wake-lib.sh owns that
# match). Prints what it did; returns 0 stopped or nothing to stop, 1 refused.
stop_home_watcher() {  # <home> <apply 0|1>
  local home=$1 apply=$2 lock pid wpath
  lock=$home/state/.watch.lock
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) echo "no watcher recorded for $home"; return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || { echo "watcher pid $pid for $home is not running"; return 0; }
  wpath=$(cat "$lock/watcher-path" 2>/dev/null || true)
  [ -r "$FM_WAKE_LIB" ] || { echo "cannot verify watcher identity: $FM_WAKE_LIB missing"; return 1; }
  if ! (
    # shellcheck disable=SC2034 # read by the sourced library below
    FM_HOME=$home STATE=$home/state FM_STATE_OVERRIDE=$home/state
    # shellcheck source=../../bin/fm-wake-lib.sh
    . "$FM_WAKE_LIB" >/dev/null 2>&1
    fm_watcher_lock_matches_pid "$home/state" "$wpath" "$pid" "$home"
  ); then
    echo "watcher pid $pid for $home does not match its recorded identity; not stopped"
    return 1
  fi
  if [ "$apply" != 1 ]; then
    echo "would stop watcher pid $pid for $home (chair dead)"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || { echo "could not signal watcher pid $pid for $home"; return 1; }
  reap "watcher-stop home=$home pid=$pid reason=chair-dead revert: FM_HOME=$home $FM_CODE/bin/fm-watch-arm.sh"
  echo "stopped watcher pid $pid for $home (chair dead)"
  return 0
}

if [ -n "$STOP_WATCHER" ]; then
  target=$(cd "$STOP_WATCHER" 2>/dev/null && pwd -P) || { echo "agent-reclaim.sh: no such home: $STOP_WATCHER" >&2; exit 2; }
  [ -n "${HOME_SEEN[$target]:-}" ] || { echo "agent-reclaim.sh: $target is not a registered home (main home or data/secondmates.md)" >&2; exit 2; }
  if chair_alive "$target"; then
    echo "agent-reclaim.sh: the chair of $target is alive; its watcher is not this guard's to stop" >&2
    exit 1
  fi
  stop_home_watcher "$target" "$APPLY"
  exit $?
fi

# ---- task records --------------------------------------------------------------
# One awk per home: worktree<TAB>home<TAB>id<TAB>kind<TAB>backend for every meta.
META_INDEX=$(mktemp "${TMPDIR:-/tmp}/ak47-reclaim.XXXXXX") || exit 1
trap 'rm -f "$META_INDEX"' EXIT
declare -A META_IDS=()   # "<home>/<id>" -> 1
declare -A KNOWN_ID=()   # "<id>" -> 1, across every home
for h in "${HOMES[@]}"; do
  set -- "$h"/state/*.meta
  [ -e "$1" ] || continue
  awk -v home="$h" '
    function flush() { if (file != "") print wt "\t" home "\t" id "\t" kind "\t" backend }
    FNR == 1 { flush(); file = FILENAME; id = FILENAME; sub(/.*\//, "", id); sub(/\.meta$/, "", id); wt = ""; kind = "ship"; backend = "tmux" }
    /^worktree=/ { wt = substr($0, 10) }
    /^kind=/ { kind = substr($0, 6) }
    /^backend=/ { backend = substr($0, 9) }
    END { flush() }
  ' "$@" >>"$META_INDEX"
  for f in "$@"; do
    f=${f##*/}; META_IDS["$h/${f%.meta}"]=1; KNOWN_ID[${f%.meta}]=1
  done
done

# Longest worktree prefix wins, so a nested worktree maps to its own task.
declare -a WT=() WT_HOME=() WT_ID=() WT_KIND=() WT_BACKEND=()
while IFS=$'\t' read -r wt h id kind backend; do
  [ -n "$wt" ] || continue
  WT+=("${wt%/}"); WT_HOME+=("$h"); WT_ID+=("$id"); WT_KIND+=("$kind"); WT_BACKEND+=("$backend")
done < <(awk -F'\t' '{ print length($1) "\t" $0 }' "$META_INDEX" | sort -t$'\t' -k1,1nr | cut -f2-)

match_meta() {  # <cwd> -> index or 1
  local cwd=$1 i
  for i in "${!WT[@]}"; do
    case "$cwd/" in "${WT[$i]}/"*) printf '%s' "$i"; return 0 ;; esac
  done
  return 1
}

declare -A LOCK_PID=()
for h in "${HOMES[@]}"; do
  p=$(cat "$h/state/.lock" 2>/dev/null || true)
  case "$p" in ''|*[!0-9]*) ;; *) LOCK_PID[$p]=$h ;; esac
done

# ---- process census --------------------------------------------------------------
# One ps pass: every agent, whether it descends from another agent, and how many
# child processes it has. A version-named Claude binary is found by argv[0].
# The guard's own ancestors are whoever invoked it (systemd, or an operator's
# session) and never count as the parent agent of anything.
CENSUS=$(ps -eo pid=,ppid=,etimes=,comm=,args= 2>/dev/null | awk -v names="$HARNESS_NAMES" -v self="$$" '
  BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) isname[a[i]] = 1 }
  {
    pid = $1; ppid[pid] = $2; et[pid] = $3; name = $4
    arg0 = $5; sub(/.*\//, "", arg0)
    if (name in isname) agent[pid] = name
    else if (arg0 in isname) agent[pid] = arg0
    kids[$2]++
  }
  END {
    q = self; hops = 0
    while (q > 1 && hops < 64) { invoker[q] = 1; q = ppid[q]; hops++ }
    for (p in agent) {
      nested = 0; q = ppid[p]; hops = 0
      while (q > 1 && hops < 64) { if ((q in agent) && !(q in invoker)) { nested = 1; break } q = ppid[q]; hops++ }
      print p "\t" et[p] "\t" agent[p] "\t" nested "\t" (kids[p] + 0)
    }
  }')

declare -a A_PID=() A_AGE=() A_NAME=() A_NESTED=() A_KIDS=()
pids=()
while IFS=$'\t' read -r pid age name nested kids; do
  [ -n "$pid" ] || continue
  [ "$pid" = "$$" ] && continue
  A_PID+=("$pid"); A_AGE+=("$age"); A_NAME+=("$name"); A_NESTED+=("$nested"); A_KIDS+=("$kids")
  pids+=("/proc/$pid/cwd")
done <<<"$CENSUS"

# Every cwd in one find, not one readlink per agent.
declare -A CWD=()
if [ "${#pids[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r p link; do
    p=${p#/proc/}; CWD[$p]=$link
  done < <(find "${pids[@]}" -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null)
fi

starttime() {  # <pid> -> /proc stat field 22; nothing for a gone or zombie pid
  local line
  read -r line <"/proc/$1/stat" 2>/dev/null || return 1
  line=${line##*) }
  # shellcheck disable=SC2086
  set -- $line
  [ "${1:-}" = Z ] && return 1   # exited, waiting only for its parent to reap it
  printf '%s' "${20:-}"
}
cputicks() {  # <pid> -> utime+stime
  local line
  read -r line <"/proc/$1/stat" 2>/dev/null || return 1
  line=${line##*) }
  # shellcheck disable=SC2086
  set -- $line
  printf '%s' "$(( ${12:-0} + ${13:-0} ))"
}
status_age_min() {  # <home> <id>
  local f="$1/state/$2.status" m
  [ -f "$f" ] || f="$1/state/$2.meta"
  m=$(stat -c %Y "$f" 2>/dev/null || echo "$NOW")
  printf '%s' "$(( (NOW - m) / 60 ))"
}
# A record whose worktree= is missing or stale still names its task id, and a
# task's worktree directory carries that id (fm-<id> under Orca). Any path
# component naming a known task keeps the agent out of the orphan class.
names_known_task() {  # <cwd>
  local c IFS=/
  for c in $1; do
    [ -n "$c" ] || continue
    [ -n "${KNOWN_ID[$c]:-}" ] || [ -n "${KNOWN_ID[${c#fm-}]:-}" ] && return 0
  done
  return 1
}
under_roots() {  # <cwd>
  local r IFS=:
  for r in $ROOTS; do
    [ -n "$r" ] || continue
    case "$1/" in "${r%/}/"*) return 0 ;; esac
  done
  return 1
}

declare -a C_PID=() C_CLASS=() C_HOME=() C_ID=() C_BACKEND=() C_STATUS=() C_AGE=() C_START=() C_NAME=() C_CWD=() C_KIDS=()
declare -A CHILDREN=()
total=0; n_chair=0; n_task=0; n_orphan=0; n_unowned=0; n_nested=0
for i in "${!A_PID[@]}"; do
  pid=${A_PID[$i]}
  cwd=${CWD[$pid]:-}
  [ -n "$cwd" ] || continue
  cwd=${cwd% (deleted)}
  if [ -n "$SCOPE" ]; then
    case "$cwd/" in "${SCOPE%/}/"*) ;; *) continue ;; esac
  fi
  if [ "${A_NESTED[$i]}" = 1 ]; then n_nested=$((n_nested + 1)); continue; fi
  total=$((total + 1))
  class=unowned; home=""; id=""; backend=""; st=""
  if [ -n "${LOCK_PID[$pid]:-}" ]; then
    class=chair; home=${LOCK_PID[$pid]}
  elif mi=$(match_meta "$cwd"); then
    home=${WT_HOME[$mi]}; id=${WT_ID[$mi]}; backend=${WT_BACKEND[$mi]}
    if [ "${WT_KIND[$mi]}" = secondmate ]; then
      class=chair
    else
      class=task; st=$(status_age_min "$home" "$id")
      CHILDREN[$home]=$(( ${CHILDREN[$home]:-0} + 1 ))
    fi
  else
    for h in "${HOMES[@]}"; do
      case "$cwd/" in "$h/"*) class=chair; home=$h; break ;; esac
    done
    if [ "$class" = unowned ] && under_roots "$cwd" && [ "${A_AGE[$i]}" -ge $((ORPHAN_MIN * 60)) ] \
       && ! names_known_task "$cwd"; then
      class=orphan
    fi
  fi
  case "$class" in
    chair) n_chair=$((n_chair + 1)) ;;
    task) n_task=$((n_task + 1)) ;;
    orphan) n_orphan=$((n_orphan + 1)) ;;
    *) n_unowned=$((n_unowned + 1)) ;;
  esac
  C_PID+=("$pid"); C_CLASS+=("$class"); C_HOME+=("$home"); C_ID+=("$id"); C_BACKEND+=("$backend")
  C_STATUS+=("$st"); C_AGE+=("${A_AGE[$i]}"); C_START+=("$(starttime "$pid")"); C_NAME+=("${A_NAME[$i]}")
  C_CWD+=("$cwd"); C_KIDS+=("${A_KIDS[$i]}")
done

# ---- working veto ----------------------------------------------------------------
# validation_state <worktree> <cwd> sets VSTATE to none | running | unknown for
# the branch checked out there. `no-mistakes runs` lists every run of the
# repository; one read per repository is cached for the run, which is why this
# sets a global instead of printing (a command substitution would lose the cache).
declare -A NM_RUNS=() NM_RC=()
validation_state() {
  local dir=$1 branch key out rc nm status
  VSTATE=none
  [ -d "$dir" ] || dir=$2
  [ -d "$dir" ] || return 0
  branch=$(git -C "$dir" branch --show-current 2>/dev/null) || branch=
  [ -n "$branch" ] || return 0
  if [ -n "${AK47_NO_MISTAKES:-}" ] && [ -x "$AK47_NO_MISTAKES" ]; then
    nm=$AK47_NO_MISTAKES
  elif nm=$(command -v no-mistakes 2>/dev/null) && [ -n "$nm" ]; then
    :
  elif [ -x "$HOME/.no-mistakes/bin/no-mistakes" ]; then
    nm=$HOME/.no-mistakes/bin/no-mistakes
  else
    VSTATE=unknown
    return 0
  fi
  key=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || key=$dir
  if [ -z "${NM_RC[$key]+x}" ]; then
    out=$(cd "$dir" && timeout 30 "$nm" runs --limit 200 2>&1); rc=$?
    NM_RUNS[$key]=$out; NM_RC[$key]=$rc
  fi
  out=${NM_RUNS[$key]}; rc=${NM_RC[$key]}
  if [ "$rc" != 0 ]; then
    case "$out" in *"not initialized"*) ;; *) VSTATE=unknown ;; esac
    return 0
  fi
  status=$(printf '%s\n' "$out" | awk -v b="$branch" '
    $2 == b && $1 ~ /^[a-z_]+$/ { print $1; exit }')
  case "$status" in
    ''|completed|failed|cancelled|passed) ;;
    *) VSTATE=running ;;
  esac
}
# held_work <home> <id> <cwd> sets HELD to why a task still holds unfinished
# work for someone (a decision, a review, unpushed or uncommitted changes), or
# to nothing. Every unreadable answer keeps the task.
declare -A PR_STATE=()
held_work() {
  local home=$1 id=$2 cwd=$3 st=$1/state/$2.status meta=$1/state/$2.meta wt pr out n merged=0
  local -a prs=()
  local seen=' ' p
  HELD=
  if [ "$CLASSIFY_OK" != 1 ]; then
    HELD="decision state unreadable"
    return 0
  fi
  if [ -f "$st" ]; then
    if ! out=$(status_open_decisions "$st"); then
      HELD="decision state unreadable"
      return 0
    fi
    if [ -n "$out" ]; then
      out=${out%%$'\n'*}
      HELD="open decision ${out%%$'\t'*}"
      return 0
    fi
    if ! out=$(awk '
      { l = $0; sub(/^[0-9][0-9TZ:.+-]* /, "", l) }
      l ~ /[^[:space:]]/ { last = l }
      END {
        s = last; sub(/[ :[].*/, "", s)
        if (s ~ /^(needs-decision|blocked|waiting|paused)$/) { print "last status " s; exit }
        if (tolower(last) ~ /(^|[^a-z])(await|waiting|ready|needs?|pending)[a-z]* (to |for |on )?([^ ]+ ){0,3}(review|approval|decision|merge|be merged)([^a-z]|$)/) print "last status awaits review or decision"
      }' "$st" 2>/dev/null); then
      HELD="status unreadable"
      return 0
    fi
    [ -n "$out" ] && { HELD=$out; return 0; }
  fi
  # Every PR the task names counts, not only the record's: on 2026-11-17
  # encore-collab-verify-c2 had pr= at a merged PR (#5485) while its live open
  # one (#5482) was named only in its last status line, so reading one of the two
  # would have stopped a task with an open PR.
  while IFS= read -r p; do [ -n "$p" ] && prs+=("$p"); done \
    < <(sed -n 's/^pr=//p' "$meta" 2>/dev/null)
  while IFS= read -r p; do [ -n "$p" ] && prs+=("$p"); done \
    < <(tail -n 1 "$st" 2>/dev/null | grep -Eo 'https://github\.com/[^/ ]+/[^/ ]+/pull/[0-9]+')
  for pr in ${prs[@]+"${prs[@]}"}; do
    case $seen in *" $pr "*) continue ;; esac
    seen="$seen$pr "
    case "$pr" in
      https://github.com/*/pull/*) ;;
      *) HELD="PR on a forge the reclaim cannot read"; return 0 ;;
    esac
    if [ -z "${PR_STATE[$pr]+x}" ]; then
      PR_STATE[$pr]=$(timeout 20 "$GH" pr view "$pr" --json state -q .state 2>/dev/null) || PR_STATE[$pr]=
    fi
    case "${PR_STATE[$pr]}" in
      MERGED) merged=1 ;;
      CLOSED) ;;
      OPEN) HELD="PR open, awaiting review: $pr"; return 0 ;;
      *) HELD="PR state unreadable: $pr"; return 0 ;;
    esac
  done
  wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -1)
  [ -d "$wt" ] || wt=$cwd
  [ -d "$wt" ] || return 0
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -e "$wt/.git" ] && HELD="git state unreadable"
    return 0
  fi
  if ! out=$(git -C "$wt" rev-list --all --max-count=1 2>/dev/null); then
    HELD="git state unreadable"
    return 0
  fi
  [ -n "$out" ] || return 0
  if [ "$merged" != 1 ]; then
    n=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || { HELD="git state unreadable"; return 0; }
    [ "$n" -gt 0 ] && { HELD="$n commit(s) on no pushed branch"; return 0; }
  fi
  out=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null) || { HELD="git state unreadable"; return 0; }
  [ -n "$out" ] && HELD="uncommitted changes"
  return 0
}

# Sample CPU only for agents an action could reach.
declare -A WORKING=() T0=() KEEP=()
if [ -r "$AK47_CONFIG/reclaim-keep" ]; then
  while IFS= read -r k; do
    k=${k%%#*}; k=${k//[[:space:]]/}
    [ -n "$k" ] && KEEP[$k]=1
  done <"$AK47_CONFIG/reclaim-keep"
fi
cand=()
for j in "${!C_PID[@]}"; do
  case "${C_CLASS[$j]}" in
    orphan) cand+=("$j") ;;
    task) [ "${C_STATUS[$j]}" -ge "$CAP_IDLE_MIN" ] && cand+=("$j") ;;
  esac
done
for j in "${cand[@]}"; do
  [ "${C_KIDS[$j]}" -gt 0 ] && { WORKING[$j]="child process"; continue; }
  if [ "${C_CLASS[$j]}" = task ]; then
    if [ -n "${KEEP[${C_ID[$j]}]:-}" ] || grep -qx 'reclaim=keep' "${C_HOME[$j]}/state/${C_ID[$j]}.meta" 2>/dev/null; then
      WORKING[$j]="kept by reclaim-keep"; continue
    fi
    if grep -q 'state=busy' "${C_HOME[$j]}/state/${C_ID[$j]}.busy-state" 2>/dev/null; then
      WORKING[$j]="busy-state busy"; continue
    fi
    if [ -e "${C_HOME[$j]}/state/${C_ID[$j]}.check.sh" ]; then
      WORKING[$j]="armed check: still monitored"; continue
    fi
    if compgen -G "${C_HOME[$j]}/state/${C_ID[$j]}.inbox/*.msg" >/dev/null; then
      WORKING[$j]="unread steering message"; continue
    fi
    validation_state "$(sed -n 's/^worktree=//p' "${C_HOME[$j]}/state/${C_ID[$j]}.meta" 2>/dev/null | head -1)" "${C_CWD[$j]}"
    case "$VSTATE" in
      running) WORKING[$j]="validation running"; continue ;;
      unknown) WORKING[$j]="validation state unreadable"; continue ;;
    esac
    held_work "${C_HOME[$j]}" "${C_ID[$j]}" "${C_CWD[$j]}"
    [ -n "$HELD" ] && { WORKING[$j]=$HELD; continue; }
  fi
  T0[$j]=$(cputicks "${C_PID[$j]}" || echo "")
done
if [ "${#T0[@]}" -gt 0 ] && [ "$SAMPLE_SECS" -gt 0 ]; then
  sleep "$SAMPLE_SECS"
fi
for j in "${!T0[@]}"; do
  t1=$(cputicks "${C_PID[$j]}" || echo "")
  if [ -z "${T0[$j]}" ] || [ -z "$t1" ]; then WORKING[$j]="gone"; continue; fi
  d=$(( t1 - T0[$j] ))
  [ "$d" -gt "$BUSY_TICKS" ] && WORKING[$j]="cpu +${d} ticks in ${SAMPLE_SECS}s"
done

# ---- choose stops ----------------------------------------------------------------
declare -A STOP=()   # index -> reason
stops=0; working_kept=0
plan_stop() {  # <index> <reason>
  [ -n "${STOP[$1]:-}" ] && return 0
  if [ -n "${WORKING[$1]:-}" ]; then working_kept=$((working_kept + 1)); return 1; fi
  [ "$stops" -lt "$MAX_STOPS" ] || return 1
  STOP[$1]=$2; stops=$((stops + 1))
  return 0
}
# Oldest first: orphans by process age, tasks by status age.
while IFS=$'\t' read -r _ j; do
  plan_stop "$j" orphan || true
done < <(for j in "${!C_PID[@]}"; do [ "${C_CLASS[$j]}" = orphan ] && printf '%s\t%s\n' "${C_AGE[$j]}" "$j"; done | sort -t$'\t' -k1,1nr)
TASKS_BY_AGE=$(for j in "${!C_PID[@]}"; do [ "${C_CLASS[$j]}" = task ] && printf '%s\t%s\n' "${C_STATUS[$j]}" "$j"; done | sort -t$'\t' -k1,1nr)
# Cap stops take finished work first: a task whose last report is a done or
# failed result has nothing left to do, while a quiet live lane may be waiting
# on purpose. Within each group, oldest status first.
TASKS_FOR_CAP=$(for j in "${!C_PID[@]}"; do
  [ "${C_CLASS[$j]}" = task ] || continue
  fin=0
  tail -n 1 "${C_HOME[$j]}/state/${C_ID[$j]}.status" 2>/dev/null \
    | grep -Eq '^([0-9][0-9TZ:.-]* )?(done|failed)\b' && fin=1
  printf '%s\t%s\t%s\n' "$fin" "${C_STATUS[$j]}" "$j"
done | sort -t$'\t' -k1,1nr -k2,2nr | cut -f2-)
while IFS=$'\t' read -r age j; do
  [ -n "$j" ] || continue
  [ "$age" -ge "$IDLE_MIN" ] && { plan_stop "$j" "idle $((age / 60))h" || true; }
done <<<"$TASKS_BY_AGE"

home_cap() {  # <home>
  local f v
  for f in "$1"/config/*-cap; do
    [ -f "$f" ] || continue
    read -r v <"$f" 2>/dev/null || continue
    case "$v" in ''|0|*[!0-9]*) continue ;; esac
    printf '%s' "$v"; return 0
  done
  printf '%s' "$HOME_CAP"
}
remaining_children() {  # <home>
  local j n=0
  for j in "${!C_PID[@]}"; do
    [ "${C_CLASS[$j]}" = task ] && [ "${C_HOME[$j]}" = "$1" ] && [ -z "${STOP[$j]:-}" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}
over=(); max_children=0
for h in "${HOMES[@]}"; do
  [ "$h" = "$MAIN_HOME" ] && continue   # the cap is per secondmate home
  n=${CHILDREN[$h]:-0}
  [ "$n" -gt "$max_children" ] && max_children=$n
  cap=$(home_cap "$h")
  [ "$n" -gt "$cap" ] || continue
  left=$n
  while IFS=$'\t' read -r age j; do
    [ -n "$j" ] && [ "$left" -gt "$cap" ] || break
    [ "${C_HOME[$j]}" = "$h" ] && [ "$age" -ge "$CAP_IDLE_MIN" ] || continue
    if [ -n "${STOP[$j]:-}" ]; then left=$((left - 1)); continue; fi
    plan_stop "$j" "over cap $n/$cap" && left=$((left - 1))
  done <<<"$TASKS_FOR_CAP"
  left=$(remaining_children "$h")
  over+=("${h##*/}:$n/$cap")
  if [ "$left" -gt "$cap" ]; then
    finding "reclaim-cap-$(key_of "${h##*/}")" "secondmate home $h holds $left resident child agents against a cap of $cap after this run; every one left is working or recent, so none was stopped"
  fi
done
if [ "$total" -gt "$BOX_CAP" ]; then
  left=$(( total - stops ))
  while IFS=$'\t' read -r age j; do
    [ -n "$j" ] && [ "$left" -gt "$BOX_CAP" ] || break
    [ "$age" -ge "$CAP_IDLE_MIN" ] || continue
    [ -n "${STOP[$j]:-}" ] && continue
    plan_stop "$j" "box over cap $total/$BOX_CAP" && left=$((left - 1))
  done <<<"$TASKS_FOR_CAP"
  over+=("box:$total/$BOX_CAP")
  if [ "$left" -gt "$BOX_CAP" ]; then
    finding reclaim-box-cap "ak47 holds $left resident agents against a box cap of $BOX_CAP after this run; the rest are chairs, working, recent, or unowned (report $REPORT)"
  fi
fi
[ "$working_kept" -gt 0 ] && [ "$n_orphan" -gt 0 ] && for j in "${!C_PID[@]}"; do
  if [ "${C_CLASS[$j]}" = orphan ] && [ -n "${WORKING[$j]:-}" ]; then
    finding "reclaim-orphan-working-${C_PID[$j]}" "agent pid ${C_PID[$j]} in ${C_CWD[$j]} has no task record in any home but is working (${WORKING[$j]}); left alone"
  fi
done

# ---- act -------------------------------------------------------------------------
term_pid() {  # <index> -> 0 gone, 1 still there or refused
  local j=$1 pid=${C_PID[$1]} t
  [ "$(starttime "$pid")" = "${C_START[$j]}" ] || return 0   # already gone or reused
  kill -TERM "$pid" 2>/dev/null || return 1
  for ((t = 0; t < TERM_WAIT; t++)); do
    [ "$(starttime "$pid")" = "${C_START[$j]}" ] || return 0
    sleep 1
  done
  [ "$(starttime "$pid")" = "${C_START[$j]}" ] && return 1
  return 0
}
stopped=0; failures=0; deferred=0
for j in "${!STOP[@]}"; do
  pid=${C_PID[$j]}; why=${STOP[$j]}
  if [ "$APPLY" != 1 ]; then continue; fi
  # The run has a wall-clock budget so the unit's own timeout never cuts a
  # stop in half; whatever is left waits for the next run.
  if [ $(( $(ak47_epoch) - NOW )) -ge "$RUN_BUDGET" ]; then deferred=$((deferred + 1)); continue; fi
  if [ "${C_CLASS[$j]}" = orphan ]; then
    if term_pid "$j"; then
      stopped=$((stopped + 1))
      reap "orphan-term pid=$pid cwd=${C_CWD[$j]} age=$((C_AGE[j] / 3600))h revert: relaunch it in that worktree"
    else
      failures=$((failures + 1))
      finding "reclaim-term-failed-$pid" "orphan agent pid $pid in ${C_CWD[$j]} did not exit on SIGTERM; left running"
    fi
    continue
  fi
  home=${C_HOME[$j]}; id=${C_ID[$j]}; how=""
  # A stop without the left-stopped mark is undone by the watchdog within
  # minutes, so no task is stopped when the mark cannot be written.
  if [ ! -x "$LEAVE_STOPPED" ]; then
    failures=$((failures + 1))
    finding reclaim-no-leave-stopped "agent reclaim stopped no task: $LEAVE_STOPPED is missing, and a stop it cannot mark left stopped would be relaunched"
    continue
  fi
  if [ "${C_BACKEND[$j]}" != orca ] && [ -x "$FM_CONTROL" ] && \
     FM_HOME=$home timeout 120 "$FM_CONTROL" "$id" exit >/dev/null 2>&1 && \
     [ "$(starttime "$pid")" != "${C_START[$j]}" ]; then
    how=fm-control
  elif term_pid "$j"; then
    how=sigterm
  fi
  if [ -n "$how" ]; then
    stopped=$((stopped + 1))
    marked=yes
    if ! FM_HOME=$home FM_SUPERVISION_ACTOR=main timeout 60 "$LEAVE_STOPPED" "$id" mark \
         --reason "ak47 agent reclaim: $why (Aaron 2026-11-17: reclaim agents nobody uses)" >/dev/null 2>&1; then
      marked=no; failures=$((failures + 1))
      finding "reclaim-mark-failed-$(key_of "$id")" "task $id in $home was stopped ($why) but could not be marked left stopped, so the watchdog may relaunch it"
    fi
    reap "task-stop home=$home task=$id pid=$pid how=$how marked=$marked reason=$why revert: FM_HOME=$home $LEAVE_STOPPED $id clear; FM_HOME=$home $FM_CODE/bin/fm-control.sh $id relaunch --note 'resumed after agent-reclaim'"
  else
    failures=$((failures + 1))
    finding "reclaim-stop-failed-$(key_of "$id")" "task $id in $home ($why) did not stop by fm-control exit or SIGTERM; left running"
  fi
done

# ---- orphan status logs ----------------------------------------------------------
archived=0; archive_pending=0
day=$(date -u +%F)
for h in "${HOMES[@]}"; do
  for f in "$h"/state/*.status; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.status}
    [ -n "${META_IDS[$h/$id]:-}" ] && continue
    [ -e "$h/state/$id.backlog-close" ] && continue   # an interrupted cleanup still needs it
    m=$(stat -c %Y "$f" 2>/dev/null || echo "$NOW")
    [ $(( (NOW - m) / 60 )) -ge "$ORPHAN_MIN" ] || continue
    if [ "$APPLY" != 1 ] || [ "$archived" -ge "$MAX_ARCHIVE" ]; then
      archive_pending=$((archive_pending + 1)); continue
    fi
    dest=$h/data/orphan-status-archive-$day
    mkdir -p "$dest" 2>/dev/null || { failures=$((failures + 1)); continue; }
    if [ -e "$dest/${f##*/}" ]; then
      archive_pending=$((archive_pending + 1)); continue
    fi
    if mv -n "$f" "$dest/" 2>/dev/null; then
      archived=$((archived + 1))
      reap "status-archive home=$h task=$id revert: mv '$dest/${f##*/}' '$h/state/'"
    else
      failures=$((failures + 1))
    fi
  done
done

# ---- dead chairs ----------------------------------------------------------------
# A dead chair must be seen on two runs at least 10 minutes apart, so a chair
# that is mid-restart is never mistaken for a dead home.
watchers=0; dead_chairs=()
mkdir -p "$CHAIR_SEEN" 2>/dev/null || true
for h in "${HOMES[@]}"; do
  mark=$CHAIR_SEEN/$(key_of "$h")
  if chair_alive "$h"; then rm -f "$mark"; continue; fi
  dead_chairs+=("${h##*/}")
  pid=$(cat "$h/state/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) rm -f "$mark"; continue ;; esac
  kill -0 "$pid" 2>/dev/null || { rm -f "$mark"; continue; }
  if [ ! -f "$mark" ]; then
    [ "$APPLY" = 1 ] && : >"$mark"
    continue
  fi
  [ $(( NOW - $(stat -c %Y "$mark" 2>/dev/null || echo "$NOW") )) -ge 600 ] || continue
  if out=$(stop_home_watcher "$h" "$APPLY"); then
    case "$out" in stopped*) watchers=$((watchers + 1)); rm -f "$mark" ;; esac
  else
    finding "reclaim-watcher-$(key_of "$h")" "home $h has a dead chair and a running watcher that could not be stopped safely: $out"
  fi
done

# ---- report ----------------------------------------------------------------------
printf '%s\n' "$max_children" >"$CHILDREN_FILE" 2>/dev/null || true
planned=${#STOP[@]}
line="reclaim mode=$MODE agents=$total cap=$BOX_CAP chairs=$n_chair tasks=$n_task orphans=$n_orphan unowned=$n_unowned nested=$n_nested stops=$([ "$APPLY" = 1 ] && echo "$stopped" || echo "would-$planned") working_kept=$working_kept deferred=$deferred over_cap=$(IFS=,; echo "${over[*]:-none}") archived=$archived archive_pending=$archive_pending watchers_stopped=$watchers dead_chairs=$(IFS=,; echo "${dead_chairs[*]:-none}") failures=$failures"
ak47_log "$LOG" "$line"
printf '%s %s\n' "$(ak47_now)" "$line" >"$LINE_FILE" 2>/dev/null || true

tmp=$(mktemp "$AK47_STATE/.reclaim-report.XXXXXX") || exit 1
{
  echo "# ak47 agent reclaim - $(ak47_now) ($MODE)"
  echo
  echo "$line"
  echo
  printf '%-8s %-8s %-6s %-9s %-24s %-28s %s\n' PID CLASS AGE_H STATUS_H HOME TASK ACTION
  for j in "${!C_PID[@]}"; do
    act=keep
    [ -n "${STOP[$j]:-}" ] && act="$([ "$APPLY" = 1 ] && echo stop || echo would-stop): ${STOP[$j]}"
    [ -n "${WORKING[$j]:-}" ] && act="keep: working (${WORKING[$j]})"
    st=${C_STATUS[$j]}; [ -n "$st" ] && st=$((st / 60))
    printf '%-8s %-8s %-6s %-9s %-24s %-28s %s\n' "${C_PID[$j]}" "${C_CLASS[$j]}" "$((C_AGE[j] / 3600))" "${st:--}" \
      "$(basename "${C_HOME[$j]:--}")" "${C_ID[$j]:--}" "$act"
  done | sort -k2,2 -k4,4nr
} >"$tmp"
mv -f "$tmp" "$REPORT" 2>/dev/null || rm -f "$tmp"

# One line in the health board. ak47-health.sh rewrites health-latest.md every
# ten minutes and carries agent-reclaim.line itself; this keeps the line current
# between its runs.
HEALTH=$AK47_STATE/health-latest.md
if [ -f "$HEALTH" ] && tmp=$(mktemp "$AK47_STATE/.health-latest.XXXXXX"); then
  grep -v '^reclaim ' "$HEALTH" >"$tmp"
  echo "$line" >>"$tmp"
  mv -f "$tmp" "$HEALTH" 2>/dev/null || rm -f "$tmp"
fi

if [ "$APPLY" = 1 ] && [ "${#findings[@]}" -gt 0 ]; then
  ak47_deliver_findings "$FIND_LOG" "ak47 agent reclaim" "$REPORT" "${findings[@]}" || true
fi

[ "$PRINT" = 1 ] && cat "$REPORT"
# A stop that did not take is a finding above, not a unit failure: a failed
# unit every fifteen minutes would bury the finding under its own noise.
exit 0
