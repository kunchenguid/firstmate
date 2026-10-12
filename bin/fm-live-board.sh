#!/usr/bin/env bash
# fm-live-board.sh - a live, self-refreshing visual view of one long-running run.
#
# The captain keeps ONE page open and never reloads it. Everything the page
# shows comes from a small JSON file this script rewrites on a fixed interval,
# so the page's own refresh is a no-store fetch rather than a page reload.
#
# Usage:
#   fm-live-board.sh sample --run-dir DIR --out FILE [--ssh HOST] [options]
#   fm-live-board.sh page   --out FILE [--template FILE] [--label TEXT]
#   fm-live-board.sh watch  --run-dir DIR --out HTML [--ssh HOST] [options]
#   fm-live-board.sh open   --out HTML [--reopen]
#
# --ssh HOST samples a run that is NOT on this machine: HOST is an ssh target
# (a configured host alias, or user@host) and --run-dir is that host's path.
# A long build migrates to whichever host is least loaded, so a view that can
# only see this box goes blind exactly when the answer has moved. Both paths
# run the SAME producer script and the SAME parser, so local is not a second
# implementation free to drift from remote.
#
# WHAT THE PRODUCER MAY DO. It reads only: ps, file sizes and mtimes, the tail
# of the run's own logs, and the host's swap, core count, and load average. It
# never signals, restarts, kills, or writes anything on the host it samples,
# and a test asserts the producer script it sends carries no such verb.
#
# AN UNREACHABLE RUN IS NEVER DRAWN AS AN IDLE ONE. When the host cannot be
# reached the sample is marked source.reachable=false with the reason, its
# verdict is `unreachable`, and its process state is unknown rather than gone -
# "I cannot see it" and "it is not running" are different facts, and a board
# that renders the first as the second is worse than no board. Every sample
# also names the host and run directory it sampled, and the page prints them,
# so a page showing little at least says where it was looking.
#
# RUN IDENTITY IS THE RUN DIRECTORY. A process belongs to this run when its
# command line names the run directory, because whatever the run spawned
# carries it in --data-dir. --match adds an opt-in command-line regex as a
# fallback, and it is NOT the default: a bare command match cannot tell two
# concurrent runs of the same command apart, so with it the liveness number
# would silently report another run - exactly wrong for a run that has died.
# Pass --match only for a layout whose processes never name the run directory.
#
# sample   Read the run's process facts and the log files it already writes,
#          classify the run's health, and write the fm-live-board.v1 JSON the
#          page renders. Pure read: it never signals, restarts, or writes to
#          the watched run, and it writes only its own --out/--state files.
# page     Write the HTML page: the shipped template with one injected
#          fm-live-board.v1 config block naming the sibling JSON file and
#          label. The page is otherwise fully static and portable.
# watch    Rewrite the JSON every --interval seconds until the run reaches a
#          terminal state, then write one final sample marked
#          monitor.stopped=true with the reason, so a page that stops
#          refreshing says the watch ENDED rather than that the monitor died.
#          Terminal states are: the run script logged "all phases done", a
#          phase exit file says the run is over and cannot continue, the run
#          directory disappeared, or --max-seconds elapsed.
#          --follow keeps sampling through a final result instead of stopping,
#          because a failed run is usually retried and a page that went quiet
#          at the first attempt would miss the second; it still ends at
#          --max-seconds.
# open     Establish the Lavish session on the page (the same visual surface
#          the fleet board uses) and print its URL.
#
# NOT the same owner as its neighbours. bin/fm-inflight.sh is the fleet text
# view of what is in flight from durable records, and bin/fm-bearings-board.sh
# is the interactive fleet board for Captain's Call reconciliation. This one
# answers a single question those do not: is THIS one long-running process
# alive, progressing, or crashing, right now.
#
# WHAT THE PAGE PROVES, AND WHY EACH SIGNAL IS THE HONEST ONE.
# 1. Alive: pid, elapsed time, and PROCESS CPU TIME - reported as CPU seconds
#    accrued over the observed window, not as elapsed time. A starved or hung
#    process accrues elapsed time while doing nothing, so elapsed time alone
#    cannot answer "is it alive". This matters here: the run's own parent
#    process (bd) accrues almost no CPU because the real work happens in the
#    Dolt server it spawned, so the CPU window is summed over the parent and
#    every process sharing this run's directory - the exact sum whose flatness
#    is what "starved, not hung" looked like.
# 2. Progressing: sources copied out of the total the plan reported, the
#    current source, and SECONDS SINCE THE LAST PROGRESS LINE. That number is
#    only meaningful against this run's OWN cadence, because a single large
#    source legitimately logs nothing for minutes: the sampler reports
#    max_gap_s, the longest observed gap between progress lines in the current
#    phase, and the verdict only calls a quiet run stalled when the quiet
#    exceeds that cadence.
# 3. Healthy: the run's Dolt RSS, swap used against its total, host load
#    against the core count, the run-wide Dolt RSS trend from the run's own
#    memory trace, and whether the phase log and output directory are still
#    growing.
# 4. Crashing: a non-zero phase exit, error-class lines from the log tail, or
#    the watched process disappearing while the run is not terminal - each
#    shown as an explicit verdict, never buried in prose.
#
# THE VERDICT IS CLASSIFIED HERE, ONCE, for the page and for any text reader,
# so the page never re-derives a different answer from the same numbers.
#
# A well-formed build log reports collisions it deliberately accepted (the
# brain unify build stops on content-disagreeing id collisions unless
# --allow-collisions is passed). Those are reported as accepted collisions
# rather than as errors, because they are the expected shape of a healthy run
# and dressing them as failures would train the reader to ignore the panel.
#
# Exit status is 0 for a sample taken from a run that is not terminal, and 0
# for a terminal one too; a run that failed is a fact the page reports, not a
# reason for the monitor itself to fail. Only a usage error, a missing
# dependency, or an unreadable run directory is non-zero.
#
# FM_LIVE_BOARD_TEMPLATE overrides the shipped template (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TEMPLATE_DEFAULT="${FM_LIVE_BOARD_TEMPLATE:-$FM_ROOT/assets/live-board-template.html}"
PLACEHOLDER='__FM_LIVE_CONFIG__'
SCHEMA=fm-live-board.v1
STATE_WINDOW_S=90      # CPU window the sample reports over
SCRATCH_CACHE_S=60     # how often the output directory's size is measured

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-live-board: %s\n' "$*" >&2
  exit 1
}

as_int() {
  case "${1:-}" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Translate the run script's exit token into what actually happened. A bare
# number hides the difference between a delivered result and a signal, which is
# the exact distinction a reader of the page is asking about.
exit_meaning() {  # <exit-token>
  case ${1:-} in
    '') printf '' ;;
    EXIT=0) printf 'finished cleanly' ;;
    EXIT=137) printf 'killed outright (SIGKILL, signal 9)' ;;
    EXIT=143) printf 'terminated (SIGTERM, signal 15)' ;;
    EXIT=130) printf 'interrupted (SIGINT, signal 2)' ;;
    EXIT=124) printf 'stopped by its own time limit' ;;
    EXIT=*) printf 'exited %s' "${1#EXIT=}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# clock_to_s "MM:SS" | "HH:MM:SS" | "D-HH:MM:SS" (fractional seconds allowed).
