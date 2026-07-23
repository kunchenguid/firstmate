#!/usr/bin/env bash
# Focused deterministic tests for the harness-neutral Telegram transport core.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}" \
  python3 "$ROOT/tests/fm_telegram_transport_tests.py"
