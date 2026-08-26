#!/usr/bin/env bash
# Loop tests/fm-remote-job.test.sh in the WSL copy; keep fixture state of failing runs.
set -u
cd /tmp/fmrepro/repo || exit 1
mkdir -p /tmp/fmrepro/failures
KEEP=/tmp/fmrepro/repo/tests/fm-remote-job-keep.test.sh
if [ "${2:-}" = gen ] || [ ! -f "$KEEP" ]; then
  sed "s|^trap cleanup_remote_job_fixture EXIT\$|trap 'rc=\$?; if [ \"\$rc\" -ne 0 ]; then cp -r -- \"\$TMP_ROOT\" \"/tmp/fmrepro/failures/run-\$\$\" 2>/dev/null; fi; cleanup_remote_job_fixture' EXIT|" \
    tests/fm-remote-job.test.sh > "$KEEP"
  grep -q 'failures/run' "$KEEP" || { echo "patch failed"; exit 1; }
  echo "generated $KEEP"
  [ "${2:-}" = gen ] && exit 0
fi
stream=${2:-s}
runs=${1:-10}
fails=0
for i in $(seq 1 "$runs"); do
  start=$(date +%s)
  if out=$(bash "$KEEP" 2>&1); then
    echo "[$stream] run $i: PASS ($(( $(date +%s) - start ))s)"
  else
    fails=$((fails + 1))
    echo "[$stream] run $i: FAIL ($(( $(date +%s) - start ))s)"
    echo "$out" | tail -4
  fi
done
echo "[$stream] fails=$fails/$runs"
