# Playwright test personas (Epic Northscapes future use)

Use these roles in specs; do not hard-code production credentials.

| Persona | Intent |
|---------|--------|
| Owner | Full platform ownership |
| Administrator | Admin panel / moderation |
| Developer | Dev tools / diagnostics |
| Curator | Editorial curation |
| Standard Artist | Create/submit collections & artworks |
| Trusted Artist | Elevated artist privileges |
| Collector | Purchase / collect |
| Artist and Collector | Dual role |
| Suspended account | Denied actions |
| Anonymous visitor | Public read-only |

## Config

- `PLAYWRIGHT_BASE_URL` (default `http://127.0.0.1:3000`)
- Artifacts: `test-results/` screenshots + traces on failure
- Isolated data: prefer demo seed scripts; reset between runs when safe

## Pilot

See `phase2/playwright/pilot-collection.spec.ts` — bounded smoke for collection visibility (requires running app).
