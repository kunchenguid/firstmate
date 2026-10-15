#!/usr/bin/env bash
# fm-unpushed-work.sh - report commits that exist on exactly one disk.
#
# Usage: fm-unpushed-work.sh [--host <ssh-host>] [--glob <pattern>] [--snap <file>]
#
# Scans every git worktree matching a glob (default "~/.treehouse/*/*/*") on this
# machine, or on <ssh-host> with --host, and prints ONE report only when some
# worktree holds commits reachable from no remote ref.
# It is the shared engine for the private state/*.check.sh shims; those own
# cadence and wake delivery, this owns detection.
# state/done-but-not-landed.check.sh stays separate on purpose: it answers a
# different question (a lane reported done and has no pull request) from this
# home's records, while this answers "is any commit on one disk only" for any
# worktree, wherever it is, without needing a record.
#
# THE TEST: `git log HEAD --not --glob=refs/remotes/*`. Never compare against
# @{u}: a branch that was never pushed has no upstream and reads as clean.
#
# Transport failure is not an all-clear. The scan ends by printing a sentinel,
# and output without it (ssh failed, timed out, or the scan died early) is
# treated as "unknown": nothing on stdout, a diagnostic on stderr, exit 3.
# The sentinel is what separates "ssh failed" from "the last slot checked was
# clean"; a loop's own exit status cannot, because it is the status of its last
# comparison.
#
# Dedupe: --snap records the worktree+branch keys already reported. Only keys
# not in it are printed, and commit counts are not part of the key, so a worker
# committing as it goes does not re-raise the same branch. A key that clears
# leaves the snapshot, so the same branch going unpushed again reports again.
# A transport failure leaves the snapshot untouched.
#
# This script never pushes, fetches, cleans, or changes any worktree.
#
# Exit: 0 scan completed (stdout empty when nothing is new), 3 scan unknown.
# Env: FM_UNPUSHED_SSH overrides the ssh command (default ssh);
# FM_UNPUSHED_TIMEOUT bounds a scan in seconds (default 150).
set -uo pipefail

HOST=""
# shellcheck disable=SC2088 # the scanned machine expands the leading tilde
GLOB='~/.treehouse/*/*/*'
SNAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=${2:-}; shift 2 ;;
    --glob) GLOB=${2:-}; shift 2 ;;
    --snap) SNAP=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fm-unpushed-work: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$GLOB" ] || { echo "fm-unpushed-work: empty --glob" >&2; exit 2; }

SENTINEL="FM_UNPUSHED_SCAN_COMPLETE"

# The scan body runs under bash on the scanned machine, the glob arriving as $1.
# One line per hit: path<TAB>branch<TAB>count. A worktree git cannot read is a
# hit with count "?", never skipped: it may hold the only copy.
scan_body() {
  cat <<'BODY'
shopt -s nullglob
g=$1
case "$g" in "~"/*) g="$HOME/${g#\~/}" ;; esac
for w in $g; do
  [ -e "$w/.git" ] || continue
  if ! b=$(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null) ||
     ! l=$(git -C "$w" log --oneline HEAD --not --glob='refs/remotes/*' 2>/dev/null); then
    printf '%s\t%s\t%s\n' "$w" "(unreadable)" "?"; continue
  fi
  [ "$b" = HEAD ] && b="(detached)"
  n=$(printf '%s' "$l" | grep -c .)
  if [ "$n" -gt 0 ]; then printf '%s\t%s\t%s\n' "$w" "$b" "$n"; fi
done
echo FM_UNPUSHED_SCAN_COMPLETE
BODY
}

TMO=${FM_UNPUSHED_TIMEOUT:-150}
if [ -n "$HOST" ]; then
  # shellcheck disable=SC2086 # FM_UNPUSHED_SSH is a command word list
  OUT=$(scan_body | timeout "$TMO" ${FM_UNPUSHED_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=15 "$HOST" bash -s -- "$(printf '%q' "$GLOB")" 2>/dev/null)
else
  OUT=$(scan_body | timeout "$TMO" bash -s -- "$GLOB" 2>/dev/null)
fi

if ! printf '%s\n' "$OUT" | grep -qxF "$SENTINEL"; then
  echo "fm-unpushed-work: scan of ${HOST:-this machine} did not complete; unpushed state unknown" >&2
  exit 3
fi

HITS=$(printf '%s\n' "$OUT" | grep -vxF "$SENTINEL" | grep -v '^$' || true)
WHERE=${HOST:-this machine}

# Keys are path+branch; counts are display only.
KEYS=$(printf '%s\n' "$HITS" | awk -F'\t' 'NF>=3{print $1 " " $2}' | sort)
NEW=""
if [ -n "$KEYS" ]; then
  if [ -n "$SNAP" ] && [ -s "$SNAP" ]; then
    NEW=$(printf '%s\n' "$KEYS" | grep -vxFf "$SNAP" 2>/dev/null || true)
  else
    NEW=$KEYS
  fi
fi
if [ -n "$SNAP" ]; then
  printf '%s\n' "$KEYS" | sed '/^$/d' > "$SNAP.tmp.$$" 2>/dev/null && mv -f "$SNAP.tmp.$$" "$SNAP" 2>/dev/null
fi
[ -n "$NEW" ] || exit 0

LIST=$(printf '%s\n' "$HITS" | awk -F'\t' -v new="$NEW" '
  BEGIN { n = split(new, a, "\n"); for (i = 1; i <= n; i++) isnew[a[i]] = 1 }
  NF>=3 && ($1 " " $2) in isnew && $3 == "?" { printf "\n  %s: git cannot read it, so it may hold unpushed commits", $1; next }
  NF>=3 && ($1 " " $2) in isnew { printf "\n  %s on %s (%s commit(s))", $2, $1, $3 }')
echo "Work on ${WHERE} exists on that one disk and on no remote:${LIST}
Nothing has been pushed. Do NOT clean, reset, or reuse these worktrees or slots first, because that destroys the only copy. Have the owning worker push the branch; deciding to push someone else's branch is not this monitor's call."
exit 0
