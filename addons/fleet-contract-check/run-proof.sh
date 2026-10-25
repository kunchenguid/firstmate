#!/usr/bin/env bash
# run-proof.sh: the fleet-contract-check proof for done-done. Runs the real script against the installed fork
# (FM_MAIN_HOME, default ~/firstmate, read-only) in a throwaway home, then the broken-caller journey, and keeps the transcript.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
{
  echo "== installed fleet: every cross-repo caller"
  bash "$repo/fleet-contract-check/fleet-contract-check"
  echo "== a tool release breaks owner-guard: the check names the caller and exits non-zero"
  fork=$(mktemp -d)
  mkdir -p "$fork/config"
  printf '#!/usr/bin/env bash\n/nonexistent/fm-owner-guard/owner-guard merge-gate "$@"\n' > "$fork/config/merge-gate"
  rc=0
  FM_MAIN_HOME=$fork bash "$repo/fleet-contract-check/fleet-contract-check" owner-guard || rc=$?
  echo "exit code: $rc"
  rm -rf -- "$fork"
  test "$rc" -eq 1
  echo "== fixture journey"
  bash "$repo/fleet-contract-check/tests/fleet-contract-check.test.sh"
} 2>&1 | tee "$evidence/fleet-contract-check.txt"
test "${PIPESTATUS[0]}" -eq 0
cat > "$evidence/steps.json" <<'J'
{"target":{"version":"fleet-contract-check from this checkout, run against the installed fork at ~/firstmate"},
 "start":"the installed fork and add-ons, with a throwaway HOME and FM_HOME",
 "steps":["an operator runs the one fleet-contract-check command after a tool release and reads one line per cross-repo caller","the operator runs the fixture journey where a tool release breaks owner-guard and dispatch-resolve and finds which caller is named"],
 "result":"every caller prints ok on the installed fleet; a broken caller prints FAIL with its name and the check exits 1; the transcript ends with PASS"}
J
