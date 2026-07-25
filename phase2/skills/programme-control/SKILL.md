# programme-control
## Purpose
Drive Phase 2 programme/task state via registry — never chat memory.
## Mandatory documents
STATE.json, IMPLEMENTATION-EXECUTION-LEDGER.md, programme.db
## Rules
- Use bin/fm-phase2-registry.sh for transitions
- Update ledger after every state change
- Continue to next ready task automatically when gates pass
## Prohibited
Treating conversation as authority; skipping dependency checks
## Expected output
Atomic transition + ledger update
## Tests
tests/phase2/01-registry.sh
## Stop conditions
Illegal transition; missing programme
