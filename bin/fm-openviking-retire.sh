#!/usr/bin/env bash
# fm-openviking-retire.sh - stop the OpenViking server and end its retry burn,
# reversibly.
#
# Usage:
#   fm-openviking-retire.sh [--dry-run]
#
# docs/memory.md owns the operator contract and the full migration runbook.
# This header owns the stop sequence, the binary overrides, and exit codes.
#
# Sequence:
#   1. Discover launchd labels containing "viking" via `launchctl list`, then
#      `launchctl bootout gui/<uid>/<label>` and `launchctl disable` each so the
#      agent stays down across reboots. A nix/home-manager rebuild can still
#      reinstall the plist; permanence needs the module removed (docs/memory.md).
#   2. SIGTERM any residual `openviking-server` / `openviking serve` process.
#   3. Rotate $FM_OV_HOME/logs/*.log (default ~/.openviking) to
#      <name>.<utc-ts> - the unrotated server.log was 107 MB in the 2026-09-20
#      investigation. Logs are renamed, never deleted.
#   4. Verify: no viking launchd label, no openviking-server process, and
#      nothing answering on 127.0.0.1:1933.
#
# The store under $FM_OV_HOME/data is never touched; rollback is
# `launchctl bootstrap gui/<uid> <plist>` on the agent's plist plus removing
# the disable mark with `launchctl enable`. The command prints the exact
# rollback hint for every label it retires.
#
# Binary overrides (for tests and unusual PATHs): FM_OV_HOME, FM_OV_LAUNCHCTL,
# FM_OV_PGREP, FM_OV_PKILL, FM_OV_CURL, FM_OV_PORT.
#
# Exit codes: 0 fully retired or nothing to do; 1 leftovers remain after the
# stop sequence; 2 usage.
set -u

OV_HOME=${FM_OV_HOME:-$HOME/.openviking}
LAUNCHCTL=${FM_OV_LAUNCHCTL:-launchctl}
PGREP=${FM_OV_PGREP:-pgrep}
PKILL=${FM_OV_PKILL:-pkill}
CURL=${FM_OV_CURL:-curl}
PORT=${FM_OV_PORT:-1933}
UID_=$(id -u)
TS=$(date -u +%Y%m%dT%H%M%SZ)
dry_run=0

usage() {
  printf 'Usage: fm-openviking-retire.sh [--dry-run]\n' >&2
}

die() {
  printf 'openviking-retire: %s\n' "$1" >&2
  exit "${2:-2}"
}

note() {
  printf 'openviking-retire: %s\n' "$1"
}

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'dry-run: %s\n' "$*"
  else
    "$@"
  fi
}

list_viking_labels() {
  local out rc
  out=$("$LAUNCHCTL" list 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk 'NR>1 {print $3}' | grep -i 'viking' || true
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

command -v "$LAUNCHCTL" >/dev/null 2>&1 || die "launchctl not found: $LAUNCHCTL"

left=0

# 1. Retire launchd labels.
labels=''
list_failed=0
if ! labels=$(list_viking_labels); then
  printf 'openviking-retire: launchctl list failed; cannot enumerate viking labels\n' >&2
  list_failed=1
fi
if [ -n "$labels" ]; then
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    note "bootout gui/$UID_/$label"
    run "$LAUNCHCTL" bootout "gui/$UID_/$label"
    note "disable gui/$UID_/$label"
    if ! run "$LAUNCHCTL" disable "gui/$UID_/$label"; then
      printf 'openviking-retire: launchctl disable failed for %s\n' "$label" >&2
      left=1
    fi
    note "rollback: $LAUNCHCTL enable gui/$UID_/$label && $LAUNCHCTL bootstrap gui/$UID_ ~/Library/LaunchAgents/$label.plist"
  done <<EOF
$labels
EOF
elif [ "$list_failed" -eq 0 ]; then
  note "no launchd label containing 'viking'"
fi

# 2. Stop residual server processes (match the server, never this script).
if "$PGREP" -f 'openviking-server|openviking serve' >/dev/null 2>&1; then
  note "stopping residual openviking server process(es)"
  run "$PKILL" -f 'openviking-server|openviking serve'
else
  note "no openviking server process"
fi

# 3. Rotate logs.
if [ -d "$OV_HOME/logs" ]; then
  while IFS= read -r log; do
    [ -n "$log" ] || continue
    [ -s "$log" ] || continue
    note "rotate $log -> $log.$TS"
    if ! run mv "$log" "$log.$TS"; then
      printf 'openviking-retire: failed to rotate %s\n' "$log" >&2
      left=1
    fi
  done <<EOF
$(find "$OV_HOME/logs" -type f -name '*.log' 2>/dev/null | sort)
EOF
else
  note "no log directory at $OV_HOME/logs"
fi

# 4. Verify.
if [ "$dry_run" -eq 0 ]; then
  if ! labels_now=$(list_viking_labels); then
    printf 'openviking-retire: cannot verify launchd labels: launchctl list failed\n' >&2
    left=1
  elif [ -n "$labels_now" ]; then
    printf 'openviking-retire: launchd label still loaded\n' >&2
    left=1
  fi
  if "$PGREP" -f 'openviking-server|openviking serve' >/dev/null 2>&1; then
    printf 'openviking-retire: server process still running\n' >&2
    left=1
  fi
  if ! command -v "$CURL" >/dev/null 2>&1; then
    printf 'openviking-retire: cannot verify port %s: %s not found\n' "$PORT" "$CURL" >&2
    left=1
  elif "$CURL" -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    printf 'openviking-retire: port %s still answers\n' "$PORT" >&2
    left=1
  fi
fi

if [ "$left" -eq 0 ]; then
  if [ "$dry_run" -eq 1 ]; then
    note "dry-run complete; nothing changed"
  else
    note "retired; data preserved under $OV_HOME (never deleted)"
    note "standing check: after any backend change, confirm the OV queue is empty (data/memory-store-reliable-cheap report)"
  fi
  exit 0
fi
exit 1