clock_to_s() {
  awk -v t="$1" 'BEGIN {
    days = 0
    if (t ~ /-/) { split(t, d, "-"); days = d[1]; t = d[2] }
    n = split(t, p, ":")
    sec = 0
    for (i = 1; i <= n; i++) sec = sec * 60 + p[i]
    printf "%d", days * 86400 + sec
  }'
}

# The observed window: "base_epoch base_cpu prev_epoch prev_cpu", read from the
# state file and aged out past STATE_WINDOW_S. Rows fall outside the window so
# the reported CPU delta is smoothed rather than a per-interval jitter read.
state_window() {  # <state-file> <now> <interval>
  local state=$1 now=$2 interval=$3 line e c
  local base_e='' base_c='' prev_e='' prev_c=''
  : >"$state.rows"
  if [ -f "$state" ]; then
    while IFS= read -r line; do
      case $line in
        "first_seen "*) continue ;;
      esac
      e=${line%%,*}
      c=${line#*,}
      case ${e:-} in '' | *[!0-9]*) continue ;; esac
      [ "$e" -ge "$((now - STATE_WINDOW_S))" ] || continue
      printf '%s,%s\n' "$e" "$c" >>"$state.rows"
      if [ -z "$base_e" ]; then
        base_e=$e
        base_c=$c
      fi
      prev_e=$e
      prev_c=$c
    done <"$state"
  fi
  [ -n "$base_e" ] || {
    base_e=$now
    base_c='0'
  }
  [ -n "$prev_e" ] || {
    prev_e=$now
    prev_c='0'
  }
  printf '%s %s %s %s\n' "$base_e" "$base_c" "$prev_e" "$prev_c"
}

state_write() {  # <state-file> <now> <cpu> <first-seen>
  local state=$1 now=$2 cpu=$3 first_seen=$4
  {
    printf 'first_seen %s\n' "$first_seen"
    cat "$state.rows" 2>/dev/null || true
    printf '%s,%s\n' "$now" "$cpu"
  } >"$state.tmp"
  mv "$state.tmp" "$state"
  rm -f "$state.rows"
}

state_first_seen() {  # <state-file>  -> echoes the recorded first-seen epoch
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    case $line in
      "first_seen "*) printf '%s' "${line#first_seen }"; return 0 ;;
    esac
  done <"$1"
}

# Processes whose command line mentions this run, and the run's own parent.
# The needle is the run directory plus a slash: anything the run spawned carries
# it in --data-dir, so one substring finds the parent and every worker it
# started, while this sampler's own argv (which holds the bare directory, with
# no trailing slash) never matches itself.
#
# The directory match WINS over the command match. Two runs of the same command
# can be alive at once - the fleet does exactly that during a retry - and a
# command-name match alone would sum the other run's CPU into this run's
# liveness number, which is the one number that must not be contaminated. The
# The command match survives only as an explicit opt-in fallback for a run
# whose data directory lives outside its run directory, where no directory
# match exists to prefer; see the usage header.
#
# A store in this federation is literally named "errors", and a source named
# "errors" imports through the log as ordinary progress, so the error scan
# below must never match the bare word. See parse_log.
ps_members() {  # <run-dir> <match-regex>
  ps -axo pid=,etime=,time=,rss=,state=,args= 2>/dev/null |
    awk -v run="$1" -v re="$2" '
      BEGIN { needle = (run == "" ? "" : run "/") }
      {
        pid = $1; etime = $2; ctime = $3; rss = $4; state = $5
        args = $6
        for (i = 7; i <= NF; i++) args = args " " $i
        # Exclude only the sampler itself. The pattern names the script, never a
        # directory: a run directory is allowed to be named after this board,
        # and matching the bare word would drop the process being watched.
        if (args ~ /fm-live-board\.sh/) next
        hit = 0
        if (needle != "" && index(args, needle) > 0) hit = 1
        if (!hit && re != "" && args ~ re) hit = 1
        if (!hit) next
        print pid "\t" etime "\t" ctime "\t" rss "\t" state "\t" args
      }
    '
}

# Parse the phase log the run already writes. Emits "key<TAB>value" records
# plus two side files: --errfile (error-class lines) and --tailfile (last
# lines of the log, for crash context).
parse_log() {  # <log> <err-file> <tail-file>
  awk -v errfile="$2" -v tailfile="$3" '
    function strip(line, body) {
      body = line
      while (body ~ /^\[[^]]*\]/) { sub(/^\[[^]]*\] */, "", body) }
      return body
    }
    function t_of(line, s) {
      if (line !~ /^\[ *[0-9]+\.[0-9]+s\]/) return -1
      s = line
      sub(/^\[ */, "", s)
      sub(/s\].*/, "", s)
      return s + 0
    }
    {
      n++
      t = t_of($0)
      if (t >= 0) {
        if (last_t >= 0 && t - last_t > max_gap) max_gap = t - last_t
        last_t = t
      }
      body = strip($0)
      # Only a line with content counts as the last thing the run said: the
      # bundle framing normalizes every mirrored log to end in a newline, and a
      # blank line would otherwise be reported as the newest progress.
      if (length(body) > 0) last_line = body
      if (body ~ /^participating sources: /) {
        sub(/^participating sources: */, "", body)
        sources_total = body + 0
      }
      if (body ~ /^importing /) {
        m = split(body, tok, /[ \t]+/)
        if (m >= 6) {
          sources_reached++
          cur_source = tok[2]
          cur_db = tok[5]
          cur_beads = tok[6]
          cur_beads = substr(cur_beads, index(cur_beads, "=") + 1)
          last_import_t = t
        }
      }
      if (body ~ /^created /) {
        c = body
        sub(/^created +/, "", c)
        sub(/ .*$/, "", c)
        cur_table = c
        last_created_t = t
      }
      if (body ~ /bead\(s\) skipped as collision losers$/) {
        c = body
        sub(/^ *[^ ]+ +/, "", c)
        sub(/ .*$/, "", c)
        skipped_losers += c + 0
      }
      if (body ~ /^BUILD BLOCKED: [0-9]+ id collision/) {
        c = body
        sub(/^BUILD BLOCKED: /, "", c)
        sub(/ .*$/, "", c)
        blocked_ids = c + 0
      }
      if (body ~ /^isolated dolt server on /) {
        c = body
        sub(/^isolated dolt server on /, "", c)
        sub(/,.*$/, "", c)
        dolt_addr = c
      }
      lines[NR] = $0
      # Deliberately narrow: a bare "error" would match the federation store
      # literally named "errors" in the plan table and in its import line, so
      # only unambiguous failure wording counts as an error. "BUILD BLOCKED" is
      # the build refusing to proceed on content-disagreeing collisions unless
      # --allow-collisions is passed, and is reported as an accepted collision
      # rather than as an error.
      lower = tolower(body)
      if (lower ~ /(panic|fatal|failed|failure|refused|unable|mismatch|cannot|error:)/ &&
          lower !~ /build blocked/ && lower !~ /0 (error|errors|failure|failures)/) {
        errcount++
        if (errcount <= 12) print $0 >> errfile
      }
    }
    END {
      print "lines_total\t" n
      print "max_gap\t" (max_gap + 0)
      print "sources_total\t" (sources_total + 0)
      print "sources_reached\t" (sources_reached + 0)
      print "sources_done\t" (sources_reached > 0 ? sources_reached - 1 : 0)
      print "skipped_losers\t" (skipped_losers + 0)
      print "blocked_ids\t" (blocked_ids + 0)
      print "error_count\t" (errcount + 0)
      print "last_line\t" last_line
      print "cur_source\t" cur_source
      print "cur_db\t" cur_db
      print "cur_beads\t" cur_beads
      print "cur_table\t" cur_table
      print "dolt_addr\t" dolt_addr
      start = (n > 800 ? n - 800 : 1)
      for (i = start; i <= n; i++) print lines[i] >> tailfile
    }
  ' "$1"
}

