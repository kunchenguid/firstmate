#!/usr/bin/env bash
# Stress just the worker-replacement cycle from tests/fm-remote-job.test.sh:
# start a worker via ensure, then repeatedly relocate the root and ensure again,
# timing how long each replacement takes to report ready.
set -u
ROOT=/tmp/fmrepro/repo
T=$(mktemp -d /tmp/fmstress.XXXXXX)
A="$T/account"; S="$T/remote-jobs"
mkdir -p "$A"
make_root() { # <dir>
  mkdir -p "$1/bin"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$1/bin/"
  printf 'fixture\n' > "$1/AGENTS.md"
  chmod +x "$1/bin"/*.sh
}
export FM_REMOTE_JOB_STATE_ROOT="$S"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export HOME="$A"
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  if [ -f "$S/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$S/worker.pid")" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$T"
}
trap cleanup EXIT
CYCLES=${1:-40}
R_PREV="$T/root-0"
make_root "$R_PREV"
fm_remote_job_ensure_worker "$R_PREV" "$A" || { echo "initial ensure failed: $FM_REMOTE_JOB_ERROR"; exit 1; }
slow=0
for i in $(seq 1 "$CYCLES"); do
  R="$T/root-$i"
  make_root "$R"
  start=$(date +%s%N)
  if ! fm_remote_job_ensure_worker "$R" "$A"; then
    echo "cycle $i: ENSURE FAILED: $FM_REMOTE_JOB_ERROR"
    echo "--- lock dir:"; ls -la "$S/worker.lock" 2>/dev/null || echo "(none)"
    echo "--- state:"; ls -la "$S" 2>/dev/null
    echo "--- newest log tail:"; tail -20 "$S/logs"/*.log 2>/dev/null | tail -25
    exit 1
  fi
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  if [ "$ms" -gt 3000 ]; then
    slow=$((slow + 1))
    echo "cycle $i: SLOW ${ms}ms"
    ls -la "$S/worker.lock" 2>/dev/null || true
  else
    echo "cycle $i: ok ${ms}ms"
  fi
  rm -rf -- "$R_PREV"
  R_PREV="$R"
done
echo "done: slow=$slow/$CYCLES"
