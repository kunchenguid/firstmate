#!/usr/bin/env bash
# Read the validation pipeline's own record of what it validated and pushed.
#
# The pipeline writes one row per run, at the time, about itself. That record is
# the only place the two heads an intake gate needs are stated by the party that
# actually did the work, rather than inferred by the party being checked.
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
#   last_pushed_sha     the pushed, post-rebase head. Empty until a push happens.
#
# THE CONSEQUENCE, WHICH BOUNDS WHAT AN INTAKE GATE CAN PROVE
# Because head_sha is overwritten at push time, the pre-rebase head that carried
# the run's own fix commits is NOT retained anywhere once the push completes.
# The comparison available after the fact is therefore
# submitted_head_sha -> last_pushed_sha. That covers every change the branch
# already carried when the run began, which includes both measured incidents. It
# cannot see content that a run's OWN fix commits created and that the same run's
# rebase then dropped, because no surviving column names that intermediate head.
# Say so rather than implying more: a bounded guarantee that is stated is worth
# more than an unbounded one that is assumed.
#
# Every read is read-only (`mode=ro`, deliberately without `immutable=1`, since
# the pipeline writes this file concurrently). A missing reader, a missing
# database, or an unreadable row is reported as could-not-observe, never as an
# absent run.
#
# Usage (sourced):
#   fm_run_record_for_pr <pr-url>   -> prints "submitted=<sha> pushed=<sha>"
# Status: 0 found, 1 no run recorded for that request, 2 could-not-observe.

FM_RUN_RECORD_DB=${FM_RUN_RECORD_DB:-$HOME/.no-mistakes/state.sqlite}

# Print the run's two heads for a pull request URL, newest run first.
fm_run_record_for_pr() {  # <pr-url>
  local url=$1 out
  [ -n "$url" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  [ -f "$FM_RUN_RECORD_DB" ] || return 2
  out=$(FM_RR_DB="$FM_RUN_RECORD_DB" FM_RR_URL="$url" python3 - <<'PY' 2>/dev/null
import os, sqlite3, sys
db, url = os.environ["FM_RR_DB"], os.environ["FM_RR_URL"]
try:
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    rows = con.execute(
        "SELECT submitted_head_sha, last_pushed_sha FROM runs "
        "WHERE pr_url = ? ORDER BY created_at DESC", (url,)).fetchall()
except Exception:
    sys.exit(2)
if not rows:
    sys.exit(1)
submitted, pushed = rows[0]
if not submitted or not pushed:
    # A recorded run that never completed a push has nothing to compare.
    sys.exit(1)
print("submitted=%s pushed=%s" % (submitted, pushed))
PY
  ) || return $?
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# Resolve the pipeline's gate repository for this checkout, which is where the
# submitted head's objects are authoritative. It is an ordinary git remote, so
# the head can be fetched rather than assumed present.
fm_run_record_gate_remote() {  # <repo-dir>
  local url
  url=$(git -C "$1" remote get-url no-mistakes 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}
