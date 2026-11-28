#!/usr/bin/env bash
# fm-sandbox-relay.sh - host-side busy-state relay for a sandboxed omp worker.
#
# Why it exists: the omp busy extension (state/<id>.omp-ext.ts) reports each
# turn edge through bin/fm-busy-event.sh, which needs a writable state/ directory
# (a lock directory plus a rename). A writable state/ inside the sandbox is the
# escape the sandbox exists to prevent: it holds every other worker's inbox and
# extension, which run unsandboxed. So a sandboxed worker's extension writes one
# small JSON file per edge into state/<id>.sbx/events.<gen>/ (bound writable beside
# only the task's own status, turn-ended and inbox paths) and this relay,
# running on the HOST as the sandbox wrapper's --host-helper child, validates
# each file and applies the edge.
#
# Trust boundary: the relay authenticates the INCARNATION, never the claim. The
# busy gen is fixed by bin/fm-spawn.sh in the helper's command line (host side)
# and a file can neither carry nor override it, and each incarnation has its own
# spool (a relaunch removes the old one), so a worker from a superseded
# incarnation cannot move its replacement's record; fm-busy-event.sh stays the
# only writer of the busy contract and enforces the gen. The source is fixed to
# omp-ext. What a worker can still do is misreport its own state, exactly what a
# compromised unsandboxed extension could.
#
# Event file (one per edge, name <seq>.json, written by rename so it is whole):
#   {"state":"busy|idle|unknown","event":"<token>"}
# <token> is 1-64 characters of [A-Za-z0-9._-]. Other keys are ignored.
#
# Dropped, never applied, and counted in state/<id>.sbx/relay.log (logfmt, host
# side only, never the pane): a non-regular file or symlink, a file over
# FM_SANDBOX_RELAY_MAX_BYTES (512), malformed or schema-violating JSON, an
# event beyond FM_SANDBOX_RELAY_RATE (20) applies in one wall-clock second
# (flood, one line per pass with its count), and an event whose apply
# fm-busy-event.sh refuses (stale incarnation). One pass takes at most
# FM_SANDBOX_RELAY_PASS (64) spool entries; the rest wait for the next poll, so
# a flooded spool costs the host a bounded amount of work per poll. A dropped
# directory is removed only when empty: a worker-made tree is never walked here
# and waits for teardown or the next relaunch, which remove the whole spool.
#
# Usage:
#   fm-sandbox-relay.sh run  --state DIR --id ID --gen GEN --events DIR [--interval SECS]
#   fm-sandbox-relay.sh once --state DIR --id ID --gen GEN --events DIR
# `run` polls until the events directory disappears (teardown) or the task is
# re-armed under another gen. The wrapper ends it with TERM when the worker
# exits; it then applies one last pass first, so an edge written in the worker's
# final moments is not lost. `once` is a single pass for diagnostics and tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LC_ALL=C

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

MODE=${1:-}
case "$MODE" in
run | once) shift ;;
-h | --help) usage ;;
*) usage ;;
esac

STATE=
ID=
GEN=
EVENTS=
INTERVAL=0.2
while [ $# -gt 0 ]; do
  case "$1" in
  --state) STATE=${2:-}; shift 2 || usage ;;
  --id) ID=${2:-}; shift 2 || usage ;;
  --gen) GEN=${2:-}; shift 2 || usage ;;
  --events) EVENTS=${2:-}; shift 2 || usage ;;
  --interval) INTERVAL=${2:-}; shift 2 || usage ;;
  *) usage ;;
  esac
done
[ -n "$STATE" ] && [ -n "$ID" ] && [ -n "$GEN" ] && [ -n "$EVENTS" ] || usage
case "$ID$GEN" in *[!A-Za-z0-9._-]*) echo "error: invalid task id or gen" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
[ -d "$EVENTS" ] || { echo "error: events dir not found: $EVENTS" >&2; exit 1; }

MAX_BYTES=${FM_SANDBOX_RELAY_MAX_BYTES:-512}
RATE=${FM_SANDBOX_RELAY_RATE:-20}
MAX_PASS=${FM_SANDBOX_RELAY_PASS:-64}
LOG="${EVENTS%/*}/relay.log"
INFLIGHT="${EVENTS%/*}/inflight"
LOG_MAX_BYTES=65536

win=-1
applied=0
flooded=0
taken=0

log_drop() {  # <reason> [count]
  local size=0
  [ ! -f "$LOG" ] || size=$(wc -c <"$LOG" | tr -d ' ')
  [ "${size:-0}" -le "$LOG_MAX_BYTES" ] || : >"$LOG"
  printf 'ts=%s level=warn source=sandbox-relay task=%s msg=dropped reason=%s count=%s\n' \
    "$(date +%s)" "$ID" "$1" "${2:-1}" >>"$LOG" 2>/dev/null || true
}