# shell_squote <value>: a single-quoted POSIX shell word, safe to prepend to a
# script that runs under sh on this machine or on a remote host.
shell_squote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# bundle_producer: the read-only POSIX sh script that collects one sample. It
# runs through `sh` locally or through `ssh HOST sh`, so the local and remote
# paths cannot drift apart. It reads RUN_DIR and WANT_DU from the assignments
# prefixed to it by fetch_bundle, and emits a sectioned text bundle.
#
# Section framing: `##LOG <name>` ... `##ENDLOG` bodies are mirrored back into
# a local logs directory verbatim, and every other section is a `KEY<TAB>value`
# record. Log bodies are normalized to end in exactly one newline so the
# framing can never be confused by a file whose last line lacks one.
#
# Reads only. There is deliberately no kill, pkill, signal, restart, tee, or
# redirection onto any file under RUN_DIR anywhere in this script.
bundle_producer() {
  cat <<'PRODUCER'
set -u
RUN_DIR=${RUN_DIR:-}
RUN_DIR_ALT=${RUN_DIR_ALT:-}
WANT_DU=${WANT_DU:-0}
RUNNER_PATTERN=${RUNNER_PATTERN:-run-unify\.sh}
printf '##FF v1\n'
if [ -z "$RUN_DIR" ]; then
  printf '##FATAL\nno run directory was given\n'
  exit 3
fi
printf '##NOW\n%s\n' "$(date +%s)"
printf '##HOST\n%s\n' "$(hostname 2>/dev/null || echo unknown)"
if [ ! -d "$RUN_DIR" ]; then
  printf '##FATAL\nrun directory not found on this host: %s\n' "$RUN_DIR"
  exit 4
fi
for f in "$RUN_DIR"/logs/*.log "$RUN_DIR"/logs/*.exit "$RUN_DIR"/logs/mem.csv; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  printf '##STAT\n%s\t%s\t%s\n' "$name" \
    "$(wc -c <"$f" 2>/dev/null | tr -d ' ')" \
    "$(date -r "$f" +%s 2>/dev/null || echo 0)"
  printf '##LOG %s\n' "$name"
  if [ "$name" = mem.csv ]; then
    body=$(tail -n 200 "$f" 2>/dev/null; printf x)
  else
    body=$(head -c 400000 "$f" 2>/dev/null; printf x)
  fi
  printf '%s\n' "${body%x}"
  printf '##ENDLOG\n'
done
# Membership is the run's OWN process tree, anchored on the runner script. A run
# directory can hold more than one unify process - a source server, or a repro
# of a failure in a neighbouring scratch directory - and each of them carries
# the run directory in its path. Reporting one of those as the run would show
# hours of somebody else's CPU and gigabytes of their memory as this run's
# liveness, for a run that had already ended. So a process belongs to the run
# when the run's runner script is one of its ancestors (or it IS the runner),
# and the working directory is taken from that set. A layout with no recognisable
# runner falls back to the command-shape rule: a process under the run directory
# whose arguments name `unify` as a word of their own.
ps_section=$(ps -axo pid=,ppid=,etime=,time=,rss=,state=,args= 2>/dev/null | awk -v run="$RUN_DIR" -v alt="$RUN_DIR_ALT" -v runner="$RUNNER_PATTERN" '
  {
    pid = $1; ppid = $2; etime = $3; ctime = $4; rss = $5; state = $6
    args = $7
    for (i = 8; i <= NF; i++) args = args " " $i
    # The sampler itself carries the runner pattern on its own command line, and
    # its helpers carry the run directory, so neither may be mistaken for the
    # run runner or counted as a member of the run.
    if (args ~ /fm-live-board\.sh/ || args ~ /-v runner=/) next
    n++
    PIDS[n] = pid
    PARENT[pid] = ppid; ARGS[pid] = args; ETM[pid] = etime; CTM[pid] = ctime
    RSSM[pid] = rss; STATEM[pid] = state
    if (args ~ runner) { nrunners++; ISRUN[pid] = 1 }
  }
  END {
    # A directory can be reachable by more than one path - a symlinked /tmp is
    # the everyday case - so both the resolved and the as-given form count.
    needle = run "/"
    needle_alt = (alt == "" ? "" : alt "/")
    if (nrunners > 0) {
      for (i = 1; i <= n; i++) {
        p = PIDS[i]; hops = 0
        while (p != 0 && p != 1 && hops < 12) {
          if (ISRUN[p]) { INRUN[PIDS[i]] = 1; break }
          p = PARENT[p]; hops++
        }
      }
      for (i = 1; i <= n; i++) if (ISRUN[PIDS[i]]) INRUN[PIDS[i]] = 1
      for (i = 1; i <= n; i++) {
        p = PIDS[i]
        if (work != "" || !INRUN[p] || ARGS[p] !~ /unify/) continue
        m = split(ARGS[p], a, " ")
        for (j = 1; j <= m; j++) {
          if (a[j] ~ /^--data-dir=/) { w = a[j]; sub(/^--data-dir=/, "", w); work = w; break }
          if (a[j] == "--data-dir") { work = a[j + 1]; break }
        }
      }
    } else {
      # No runner in sight: the run is identified by command shape, and the
      # working directory it names then brings in its own workers, which do not
      # name the run command themselves.
      for (i = 1; i <= n; i++) {
        p = PIDS[i]
        hit = index(ARGS[p], needle) > 0
        if (!hit && needle_alt != "") hit = index(ARGS[p], needle_alt) > 0
        if (!hit) continue
        m = split(ARGS[p], a, " ")
        found = 0
        for (j = 1; j <= m; j++) if (a[j] == "unify") { found = 1; break }
        if (!found) continue
        CAND[p] = 1
        if (work != "") continue
        for (j = 1; j <= m; j++) {
          if (a[j] ~ /^--data-dir=/) { w = a[j]; sub(/^--data-dir=/, "", w); work = w; break }
          if (a[j] == "--data-dir") { work = a[j + 1]; break }
        }
      }
      if (work != "") {
        for (i = 1; i <= n; i++) {
          p = PIDS[i]
          q = index(ARGS[p], work)
          if (q == 0) continue
          after = substr(ARGS[p], q + length(work), 1)
          if (after != "" && after != "/") continue
          INRUN[p] = 1
        }
      }
      for (i = 1; i <= n; i++) if (CAND[PIDS[i]]) INRUN[PIDS[i]] = 1
    }
    printf "##WORKDIR\n%s\n##PS\n", work
    for (i = 1; i <= n; i++) {
      p = PIDS[i]
      if (!INRUN[p]) continue
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", p, ETM[p], CTM[p], RSSM[p], STATEM[p], ARGS[p]
    }
  }')
# The working directory is named inside the same pass, so it is lifted back out
# here for the size measurement below, and the section is re-emitted verbatim.
work=$(printf '%s\n' "$ps_section" | sed -n '/^##WORKDIR$/{n;p;}' | head -1)
printf '%s\n' "$ps_section"
printf '##SYSCTL\n'
if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  raw=$(sysctl -n vm.swapusage 2>/dev/null || true)
  printf 'swap_total_mb\t%s\n' "$(printf '%s' "$raw" | sed -nE 's/.*total = ([0-9.]+)M.*/\1/p')"
  printf 'swap_used_mb\t%s\n' "$(printf '%s' "$raw" | sed -nE 's/.*used = ([0-9.]+)M.*/\1/p')"
  printf 'cores\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  printf 'load_1m\t%s\n' "$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
else
  printf 'swap_total_mb\t%s\n' "$(awk '/SwapTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)"
  printf 'swap_used_mb\t%s\n' "$(awk 'BEGIN{t=0;f=0} /SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print int((t - f) / 1024)}' /proc/meminfo 2>/dev/null)"
  printf 'cores\t%s\n' "$(nproc 2>/dev/null || echo 1)"
  printf 'load_1m\t%s\n' "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
fi
if [ "$WANT_DU" = 1 ] && [ -n "$work" ] && [ -d "$work" ]; then
  printf '##DU\n%s\n' "$(du -sk "$work" 2>/dev/null | awk '{print $1}')"
fi
PRODUCER
}

