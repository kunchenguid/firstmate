#!/usr/bin/env bash
# Opt-in paid reasoning checks: Pi default/Atropos routes and Claude alternative.
# FM_MOIRAS_LIVE_CASE optionally selects pi-default, pi-atropos or claude-alternative.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib.sh"
fm_live_gate opt-in FM_MOIRAS_LIVE node pi claude
FM_MOIRAS_LIVE_ADMITTED=1 node --test "$ROOT/modules/moiras/tests/live-reasoning.mjs"
