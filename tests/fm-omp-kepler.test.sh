#!/usr/bin/env bash
# Portable behavior checks: inert OS children and injected fake SDK only.
# Usage: FM_OMP_KEPLER_TEST_BUN=/absolute/pinned/bun bash tests/fm-omp-kepler.test.sh
# No agent/auth/session construction, provider request, or global home changes.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
/usr/bin/python3 -I "$ROOT/tests/fm-omp-kepler.test.py"
if [ -n "${FM_OMP_KEPLER_TEST_BUN:-}" ]; then
  "$FM_OMP_KEPLER_TEST_BUN" --no-env-file "$ROOT/tests/fm-omp-kepler.test.ts"
else
  printf '%s\n' 'SKIP fake SDK checks: set FM_OMP_KEPLER_TEST_BUN to a pinned private Bun'
fi
