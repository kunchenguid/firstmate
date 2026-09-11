#!/usr/bin/env bash
# Deterministic rules, real I/O composition and calm terminal contracts; no models.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$ROOT/modules/moiras/tests/"*.test.mjs
