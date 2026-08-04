#!/usr/bin/env bash
# fm-nm-step-liveness.sh - is a no-mistakes run's active step ACTUALLY doing work?
#
# Why this exists (2026-08-02 incident, docs/postmortems/nm-quiet-test-step.md):
# no-mistakes reports NO liveness signal for a step that runs a configured shell
# command (`commands.test` / `commands.lint` in .no-mistakes.yaml). Such a step
# publishes `agent_pid` empty (only agent invocations record a pid), `round`
# `starting` (a round row is written when the round ENDS), and a step log that is
# flushed only when the step finishes - so `last_activity` never advances and
# `axi status` renders a perfectly healthy step as `quiet 1h28m ago`. All three
# signals independently read as "dead" while the command is running normally.
# firstmate aborted two healthy runs on that false reading.
#
# The hand check that produced the false negative was a process search by NAME:
# `ps -ef | grep <run-id>` finds nothing, because the test command's argv is
# `sh -c command -v tmux ...` and its children are `bash tests/<name>.test.sh` -
# relative paths, no run id, no worktree path anywhere in argv. The ONLY reliable
# link from a process to its run is its WORKING DIRECTORY. This probe uses cwd.
#
# Verdicts, one canonical line on stdout:
#
#   liveness: <alive|stalled|dead|unknown> · run: <id> · procs: <n> · <detail>
#
#   alive    processes are running in the run's worktree AND made measurable
#            progress (CPU advanced, or a new process appeared) during the sample.
#   stalled  processes exist but showed no progress in the sample window. NOT the
#            same as dead: a command legitimately blocked on I/O, a network call,
#            or `sleep` reads this way. Sample longer before acting on it.
#   dead     PROVABLY zero processes in the worktree while the step is recorded
#            running. This is the only verdict that justifies aborting a run.
#   unknown  anything could not be established. Fail-closed, per the same rule
#            bin/fm-lock-lib.sh applies to lsof: an unreadable answer is never
#            evidence of absence, because acting on a false `dead` destroys work.
#
# Read-only and side-effect free. Exits 0 on any successful read regardless of
# verdict; exit 2 only on a usage error. Callers parse the verdict word.
#
# Usage:
#   bin/fm-nm-step-liveness.sh <run-id> [--sample <seconds>] [--worktree <path>]
#
# --sample 0 skips the progress sample and answers presence only (alive, dead,
# or unknown, with no progress wait). Presence alone is decisive for the failure
# this exists to catch, so callers on a hot path (bin/fm-crew-state.sh) use it.

set -u

VERDICT_SEP=' · '
NM_HOME="${FM_NM_HOME:-${NO_MISTAKES_HOME:-$HOME/.no-mistakes}}"
SAMPLE_DEFAULT=3
# How long to wait before re-scanning when the first scan finds nothing, so a
# momentary gap between the step's units of work cannot be reported as death.
ABSENCE_CONFIRM_DELAY=${FM_NM_ABSENCE_CONFIRM_DELAY-1}

RUN_ID=""
SAMPLE=$SAMPLE_DEFAULT
WORKTREE=""

usage() {
  echo "usage: fm-nm-step-liveness.sh <run-id> [--sample <seconds>] [--worktree <path>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sample)
      [ $# -ge 2 ] || usage
      SAMPLE=$2
      shift 2
      ;;
    --worktree)
      [ $# -ge 2 ] || usage
      WORKTREE=$2
      shift 2
      ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)
      [ -z "$RUN_ID" ] || usage
      RUN_ID=$1
      shift
      ;;
  esac
done

[ -n "$RUN_ID" ] || usage
case "$SAMPLE" in ''|*[!0-9]*) SAMPLE=$SAMPLE_DEFAULT ;; esac

# Emit the one canonical line and exit 0.
emit() {  # <verdict> <procs> [detail]
  local line="liveness: $1${VERDICT_SEP}run: $RUN_ID${VERDICT_SEP}procs: $2"
  [ -n "${3:-}" ] && line="$line${VERDICT_SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

absence_confirm_delay_is_positive() {
  awk -v value="$ABSENCE_CONFIRM_DELAY" 'BEGIN {
    exit !(value ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && value + 0 > 0)
  }'
}

