#!/usr/bin/env bash
# Write a durable health-check wake event to the firstmate wake queue.
# Called by systemd timer 3x daily during market hours.
# Firstmate picks it up on next watcher cycle and dispatches a crewmate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
source "$SCRIPT_DIR/fm-wake-lib.sh"

fm_wake_append "check" \
  "${STATE}/health-check.check.sh" \
  "check: health-check: market-hours ingestion health check due"
