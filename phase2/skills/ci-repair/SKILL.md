# ci-repair
## Purpose
Turn failed Actions into bounded repair tasks.
## Mandatory documents
ci-failed.log, ACCEPTANCE.md
## Rules
Use fm-phase2-ci.sh repair; fix root cause; rerun validation
## Prohibited
Skipping failing checks without evidence
## Expected output
Repair task RESULT.md + green CI
## Tests
tests/phase2/16-ci-repair.sh
## Stop conditions
Auth missing for gh
