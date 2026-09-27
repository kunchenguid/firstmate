#!/usr/bin/env bash
# fm-jev-shm-guard.sh - Wrapper for Jev POSIX Shared Memory & Semaphore Leak Guard (Pattern 42)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-shm-guard.py" "$@"