if [ "$ABSENCE_CONFIRM_DELAY" = 0 ]; then
  if [ "${FM_NM_TEST_BARRIER_PHASE:-}" != after-empty-scan ] \
    || [ -z "${FM_NM_TEST_BARRIER_DIR:-}" ] \
    || [ ! -d "$FM_NM_TEST_BARRIER_DIR" ]; then
    emit unknown 0 "invalid absence-confirmation delay: zero requires the explicit empty-scan test barrier"
  fi
elif ! absence_confirm_delay_is_positive; then
  emit unknown 0 "invalid absence-confirmation delay: expected a positive number"
fi

# --- cross-heartbeat progress ------------------------------------------------
# Snapshot store for the presence path's two observations. Kept outside the
# worktree so it survives teardown and cannot be mistaken for a run process.
SNAP_DIR=${FM_NM_SNAP_DIR:-${TMPDIR:-/tmp}/fm-nm-liveness}
# Minimum per-process cpu hundredths that must accumulate for a persistent
# process to count as working. One hundredth is the trace-noise floor: the
# keystone hang moved 4:39.05 -> 4:39.06 across 30s, which is exactly 1.
MIN_TICKS=${FM_NM_MIN_TICKS:-2}
# Below this window a rate means nothing; report unknown rather than guess.
MIN_WINDOW=${FM_NM_MIN_WINDOW:-20}
case "$MIN_TICKS" in ''|*[!0-9]*) MIN_TICKS=2 ;; esac
case "$MIN_WINDOW" in ''|*[!0-9]*) MIN_WINDOW=20 ;; esac

cpu_of_pid() {  # <pid> -> hundredths, or empty when unreadable
  local t days part
  t=$(ps -o time= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [ -n "$t" ] || return 1
  case "$t" in *-*) days=${t%%-*}; t=${t#*-} ;; *) days=0 ;; esac
  case "$t" in *:*:*) ;; *:*) t="0:$t" ;; *) t="0:0:$t" ;; esac
  part=$(printf '%s\n' "$t" | awk -F: '{printf "%d\n", ($1*3600+$2*60+$3)*100}' 2>/dev/null)
  case "$part" in ''|*[!0-9]*) part=0 ;; esac
  case "$days" in ''|*[!0-9]*) days=0 ;; esac
  printf '%s' "$(( part + days * 8640000 ))"
}

# Emits the verdict for the presence path and exits. Never returns.
progress_verdict() {  # <pids> <count> <doing>
  local pids=$1 count=$2 doing=$3
  local now snap prev prev_t cur pid cpu prior entry pe
  local advanced=0 newpids=0 persisted=0 best=0 window

  now=$(date +%s 2>/dev/null) || \
    emit unknown "$count" "cannot read the clock to establish a progress window$doing"
  mkdir -p "$SNAP_DIR" 2>/dev/null || \
    emit unknown "$count" "cannot open the progress snapshot store$doing"
  snap="$SNAP_DIR/$RUN_ID.snap"

  # Record EVERY enumerated pid, including ones whose cpu cannot be read.
  #
  # A short-lived child can exit between the cwd enumeration and the `ps` call,
  # which makes its cpu unreadable - and those are precisely the processes that
  # PROVE the step is working, because rapid child turnover is what a crawling
  # but healthy step looks like. Dropping them made a step with flat parent cpu
  # and children turning over every few seconds read `stalled`, which is a false
  # hang call on the exact shape of a slow-but-alive step. Unreadable cpu is
  # marked `?` so the pid still counts for membership while never contributing a
  # bogus cpu delta.
  cur=""
  for pid in $pids; do
    cpu=$(cpu_of_pid "$pid") || cpu='?'
    [ -n "$cpu" ] || cpu='?'
    cur="$cur$pid:$cpu "
  done
  [ -n "$cur" ] || emit unknown "$count" "no process could be recorded for comparison$doing"

  prev_t=""; prev=""
  if [ -r "$snap" ]; then
    prev_t=$(head -1 "$snap" 2>/dev/null)
    prev=$(tail -1 "$snap" 2>/dev/null)
  fi
  { printf '%s\n' "$now"; printf '%s\n' "$cur"; } > "$snap" 2>/dev/null || true

  case "$prev_t" in
    '') emit unknown "$count" "first observation of this run; no prior sample to compare against$doing" ;;
    *[!0-9]*) emit unknown "$count" "prior progress snapshot unreadable$doing" ;;
  esac
  window=$(( now - prev_t ))
  [ "$window" -ge 0 ] || window=0
  [ "$window" -ge "$MIN_WINDOW" ] || \
    emit unknown "$count" "only ${window}s since the last observation (need ${MIN_WINDOW}s); progress not yet establishable$doing"

  for entry in $cur; do
    pid=${entry%%:*}; cpu=${entry##*:}
    prior=""
    for pe in $prev; do
      case "$pe" in "$pid":*) prior=${pe##*:}; break ;; esac
    done
    # Membership is judged on the enumeration, not on cpu readability: a pid the
    # prior observation never saw is NEW work regardless of whether its cpu could
    # be sampled. This is the child-turnover signal, and it is the discriminator
    # between a slow-but-spawning step and a stranded one.
    if [ -z "$prior" ]; then newpids=$(( newpids + 1 )); continue; fi
    # A cpu delta needs a readable number at BOTH ends; `?` means unreadable and
    # contributes membership only, never a delta.
    case "$cpu" in ''|*[!0-9]*) continue ;; esac
    case "$prior" in ''|*[!0-9]*) continue ;; esac
    persisted=$(( persisted + 1 ))
    delta=$(( cpu - prior ))
    [ "$delta" -ge 0 ] || delta=0
    [ "$delta" -gt "$best" ] && best=$delta
    [ "$delta" -ge "$MIN_TICKS" ] && advanced=$(( advanced + 1 ))
  done

  if [ "$advanced" -gt 0 ]; then
    emit alive "$count" "$advanced of $persisted persistent process(es) advanced cpu over ${window}s (best +$(awk -v b="$best" 'BEGIN{printf "%.2f", b/100}')s)$doing"
  fi
  if [ "$newpids" -gt 0 ]; then
    emit alive "$count" "$newpids new process(es) started in ${window}s - the step began new units of work$doing"
  fi
  emit stalled "$count" \
    "PRESENT BUT NOT PROGRESSING: no new processes and no persistent process advanced cpu in ${window}s (best +$(awk -v b="$best" 'BEGIN{printf "%.2f", b/100}')s) - this is the confirmed field-hang signature, not a slow step$doing"
}