# drop_held <path> [reason]: remove a held entry that is not applied, without
# walking a tree the worker built (rmdir leaves a non-empty directory in place).
drop_held() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    rmdir -- "$1" 2>/dev/null || true
  else
    rm -f -- "$1"
  fi
  [ -z "${2:-}" ] || log_drop "$2"
}

# relay_one <path>: validate one event file, already moved out of the spool into
# the host-only inflight directory, and apply it. The file is removed whatever
# the verdict, so the spool never accumulates.
relay_one() {
  local f=$1 body parsed st ev
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    drop_held "$f" nonregular
    return 0
  fi
  body=$(head -c $((MAX_BYTES + 1)) -- "$f" 2>/dev/null) || body=
  rm -f -- "$f"
  if [ "${#body}" -gt "$MAX_BYTES" ]; then
    log_drop oversize
    return 0
  fi
  parsed=$(printf '%s' "$body" | jq -r '
    select(type == "object")
    | select((.state | type) == "string" and (.event | type) == "string")
    | [.state, .event] | join(" ")' 2>/dev/null) || parsed=
  st=${parsed%% *}
  ev=${parsed#* }
  case "$st" in
  busy | idle | unknown) ;;
  *)
    log_drop malformed
    return 0
    ;;
  esac
  case "$ev" in
  '' | *[!A-Za-z0-9._-]*)
    log_drop malformed
    return 0
    ;;
  esac
  if [ "${#ev}" -gt 64 ]; then
    log_drop malformed
    return 0
  fi
  if [ "$SECONDS" != "$win" ]; then
    win=$SECONDS
    applied=0
  fi
  if [ "$applied" -ge "$RATE" ]; then
    flooded=$((flooded + 1))
    return 0
  fi
  applied=$((applied + 1))
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" "$st" \
    --gen "$GEN" --source omp-ext --event "$ev" >/dev/null 2>&1 || log_drop refused
  return 0
}

# relay_take <entry> [reason]: rename one spool entry into INFLIGHT (beside the
# spool, never bound into the sandbox) before it is inspected, so the worker
# cannot swap a FIFO or symlink in between the check and the read; then apply
# it, or drop it for <reason> (empty: silently).
relay_take() {
  local f=$1 held
  taken=$((taken + 1))
  held="$INFLIGHT/$$.$taken"
  mv -f -- "$f" "$held" 2>/dev/null || return 0
  if [ "$#" -gt 1 ]; then
    drop_held "$held" "$2"
    return 0
  fi
  case "$f" in
  *.json) relay_one "$held" ;;
  *) drop_held "$held" nonregular ;;
  esac
}

# relay_pass: take at most MAX_PASS spool entries.
relay_pass() {
  local f n=0
  [ -d "$INFLIGHT" ] || return 0
  flooded=0
  # Names sort in write order (zero-padded sequence), so edges apply in order.
  for f in "$EVENTS"/*; do
    [ "$n" -lt "$MAX_PASS" ] || break
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=$((n + 1))
    relay_take "$f"
  done
  # A half-written temporary (dot-prefixed, never read) that outlives a crashed
  # writer is swept from what is left of the budget, so the spool stays bounded.
  while [ "$n" -lt "$MAX_PASS" ] && IFS= read -r -d '' f; do
    n=$((n + 1))
    relay_take "$f" ''
  done < <(find "$EVENTS" -mindepth 1 -maxdepth 1 -name '.*' -mmin +1 -print0 2>/dev/null)
  [ "$flooded" -eq 0 ] || log_drop flood "$flooded"
}

if [ "$MODE" = once ]; then
  relay_pass
  exit 0
fi

# The wrapper ends this helper with TERM once the worker exits, so one last pass
# applies whatever the worker wrote in its final moments before the relay goes.
relay_drain_and_exit() {
  if [ -d "$EVENTS" ] && [ "$(cat "$STATE/$ID.busy-gen" 2>/dev/null)" = "$GEN" ]; then
    relay_pass
  fi
  exit 0
}
trap relay_drain_and_exit TERM INT HUP
while :; do
  [ -d "$EVENTS" ] || exit 0
  [ "$(cat "$STATE/$ID.busy-gen" 2>/dev/null)" = "$GEN" ] || exit 0
  relay_pass
  # A backgrounded sleep keeps the trap prompt: bash defers a trap while a
  # foreground command runs.
  sleep "$INTERVAL" &
  wait $!
done
