#!/usr/bin/env bash
# fm-reap-strays.sh - clean up hung stub processes left behind by a test run.
#
# Usage:
#   tests/fm-reap-strays.sh snapshot            print the strays alive right now
#   tests/fm-reap-strays.sh reap <snapshot>     kill only strays NOT in <snapshot>
#   tests/fm-reap-strays.sh count               print how many strays are alive
#   tests/fm-reap-strays.sh tmpdirs             count stale test temp dirs
#   tests/fm-reap-strays.sh reap-tmpdirs [mins] remove test temp dirs older than
#                                               <mins> (default 60)
#
# "tmpdirs" covers both shapes of temp debris: the mktemp directories the suites
# create, and the cleanup-registry files tests/lib.sh writes alongside them.
#
# WHY THIS EXISTS
#
# The boot gates stub their helpers with `sleep 999` so a wedged helper can be
# observed. The emitter kills those as a process group, and gate m4 asserts it
# leaks none - but that assertion, and any cleanup, only ever ran on the HAPPY
# PATH. A run that failed an earlier assertion exited through `fail` and left
# whatever it had spawned behind. Repeated failing runs are exactly when strays
# accumulate, and they are the runs least likely to clean up after themselves.
#
# That mattered here: 194 orphaned `sleep 999` processes once accumulated across
# an afternoon of gate runs and carried the machine's load average to 186, which
# then slowed the very boots the budget gate was timing. The gate was measuring
# its own debris. It was cleaned up at the time with an ad-hoc `ps | awk | kill`
# pipeline typed at a prompt - which worked, but nobody could review it, and a
# process-killing command that nobody reviews is not something to leave lying
# around in a repository's history as the answer.
#
# SAFETY - this kills processes, so it is deliberately narrow
#
# A stray must satisfy ALL of:
#   1. its FULL argv is exactly `sleep 999` - the stub's signature, not a
#      substring match that could catch an unrelated sleep
#   2. it is owned by the user running this script
#   3. its parent is init (pid 1), i.e. it is genuinely orphaned rather than a
#      live child of some running program
#   4. `reap` additionally requires that it was NOT in the snapshot taken before
#      the run - so it is provably this run's debris, never anything that was
#      already running
#
# Condition 4 is what makes this safe to wire into a trap. Without it the script
# would be guessing; with it, it only ever removes processes it watched appear.
set -u

# The stub signature. Exact-argv match, anchored at both ends.
STRAY_ARGV='sleep 999'

usage() {
  echo "usage: $(basename "$0") snapshot | count | reap <snapshot-file>" >&2
  echo "       $(basename "$0") tmpdirs | reap-tmpdirs [older-than-minutes]" >&2
  exit 2
}

# Stale temp dirs are the other half of the debris. tests/lib.sh registered them
# inside a command-substitution subshell, so nothing was ever removed and 2,308
# had accumulated before the registration was repaired. The repair stops new
# ones; this clears the backlog.
#
# Narrow, again: only directories DIRECTLY under TMPDIR, only ones whose name
# matches the mktemp template these suites use (fm-<something>.XXXXXX), only
# ones owned by the invoking user, and only ones older than the age guard - so
# a suite running right now, here or in another worktree, is never disturbed.
list_tmpdirs() {
  local mins=${1:-60} tmp=${TMPDIR:-/tmp}
  find "$tmp" -maxdepth 1 -type d -user "$(id -u)" \
    -name 'fm-*.??????' -mmin "+$mins" -print 2>/dev/null
}

# The other half of the same leak, and the reason it survived the repair above.
# tests/lib.sh records its registered dirs in a REGULAR FILE,
# $TMPDIR/fm-test-cleanup.<pid>, and only fm_test_cleanup unlinks it. Thirteen
# suites install their own EXIT trap, which replaces the source-time one, so
# each of those runs leaves its registry behind - and list_tmpdirs cannot see
# it, because it matches directories on the mktemp template. Same shape, same
# unbounded accumulation, so it gets the same narrow treatment: directly under
# TMPDIR, exact name shape, owned by the invoking user, older than the age
# guard, so a suite running right now is never disturbed.
list_registries() {
  local mins=${1:-60} tmp=${TMPDIR:-/tmp}
  find "$tmp" -maxdepth 1 -type f -user "$(id -u)" \
    -name 'fm-test-cleanup.*' -mmin "+$mins" -print 2>/dev/null
}

# Both shapes, one listing: every caller wants the whole sweep, and splitting
# them would just be a second place to forget one.
list_stale() {
  list_tmpdirs "${1:-60}"
  list_registries "${1:-60}"
}

# Print "pid" per line for every process that looks like our stub and is
# orphaned. ps, not pgrep: pgrep -x matches the process NAME only (every sleep
# looks alike) and pgrep -f substring-matches, which would also match this
# script's own command line.
list_strays() {
  local me
  me=$(id -un)
  # shellcheck disable=SC2009
  ps -eo user=,ppid=,pid=,args= 2>/dev/null | awk -v me="$me" -v want="$STRAY_ARGV" '
    {
      user = $1; ppid = $2; pid = $3
      argv = ""
      for (i = 4; i <= NF; i++) argv = argv (i > 4 ? " " : "") $i
      if (user == me && ppid == 1 && argv == want) print pid
    }'
}

case "${1:-}" in
  snapshot)
    list_strays
    ;;
  count)
    list_strays | wc -l | tr -d ' '
    ;;
  reap)
    [ $# -eq 2 ] || usage
    before=$2
    # -r not -f: an empty snapshot may legitimately be /dev/null, which is a
    # character device rather than a regular file.
    [ -r "$before" ] || { echo "error: cannot read snapshot at $before" >&2; exit 2; }
    killed=0
    while read -r pid; do
      [ -n "$pid" ] || continue
      # Never touch anything that was already alive before the run.
      if grep -qx -- "$pid" "$before" 2>/dev/null; then
        continue
      fi
      if kill -9 "$pid" 2>/dev/null; then
        killed=$((killed + 1))
      fi
    done <<EOF
$(list_strays)
EOF
    if [ "$killed" -gt 0 ]; then
      echo "reaped $killed stray '$STRAY_ARGV' process(es) left by this run" >&2
    fi
    ;;
  tmpdirs)
    list_stale "${2:-60}" | wc -l | tr -d ' '
    ;;
  reap-tmpdirs)
    mins=${2:-60}
    removed=0
    while read -r d; do
      [ -n "$d" ] || continue
      rm -rf "$d" && removed=$((removed + 1))
    done <<EOF
$(list_stale "$mins")
EOF
    echo "removed $removed stale test temp path(s) older than ${mins}m" >&2
    ;;
  *)
    usage
    ;;
esac