# fetch_bundle <bundle-out> <err-out> <run-dir> <ssh-target> <want-du> <runner> <alt-run-dir>
# Runs the producer through ssh when a target is given, otherwise through a
# local sh. Returns non-zero only when no usable bundle came back.
fetch_bundle() {
  local bundle=$1 errfile=$2 run_dir=$3 ssh_target=$4 want_du=$5 runner=$6 alt=$7
  local input="$bundle.in"
  {
    printf 'RUN_DIR=%s\n' "$(shell_squote "$run_dir")"
    printf 'WANT_DU=%s\n' "$want_du"
    printf 'RUNNER_PATTERN=%s\n' "$(shell_squote "$runner")"
    printf 'RUN_DIR_ALT=%s\n' "$(shell_squote "$alt")"
    bundle_producer
  } >"$input"
  : >"$errfile"
  local rc=0
  if [ -n "$ssh_target" ]; then
    # BatchMode: never prompt, so an unreachable or unauthenticated host fails
    # as a fact instead of hanging the page behind an interactive login.
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$ssh_target" sh <"$input" >"$bundle" 2>>"$errfile"; then
      rc=1
    fi
  else
    if ! sh <"$input" >"$bundle" 2>>"$errfile"; then
      rc=1
    fi
  fi
  rm -f "$input"
  if [ "$rc" -ne 0 ] && ! grep -q '^##NOW$' "$bundle" 2>/dev/null; then
    return 1
  fi
  grep -q '^##NOW$' "$bundle" 2>/dev/null || return 1
  return 0
}

# parse_bundle <bundle> <mirror-logs-dir>: mirrors every ##LOG section into
# <mirror-logs-dir> and prints every other section as a `SECTION<TAB>row`
# record for the caller's case loop.
parse_bundle() {
  awk -v dir="$2" '
    function shut() { if (open) { close(out); open = 0 } }
    /^##LOG / { shut(); out = dir "/" substr($0, 7); open = 1; next }
    /^##ENDLOG$/ { shut(); next }
    /^##/ { shut(); sec = substr($0, 3); next }
    {
      if (open) { print > out } else if (sec != "") { print sec "\t" $0 }
    }
    END { shut() }
  ' "$1"
}

sample_run() {  # writes one fm-live-board.v1 sample
  local run_dir='' out='' state='' label='' match_re='' ssh_target=''
  local runner_re='run-unify\.sh'
  local interval=3 monitor_pid='' stopped_reason=''
  while [ $# -gt 0 ]; do
    case $1 in
      --run-dir) run_dir=${2:?--run-dir needs a value}; shift 2 ;;
      --out) out=${2:?--out needs a value}; shift 2 ;;
      --state) state=${2:?--state needs a value}; shift 2 ;;
      --label) label=${2-}; shift 2 ;;
      --match) match_re=${2-}; shift 2 ;;
      --ssh) ssh_target=${2:?--ssh needs a value}; shift 2 ;;
      --runner) runner_re=${2:?--runner needs a value}; shift 2 ;;
      --interval) interval=${2:?--interval needs a value}; shift 2 ;;
      --monitor-pid) monitor_pid=${2-}; shift 2 ;;
      --stopped) stopped_reason=${2:?--stopped needs a reason}; shift 2 ;;
      *) die "sample: unknown argument $1" ;;
    esac
  done
  [ -n "$run_dir" ] || die 'sample: --run-dir is required'
  [ -n "$out" ] || die 'sample: --out is required'
  command -v jq >/dev/null 2>&1 || die 'sample: jq is required to write the sample'
  # A remote run directory is that host's path: it is checked by the producer,
  # which is the only thing that can actually see it.
  # The resolved path is used for display and for the producer, but the path as
  # given is kept too: the run's processes may name it in the other form.
  local run_dir_alt=''
  if [ -z "$ssh_target" ]; then
    [ -d "$run_dir" ] || die "sample: run directory not found: $run_dir"
    local run_dir_arg="$run_dir"
    run_dir=$(cd "$run_dir" && pwd -P)
    [ "$run_dir_arg" = "$run_dir" ] || run_dir_alt=$run_dir_arg
  fi
  [ -n "$state" ] || state="$out.state"
  mkdir -p "$(dirname "$out")"
  local now interval_i
  now=$(date +%s)
  interval_i=$(as_int "$interval")
  [ "$interval_i" -gt 0 ] || interval_i=3

  # --- one read-only sample, locally or over ssh -------------------------
  # The logs are mirrored into a local directory so every parser below works on
  # real files, identically for a local and a remote run.
  local mirror="$out.mirror"
  local bundle="$mirror/bundle" ssh_err="$mirror/ssh.err"
  rm -rf "$mirror"
  mkdir -p "$mirror/logs"
  local want_du=1
  if [ -f "$state.du" ]; then
    local du_age
    du_age=$(( now - $(as_int "$(cut -d' ' -f1 "$state.du" 2>/dev/null)") ))
    [ "$du_age" -ge "$SCRATCH_CACHE_S" ] || want_du=0
  fi
  local reachable=true ssh_error=''
  if ! fetch_bundle "$bundle" "$ssh_err" "$run_dir" "$ssh_target" "$want_du" "$runner_re" "$run_dir_alt"; then
    reachable=false
    ssh_error=$(head -1 "$ssh_err" 2>/dev/null)
    [ -n "$ssh_error" ] || ssh_error="no sample came back from ${ssh_target:-this host}"
  fi
  local now_ref="$now" host_name='' work_dir='' du_kb_remote=0
  local ps_lines='' stat_lines='' fatal_note=''
  local swap_used_mb=0 swap_total_mb=0 cores=1 load_1m=0
  if [ "$reachable" = true ]; then
    local k v sub val
    while IFS=$'\t' read -r k v; do
      case $k in
        NOW) now_ref=$(as_int "$v") ;;
        HOST) host_name=$v ;;
        WORKDIR) work_dir=$v ;;
        DU) du_kb_remote=$(as_int "$v") ;;
        FATAL) fatal_note=$v ;;
        PS)
          ps_lines="$ps_lines$v
