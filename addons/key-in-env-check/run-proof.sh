#!/usr/bin/env bash
# Capture the key-in-env check's fixture-process journey for done-done.
# Captures and steps.json land in $DONE_DONE_EVIDENCE_ROOT (run root), matching
# other add-on run-proof.sh scripts: done-done reads steps.json beside captures.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
cd "$repo"

printf '$ bash key-in-env-check/tests/key-in-env-check-e2e.sh\n' >"$evidence/key-in-env-check.txt"
bash key-in-env-check/tests/key-in-env-check-e2e.sh >>"$evidence/key-in-env-check.txt" 2>&1

python3 - "$evidence/steps.json" "$(git rev-parse HEAD)" <<'PY'
import json, sys
record = {
    "target": {"version": sys.argv[2]},
    "start": "A fixture home with synthetic key-carrying processes, a key-free process, and a temp HOME whose ~/.config/openrouter/api_key matches the fixture env canary.",
    "steps": [
        "Run the key-in-env checker against the fixture process tree and inspect its incident list.",
        "Repeat the unchanged finding, then increase the carrier count by 10% and confirm silence.",
        "Increase the carrier count by exactly 26%, force a new key name while the env still matches the file (wake), then rotate the fixture key file so the env canary is old (stderr log only, no wake) and grow the count while old.",
        "Run a clean scan, restore the file to the env canary, and inspect the alert and redaction output."
    ],
    "result": "The checker alerts initially, stays quiet for an unchanged finding and a 10% increase, alerts at 26% and for a new key name while the OpenRouter env hash matches the key file, logs key revoked on stderr with no wake when the file is rotated (including count growth), re-alerts after a clean scan when the file matches again, and never exposes canary values or makes a network call."
}
with open(sys.argv[1], "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
PY
echo "run-proof: captured the key-in-env check journey"
