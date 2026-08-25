#!/usr/bin/env bash
# tests/fm-omp-session-lock-live-e2e.test.sh - opt-in live guard proving the
# two vendor-controlled facts bin/fm-session-lock-lib.sh's omp recognition
# depends on: that a real omp process's own comm/args report base name "omp"
# (the shape fm_harness_process_matches matches on), and that a real omp
# session's own process environment genuinely carries CLAUDECODE=1 (the
# marker the whole recognition is gated on).
#
# Why this file exists: both facts are vendor behavior that can change without
# notice - a rename, or omp dropping the compatibility marker - and the
# portable regression in tests/fm-session-lock-ancestry.test.sh only replays
# those facts through an injected fake `ps`, which cannot detect a real
# vendor change. This guard drives the real omp binary and feeds the real
# fm_harness_process_matches its actual observed comm/args, so a vendor
# change that breaks the assumption fails here first.
#
# CLAUDECODE cannot be read from a live omp process by an external observer:
# macOS `ps` does not expose another process's environment (verified: neither
# `ps -wwE` nor `ps eww` show env for a child this same test spawned), and
# there is no /proc on macOS to fall back to. The only real proof available is
# to ask omp itself, through its own bash tool, to report its own $CLAUDECODE
# - which is a genuine model turn and spends a small, bounded amount of
# tokens. That spend is explicitly sanctioned for exactly this class of check
# (firstmate-coding-guidelines, "Harness-dependent checks"): the cost is small
# against a check that silently stops working.
#
# Standard CI has no omp binary or credentials, so this guard is opt-in and
# on-demand, mirroring tests/fm-harness-liveness-drift-live-e2e.test.sh. Run
# it after any omp upgrade and before trusting refreshed evidence.
# shellcheck disable=SC2016 # single quotes are deliberate: $CLAUDECODE must expand inside omp's own bash tool, not this shell
set -u

if [ "${FM_OMP_LOCK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LOCK_LIVE_E2E=1 to run the live omp session-lock identity guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

if ! OMP_BIN=$(command -v omp 2>/dev/null); then
  echo "skip: omp is not installed on this machine, so its classification is unverified here"
  exit 0
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-omp-lock-live.XXXXXX")
cleanup_all() {
  if [ -n "${OMP_PID:-}" ] && kill -0 "$OMP_PID" 2>/dev/null; then
    kill -9 "$OMP_PID" 2>/dev/null || true
  fi
  [ -n "${OUT:-}" ] && rm -f "$OUT"
}
trap cleanup_all EXIT

version=$("$OMP_BIN" --version 2>/dev/null | head -1 | tr -d '\r') || version=
[ -n "$version" ] || version="unknown"

# A real, non-interactive omp turn that uses its own bash tool to report its
# own environment, then holds briefly so `ps` can observe it mid-run. No
# --no-session flag would change what CLAUDECODE the tool subprocess sees;
# --no-session only skips persisting the transcript.
"$OMP_BIN" -p --no-session \
  'Run this exact bash command using your tool and output only its result, nothing else: echo -n "OMPCLAUDECODE=$CLAUDECODE"; sleep 3' \
  > "$OUT" 2>&1 &
OMP_PID=$!

# Sample the real process's identity while it is still alive.
REAL_COMM=
REAL_ARGS=
for _ in $(seq 1 30); do
  kill -0 "$OMP_PID" 2>/dev/null || break
  REAL_COMM=$(ps -p "$OMP_PID" -o comm= 2>/dev/null | tr -d ' ')
  REAL_ARGS=$(ps -p "$OMP_PID" -o args= 2>/dev/null)
  [ -n "$REAL_COMM" ] && break
  sleep 0.2
done
[ -n "$REAL_COMM" ] || fail \
  "omp $version: could not observe the live process's own comm/args before it exited"

# Let the turn finish (bounded wait; no portable `timeout`/`gtimeout` on this
# machine, so poll-and-kill instead).
for _ in $(seq 1 60); do
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$OMP_PID" 2>/dev/null; then
  kill -9 "$OMP_PID" 2>/dev/null || true
  fail "omp $version: the live probe turn did not finish within the bounded wait"
fi
wait "$OMP_PID" 2>/dev/null
OMP_PID=

OUTPUT=$(cat "$OUT")

case "$OUTPUT" in
  *OMPCLAUDECODE=1*) ;;
  *) fail "OMP DRIFT: omp $version's own bash tool did not report CLAUDECODE=1 in its own process environment (observed output: $OUTPUT). The whole session-lock recognition in bin/fm-session-lock-lib.sh is gated on this marker; teach it whatever this release actually sets, or stop trusting the marker for omp." ;;
esac
note "omp $version: its own bash tool reported CLAUDECODE=1 in its own environment"
pass "omp session-lock live guard: a real omp session's own process environment carries CLAUDECODE=1"

base=$(basename -- "$REAL_COMM")
[ "$base" = omp ] || fail \
  "OMP DRIFT: omp $version's own process reports comm='$REAL_COMM' (basename '$base'), not 'omp'. bin/fm-session-lock-lib.sh's fm_harness_process_matches matches on exactly base='omp'; teach it the name this release actually uses."
note "omp $version: live process comm='$REAL_COMM' args='$REAL_ARGS'"
pass "omp session-lock live guard: a real omp process's own comm reports base name 'omp'"

# Feed the REAL observed comm/args into the real (unfaked) library function,
# with CLAUDECODE=1 set in this shell exactly as a genuine omp session's own
# self=1 ancestry check would see it.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

CLAUDECODE=1 fm_harness_process_matches "$REAL_COMM" "$REAL_ARGS" 1 \
  || fail "the real (unfaked) fm_harness_process_matches did not recognize this live omp process's own comm/args as a harness with self=1 and CLAUDECODE=1"
[ "$FM_HARNESS_IS_CLAUDE" -eq 0 ] || fail \
  "fm_harness_process_matches set FM_HARNESS_IS_CLAUDE=1 for a live omp process; it must stay 0 so the ancestry walk stops at omp's own session boundary instead of climbing into its parent"
pass "omp session-lock live guard: the real (unfaked) classifier recognizes a live omp process from its own ancestry without extending past it"

cleanup_all
trap - EXIT
