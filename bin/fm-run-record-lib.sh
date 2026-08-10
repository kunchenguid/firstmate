#!/usr/bin/env bash
# Read the validation pipeline's own record of what it validated and pushed.
#
# The pipeline writes one row per run, at the time, about itself. That record is
# the only place the heads an intake gate needs are stated by the party that did
# the work rather than inferred by the party being checked.
#
# WHAT THE COLUMNS MEAN, ESTABLISHED RATHER THAN ASSUMED
# Measured across all 116 runs in a live database on 2026-08-10, cross-checked
# against two pull requests whose heads were verified independently in git:
#   submitted_head_sha  the head the worker submitted when the run started.
#                       Never rewritten.
#   head_sha            the pipeline's LIVE head. It advances with the run's own
#                       fix commits, and at push time it is overwritten with the
#                       pushed head: 68 of 68 pushed runs have
#                       head_sha == last_pushed_sha, with no exceptions.
#   last_pushed_sha     the pushed, post-rebase head. Empty until a push.
#
# SO THE VALIDATED HEAD IS DESTROYED AT PUSH, AND MUST BE CAPTURED BEFORE IT
# `submitted_head_sha` is NOT the validated side, however much the name suggests
# it: it predates the run's own fix commits, so an accepted fix that rewrites a
# line the branch added reads as that line having been dropped. Measured on a
# real run whose review fix legitimately rewrote those lines, that comparison
# refuses 6 paths, and 62 of 69 pushed runs have submitted differing from
# pushed - so it would refuse the common case, not an edge. See
# docs/verification/rebase-equivalence.md.
#
# The validated head is therefore SNAPSHOT while it still exists: the watcher
# records the last head_sha seen while a run had not yet pushed, keyed by run
# id, with the time it was observed. A tail rather than a trigger, because poll
# timing cannot reliably catch an exact phase boundary. A run with no snapshot
# is could-not-observe and arms nothing; snapshots are never back-filled, since
# a fabricated record is indistinguishable from a real one afterwards.
#
# Every read is read-only (`mode=ro`, deliberately without `immutable=1`, since
# the pipeline writes this file concurrently). A missing reader, a missing
# database, or an unresolvable request identity is could-not-observe, never an
# absent run.
#
# Usage (sourced):
#   fm_run_record_for_pr <pr-url>       -> "run=<id> pushed=<sha>"
#   fm_run_snapshot_tick <state-dir>    -> refresh snapshots for unpushed runs
#   fm_run_snapshot_read <state-dir> <run-id> -> "head=<sha> observed_at=<epoch>"
#   fm_run_record_gate_remote <repo-dir>
# Status: 0 found, 1 nothing recorded, 2 could-not-observe.

FM_RUN_RECORD_DB=${FM_RUN_RECORD_DB:-$HOME/.no-mistakes/state.sqlite}

# Requests are matched on forge identity, never on the URL's exact spelling. A
# trailing slash, a www prefix, or a .git suffix would otherwise silently turn
# the gate off, and a silently disabled gate is worse than a crash because
# nothing distinguishes it from "this request had no pipeline run".
_fm_run_record_py() {
  cat <<'PY'
import re, sys

def db_uri(path):
    # sqlite3 takes a URI here, so the path must be percent-encoded. An
    # unescaped '?', '#' or space silently reparses into a different - and
    # unreadable - database, which would refuse every read on this machine.
    from urllib.parse import quote
    return 'file:%s?mode=ro' % quote(path)


def identity(url):
    if not url:
        return None
    u = url.strip().rstrip('/')
    m = re.match(r'^https?://([^/]+)/(.+?)/(?:pull|-/merge_requests|merge_requests)/(\d+)$', u)
    if not m:
        return None
    host, path, number = m.group(1).lower(), m.group(2), m.group(3)
    if host.startswith('www.'):
        host = host[4:]
    if path.endswith('.git'):
        path = path[:-4]
    return (host, path, number)
PY
}

