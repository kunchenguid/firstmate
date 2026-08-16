#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# It also owns the two run-object questions the supervisors ask about a run
# they have already located: is it EXECUTING right now
# (fm_nm_run_is_executing), and has it MOVED since last time
# (fm_nm_run_progress_fingerprint). Both are read-only pure text functions over
# captured `axi status` output; fm-classify-lib.sh's crew_run_progressed is
# their supervision-side caller.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 when `axi status` output $1 carries a gate block or line, in either the
# scalar (`gate: review`) or nested (`gate:` + `step:`) shape.
fm_nm_run_has_gate() {  # <toon-output>
  printf '%s\n' "$1" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}

# 0 when the run object in `axi status` output $1 is EXECUTING pipeline work
# right now: no terminal outcome, no gate waiting on an answer, and a status
# word that means the pipeline itself is busy.
#
# Deliberately narrower than "not terminal". A run parked at a gate is waiting,
# not working, and an abandoned parked run can hold that state indefinitely, so
# it must keep earning attribution the ordinary way (a head that binds to the
# crew's code). An executing run cannot be history: something is running it
# right now, on the branch it names. That is what lets callers trust an
# executing run over a stale record - a terminal run a newer executing one
# replaced, or a head the pipeline moved off the local line of history - while
# a parked or terminal run gets no such relaxation.
fm_nm_run_is_executing() {  # <toon-output>
  local out=$1 status
  [ -n "$out" ] || return 1
  [ -z "$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")" ] || return 1
  fm_nm_run_has_gate "$out" && return 1
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]*awaiting_agent:' && return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  case "$status" in
    running|fixing|ci) return 0 ;;
  esac
  return 1
}

# A compact fingerprint of the PROGRESS a run object in $1 has made: the run id,
# its status, its head, its outcome, a scalar gate name, and every steps[] row
# reduced to "<step>=<status>:<findings>".
#
# What it deliberately leaves out is the point. Elapsed values - a step's
# duration_ms, an `awaiting_agent: parked 2m10s` timer - advance on their own
# while a run is frozen, so folding them in would make any wedge look like
# progress and blind the very detection this feeds. Only fields the pipeline
# itself has to move can change this fingerprint.
#
# It is a movement detector, not a description of the run: two different runs
# never need distinguishable fingerprints beyond their differing ids, and a
# field this misses only costs one extra escalation cycle, never a false absorb.
fm_nm_run_progress_fingerprint() {  # <toon-output>
  local out=$1 key
  [ -n "$out" ] || return 1
  for key in id status head outcome gate; do
    printf '%s=%s\n' "$key" "$(fm_nm_strip_quotes "$(fm_nm_field "$out" "$key")")"
  done
  printf '%s\n' "$out" | sed -n \
    's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_-]*\),[[:space:]]*"\{0,1\}\([A-Za-z_][A-Za-z0-9_-]*\)"\{0,1\},[[:space:]]*\([0-9][0-9]*\),.*$/step:\1=\2:\3/p'
}
