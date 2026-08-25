#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting), fm-teardown.sh (pre-teardown run abort,
# see its "Fix 1" header comment), and fm-classify-lib.sh's run-activity probe.
# Getting this wrong in either direction is unsafe: a false negative hides a
# genuinely parked run, and a false positive lets teardown act on a run it does
# not own.
#
# The rule is split into three pieces so each is separately testable and neither
# caller re-derives it: fm_nm_head_identity says where the run's head sits
# relative to local HEAD, fm_nm_status_is_terminal says whether the run has
# concluded, and fm_nm_run_attributable is the policy that combines them.
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

# Where a run's recorded head sits relative to worktree $1's HEAD. Prints exactly
# one token, and never fails: "I cannot tell" is itself a verdict the attribution
# policy below is entitled to weigh, and collapsing it into a plain rejection is
# what produced the 2026-08-23 false-failure incident.
#   same         - the same commit.
#   ahead        - the run head descends from local HEAD: the pipeline committed
#                  fix rounds onto the branch it owns and advanced past the crew.
#   behind       - the run head is a strict ancestor of local HEAD: local work
#                  moved on from the code this run recorded.
#   unrelated    - both commits resolve here and neither descends from the other:
#                  a rewritten or diverged tip.
#   unverifiable - a head IS recorded, but it is not an object in this worktree at
#                  all, so it can be placed neither on our history nor off it.
#   absent       - no head was recorded, or this worktree's own HEAD is unreadable:
#                  nothing to compare, and only the branch name would be left.
#
# unverifiable and absent are deliberately distinct, because they carry different
# amounts of information and the policy below treats them differently. An absent
# head says nothing at all. An unverifiable head names a specific commit this
# worktree simply does not have, which is the ROUTINE state of a healthy run:
# while no-mistakes holds custody of the branch it commits fix rounds in its own
# gate clone, so a live run's head is regularly absent from the crew's object
# store. Verified 2026-08-23 against the installed v1.53.0 during a live fix
# round - `axi status` reported branch fm/hm-vault-scripts-k2, status running,
# head 1f645c15, while `git rev-parse --verify 1f645c15^{commit}` in that crew's
# own worktree failed with "Needed a single revision"; when that run later
# concluded and custody returned, the worktree HEAD became exactly 9f632958, the
# head the finished run reported.
fm_nm_head_identity() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || { printf 'absent'; return 0; }
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'absent'; return 0; }
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) \
    || { printf 'unverifiable'; return 0; }
  if [ "$run_full" = "$local_full" ]; then printf 'same'; return 0; fi
  if git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'ahead'; return 0
  fi
  if git -C "$wt" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null; then
    printf 'behind'; return 0
  fi
  printf 'unrelated'
}

# 0 when an `axi status` run object has reached a terminal result: any recorded
# outcome at all, else a terminal status word. Every other status - running,
# fixing, ci, awaiting_approval, fix_review, or none recorded yet - is a run still
# under way. Callers that only have the coarse `no-mistakes runs` status word pass
# it as $1 with an empty $2.
fm_nm_status_is_terminal() {  # <status> <outcome>
  [ -z "${2:-}" ] || return 0
  case "${1:-}" in completed|failed|cancelled) return 0 ;; esac
  return 1
}

# 0 when a run with recorded head $2 may be attributed to worktree $1. $3 is the
# run's phase, `active` or `terminal` (fm_nm_status_is_terminal decides it).
#
#   identity      active run   terminal run
#   same          attribute    attribute
#   ahead         attribute    attribute
#   behind        reject       reject
#   unrelated     reject       reject
#   unverifiable  ATTRIBUTE    reject
#   absent        reject       reject
#
# Only the unverifiable/active cell differs from the rule this file shipped
# before; every other cell is unchanged, and each rejection keeps the incident it
# was written for. `behind` stays rejected in both phases because a crew that
# committed past its run's head has moved on to work that run never saw, so
# reporting that run's state - parked or terminal - misreads the crew. `absent`
# stays rejected because a run with no head at all leaves nothing but the branch
# name to match on, which is exactly the branch-reuse misattribution this check
# exists to prevent.
#
# The one changed cell is asymmetric by phase because the two ways of being wrong
# cost very different things. Attributing an ACTIVE run that is not ours reports
# the crew as still working: firstmate keeps waiting, and the crew's own gate
# appends still surface a real decision through the status log. Attributing a
# TERMINAL run that is not ours reports done or failed, which invites tearing down
# live work and telling the captain about a failure that did not happen. So an
# unverifiable head - the normal condition of a run that currently holds branch
# custody - is allowed to keep a live run attributed, and is never allowed to
# produce a terminal verdict.
fm_nm_run_attributable() {  # <worktree> <run_head> <active|terminal>
  local phase=${3:-terminal}
  case "$(fm_nm_head_identity "$1" "$2")" in
    same|ahead)   return 0 ;;
    unverifiable) [ "$phase" = active ] ;;
    *)            return 1 ;;
  esac
}

