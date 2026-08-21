#!/usr/bin/env bash
# Container entrypoint: register one ephemeral runner, serve exactly one job,
# then exit. The container is started with --rm, so the workspace dies with it.
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"
: "${RUNNER_LABELS:?RUNNER_LABELS is required}"

cd /home/runner

# --ephemeral    : deregister after one job, never reuse state
# --disableupdate: the image is immutable; a self-update mid-run would defeat that
# --replace      : reclaim the name if a previous container died without deregistering
./config.sh \
  --url "$REPO_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work \
  --ephemeral \
  --disableupdate \
  --replace \
  --unattended

# NOT `exec ./run.sh`. run.sh is bash, and bash as PID 1 defers a trap until
# its foreground child exits, so a SIGTERM from systemd would be swallowed
# and every restart would sit out TimeoutStopSec (measured: 300s, 21.08.2026).
# Backgrounding and waiting makes `wait` interruptible, so the signal reaches
# the runner and an idle container stops in seconds. A BUSY runner still
# finishes its job first - the runner's own graceful shutdown owns that, and
# TimeoutStopSec is the outer bound.
./run.sh &
runner_pid=$!
trap 'kill -TERM "$runner_pid" 2>/dev/null || true' TERM INT

# `wait` returns early when a trap fires, before the child is actually gone,
# so keep waiting until it really is and preserve the runner's exit code.
rc=0
while :; do
  if wait "$runner_pid"; then rc=0; else rc=$?; fi
  kill -0 "$runner_pid" 2>/dev/null || break
done
exit "$rc"
