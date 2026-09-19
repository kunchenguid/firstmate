#!/usr/bin/env bash
# Usage: FM_HOME=<home> FM_PROBE_HOME=<runtime> FM_PROBE_JQ_IMAGE=<image> startup.sh
# Required environment: FM_HOME, FM_PROBE_HOME, and FM_PROBE_JQ_IMAGE.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOG=$(cygpath -u "${FM_PROBE_HOME:?}")
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
export PATH="$ROOT/bin/native-owner/tools:$PATH"
cd "$ROOT"
bin/fm-sessionstart-run.sh --source startup > "$LOG/startup.log" 2>&1
. bin/fm-session-lock-lib.sh
fm_session_lock_owned_by_self "$FM_HOME/state"
[ "$(<"$FM_HOME/state/.session-start-complete")" = "$(<"$FM_HOME/state/.lock")" ]
if grep -q 'READ-ONLY SESSION\|SESSION START INCOMPLETE' "$LOG/startup.log"; then exit 1; fi
printf 'ready\n' > "$LOG/digest.ready"
# The existing worker owns network work. This scope neither repeats that work
# nor delays delivery of the digest to the host.
for ((i=0; i<180; i++)); do
  phase=$(awk -F= '$1=="state" {print $2}' "$FM_HOME/state/.startup-network.status" 2>/dev/null || true)
  case "$phase" in done|failed|timeout) break ;; esac
  sleep 1
done
case "$phase" in done|failed|timeout) ;; *) printf 'Deferred startup exceeded its bound\n' >&2; exit 1 ;; esac
bin/fm-startup-network.sh report > "$LOG/deferred.log" 2>&1
printf 'finished\n' > "$LOG/startup.finished"
