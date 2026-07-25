# database-migrations
## Purpose
Safe schema changes with validation.
## Mandatory documents
TEST-PLAN.md migration section; FILE-OWNERSHIP.md
## Rules
Max one migration worker; expand/contract friendly; no destructive prod migrate without captain
## Prohibited
Dropping production data; running migrate against prod
## Expected output
Migration files + validate evidence in RESULT.md
## Tests
project migration validate script
## Stop conditions
Destructive migration without approval