"
          ;;
        STAT)
          stat_lines="$stat_lines$v
"
          ;;
        SYSCTL)
          sub=${v%%$'\t'*}
          val=${v#*$'\t'}
          case $sub in
            swap_used_mb) swap_used_mb=$(as_int "${val%.*}") ;;
            swap_total_mb) swap_total_mb=$(as_int "${val%.*}") ;;
            cores) cores=$(as_int "$val") ;;
            load_1m) load_1m=$(as_int "${val%.*}") ;;
          esac
          ;;
      esac
    done <<EOF
$(parse_bundle "$bundle" "$mirror/logs")
EOF
    if [ -n "$fatal_note" ]; then
      reachable=false
      ssh_error=$fatal_note
    fi
  fi
  # An unreachable host must leave every downstream fact visibly empty rather
  # than zeroed into a plausible-looking idle run.
  if [ "$reachable" != true ] && [ -z "$host_name" ]; then
    host_name=${ssh_target:-$(hostname 2>/dev/null || echo local)}
  fi

  local logs="$mirror/logs"
  local phase='' phase_log='' run_log="$logs/run.log"
  # The phase is whatever the run script last announced, so the sampler follows
  # the build into verification without being told.
  if [ -f "$run_log" ]; then
    phase=$(grep -E '^=== .* started ' "$run_log" 2>/dev/null | tail -1 | awk '{print $2}')
  fi
  [ -n "$phase" ] || phase=build
  phase_log="$logs/$phase.log"
  [ -f "$phase_log" ] || phase_log="$logs/build.log"

  # --- process facts -----------------------------------------------------
  local members="$ps_lines"
  if [ "$reachable" = true ] && [ -z "$members" ] && [ -n "$match_re" ]; then
    # The explicit opt-in fallback: only meaningful when the caller named the
    # command, and only consulted when the host answered and no process named
    # the run directory.
    members=$(ps_members '' "$match_re")
  fi
  local max_etime_s=0 primary_best_s=-1
  local primary_pid='' primary_args='' primary_etime='' primary_cpu_txt=''
  local cpu_s=0 rss_kb=0 member_count=0 member_json='[]'
  while IFS=$'\t' read -r pid etime ctime rss st args; do
    [ -n "${pid:-}" ] || continue
    local c rs e_s
    c=$(clock_to_s "$ctime")
    rs=$(as_int "$rss")
    e_s=$(clock_to_s "$etime")
    cpu_s=$((cpu_s + c))
    rss_kb=$((rss_kb + rs))
    member_count=$((member_count + 1))
    [ "$e_s" -gt "$max_etime_s" ] && max_etime_s=$e_s
    if printf '%s' "$args" | grep -Eq "$match_re" && [ "$e_s" -gt "$primary_best_s" ]; then
      primary_best_s=$e_s
      primary_pid=$pid
      primary_etime=$etime
      primary_cpu_txt=$ctime
      primary_args=$args
    fi
    member_json=$(printf '%s' "$member_json" | jq -c \
      --argjson pid "$(as_int "$pid")" \
      --argjson cpu_s "$c" \
      --argjson rss_mb "$((rs / 1024))" \
      --arg state "$st" \
      --arg etime "$etime" \
      --arg args "$args" \
      '. + [{pid: $pid, cpu_s: $cpu_s, rss_mb: $rss_mb, state: $state, etime: $etime, args: $args}]')
  done <<EOF
$members
EOF
  local alive=false
  [ -n "$primary_pid" ] && alive=true
  [ -n "$primary_etime" ] || primary_etime=$(printf '%s' "$max_etime_s" | awk '{printf "%d:%02d", int($1 / 60), $1 % 60}')

  # --- CPU window --------------------------------------------------------
  local base_e base_c prev_e prev_c first_seen window_s cpu_delta wall_delta
  read -r base_e base_c prev_e prev_c <<EOF
$(state_window "$state" "$now" "$interval_i")
EOF
  first_seen=$(state_first_seen "$state")
  [ -n "$first_seen" ] || first_seen=$now
  window_s=$((now - base_e))
  [ "$window_s" -gt 0 ] || window_s=$interval_i
  cpu_delta=$((cpu_s - base_c))
  [ "$cpu_delta" -ge 0 ] || cpu_delta=0
  wall_delta=$((now - prev_e))
  [ "$wall_delta" -gt 0 ] || wall_delta=$interval_i
  state_write "$state" "$now" "$cpu_s" "$first_seen"
  local run_elapsed_s=$((now - first_seen))

  # --- log-derived progress ---------------------------------------------
  local errfile="$out.errs" tailfile="$out.tail"
  : >"$errfile"
  : >"$tailfile"
  local lines_total=0 max_gap=0 sources_total=0 sources_done=0
  local skipped_losers=0 blocked_ids=0 error_count=0
  local last_line='' cur_source='' cur_db='' cur_beads='' cur_table='' dolt_addr=''
  if [ -f "$phase_log" ]; then
    local k v
    while IFS=$'\t' read -r k v; do
      case $k in
        lines_total) lines_total=$v ;;
        max_gap) max_gap=$v ;;
        sources_total) sources_total=$v ;;
        sources_done) sources_done=$v ;;
        skipped_losers) skipped_losers=$v ;;
        blocked_ids) blocked_ids=$v ;;
        error_count) error_count=$v ;;
        last_line) last_line=$v ;;
        cur_source) cur_source=$v ;;
        cur_db) cur_db=$v ;;
        cur_beads) cur_beads=$v ;;
        cur_table) cur_table=$v ;;
        dolt_addr) dolt_addr=$v ;;
      esac
    done <<EOF
$(parse_log "$phase_log" "$errfile" "$tailfile")
EOF
  fi

  # Gap since the log last grew is the honest "quiet" measure: the run flushes
  # every line, so the phase log's mtime moves with progress. The size and mtime
  # come from the producer, which measured them on the host that owns the file,
  # and the gap is measured against that host's own clock so clock skew between
  # the two machines cannot be mistaken for a run that has stopped working.
  local log_bytes=0 log_epoch=0 gap_s=0
  local stat_name stat_bytes stat_epoch
  while IFS=$'\t' read -r stat_name stat_bytes stat_epoch; do
    [ "$stat_name" = "$(basename "$phase_log")" ] || continue
    log_bytes=$(as_int "$stat_bytes")
    log_epoch=$(as_int "$stat_epoch")
  done <<EOF