# Seconds represented by a no-mistakes duration token (32s, 2m39s, 1h51m). Prints
# nothing for anything that is not one, so a caller's `[ -n ... ]` guard is the
# single test for "no usable duration here".
#
# Every component is evaluated in explicit base 10, because a zero-padded
# component is ordinary in these tokens and bash reads a zero-prefixed literal as
# OCTAL. `2m09s` and `08s` therefore aborted the whole expansion with a bash
# diagnostic on stderr and returned nothing, which reads to the caller below as
# "no usable age" - so the wedge escalation this clock exists to suppress fired
# anyway, against a run that had just reported progress. `1h05m` was the worse
# half: it parsed, and was right only by the coincidence that octal and decimal
# agree below 8. A component longer than any real duration is refused rather than
# wrapped silently around the arithmetic range, because a wrapped negative age
# would read as activity from the future and suppress a GENUINE wedge.
fm_nm_duration_secs() {  # <token>
  local t=${1:-} total=0 n unit found=0
  case "$t" in ''|*[!0-9hms]*) return 0 ;; esac
  while [ -n "$t" ]; do
    n=${t%%[hms]*}
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    [ "${#n}" -le 9 ] || return 0
    t=${t#"$n"}
    unit=${t%"${t#?}"}
    t=${t#?}
    case "$unit" in
      h) total=$(( total + 10#$n * 3600 )) ;;
      m) total=$(( total + 10#$n * 60 )) ;;
      s) total=$(( total + 10#$n )) ;;
      *) return 0 ;;
    esac
    found=1
  done
  [ "$found" = 1 ] && printf '%s' "$total"
  return 0
}

# Age in seconds of the most recent activity `axi status` output $1 reports for a
# run's own active steps, or nothing when it reports none. This is the pipeline's
# own progress clock, and it is the only liveness signal that survives a fix round:
# the run holds custody of the branch and works in its gate clone, so the crew's
# pane renders nothing and its worktree receives no writes for as long as the
# round lasts. Read only from the active_steps table - `active_for` elsewhere in
# the run object measures how long a step has been open, which is the opposite of
# evidence - and the smallest age wins when several steps are active.
#
# Shape verified 2026-08-23 against the installed v1.53.0, on four separate live
# runs. `no-mistakes axi status` emits the table as
#   active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
#     review,fixing,20m15s,"2m39s ago: log: I'll start by examining ...","1827880",fix 1
# so the age is a duration token immediately before " ago" inside the row, and
# the free text after it may itself contain commas - which is why this scans for
# the token rather than splitting the row on commas. Observed ages spanned 32s,
# 2m10s, 2m39s and 7m50s, and `active_for` values (20m15s, 58m59s, 1h51m, 2h31m)
# sit in the same row without an " ago" suffix, which is what keeps them out.
#
# last_activity is a TRUNCATED, FROZEN agent log line, so only the FIRST " ago"
# token in each row - the one that opens the cell - is read as that row's own
# age. Any later " ago"-shaped substring in the row's free text (a retry message,
# a quoted elapsed time, a pasted log fragment) is ignored: once written that
# text never changes, so treating it as evidence would let a single small
# duration inside it permanently suppress every future wedge escalation for
# that crew, which is the opposite of what this probe exists to catch.
#
# The table ends at the first line that is not one of its own data rows, decided
# by INDENTATION relative to the header: a row of this table is always indented
# deeper than the header that introduced it, so anything at or left of the header
# column - a following scalar, a sibling table, a blank line, the end of the
# object - closes it. Terminating only on a header-shaped line was not enough: a
# trailing scalar such as `updated: 3s ago` stayed inside the block and its token
# became activity evidence, and because the SMALLEST age wins one stray token
# after the table proved recent liveness for a run that had said nothing for
# forty minutes - suppressing a genuine wedge escalation, the exact failure this
# probe must never cause. A key-shaped line is still refused at any depth, so a
# nested object under the table cannot re-open the same hole.
fm_nm_last_activity_secs() {  # <toon-output>
  local block tok secs min=
  block=$(printf '%s\n' "${1:-}" | awk '
    !inblk && /active_steps\[/ {
      match($0, /^[[:space:]]*/); header_indent = RLENGTH; inblk = 1; next
    }
    inblk {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= header_indent) { inblk = 0; next }
      if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[0-9]+\])?(\{[^}]*\})?:/) { inblk = 0; next }
      print
    }
  ')
  [ -n "$block" ] || return 0
  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tok=$(printf '%s\n' "$row" | grep -oE '[0-9][0-9hms]*[[:space:]]+ago' | head -n1 | sed 's/[[:space:]]*ago$//')
    [ -n "$tok" ] || continue
    secs=$(fm_nm_duration_secs "$tok")
    [ -n "$secs" ] || continue
    if [ -z "$min" ] || [ "$secs" -lt "$min" ]; then min=$secs; fi
  done <<EOF
$block
EOF
  [ -n "$min" ] && printf '%s' "$min"
  return 0
}
