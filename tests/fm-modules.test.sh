#!/usr/bin/env bash
# Portable shared-module core, use-case, adapter and real process-event checks.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
node --test modules/fm-tui-core/tests/*.test.mjs modules/fm-state-reader/tests/*.test.mjs
