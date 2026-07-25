# FirstMate Phase 2 — Worker Profiles

Profiles live under `phase2/profiles/*.json`. Dispatch selects `worker_type` on each task.

| Profile | Role |
|---------|------|
| architect | Design / task packet decomposition |
| database_engineer | Schema & migrations (max 1 concurrent) |
| backend_engineer | API / domain logic |
| frontend_engineer | UI / routes |
| security_engineer | AuthZ / secret boundaries |
| integration_engineer | Gelato / Stripe / external APIs |
| test_engineer | Tests / Playwright |
| reviewer | Independent AC review (cannot approve own work) |
| no_mistake_reviewer | Drive no-mistakes axi |
| release_engineer | Release readiness (deploy disabled by default) |

## Global denies (all profiles)

- Production secrets / live Stripe / live Gelato keys
- SSH private keys
- Production `.env`
- Docker socket
- Unrelated repositories
- Force-push / rewrite main
- Automatic production deploy

See individual JSON files for allowed tools, directories, required skills, max scope, required tests, and final report path (`packet/RESULT.md`).
