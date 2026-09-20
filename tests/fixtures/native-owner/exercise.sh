#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<evidence-dir> FM_PROBE_JQ_IMAGE=<image> exercise.sh
# Required environment: FM_HOME, FM_PROBE_HOME, FM_PROBE_JQ_IMAGE.
# Real startup in an empty disposable home; no mocked startup/deferred owners.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD=$(cd "$ROOT/.." && pwd)
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
export PATH="$BUILD/tools:$PATH"
LOG=$(cygpath -u "${FM_PROBE_HOME:?}")
if [ "${FM_PROBE_STARTUP_QUEUED:-}" = 1 ]; then
  for ((i=0; i<100; i++)); do
    [ -f "$LOG/startup-unavailable-observed" ] && break
    sleep 0.1
  done
  [ -f "$LOG/startup-unavailable-observed" ]
fi
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data"
# Explicit empty manual backlog avoids inventing work or invoking task migration.
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '# Backlog\n' > "$FM_HOME/data/backlog.md"
cd "$ROOT"
printf '%s\n' "$(bin/fm-harness.sh)" > "$LOG/detected-harness.txt"
jq --version > "$LOG/jq-version.txt"
bin/fm-sessionstart-run.sh --source startup > "$LOG/startup.log" 2>&1
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$FM_HOME/state"
identity=$(<"$FM_HOME/state/.lock")
[ "$(<"$FM_HOME/state/.session-start-complete")" = "$identity" ]
if grep -q 'READ-ONLY SESSION\|SESSION START INCOMPLETE' "$LOG/startup.log"; then
  printf 'Startup did not complete with ownership\n' >&2
  exit 1
fi
printf 'STARTUP_COMPLETION_PASS\n'
# Observe the real detached worker; do not reimplement or invoke its work twice.
for ((i=0; i<150; i++)); do
  phase=$(awk -F= '$1=="state" {print $2}' "$FM_HOME/state/.startup-network.status" 2>/dev/null || true)
  case "$phase" in done|failed|timeout) break ;; esac
  sleep 1
done
bin/fm-startup-network.sh report > "$LOG/deferred-report.log" 2>&1
cp "$FM_HOME/state/.startup-network.status" "$LOG/deferred-status.txt"
[ "$phase" = 'done' ]
grep -qx 'locked=1' "$LOG/deferred-status.txt"
grep -qx 'rc=0' "$LOG/deferred-status.txt"
# A later check, after startup and deferred work, must retain the same owner.
fm_session_lock_owned_by_self "$FM_HOME/state"
[ "$(<"$FM_HOME/state/.lock")" = "$identity" ]
printf '%s\n' "$identity" > "$LOG/final-owner.txt"
printf 'DEFERRED_WORK_PASS\nSUBSEQUENT_OWNER_CHECK_PASS\nACTUAL_FIRSTMATE_OPERATION_PASS\n'
