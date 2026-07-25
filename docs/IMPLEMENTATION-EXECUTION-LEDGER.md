# Implementation Execution Ledger

_Updated: 2026-07-25 19:09:32Z_

## Programme

- **ID:** pilot-collections
- **Title:** Artist collection submit/approve pilot
- **Phase:** pilot
- **Status:** active

## Counts

```json
{
  "cancelled": 1,
  "planned": 7,
  "ready": 2
}
```

## Tasks

| ID | Status | Worker | Priority | Branch | PR | CI | Blocker |
|----|--------|--------|----------|--------|----|----|---------|
| pilot-deliberate-fail | cancelled | test_engineer | 5 |  |  |  | intentional |
| pilot-db-collection | ready | database_engineer | 10 |  |  |  |  |
| repair-pilot-deliberate-fail-6568 | ready | backend_engineer | 10 |  |  |  |  |
| pilot-api-collection | planned | backend_engineer | 20 |  |  |  |  |
| pilot-ui-collection | planned | frontend_engineer | 30 |  |  |  |  |
| pilot-admin-review | planned | backend_engineer | 40 |  |  |  |  |
| pilot-public-visible | planned | frontend_engineer | 50 |  |  |  |  |
| pilot-tests-browser | planned | test_engineer | 60 |  |  |  |  |
| pilot-review-gate | planned | reviewer | 70 |  |  |  |  |
| pilot-ci-gate | planned | release_engineer | 80 |  |  |  |  |

## Ready queue

- `pilot-db-collection` — DB: collection draft model support
- `repair-pilot-deliberate-fail-6568` — CI repair for pilot-deliberate-fail

---

_Machine authority: `state/programme.db`. This ledger is the human view._
