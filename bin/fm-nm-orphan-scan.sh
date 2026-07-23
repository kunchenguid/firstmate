#!/usr/bin/env bash
# Report a no-mistakes run THIS home armed that is parked with no live task left
# to answer it - an ORPHAN.
#
# no-mistakes announces a parked run three ways: the durable record (`no-mistakes
# parked`, read without the daemon), a level-triggered reminder cascade, and -
# for a run a LIVE task still owns - firstmate's own armed poll, which asks by run
# id whether this task's watch run parked (bin/fm-poll-extra.sh). The poll covers
# every park a live task owns; a crew-driven gate park is reported by the crew
# itself; a stuck worker is caught by the stale path. The one park nobody covers
# is the run whose task is GONE: a direct-PR task that was cancelled or torn down
# leaves its watch run parked, the meta that recorded its run id is deleted, and
# the reminder cascade re-sends into silence. One such run sat parked for 1d21h
# over 42 reminders with nobody woken.
#
# This scan closes that gap by OWNERSHIP, not by a push hook. It reports only the
# parked runs THIS home armed - recorded in data/nm-armed-runs by
# bin/fm-nm-watch.sh - that no live task in this home still owns. A run this home
# never armed (the captain's own no-mistakes work, or another firstmate home's
# task) is not in this home's ledger, so it is never read and never reported.
# That is the hard boundary the captain set: every scan bounds its range by this
# home's own attribution record, so one machine-wide record cannot make one home
# answer for another's work, and independent homes never step on each other.
#
# Run id, not the fm/<task-id> branch alone, is the scoping key: a torn-down
# task's meta is gone, and the fm/<id> branch shape is shared by every firstmate
# home, so branch alone cannot tell one home's orphan from another's. The ledger
# records the run ids this home armed and survives teardown, which the meta does
# not. The branch is still used, exactly as the old edge hook used it, to skip a
# run whose fm/<id> task is still live (a superseded or re-armed watch).
#
# It emits one `NM_ORPHAN:` line per orphaned run (consumed by the
# bootstrap-diagnostics skill) and exits 0. It is silent when no-mistakes or jq
# is absent, when this home has armed nothing, when the record cannot be read, or
# when nothing this home armed is orphaned. Timeliness is not a concern: an
# orphan is by definition a run nobody is waiting on, so a once-per-session-start
# scan is enough, and each session start re-reads durable state and converges.
#
# Usage: fm-nm-orphan-scan.sh
#        fm-nm-orphan-scan.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NM_BIN="${FM_NM_BIN:-no-mistakes}"
LEDGER="$DATA/nm-armed-runs"

# Longest line this emits; the finding detail beyond it lives in `no-mistakes
# parked` and the run's own log, so truncation eats the finding tail, never the
# run id or the settle command.
MAX_LINE="${FM_NM_ORPHAN_MAX_LINE:-260}"
case "$MAX_LINE" in ''|0|*[!0-9]*) MAX_LINE=260 ;; esac
# Ledger hygiene: an entry this old whose run is no longer parked is pruned; an
# entry whose run is still parked is always kept regardless of age.
LEDGER_KEEP_DAYS="${FM_NM_ORPHAN_LEDGER_DAYS:-90}"
case "$LEDGER_KEEP_DAYS" in ''|*[!0-9]*) LEDGER_KEEP_DAYS=90 ;; esac
# Line count above which the ledger is pruned; below it the file is left alone,
# so a healthy home never rewrites the ledger on a routine session start.
LEDGER_PRUNE_ABOVE="${FM_NM_ORPHAN_LEDGER_MAX:-200}"
case "$LEDGER_PRUNE_ABOVE" in ''|0|*[!0-9]*) LEDGER_PRUNE_ABOVE=200 ;; esac

usage() {
  cat <<'EOF'
Usage: fm-nm-orphan-scan.sh

Report a no-mistakes run this home armed that is parked with no live task to
answer it. Reads the machine-wide `no-mistakes parked` record and reports only
the runs recorded in this home's data/nm-armed-runs ledger (written by
bin/fm-nm-watch.sh) that no live task in this home still owns.

Emits one `NM_ORPHAN:` line per orphaned run and exits 0. Silent when no-mistakes
or jq is absent, when this home has armed nothing, when the record cannot be
read, or when nothing this home armed is orphaned.

