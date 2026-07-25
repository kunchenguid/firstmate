# authentication-security
## Purpose
AuthN/Z and secret hygiene.
## Mandatory documents
ACCEPTANCE.md security criteria; SECURITY.md
## Rules
Least privilege; redact secrets in logs; no live keys in packets
## Prohibited
Committing secrets; weakening auth for convenience
## Expected output
Security notes in RESULT.md
## Tests
secret scanning / auth tests
## Stop conditions
Secret leakage detected
