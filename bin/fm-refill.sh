#!/usr/bin/env bash
# fm-refill.sh - refill evidence for the watcher's heartbeat wake.
#
# Prints exactly one line on success and nothing otherwise:
#   refill: ready=<n> live=<m> ids=<id,id,...>
# <n> is how many queued backlog items the configured backlog backend reports as
# dispatchable right now (unblocked and unheld - `tasks-axi ready`), <m> is how
# many ship and scout tasks still have a live recorded endpoint, and <ids> lists
# up to FM_REFILL_IDS_MAX of those ready ids in the backend's own order. <ids> is
# empty when nothing is ready, and <n> stays authoritative for how much work
# exists beyond the listed ids.
#
# Why it exists: a bare `heartbeat` wake carries no evidence about fleet
# capacity, so refilling a fleet that drained while nobody was watching depends
# on the supervisor deciding to go look. Carrying the evidence on the wake makes
# acting on it part of the ordinary wake-handling contract (AGENTS.md section 8,
# heartbeat wake) instead of a judgment call. The numbers are a wake-time
# observation, exactly like every other wake payload, never current state.
#
# FAIL OPEN, ALWAYS. Every failure prints nothing and exits 0: a `manual`
# backlog backend, a missing or incompatible tasks-axi, an unreadable backlog, a
# probe that outruns FM_REFILL_TIMEOUT, or any unexpected error. The caller then
# emits its heartbeat exactly as it would have without this script, so the probe
# can never delay, suppress, or break a heartbeat.
#
# Usage: fm-refill.sh <state-dir> <config-dir> <backlog-file>
#        fm-refill.sh --actionable <refill-line>
# Env:   FM_REFILL_TIMEOUT (default 10) hard bound on the WHOLE probe, backlog
#                                       read and endpoint probes together
#        FM_REFILL_IDS_MAX (default 8)  how many ready ids the line carries
#        FM_REFILL_MIN_LIVE (default 1) live capacity below which ready work is
#                                       actionable
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

refill_line_is_actionable() {
  local line=$1 min=${FM_REFILL_MIN_LIVE:-1} rest ready live ids
  case "$min" in ''|*[!0-9]*) min=1 ;; esac
  case "$line" in
    'refill: ready='*' live='*' ids='*) ;;
    *) return 1 ;;
  esac
  rest=${line#refill: ready=}
  ready=${rest%% live=*}
  rest=${rest#* live=}
  live=${rest%% ids=*}
  ids=${rest#* ids=}
  case "$ready" in ''|*[!0-9]*) return 1 ;; esac
  case "$live" in ''|*[!0-9]*) return 1 ;; esac
  case "$ids" in *[!A-Za-z0-9._,-]*) return 1 ;; esac
  [ "$ready" -gt 0 ] && [ "$live" -lt "$min" ]
}

if [ "${1:-}" = --actionable ]; then
  refill_line_is_actionable "${2:-}"
  exit "$?"
fi

STATE_DIR=${1:-}
CONFIG_DIR=${2:-}
BACKLOG=${3:-}
[ -n "$STATE_DIR" ] && [ -n "$CONFIG_DIR" ] && [ -n "$BACKLOG" ] || exit 0

REFILL_TIMEOUT=${FM_REFILL_TIMEOUT:-10}
case "$REFILL_TIMEOUT" in ''|0|*[!0-9]*) REFILL_TIMEOUT=10 ;; esac
IDS_MAX=${FM_REFILL_IDS_MAX:-8}
case "$IDS_MAX" in ''|*[!0-9]*) IDS_MAX=8 ;; esac

