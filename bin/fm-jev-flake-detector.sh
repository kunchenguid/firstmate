#!/usr/bin/env bash
# fm-jev-flake-detector.sh - Shell wrapper for Jev Flake vs Regression Disambiguator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "Jev Flake Detector: python3 not found, failing open" >&2
  exit 0
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 --pr PR [--repo REPO] [--retrigger] [--json]" >&2
  exit 2
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-flake-detector.py" "$@"
