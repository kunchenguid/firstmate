#!/usr/bin/env bash
# fm-progress-lib.sh - the ONE owner of firstmate's POSITIVE progress measurement.
#
# Sourced, never executed.
#
# WHY THIS EXISTS. Supervision's wedge detector (bin/fm-watch.sh) decided a pane
# was "possibly wedged" from an ABSENCE: the rendered tail had not changed for
# FM_STALE_ESCALATE_SECS. Absence of pixel change is not absence of progress, and
# on 2026-08-20 that proxy inverted in both directions on one night: three healthy
# workers escalated repeatedly (a long model turn, a `sleep`-and-poll loop waiting
# on CI, and a live pane-driving experiment that renders nothing until it ends),
# while three workers stopped dead by a provider session limit raised nothing at
# all, because a stopped harness that never fired its turn-end hook still
# classifies busy and a busy pane was exempt from stale detection entirely.
#
# WHAT THIS MEASURES INSTEAD. Two readings of the pane's own process subtree,
# taken minutes apart, compared on ACCUMULATED CPU time - the discriminator that
# settled the same question by hand:
#
#   reading 1: 49267  elapsed 03:36:15  time 5:27.95  %CPU 5.2
#   reading 2: 49267  elapsed 03:41:49  time 6:03.14  %CPU 6.1
#
# +35s of CPU over 5.5 minutes of wall clock. A wedged interpreter accumulates
# near zero; one instantaneous %CPU sample cannot tell the two apart, the DELTA
# can. It needs no cooperation from the worker, no harness-specific parsing, and
# no guess about what the pane is rendering - and it stays correct for the case
# the rendered-tail detector missed entirely, because a session-limited worker
# sitting at an empty composer accumulates nothing and reads stalled.
#
# TWO INDEPENDENT POSITIVE SIGNALS, either of which carries a progressing
# verdict, because they fail for different reasons:
#
#   1. CPU RATE. delta accumulated CPU over the span, expressed as percent of one
#      core (centiseconds per second IS percent), against FM_PROGRESS_CPU_MIN_PCT.
#   2. SUBTREE COMPOSITION. The set of pids under the pane. `ps -o time=` reports
#      a process's OWN utime+stime and never the CPU of children it already
#      reaped, so a worker whose turn is a series of short shell commands can
#      show almost no CPU on any single sample while doing real work. Its pid set
#      changes every time it spawns or reaps one, which the wedged pane's does
#      not. Every sample is compared against the SAME baseline rather than
#      against the previous sample, so one poll that catches a transient child is
#      enough to clear the whole span - at FM_POLL=15 and 240s of wedge timer
#      there are roughly sixteen such chances.
#
# Both are kernel facts read through `ps`. Neither reads rendered output, so no
# change to what a harness DRAWS can move the verdict, and neither asks the
# worker to declare anything - a worker already stopped by a provider limit never
# gets the turn in which to declare a `paused:` line. What a release CAN move is
# where a harness's own idle and mid-turn states sit relative to the threshold (a
# TUI that repaints while idle would raise the idle floor), so that relationship
# is guarded live per installed harness rather than assumed - see
# tests/fm-progress-probe-live-e2e.test.sh and the measured margins in
# docs/verification/supervision.md "Progress probe".
#
# VERDICTS (fm_progress_probe prints exactly one token):
#   progressing - a positive signal fired. The worker is doing work; do not
#                 escalate. The baseline is rolled forward to this sample.
#   stalled     - the span is mature and NEITHER signal fired. This is positive
#                 evidence of non-progress, the only thing that may raise the new
#                 busy-pane stall wake.
#   unknown     - no baseline yet, the span is not mature, or the subtree could
#                 not be read (no pid source for this backend, a dead pane, a ps
#                 failure). NEVER treated as either verdict: callers preserve
#                 whatever they would have done without a probe, so a backend
#                 with no pid source degrades to the pre-existing behavior rather
#                 than to silence.
#
# ROOT PIDS come from fm_backend_agent_root_pids (bin/fm-backend.sh), which owns
# per-backend resolution. This library takes pids and never talks to a backend.
#
# BASELINE RECORDS live at <state-dir>/.progress-<key>, one line, replaced
# atomically. They are watcher bookkeeping like every other .stale-*/.hash-*
# record: safe to delete (the next poll re-baselines and returns unknown until
# the span matures again), never task or endpoint authority.

FM_PROGRESS_LIB_VERSION=v1

