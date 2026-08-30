#!/usr/bin/env bash
# Hermetic public-interface tests for the default-off curated context handoff.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/fm-context-handoff.test.py"