$stat_lines
EOF
  if [ "$log_epoch" -gt 0 ]; then
    gap_s=$((now_ref - log_epoch))
    [ "$gap_s" -ge 0 ] || gap_s=0
  fi
  local cadence_known=false
  [ "$max_gap" -gt 0 ] && cadence_known=true

  # --- verification progress --------------------------------------------
  # Verification imports nothing, so the build's source counter would show an
  # empty bar through the whole phase. It works table by table instead, and the
  # build log already recorded every table it created, which supplies the
  # denominator; the verify log supplies the ones already checked.
  local progress_unit=sources
  if [ "$phase" != build ] && [ -f "$logs/build.log" ] && [ -s "$phase_log" ]; then
    local tables_total tables_done last_table
    tables_total=$(grep -cE '\] +created [a-z_0-9]+ +scope=' "$logs/build.log" 2>/dev/null || true)
    tables_done=$(grep -cE 'unified +[a-z_0-9]+ +[0-9]+ group\(s\)$' "$phase_log" 2>/dev/null || true)
    if [ "$(as_int "$tables_total")" -gt 0 ]; then
      sources_total=$(as_int "$tables_total")
      sources_done=$(as_int "$tables_done")
      progress_unit=tables
      last_table=$(grep -E '\] +table +[a-z_0-9]+ +scope=' "$phase_log" 2>/dev/null | tail -1 |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "table") { print $(i + 1); exit } }')
      [ -z "$last_table" ] || cur_source=$last_table
    fi
  fi

  # --- host memory / load ----------------------------------------------
  # Swap, cores, and load all belong to the host the run is on, so they come
  # from the producer rather than from whichever machine is drawing the page.
  local dolt_rss_mb=0
  local mem_csv="$logs/mem.csv"
  if [ -f "$mem_csv" ]; then
    # The last row with content, because the bundle framing can leave a blank
    # line after the mirrored body and the header row is not a sample.
    local lastrow
    lastrow=$(grep -v '^[[:space:]]*$' "$mem_csv" 2>/dev/null | tail -1)
    dolt_rss_mb=$(printf '%s' "$lastrow" | cut -d, -f3)
  fi
  dolt_rss_mb=$(as_int "$dolt_rss_mb")
  cores=$(as_int "$cores")
  [ "$cores" -gt 0 ] || cores=1
  local work_dolt_rss_mb=0
  if [ -n "$primary_args" ]; then
    work_dolt_rss_mb=$(printf '%s' "$member_json" |
      jq -r '[.[] | select(.args | test("dolt sql-server")) | .rss_mb] | add // 0')
  fi

  # --- memory trend from the run's own trace ---------------------------
  local hist='[]'
  if [ -f "$mem_csv" ]; then
    hist=$(tail -60 "$mem_csv" |
      awk -F, '$1 ~ /^[0-9]+$/ && NF >= 3 {printf "%s,%s,%s\n", $1, $2, $3}' |
      jq -R -s -c 'split("\n") | map(select(length > 0) | split(",") |
        {t: (.[0] | tonumber), swap_mb: (.[1] | tonumber), dolt_rss_mb: (.[2] | tonumber)})')
  fi

  # --- output growth ----------------------------------------------------
  # The output directory is measured at most once per SCRATCH_CACHE_S because
  # walking a Dolt data directory is not free; the client asks the producer for
  # a fresh reading only when its cache is stale, and a cached reading reports
  # no delta rather than inventing one.
  local scratch_mb=0 scratch_delta_mb=0 scratch_measured_s=0
  if [ "$reachable" = true ] && [ "$want_du" = 1 ] && [ "$du_kb_remote" -gt 0 ]; then
    local du_kb=0
    if [ -f "$state.du" ]; then
      du_kb=$(as_int "$(cut -d' ' -f2 "$state.du" 2>/dev/null)")
    fi
    [ "$du_kb" -eq 0 ] || scratch_delta_mb=$(((du_kb_remote - du_kb) / 1024))
    printf '%s %s\n' "$now" "$du_kb_remote" >"$state.du"
    scratch_mb=$((du_kb_remote / 1024))
  elif [ -f "$state.du" ]; then
    local cached_kb
    cached_kb=$(as_int "$(cut -d' ' -f2 "$state.du" 2>/dev/null)")
    scratch_mb=$((cached_kb / 1024))
    scratch_measured_s=$((now - $(as_int "$(cut -d' ' -f1 "$state.du" 2>/dev/null)") ))
  fi

  # --- phase exit / outcome --------------------------------------------
  local build_exit='' verify_exit='' all_done=false
  [ -f "$logs/build.exit" ] && build_exit=$(tr -d ' \n' <"$logs/build.exit")
  [ -f "$logs/verify.exit" ] && verify_exit=$(tr -d ' \n' <"$logs/verify.exit")
  if [ -f "$run_log" ] && grep -q 'all phases done' "$run_log" 2>/dev/null; then
    all_done=true
  fi

  local outcome='null' finished=false
  local o_state='' o_title='' o_detail='' o_ok=false defects='[]'
  local build_note verify_note
  build_note=$(exit_meaning "$build_exit")
  verify_note=$(exit_meaning "$verify_exit")
  # A failure detail names where the run actually got to, so the reader does not
  # have to open a log to learn whether anything was verified.
  local reached=''
  if [ "$(as_int "$sources_total")" -gt 0 ]; then
    reached=" after ${sources_done} of ${sources_total} sources"
    [ -z "$cur_source" ] || reached="$reached, on ${cur_source}"
  fi
  case ${build_exit:-none} in
    none) ;;
    EXIT=0) ;;
    *)
      o_state=build-failed
      o_title="Build failed - $build_note"
      o_detail="the build stopped$reached; verification never ran, so nothing has been verified"
      ;;
  esac
  if [ -z "$o_state" ]; then
    case ${verify_exit:-none} in
      none) ;;
      EXIT=0)
        o_state=verified
        o_ok=true
        o_title='Verified sound'
        o_detail='the build finished with no failures and verification passed'
        ;;
      *)
        o_state=verify-failed
        o_title="Verification failed - $verify_note"
        o_detail='verification could not confirm the copy; read the failure list below'
        defects=$(grep -aiE '(error:|panic|fatal|failed|failure|refused|unable|mismatch|missing|want )' "$logs/verify.log" 2>/dev/null |
          tail -8 | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
        ;;
    esac
  fi
  if [ -z "$o_state" ] && [ "$build_exit" = 'EXIT=0' ] && [ "$all_done" != true ]; then
    o_state=build-ok
    o_title='Copy built, verification next'
    o_detail='the build finished cleanly and the run is moving on to verification'
  fi
  if [ -z "$o_state" ] && [ "$all_done" = true ]; then
    o_state=incomplete
    o_title='Run ended without a clean result'
    o_detail='the run script logged completion but no phase reported a clean exit'
  fi
  if [ -n "$o_state" ]; then
    case $o_state in
      verified | verify-failed | build-failed | incomplete) finished=true ;;
      build-ok) finished=false ;;
    esac
    outcome=$(jq -c -n \
      --arg state "$o_state" \
      --arg title "$o_title" \
      --arg detail "$o_detail" \
      --argjson ok "$o_ok" \
      --arg build_exit "${build_exit:-}" \
      --arg verify_exit "${verify_exit:-}" \
      --argjson defects "$defects" \
      '{state: $state, title: $title, detail: $detail, ok: $ok, build_exit: $build_exit, verify_exit: $verify_exit, defects: $defects}')
  fi

  # --- verdict: the single classification both the page and a reader use --
  local verdict note
  if [ "$reachable" != true ]; then
    # First, because nothing below can be established without contact: a host
    # that cannot be reached says nothing about whether its run is alive, and
    # reporting its silence as a stopped process would be a fabrication.
    verdict=unreachable
    note="cannot reach ${ssh_target:-the host} to sample ${host_name}:${run_dir} - ${ssh_error}"
    finished=false
  elif [ "$finished" = true ]; then
    if [ "$o_ok" = true ]; then
      verdict='finished-ok'
      note='run complete and verified'
    else
      verdict='finished-failed'
      note='run complete, result not clean'
    fi
  elif [ "$error_count" -gt 0 ]; then
    verdict=errors
    note="$error_count error-class line(s) in the current phase log"
  elif [ "$build_exit" = 'EXIT=0' ] && [ -z "$verify_exit" ] && [ "$alive" != true ] && [ ! -s "$phase_log" ]; then
    # The hand-off between phases: the build reported a clean exit and the next
    # phase has not written a line yet. Calling this "gone" would read as a
    # failure at the one moment nothing is wrong.
    verdict='between-phases'
    note='the build reported a clean exit; the next phase has not written anything yet'
  elif [ "$alive" != true ]; then
    verdict=gone
    note='the watched process is no longer running and the run has not reported a result'
  elif ! $cadence_known; then
    # Before the run has produced two distinct progress timestamps there is no
    # cadence to compare against, so the only honest stall test is an absolute
    # one: a long quiet spell with no CPU advance over a wide window.
    if [ "$gap_s" -gt 180 ] && [ "$cpu_delta" -eq 0 ] && [ "$window_s" -ge 30 ]; then
      verdict=stalled
      note="no progress line for ${gap_s}s and no CPU advance over ${window_s}s"
    else
      verdict=unknown-cadence
      note='no progress-line cadence yet; waiting for the second progress timestamp'
    fi
  elif [ "$gap_s" -gt "$((max_gap * 3))" ] && [ "$gap_s" -gt 60 ]; then
    if [ "$cpu_delta" -gt 0 ]; then
      verdict=slow
      note="quiet for ${gap_s}s against a ${max_gap}s cadence, but CPU is still advancing"
    else
      verdict=stalled
      note="quiet for ${gap_s}s against a ${max_gap}s cadence with no CPU advance: starved or hung"
    fi
  else
    verdict=progressing
    note="last progress line ${gap_s}s ago, within this run's ${max_gap}s cadence"
  fi
  if [ -n "$stopped_reason" ] && [ "$finished" != true ] && [ "$reachable" = true ]; then
    verdict=unwatched
    note="watch stopped: $stopped_reason"
  fi

  local err_json tail_json
  err_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' <"$errfile")
  tail_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' <"$tailfile")

  local stopped_json=false
  if [ -n "$stopped_reason" ]; then
    stopped_json=true
  fi

  jq -n \
    --arg schema "$SCHEMA" \
    --arg label "${label:-$run_dir}" \
    --arg run_dir "$run_dir" \
    --arg source_kind "$([ -n "$ssh_target" ] && echo ssh || echo local)" \
    --arg source_target "$ssh_target" \
    --arg source_host "$host_name" \
    --argjson source_reachable "$reachable" \
    --arg source_error "$ssh_error" \
    --argjson sampled_at "$now" \
    --arg sampled_iso "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
    --argjson interval_s "$interval_i" \
    --argjson stale_after_s "$((interval_i * 4))" \
    --argjson monitor_pid "$(as_int "$monitor_pid")" \
    --argjson monitor_stopped "$stopped_json" \
    --arg monitor_reason "$stopped_reason" \
    --arg verdict "$verdict" \
    --arg verdict_note "$note" \
    --argjson finished "$finished" \
    --argjson alive "$alive" \
    --argjson pid "$(as_int "$primary_pid")" \
    --arg etime "$primary_etime" \
    --arg cputime "$primary_cpu_txt" \
    --argjson elapsed_s "$max_etime_s" \
    --argjson run_elapsed_s "$run_elapsed_s" \
    --argjson cpu_s "$cpu_s" \
    --argjson cpu_delta_s "$cpu_delta" \
    --argjson window_s "$window_s" \
    --argjson rss_mb "$((rss_kb / 1024))" \
    --argjson process_count "$member_count" \
    --argjson members "$member_json" \
    --arg phase "$phase" \
    --argjson sources_total "$(as_int "$sources_total")" \
    --argjson sources_done "$(as_int "$sources_done")" \
    --arg current_source "$cur_source" \
    --arg current_db "$cur_db" \
    --arg current_beads "$cur_beads" \
    --arg current_table "$cur_table" \
    --arg last_line "$last_line" \
    --argjson lines_total "$(as_int "$lines_total")" \
    --argjson gap_s "$gap_s" \
    --argjson max_gap_s "$(as_int "$max_gap")" \
    --argjson cadence_known "$cadence_known" \
    --arg progress_unit "$progress_unit" \
    --argjson log_bytes "$(as_int "$log_bytes")" \
    --argjson error_count "$(as_int "$error_count")" \
    --argjson errors "$err_json" \
    --argjson log_tail "$tail_json" \
    --argjson skipped_losers "$(as_int "$skipped_losers")" \
    --argjson blocked_ids "$(as_int "$blocked_ids")" \
    --argjson work_dolt_rss_mb "$(as_int "$work_dolt_rss_mb")" \
    --argjson dolt_rss_mb "$dolt_rss_mb" \
    --argjson swap_used_mb "$swap_used_mb" \
    --argjson swap_total_mb "$swap_total_mb" \
    --argjson load_1m "$(as_int "${load_1m%.*}")" \
    --argjson cores "$cores" \
    --argjson scratch_mb "$(as_int "$scratch_mb")" \
    --argjson scratch_delta_mb "$(as_int "$scratch_delta_mb")" \
    --argjson scratch_measured_s "$(as_int "$scratch_measured_s")" \
    --arg work_dir "$work_dir" \
    --arg dolt_addr "$dolt_addr" \
    --arg build_exit "$build_exit" \
    --arg verify_exit "$verify_exit" \
    --arg build_note "$build_note" \
    --arg verify_note "$verify_note" \
    --argjson outcome "$outcome" \
    --argjson history_mem "$hist" \
    '{
      schema: $schema,
      label: $label,
      run_dir: $run_dir,
      sampled_at: $sampled_at,
      sampled_iso: $sampled_iso,
      monitor: {pid: $monitor_pid, interval_s: $interval_s, stale_after_s: $stale_after_s,
                stopped: $monitor_stopped, reason: $monitor_reason},
      verdict: $verdict,
      verdict_note: $verdict_note,
      finished: $finished,
      process: {alive: $alive, pid: $pid, etime: $etime, cputime: $cputime,
                elapsed_s: $elapsed_s, run_elapsed_s: $run_elapsed_s, cpu_s: $cpu_s,
                cpu_delta_s: $cpu_delta_s, window_s: $window_s, rss_mb: $rss_mb,
                count: $process_count, members: $members},
      source: {kind: $source_kind, target: $source_target, host: $source_host,
               run_dir: $run_dir, reachable: $source_reachable, error: $source_error},
      progress: {phase: $phase, unit: $progress_unit, sources_total: $sources_total, sources_done: $sources_done,
                 current_source: $current_source, current_db: $current_db,
                 current_beads: $current_beads, current_table: $current_table,
                 last_line: $last_line, lines_total: $lines_total,
                 gap_s: $gap_s, max_gap_s: $max_gap_s, cadence_known: $cadence_known,
                 log_bytes: $log_bytes},
      collisions: {accepted_content_disagreements: $blocked_ids, skipped_losing_rows: $skipped_losers},
      errors: {count: $error_count, lines: $errors},
      health: {work_dolt_rss_mb: $work_dolt_rss_mb, dolt_rss_mb: $dolt_rss_mb,
               swap_used_mb: $swap_used_mb, swap_total_mb: $swap_total_mb,
               load_1m: $load_1m, cores: $cores, scratch_mb: $scratch_mb,
               scratch_delta_mb: $scratch_delta_mb, scratch_measured_s: $scratch_measured_s,
               work_dir: $work_dir, dolt_addr: $dolt_addr},
      exit: {build: $build_exit, verify: $verify_exit,
             build_note: $build_note, verify_note: $verify_note},
      outcome: $outcome,
      log_tail: $log_tail,
      history_mem: $history_mem
    }' >"$out.tmp"
  mv "$out.tmp" "$out"
  rm -f "$errfile" "$tailfile"
}