Environment:
  FM_HOME                    firstmate home to scan (default: the repo root this
                             script lives in)
  FM_NM_ORPHAN_LEDGER_DAYS   ledger entries older than this whose run is not
                             parked are pruned (90)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "fm-nm-orphan-scan.sh: unexpected argument: $1" >&2; exit 2 ;;
esac

command -v "$NM_BIN" >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# No ledger means this home has armed no watch run, so it can own no orphan.
[ -f "$LEDGER" ] || exit 0

one_line() {  # <text> [max] -> single-line, space-collapsed, truncated
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ' | cut -c "1-${2:-$MAX_LINE}"
}

# The parked record is machine-wide and read without the daemon. Exit 0 means
# something is parked, 1 means nothing is; anything else means it could not be
# read, and a scan that cannot read the record stays silent rather than guess -
# the reminder cascade still keeps the run on record for the next session start.
json=$("$NM_BIN" parked --json 2>/dev/null)
case "$?" in
  0) ;;
  *) exit 0 ;;
esac
[ -n "$json" ] || exit 0

# 0 when some live meta in this home records <run-id> as its watch run, so the
# armed poll owns that park and this scan must stay out of it.
meta_owns_run() {  # <run-id>
  local run=$1 meta recorded
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recorded=$(grep '^nm_watch_run=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$recorded" = "$run" ] && return 0
  done
  return 1
}

# 0 when <run-id> is one this home armed (field 2 of a ledger line).
ledger_has() {  # <run-id>
  awk -v r="$1" '$2 == r { found = 1 } END { exit found ? 0 : 1 }' "$LEDGER"
}

# One tab-separated row per parked run: run, branch, step, gate, parked_for, and
# the first finding as "id - description" (bounded). @tsv keeps every field on
# one physical field even when a description carries newlines.
parked_rows=$(printf '%s' "$json" | jq -r '
  .[]? | [
    .run,
    (.branch // ""),
    (.step // ""),
    (.gate // ""),
    (.parked_for // ""),
    (if ((.findings // []) | length) > 0
     then ((.findings[0].id // "finding") + " - " + ((.findings[0].description // "") | .[0:120]))
     else "" end)
  ] | @tsv' 2>/dev/null) || exit 0

while IFS=$(printf '\t') read -r run branch step gate parked_for finding; do
  [ -n "$run" ] || continue
  # Range guard: a run this home never armed is not this home's to read, report,
  # or answer - the captain's own runs and other homes' runs both fall here.
  ledger_has "$run" || continue
  # A live task in this home owns this park through its armed poll.
  meta_owns_run "$run" && continue
  # A run whose fm/<id> task is still live (a re-armed or superseded watch) is
  # the live task's, not an orphan.
  case "$branch" in
    fm/*)
      id=${branch#fm/}
      [ -n "$id" ] && [ -f "$STATE/$id.meta" ] && continue
      ;;
  esac

  what="no-mistakes ${step:-step}/${gate:-gate} run parked"
  [ -n "$parked_for" ] && what="$what for $parked_for"
  detail=$finding
  [ -n "$detail" ] || detail="see: no-mistakes parked"
  one_line "NM_ORPHAN: $what on ${branch:-unknown branch} (run $run) - no live task in this home owns it; answer it with 'no-mistakes axi respond --run $run' or cancel the run (details: no-mistakes parked): $detail"
done <<EOF
$parked_rows
EOF

# Ledger hygiene, best effort: only when the file has grown past the cap, keep an
# entry when it is recent OR its run is still parked, so a live orphan is never
# pruned out from under the next scan. Any failure leaves the ledger untouched.
if [ "$(wc -l < "$LEDGER" 2>/dev/null || echo 0)" -gt "$LEDGER_PRUNE_ABOVE" ]; then
  now=$(date +%s 2>/dev/null || echo 0)
  cutoff=$((now - LEDGER_KEEP_DAYS * 86400))
  parked_ids=$(printf '%s' "$json" | jq -r '.[]?.run' 2>/dev/null || true)
  tmp="$LEDGER.tmp.$$"
  if [ "$now" -gt 0 ] && awk -v cutoff="$cutoff" -v parked="$parked_ids" '
      BEGIN { n = split(parked, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") P[a[i]] = 1 }
      { ts = $1 + 0; if (ts >= cutoff || ($2 in P)) print }
    ' "$LEDGER" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$LEDGER" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
fi

exit 0