# Print "run=<id> pushed=<sha>" for a pull request, newest run first.
fm_run_record_for_pr() {  # <pr-url>
  local url=$1 out rc
  [ -n "$url" ] || return 2
  # No pipeline state file at all means no pipeline run has ever existed here,
  # which is genuinely "nothing recorded" rather than a failure to observe. A
  # database that IS present but cannot be read is could-not-observe, because
  # then a run may well exist and this cannot tell.
  [ -f "$FM_RUN_RECORD_DB" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 2
  out=$(FM_RR_DB="$FM_RUN_RECORD_DB" FM_RR_URL="$url" python3 -c "
$(_fm_run_record_py)
import os, sqlite3
target = identity(os.environ['FM_RR_URL'])
if target is None:
    sys.exit(2)   # unresolvable request identity is never 'no record'
try:
    con = sqlite3.connect(db_uri(os.environ['FM_RR_DB']), uri=True)
    rows = con.execute(\"SELECT id, pr_url, last_pushed_sha FROM runs \"
                       \"WHERE pr_url IS NOT NULL AND pr_url <> '' \"
                       \"ORDER BY created_at DESC\").fetchall()
except Exception:
    sys.exit(2)
# Keep scanning past a matching run that has not pushed. Stopping at the first
# match would report 'nothing recorded' whenever a RE-RUN is in flight for the
# same request, so a request that genuinely was produced by a pipeline push
# would be treated as one that never had a run at all.
for run_id, pr_url, pushed in rows:
    if identity(pr_url) == target and pushed:
        print('run=%s pushed=%s' % (run_id, pushed))
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# Watcher tail: refresh the recorded head of every run that has NOT pushed yet.
# Once a run pushes it stops being selected, so the file retains the last head
# seen while the validated content still existed. Best effort by design - a
# missed snapshot must surface later as could-not-observe, never be invented.
fm_run_snapshot_tick() {  # <state-dir>
  local state=$1 dir now window run head tmp
  [ -n "$state" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$FM_RUN_RECORD_DB" ] || return 0
  dir="$state/run-snapshot"
  mkdir -p "$dir" 2>/dev/null || return 0
  now=$(date +%s 2>/dev/null) || return 0
  window=$(( now - ${FM_RUN_SNAPSHOT_WINDOW:-172800} ))
  [ "$window" -ge 0 ] || window=0
  FM_RR_DB="$FM_RUN_RECORD_DB" FM_RR_WINDOW="$window" python3 -c "
$(_fm_run_record_py)
import os, sqlite3
try:
    con = sqlite3.connect(db_uri(os.environ['FM_RR_DB']), uri=True)
    # Bounded to runs touched recently. Every never-pushed run ever recorded
    # otherwise qualifies forever - 48 of 116 in a real database - and each
    # would be rewritten on every watcher cycle.
    cutoff = int(os.environ.get('FM_RR_WINDOW', '0'))
    rows = con.execute(\"SELECT id, head_sha FROM runs \"
                       \"WHERE (last_pushed_sha IS NULL OR last_pushed_sha = '') \"
                       \"AND head_sha IS NOT NULL AND head_sha <> '' \"
                       \"AND COALESCE(updated_at, created_at, 0) >= ?\",
                       (cutoff,)).fetchall()
except Exception:
    sys.exit(0)
for run_id, head in rows:
    if run_id and head:
        print('%s %s' % (run_id, head))
" 2>/dev/null | while read -r run head; do
    case "$run" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    case "$head" in ''|*[!0-9a-fA-F]*) continue ;; esac
    # An unchanged head needs no write: rewriting every tracked run on every
    # cycle is pure churn in a directory nothing prunes.
    [ "$(sed -n 's/^head=//p' "$dir/$run" 2>/dev/null | head -1)" = "$head" ] && continue
    tmp="$dir/.$run.tmp.$$"
    {
      printf 'run=%s\n' "$run"
      printf 'head=%s\n' "$head"
      printf 'observed_at=%s\n' "$now"
      printf 'pushed=no\n'
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$run" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
  done
  return 0
}

# Read one run's snapshot. Absent is 1, unreadable or malformed is 2, so a
# missing snapshot is never confused with a corrupt one.
fm_run_snapshot_read() {  # <state-dir> <run-id>
  local state=$1 run=$2 f head observed
  [ -n "$state" ] && [ -n "$run" ] || return 2
  case "$run" in *[!A-Za-z0-9._-]*) return 2 ;; esac
  f="$state/run-snapshot/$run"
  [ -e "$f" ] || return 1
  [ -f "$f" ] && [ ! -L "$f" ] || return 2
  head=$(sed -n 's/^head=//p' "$f" 2>/dev/null | head -1)
  observed=$(sed -n 's/^observed_at=//p' "$f" 2>/dev/null | head -1)
  case "$head" in ''|*[!0-9a-fA-F]*) return 2 ;; esac
  case "$observed" in ''|*[!0-9]*) return 2 ;; esac
  printf 'head=%s observed_at=%s\n' "$head" "$observed"
}

# The pipeline's gate repository for this checkout, where the snapshot head's
# objects are authoritative. An ordinary git remote, so it can be fetched.
fm_run_record_gate_remote() {  # <repo-dir>
  local url
  url=$(git -C "$1" remote get-url no-mistakes 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}