page_write() {
  local out='' template="$TEMPLATE_DEFAULT" label='brain unify build' data_name=''
  while [ $# -gt 0 ]; do
    case $1 in
      --out) out=${2:?--out needs a value}; shift 2 ;;
      --template) template=${2:?--template needs a value}; shift 2 ;;
      --label) label=${2-}; shift 2 ;;
      --data) data_name=${2-}; shift 2 ;;
      *) die "page: unknown argument $1" ;;
    esac
  done
  [ -n "$out" ] || die 'page: --out is required'
  [ -f "$template" ] || die "page: template not found: $template"
  command -v jq >/dev/null 2>&1 || die 'page: jq is required to write the page'
  [ -n "$data_name" ] || data_name="$(basename "${out%.html}").json"
  local cfg="$out.cfg"
  jq -c -n --arg data "$data_name" --arg label "$label" \
    '{data: $data, label: $label}' | sed 's/</\\u003c/g' >"$cfg"
  awk -v cfgfile="$cfg" -v ph="$PLACEHOLDER" '
    BEGIN { if ((getline cfgline < cfgfile) < 0) exit 1 }
    index($0, ph) > 0 { print "window.FM_LIVE = " cfgline ";"; next }
    { print }
  ' "$template" >"$out.tmp"
  mv "$out.tmp" "$out"
  rm -f "$cfg"
  printf 'page: %s\n' "$out"
}

