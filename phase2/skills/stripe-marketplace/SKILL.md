# stripe-marketplace
## Purpose
Marketplace/payments against Stripe test mode only.
## Mandatory documents
CONTEXT.md test-mode flags
## Rules
No live charges; no payout changes in prod
## Prohibited
Live Stripe secret keys
## Expected output
Test-mode evidence in RESULT.md
## Tests
webhook/signature unit tests
## Stop conditions
Live financial action