# Minimum wall-clock span before a no-signal reading may be called stalled. Set
# below FM_STALE_ESCALATE_SECS (240) so a baseline taken when the wedge timer
# starts is already mature when that timer fires, and high enough that "minutes
# apart" is literally true - a short span cannot distinguish a wedge from the gap
# between two tool calls. "Taken when the wedge timer starts" is a property of the
# CALLER, not of this number: bin/fm-watch.sh's start_wedge_timer owns it, and
# without it the first reading available when the timer fires is the absence of
# one, whatever this span is set to.
FM_PROGRESS_MIN_SPAN_SECS=${FM_PROGRESS_MIN_SPAN_SECS:-180}
# Sustained absence of both signals before a busy pane may be called stalled on
# its own - the NEW alarm, so it buys confidence with a much longer window than
# the wedge gate needs. Ten minutes of a pane that claims to be mid-turn while
# its whole process subtree accumulates no CPU and spawns nothing is diagnostic;
# it is also six times faster than FM_BUSY_TURN_MAX_SECS, the only bound that
# covered this case before.
FM_PROGRESS_STALL_SPAN_SECS=${FM_PROGRESS_STALL_SPAN_SECS:-600}
# Sustained CPU, in percent of one core, that counts as work. Measured against
# real panes rather than guessed: see docs/verification/supervision.md
# "Progress probe".
FM_PROGRESS_CPU_MIN_PCT=${FM_PROGRESS_CPU_MIN_PCT:-2}