watch_run() {
  local run_dir='' out='' label='' match_re='' ssh_target='' follow=false
  local runner_re='run-unify\.sh'
  local interval=3 max_seconds=32400 state=''
  while [ $# -gt 0 ]; do
    case $1 in
      --run-dir) run_dir=${2:?--run-dir needs a value}; shift 2 ;;
      --out) out=${2:?--out needs a value}; shift 2 ;;
      --label) label=${2-}; shift 2 ;;
      --match) match_re=${2-}; shift 2 ;;
      --ssh) ssh_target=${2:?--ssh needs a value}; shift 2 ;;
      --runner) runner_re=${2:?--runner needs a value}; shift 2 ;;
      --follow) follow=true; shift ;;
      --interval) interval=${2:?--interval needs a value}; shift 2 ;;
      --max-seconds) max_seconds=${2:?--max-seconds needs a value}; shift 2 ;;
      *) die "watch: unknown argument $1" ;;
    esac
  done
  [ -n "$run_dir" ] || die 'watch: --run-dir is required'
  [ -n "$out" ] || die 'watch: --out is required (the page path)'
  # A remote run's directory is only checkable on its own host, so only the
  # local case may treat a missing directory as the end of the watch.
  local check_dir=true
  [ -z "$ssh_target" ] || check_dir=false
  local json="${out%.html}.json"
  state="$json.state"
  local start now reason=''
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    reason=''
    if [ "$check_dir" = true ] && [ ! -d "$run_dir" ]; then
      reason='run directory removed'
    elif [ "$((now - start))" -ge "$max_seconds" ]; then
      reason="watch time limit (${max_seconds}s) reached"
    fi
    if [ -z "$reason" ]; then
      # shellcheck disable=SC2086
      sample_run --run-dir "$run_dir" --out "$json" --state "$state" \
        --label "$label" --match "$match_re" --interval "$interval" \
        --monitor-pid "$$" ${ssh_target:+--ssh "$ssh_target"} --runner "$runner_re"
      if jq -e '.finished == true' "$json" >/dev/null 2>&1; then
        reason='run reached its final result'
        # A retried run is a normal shape here, and a page that silently stops
        # when the first attempt ends would go quiet exactly when the next one
        # starts. --follow keeps sampling through the retry; without it the
        # watch ends and says so, which is the cheaper default.
        if [ "$follow" = true ]; then
          reason=''
        fi
      fi
    fi
    if [ -n "$reason" ]; then
      # One final sample carrying the reason, so a page that stops refreshing
      # reports that the watch ENDED instead of looking like a dead monitor.
      # shellcheck disable=SC2086
      sample_run --run-dir "$run_dir" --out "$json" --state "$state" \
        --label "$label" --match "$match_re" --interval "$interval" \
        --monitor-pid "$$" ${ssh_target:+--ssh "$ssh_target"} --runner "$runner_re" --stopped "$reason"
      printf 'watch: ended: %s\n' "$reason"
      break
    fi
    sleep "$interval"
  done
}

open_board() {
  local out='' reopen=''
  while [ $# -gt 0 ]; do
    case $1 in
      --out) out=${2:?--out needs a value}; shift 2 ;;
      --reopen) reopen=--reopen; shift ;;
      *) die "open: unknown argument $1" ;;
    esac
  done
  [ -n "$out" ] || die 'open: --out is required'
  [ -f "$out" ] || die "open: page not found: $out (run 'page' first)"
  command -v lavish-axi >/dev/null 2>&1 || die 'open: lavish-axi is not installed'
  # shellcheck disable=SC2086
  lavish-axi $reopen "$out"
}

[ $# -gt 0 ] || {
  usage
  exit 2
}
cmd=$1
shift
case $cmd in
  sample) sample_run "$@" ;;
  page) page_write "$@" ;;
  watch) watch_run "$@" ;;
  open) open_board "$@" ;;
  # Expose the read-only producer so its syntax can be checked for the shell it
  # will actually run under, and so its freedom from state-changing verbs is
  # inspectable rather than a claim in a comment.
  producer) bundle_producer ;;
  help | --help | -h) usage ;;
  *) die "unknown subcommand: $cmd" ;;
esac
