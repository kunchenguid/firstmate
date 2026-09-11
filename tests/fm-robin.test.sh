#!/usr/bin/env bash
# Core, fake workflow, file/event composition, CLI and scene checks for Robin.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
node --test modules/fm-robin/tests/*.test.mjs