test_scan_barrier() {  # <phase>
  local phase=$1 dir=${FM_NM_TEST_BARRIER_DIR:-} released
  [ "${FM_NM_TEST_BARRIER_PHASE:-}" = "$phase" ] || return 0
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  printf '%s\n' "$phase" > "$dir/ready" || return 1
  while [ ! -f "$dir/release" ]; do sleep 0.01; done
  IFS= read -r released < "$dir/release" || return 1
  [ "$released" = "$phase" ]
}

# --- resolve the run's worktree ---------------------------------------------
# no-mistakes lays worktrees out as <home>/worktrees/<repo-id>/<run-id>. The
# repo id is not exposed by any CLI surface, so glob it rather than reading the
# daemon's private state database.
if [ -z "$WORKTREE" ]; then
  for candidate in "$NM_HOME"/worktrees/*/"$RUN_ID"; do
    [ -d "$candidate" ] || continue
    WORKTREE=$candidate
    break
  done
fi
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || \
  emit unknown 0 "no worktree for this run under $NM_HOME/worktrees"

# Resolve to a physical path so it compares equal to a process cwd, which the
# kernel always reports resolved (/tmp vs /private/tmp on macOS).
WORKTREE_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || WORKTREE_REAL=""
[ -n "$WORKTREE_REAL" ] || emit unknown 0 "worktree $WORKTREE is not readable"

# --- enumerate processes whose cwd is in that worktree ----------------------
# Prints one pid per line. Returns non-zero when the answer is not establishable,
# which the caller must translate to `unknown` and never to `dead`.
procs_in_worktree() {
  local pid cwd line
  if [ -d /proc ] && [ -r /proc/self/cwd ]; then
    # Linux: read cwd links directly. Unreadable entries belong to other users'
    # processes, which cannot be this run's, so skipping them is safe.
    local found=0
    for pid in /proc/[0-9]*; do
      found=1
      cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
      case "$cwd" in
        "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) printf '%s\n' "${pid#/proc/}" ;;
      esac
    done
    [ "$found" = 1 ] && return 0
    return 1
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  # One pass over every process's cwd. -F gives machine-readable pairs:
  # `p<pid>` lines introduce the process, `n<path>` gives the directory.
  local out
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        cwd=${line#n}
        case "$cwd" in
          "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) [ -n "$pid" ] && printf '%s\n' "$pid" ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# --- what the step is currently doing ---------------------------------------
#
# "Alive" alone still leaves the operator guessing whether hours of runtime are
# legitimate. Naming the unit of work and its age makes slow separable from hung
# WITHOUT another abort: a suite that keeps changing what it is on is slow, one
# that sits on the same unit past any plausible budget is worth investigating.
#
# The step's root process is the one in the set whose parent is NOT in the set
# (the daemon owns it). Its direct children in the set are the current unit of
# work - here, the `bash tests/<name>.test.sh` the suite loop is on.
current_work() {  # <pids>
  local pids=$1 pid ppid args elapsed roots="" out=""
  local table
  table=$(ps -o pid=,ppid= -p "$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null) || return 0
  while read -r pid ppid; do
    [ -n "${pid:-}" ] || continue
    case "
$pids
" in
      *"
$ppid
"*) ;;
      *) roots="$roots $pid" ;;
    esac
  done <<EOF
$table
EOF
  for pid in $roots; do
    while read -r cpid cppid; do
      [ "${cppid:-}" = "$pid" ] || continue
      args=$(ps -o args= -p "$cpid" 2>/dev/null | cut -c1-60) || continue
      elapsed=$(ps -o etime= -p "$cpid" 2>/dev/null | tr -d ' ')
      [ -n "$args" ] || continue
      out="$args (${elapsed:-?})"
      break
    done <<EOF
$table
EOF
    [ -n "$out" ] && break
  done
  printf '%s' "$out"
}

PIDS_T0=$(procs_in_worktree) || \
  emit unknown 0 "cannot enumerate process working directories (no /proc, no usable lsof)"
COUNT_T0=$(printf '%s' "$PIDS_T0" | grep -c . || true)
case "$COUNT_T0" in ''|*[!0-9]*) COUNT_T0=0 ;; esac

# A single empty scan is NOT proof of death. The step's loop replaces its child
# between units of work (`for t in tests/*.test.sh; do bash "$t"; done` is empty
# for the instant between two scripts), so one unlucky sample lands in that gap
# and reads zero on a perfectly healthy step. `dead` is the only verdict that
# authorizes discarding a run, so it must survive a CONFIRMING rescan.
#
# The confirm delay is paid only when the first scan is already empty, so the
# common alive case - and the ~0.2s presence-only path on the heartbeat read -
# is unaffected.
if [ "$COUNT_T0" = 0 ]; then
  test_scan_barrier after-empty-scan || \
    emit unknown 0 "empty-scan test barrier could not be completed"
  sleep "$ABSENCE_CONFIRM_DELAY"
  WAIT_STATUS=$?
  [ "$WAIT_STATUS" -eq 0 ] || \
    emit unknown 0 "absence-confirmation wait failed: sleep exited $WAIT_STATUS"
  PIDS_CONFIRM=$(procs_in_worktree) || \
    emit unknown 0 "process enumeration failed while confirming absence"
  COUNT_CONFIRM=$(printf '%s' "$PIDS_CONFIRM" | grep -c . || true)
  case "$COUNT_CONFIRM" in ''|*[!0-9]*) COUNT_CONFIRM=0 ;; esac
  if [ "$COUNT_CONFIRM" = 0 ]; then
    emit dead 0 "no process has its working directory in $WORKTREE_REAL (confirmed by a second scan ${ABSENCE_CONFIRM_DELAY}s later)"
  fi
  # Processes reappeared: the first scan caught a gap between units of work.
  # Continue with the confirming scan's set rather than reporting either verdict
  # from the reading that was about to be wrong.
  PIDS_T0=$PIDS_CONFIRM
  COUNT_T0=$COUNT_CONFIRM
fi

# --- presence is NOT progress -----------------------------------------------
#
# This path used to emit `alive` for any process holding the worktree cwd. That
# was the defect restated as a feature: four confirmed field hangs had their
# processes PRESENT and frozen - identical pid set, no new spawns, zero cpu
# movement across 30-40s - and every one of them read `alive` here, so the wake
# was absorbed and nobody was told. The keystone case held 18 lanes across five
# homes for five hours that way.
#
# Progress is now established WITHOUT a sleep, by comparing against the previous
# heartbeat's observation. Heartbeats recur, so consecutive reads give a free
# window - and a far better one than any few-second sleep, since real hangs run
# for hours. Two signals count as progress, and BOTH are needed:
#   - a pid present in both observations advanced its own cpu, or
#   - new pids appeared (the suite started a new unit of work)
# Per-process, never a whole-set sum: the suite churns children constantly, and
# an exited child takes its accumulated cpu out of a sum, so a summed rate reads
# a working step as hung. That false positive was measured on a real run before
# this shipped, which is why the comparison is per-pid.
if [ "$SAMPLE" = 0 ]; then
  DOING=$(current_work "$PIDS_T0")
  [ -n "$DOING" ] && DOING="${VERDICT_SEP}doing: $DOING"
  progress_verdict "$PIDS_T0" "$COUNT_T0" "$DOING"
fi

# --- sample progress --------------------------------------------------------
# Total CPU seconds across the matched process set. `ps -o time=` formats as
# [[DD-]HH:]MM:SS[.ss]; sum it in hundredths to stay integer-only.
cpu_hundredths() {  # <pids...>
  local pid t total=0 part days=0
  for pid in "$@"; do
    t=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [ -n "$t" ] || continue
    case "$t" in
      *-*) days=${t%%-*}; t=${t#*-} ;;
      *)   days=0 ;;
    esac
    # Normalize to H:M:S by left-padding missing fields.
    case "$t" in
      *:*:*) ;;
      *:*)   t="0:$t" ;;
      *)     t="0:0:$t" ;;
    esac
    part=$(
      printf '%s\n' "$t" | awk -F: '{
        s = $1 * 3600 + $2 * 60 + $3
        printf "%d\n", s * 100
      }' 2>/dev/null
    )
    case "$part" in ''|*[!0-9]*) part=0 ;; esac
    case "$days" in ''|*[!0-9]*) days=0 ;; esac
    total=$(( total + part + days * 8640000 ))
  done
  printf '%s' "$total"
}

# shellcheck disable=SC2086  # deliberate word splitting: PIDS_* are newline lists
CPU_T0=$(cpu_hundredths $PIDS_T0)
test_scan_barrier before-progress-sample || \
  emit unknown "$COUNT_T0" "progress-sample test barrier could not be completed"
sleep "$SAMPLE"
PIDS_T1=$(procs_in_worktree) || \
  emit unknown "$COUNT_T0" "process enumeration failed mid-sample"
COUNT_T1=$(printf '%s' "$PIDS_T1" | grep -c . || true)
case "$COUNT_T1" in ''|*[!0-9]*) COUNT_T1=0 ;; esac

if [ "$COUNT_T1" = 0 ]; then
  emit unknown 0 "processes present at the first scan were gone by the second; the step transition could not be established"
fi

# shellcheck disable=SC2086  # deliberate word splitting: PIDS_* are newline lists
CPU_T1=$(cpu_hundredths $PIDS_T1)
CPU_DELTA=$(( CPU_T1 - CPU_T0 ))

# A pid present at t1 but not t0 is fresh work the step spawned - progress even
# when the sampled CPU total happens not to move.
NEW_PIDS=0
for p in $PIDS_T1; do
  case "
$PIDS_T0
" in
    *"
$p
"*) ;;
    *) NEW_PIDS=$(( NEW_PIDS + 1 )) ;;
  esac
done

# A negative delta means processes in the set exited and were replaced between
# samples - churn, which is progress. Report it as no measured CPU rather than a
# nonsensical "cpu +-0.01s"; NEW_PIDS carries the real signal in that case.
[ "$CPU_DELTA" -lt 0 ] && CPU_DELTA=0
CPU_NOTE=$(awk -v d="$CPU_DELTA" 'BEGIN { printf "%.2fs", d / 100 }')
DOING=$(current_work "$PIDS_T1")
[ -n "$DOING" ] && DOING="${VERDICT_SEP}doing: $DOING"

if [ "$CPU_DELTA" -gt 0 ] || [ "$NEW_PIDS" -gt 0 ]; then
  emit alive "$COUNT_T1" "progress in ${SAMPLE}s: cpu +$CPU_NOTE, $NEW_PIDS new process(es)$DOING"
fi

emit stalled "$COUNT_T1" \
  "no cpu or process change in ${SAMPLE}s (may be blocked on I/O or sleeping - sample longer before acting)$DOING"
