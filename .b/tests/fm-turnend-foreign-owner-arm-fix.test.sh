#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-turnend-foreign-owner-repro.py"
