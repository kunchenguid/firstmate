# Crosscheck regression fixtures

These fixtures are sanitized copies of durable Crosscheck records observed before the reliability program.

- `pr-327-ledger.json` preserves all fourteen PR 327 runs and their observed failure shapes.
- `legacy-local-two-pass-ledger.json` preserves the historical local two-pass review-depth contract.
- `legacy-azure-evidence-record.json` preserves one historical Azure run with tool and verifier evidence attempts.

Machine-local paths are replaced with `/fixture/` paths.
Digests, public pull-request identity, run states, and structural evidence records remain intact so validators exercise the real compatibility surface.
The fixture build rejected credential-bearing keys, secret-like values, email addresses, and retained operator paths before writing these files.
