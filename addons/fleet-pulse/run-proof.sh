#!/usr/bin/env bash
# Sealed done-done proof for newest-retro discovery (screen: none).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
{
  echo "== fixture homes: newest across homes, due/quiet cases, install retarget"
  bash "$repo/fleet-pulse/tests/newest-retro.test.sh"
  echo "== live main home: newest report path"
  bash "$repo/fleet-pulse/bin/newest-retro-report.sh" "${FM_MAIN_HOME:-$HOME/firstmate}"
} 2>&1 | tee "$evidence/newest-retro.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet-pulse bin/newest-retro-report.sh and bin/fleet-retro-due.sh from this checkout"},
 "start":"disposable main and sibling firstmate homes with planted data/*retro*/report.md files at controlled mtimes",
 "steps":["run the fixture journey: none due, older main plus newer sibling quiet, all old due, wake mark suppresses, install retargets the pulse check","print the newest report path for the live main home"],
 "result":"fixture cases print PASS newest-retro; the live newest path is a data/*retro*/report.md under a known home"}
J
