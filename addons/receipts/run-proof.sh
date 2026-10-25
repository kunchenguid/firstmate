#!/usr/bin/env bash
# run-proof.sh: the receipt-candidate hook proof for done-done. Runs the receipts hook journey, which drives the
# real fork bin/fm-pr-check.sh with this add-on's fm_receipts_pr_candidate, and keeps its transcript as evidence.
# FM_TEST_FORK names a read-only Firstmate checkout (default ~/firstmate); nothing in it is changed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
export FM_TEST_FORK=${FM_TEST_FORK:-$HOME/firstmate}
bash "$repo/receipts/tests/receipts-hook-e2e.sh" 2>&1 | tee "$evidence/receipt-candidate.txt"
test "${PIPESTATUS[0]}" -eq 0
cat > "$evidence/steps.json" <<'J'
{"target":{"version":"firstmate bin/fm-pr-check.sh from a read-only fork checkout, with this add-on's receipts library"},
 "start":"a disposable firstmate home with one direct-PR task and a verified forge head",
 "steps":["call fm_receipts_pr_candidate for a pull request outside the worktree's origin, for one in it, and with an empty head","run the real fm-pr-check.sh with the add-on library for the outside-origin and the same-repo pull request and read the candidate the gate receives"],
 "result":"the outside-origin pull request's verified head is the receipt candidate; a same-repo or unverified one gives none; the transcript ends with ok"}
J
