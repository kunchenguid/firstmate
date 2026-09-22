#!/usr/bin/env bash
# fm-jev-runner-balancer.sh - Jev Autonomous CI Runner Health & Shard Load Balancer (Pattern 23)
#
# Shell wrapper for bin/fm-jev-runner-balancer.py.
# Inspects GitHub Actions self-hosted runners and balances matrix shard throughput.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev runner balancer" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-runner-balancer.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev runner balancer" >&2
  exit 0
fi

exec "$PYTHON_BIN" "$ENGINE" "$@"