# --- parent: bound the probe, then own the printed format -------------------
#
# The computation runs as a child under a hard time bound, and reports raw
# fields ("<ready>\t<live>\t<ids>") rather than the finished line. The parent
# validates every field before formatting, so neither a truncated child (killed
# at the bound mid-write) nor a hostile backlog id can shape what the caller
# appends to a wake payload.
if [ "${FM_REFILL_CHILD:-0}" != 1 ]; then
  run_bounded() {
    if command -v timeout >/dev/null 2>&1; then
      FM_REFILL_CHILD=1 timeout --kill-after=1 "$REFILL_TIMEOUT" bash "$0" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
      FM_REFILL_CHILD=1 gtimeout --kill-after=1 "$REFILL_TIMEOUT" bash "$0" "$@"
    else
      # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
      FM_REFILL_CHILD=1 perl -MPOSIX=:sys_wait_h -e 'my $t = shift; my $pid = fork; exit 0 unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 } local $SIG{ALRM} = sub { my $reaped = 0; kill "TERM", -$pid; for (1..10) { if (!$reaped) { my $done = waitpid $pid, WNOHANG; $reaped = 1 if $done == $pid || $done == -1 } select undef, undef, undef, 0.1 } kill "KILL", -$pid; waitpid $pid, 0 unless $reaped; exit 124 }; alarm $t; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
        "$REFILL_TIMEOUT" bash "$0" "$@"
    fi
  }

  RAW=$(run_bounded "$@" 2>/dev/null) || exit 0
  TAB=$(printf '\t')
  case "$RAW" in
    *"$TAB"*"$TAB"*) ;;
    *) exit 0 ;;
  esac
  READY=${RAW%%"$TAB"*}
  REST=${RAW#*"$TAB"}
  LIVE=${REST%%"$TAB"*}
  IDS=${REST#*"$TAB"}
  case "$IDS" in *"$TAB"*) exit 0 ;; esac
  case "$READY" in ''|*[!0-9]*) exit 0 ;; esac
  case "$LIVE" in ''|*[!0-9]*) exit 0 ;; esac
  case "$IDS" in *[!A-Za-z0-9._,-]*) exit 0 ;; esac
  printf 'refill: ready=%s live=%s ids=%s\n' "$READY" "$LIVE" "$IDS"
  exit 0
fi

# --- child: compute the raw fields ------------------------------------------

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# The configured backlog backend decides whether this home can answer at all: a
# `manual` backend or an incompatible tasks-axi is a silent no-answer, never a
# guess from hand-parsed Markdown.
fm_tasks_axi_backend_available "$CONFIG_DIR" || exit 0
[ -f "$BACKLOG" ] || exit 0

READY_OUT=$(tasks-axi ready --file "$BACKLOG" 2>/dev/null) || exit 0

# `tasks-axi ready` prints a `ready[<n>]{...}:` header followed by one indented
# record per dispatchable item, and a plain `ready: 0 ...` line when nothing is
# dispatchable. Read the count from the header and the id from each record's
# first field; ignore anything that is not a plain id so a crafted backlog
# cannot inject payload text.
READY_FIELDS=$(printf '%s\n' "$READY_OUT" | awk -v max="$IDS_MAX" '
  /^count: [0-9]+$/ {
    count_headers++
    reported = $0
    sub(/^count: /, "", reported)
    next
  }
  /^ready\[[0-9]+\]\{id,state,kind,repo,title\}:$/ {
    ready_headers++
    header = $0
    sub(/^ready\[/, "", header)
    sub(/\].*$/, "", header)
    count = header
    collecting = 1
    next
  }
  /^ready: 0 unblocked queued tasks$/ {
    empty_headers++
    count = 0
    collecting = 0
    next
  }
  collecting && /^[[:space:]]/ {
    item = $0
    sub(/^[[:space:]]+/, "", item)
    sub(/,.*$/, "", item)
    if (item !~ /^[A-Za-z0-9._-]+$/) {
      invalid = 1
      next
    }
    items++
    if (listed < max) {
      ids = (listed == 0) ? item : ids "," item
      listed++
    }
    next
  }
  collecting { collecting = 0 }
  END {
    if (invalid || count_headers != 1 || reported !~ /^[0-9]+$/ ||
        ready_headers + empty_headers != 1 || reported != count ||
        (count == 0 && empty_headers != 1) ||
        (count > 0 && (ready_headers != 1 || items != count))) exit 1
    printf "%s\t%s\n", count, ids
  }
') || exit 0

CHILD_TAB=$(printf '\t')
READY_COUNT=${READY_FIELDS%%"$CHILD_TAB"*}
READY_IDS=${READY_FIELDS#*"$CHILD_TAB"}
case "$READY_COUNT" in ''|*[!0-9]*) exit 0 ;; esac

# Live capacity uses the same cheap endpoint read as the session-start fleet
# digest (fm_backend_target_exists), so there is exactly one liveness reader.
# Only ship and scout tasks are capacity: a persistent secondmate is idle by
# design and its quiet endpoint is not a free seat.
LIVE=0
for meta in "$STATE_DIR"/*.meta; do
  [ -f "$meta" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in ship|scout) ;; *) continue ;; esac
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || continue
  id=$(basename "$meta" .meta)
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$(fm_backend_of_meta "$meta")" "${target:-$window}" "fm-$id" || continue
  LIVE=$((LIVE + 1))
done

printf '%s\t%s\t%s\n' "$READY_COUNT" "$LIVE" "$READY_IDS"
exit 0
