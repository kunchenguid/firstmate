#!/usr/bin/env bash
set -eu
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/fm-bench-review.test.py" "$@"