# fm_progress_time_to_centis: parse one `ps -o time=` value into centiseconds.
# Accepts every documented shape across platforms - `MM:SS.cc` (macOS),
# `HH:MM:SS` (Linux), and `DD-HH:MM:SS` for a long-lived process. Prints nothing
# and returns 1 on anything it does not fully recognize, so an unparsed value can
# never be silently read as zero CPU.
fm_progress_time_to_centis() {  # <ps-time-value>
  local v=$1 days=0 rest secs centis=0 part n total=0
  v=${v//[[:space:]]/}
  [ -n "$v" ] || return 1
  case "$v" in
    *-*)
      days=${v%%-*}
      rest=${v#*-}
      case "$days" in ''|*[!0-9]*) return 1 ;; esac
      ;;
    *) rest=$v ;;
  esac
  case "$rest" in
    *.*)
      centis=${rest##*.}
      rest=${rest%.*}
      case "$centis" in ''|*[!0-9]*) return 1 ;; esac
      # Normalize a fractional field of any width to hundredths.
      while [ "${#centis}" -lt 2 ]; do centis="${centis}0"; done
      centis=${centis:0:2}
      centis=$((10#$centis))
      ;;
  esac
  # Fields are seconds-last: [[HH:]MM:]SS.
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  unset IFS
  [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 1
  for part in "$@"; do
    case "$part" in ''|*[!0-9]*) return 1 ;; esac
  done
  secs=0
  for part in "$@"; do
    n=$((10#$part))
    secs=$((secs * 60 + n))
  done
  total=$(( (days * 86400 + secs) * 100 + centis ))
  printf '%s' "$total"
}

# fm_progress_subtree_pids: every pid in the process subtree rooted at each
# <root-pid>, roots included, one per line, ascending.
#
# Resolved by walking the ppid graph from ONE `ps -axo pid=,ppid=` read, never by
# `pgrep -f`: a command-line match picks up unrelated processes that merely
# mention the harness (this script, a grep, another home's worker) and would let
# an idle pane borrow a busy stranger's CPU. Returns 1 when the process table
# cannot be read or no root resolves to a live process.
fm_progress_subtree_pids() {  # <root-pid>...
  local rows roots=
  [ "$#" -ge 1 ] || return 1
  local p
  for p in "$@"; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" -gt 1 ] || continue
    roots="$roots $p"
  done
  [ -n "$roots" ] || return 1
  rows=$(LC_ALL=C ps -axo pid=,ppid= 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1
  # Captured rather than piped straight out: awk's END exit status is lost behind
  # `sort` in a pipeline, and a root that names no live process must fail here
  # rather than return success with nothing.
  local out
  out=$(printf '%s\n' "$rows" | awk -v roots="$roots" '
    { pid[$1] = 1; ppid[$1] = $2; if ($2 != "") children[$2] = children[$2] " " $1 }
    END {
      n = split(roots, r, " ")
      for (i = 1; i <= n; i++) if (r[i] != "" && (r[i] in pid)) { queue[++tail] = r[i] }
      if (tail == 0) exit 1
      head = 0
      while (head < tail) {
        cur = queue[++head]
        if (cur in seen) continue
        seen[cur] = 1
        split(children[cur], kids, " ")
        for (k in kids) if (kids[k] != "" && !(kids[k] in seen)) queue[++tail] = kids[k]
      }
      for (s in seen) print s + 0
    }
  ' | sort -n)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_progress_sample: one instantaneous reading of a pane's process subtree.
#
# Prints "v1 <epoch> <cpu-centis> <pid-count> <composition>" where composition is
# the subtree's pid set joined by commas. Returns 1 when the subtree or its CPU
# time cannot be read, so a failed reading is never mistaken for zero work.
fm_progress_sample() {  # <root-pid>...
  local pids list rows total=0 pid t c count=0 composition=
  pids=$(fm_progress_subtree_pids "$@") || return 1
  [ -n "$pids" ] || return 1
  list=$(printf '%s' "$pids" | tr '\n' ',')
  list=${list%,}
  rows=$(LC_ALL=C ps -p "$list" -o pid=,time= 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1
  # Sorted, because `ps -p` makes no promise about output order: an unsorted
  # membership string could differ between two samples of the SAME processes and
  # report a change that never happened - which reads as progress, and would let
  # a wedged pane borrow a verdict from row ordering.
  rows=$(printf '%s\n' "$rows" | sort -n)
  while read -r pid t; do
    [ -n "$pid" ] || continue
    c=$(fm_progress_time_to_centis "$t") || continue
    total=$((total + c))
    count=$((count + 1))
    composition="$composition,$pid"
  done <<EOF
$rows
EOF
  [ "$count" -ge 1 ] || return 1
  printf '%s %s %s %s %s' "$FM_PROGRESS_LIB_VERSION" "$(date +%s)" "$total" "$count" "${composition#,}"
}

# fm_progress_compare: the verdict for <sample> against <baseline>, with no state
# of its own. Prints "<verdict> <detail>"; detail is a human-readable reading a
# wake reason or a test can quote verbatim.
fm_progress_compare() {  # <baseline-record> <sample-record> [min-span-secs]
  local b=$1 s=$2 min_span=${3:-$FM_PROGRESS_MIN_SPAN_SECS}
  local bv bt bc bn bcomp sv st sc sn scomp span delta pct
  # shellcheck disable=SC2086
  set -- $b
  [ "$#" -eq 5 ] || { printf 'unknown no-baseline'; return 0; }
  bv=$1 bt=$2 bc=$3 bn=$4 bcomp=$5
  # shellcheck disable=SC2086
  set -- $s
  [ "$#" -eq 5 ] || { printf 'unknown unreadable-sample'; return 0; }
  sv=$1 st=$2 sc=$3 sn=$4 scomp=$5
  [ "$bv" = "$FM_PROGRESS_LIB_VERSION" ] && [ "$sv" = "$FM_PROGRESS_LIB_VERSION" ] \
    || { printf 'unknown record-version'; return 0; }
  case "$bt$bc$st$sc" in *[!0-9]*) printf 'unknown malformed-record'; return 0 ;; esac
  span=$((st - bt))
  [ "$span" -gt 0 ] || { printf 'unknown non-monotonic-clock'; return 0; }
  if [ "$scomp" != "$bcomp" ]; then
    printf 'progressing subtree-changed (%s processes now vs %s, membership differs over %ss)' \
      "$sn" "$bn" "$span"
    return 0
  fi
  delta=$((sc - bc))
  [ "$delta" -ge 0 ] || { printf 'unknown cpu-time-regressed'; return 0; }
  pct=$((delta / span))
  if [ "$pct" -ge "$FM_PROGRESS_CPU_MIN_PCT" ]; then
    printf 'progressing cpu +%s.%02ds over %ss (%s%% of a core)' \
      "$((delta / 100))" "$((delta % 100))" "$span" "$pct"
    return 0
  fi
  if [ "$span" -lt "$min_span" ]; then
    printf 'unknown span-immature (%ss of %ss)' "$span" "$min_span"
    return 0
  fi
  printf 'stalled cpu +%s.%02ds over %ss (%s%% of a core, %s processes unchanged)' \
    "$((delta / 100))" "$((delta % 100))" "$span" "$pct" "$sn"
}

fm_progress_record_path() {  # <state-dir> <key>
  printf '%s/.progress-%s' "$1" "$2"
}

# fm_progress_probe: the stateful entry point supervision calls. Takes one
# sample, compares it against <key>'s stored baseline, and prints
# "<verdict> <detail>".
#
# Baseline lifecycle: absent or unreadable -> record this sample and report
# unknown; progressing -> roll the baseline forward to this sample, so the next
# span measures from the last proof of work rather than from an ever-older
# origin; stalled or unknown -> leave the baseline alone so the span keeps
# maturing. A subtree that cannot be read at all leaves the baseline untouched
# and reports unknown, so one transient ps failure cannot reset a maturing span.
fm_progress_probe() {  # <state-dir> <key> <min-span-secs> <root-pid>...
  local state=$1 key=$2 min_span=$3 record sample baseline verdict
  shift 3
  case "$min_span" in ''|*[!0-9]*) min_span=$FM_PROGRESS_MIN_SPAN_SECS ;; esac
  record=$(fm_progress_record_path "$state" "$key")
  if ! sample=$(fm_progress_sample "$@"); then
    printf 'unknown subtree-unreadable'
    return 0
  fi
  baseline=$(cat "$record" 2>/dev/null || true)
  if [ -z "$baseline" ]; then
    fm_progress_write "$record" "$sample"
    printf 'unknown baseline-recorded'
    return 0
  fi
  verdict=$(fm_progress_compare "$baseline" "$sample" "$min_span")
  case "$verdict" in
    progressing*|'unknown no-baseline'*|'unknown malformed-record'*|'unknown record-version'*|'unknown non-monotonic-clock'*|'unknown cpu-time-regressed'*)
      fm_progress_write "$record" "$sample"
      ;;
  esac
  printf '%s' "$verdict"
}

fm_progress_write() {  # <record-path> <line>
  local path=$1 line=$2 tmp
  tmp="$path.tmp.$$"
  printf '%s' "$line" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
  return 0
}

fm_progress_reset() {  # <state-dir> <key>
  rm -f "$(fm_progress_record_path "$1" "$2")" 2>/dev/null || true
  return 0
}
