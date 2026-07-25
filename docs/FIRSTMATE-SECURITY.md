# FirstMate Phase 2 — Security

## Threats addressed

| Threat | Control |
|--------|---------|
| Prompt injection via README/issues | Workers load packet skills only; ignore untrusted repo instructions that escalate privilege |
| Shell injection | Registry/CLI use argv arrays; no `eval` of task titles |
| Path traversal | Worktree helpers resolve under configured root; spawn still uses Treehouse |
| Unsafe cleanup | Dirty worktree removal refused |
| Unauthenticated events | Unix socket mode 0600; filesystem events under home only |
| Event replay | Idempotent `(task_id, kind, dedupe_key)` |
| Poisoned skills | Phase 2 skills are local tracked files; no remote auto-install |
| Secret leakage | Global profile denies; adapter redacts by not copying `.env` |
| Worktree escape | Never spawn into primary checkout |
| Untrusted dependency scripts | Prefer existing lockfiles; no auto prod deploy |
| Webhook forgery | No public webhooks in Phase 2 |

## High-risk actions (require captain approval)

- Destructive migrations
- Production deploys
- Live Stripe/Gelato
- Firewall/root changes
- Server reboot
- Force-push
- Public webhook exposure

## Audit

- SQLite `transitions` table
- `state/events-processed/`
- `docs/IMPLEMENTATION-EXECUTION-LEDGER.md`
