# Mock and Seam Inventory

## Known Cross-module mock.module Locations

The following directories contain test files that use cross-module `mock.module` (permitted under two-tier convention):

- `tests/unit/commands/` — mocks tools, hooks, services, state
- `tests/unit/hooks/` — mocks knowledge-store, knowledge-validator, knowledge-reader, telemetry, utils
- `tests/unit/tools/` — mocks Node built-ins (fs, child_process), sast-baseline, build/discovery
- `tests/unit/services/` — mocks path-security
- `tests/unit/config/` — mocks node:fs/promises
- `tests/unit/background/` — mocks utils, event-bus, evidence-summary-service
- `tests/unit/council/` — mocks node:fs
- `tests/unit/plan/` — mocks spec-hash
- `tests/unit/mutation/` — mocks node:child_process
- `tests/unit/git/` — mocks node:child_process
- `tests/integration/` — mocks co-change-analyzer, knowledge-store
- `src/__tests__/` — mocks plan/manager, preflight-service, telemetry
- `src/hooks/` — mocks logger, event-bus
- `src/tools/__tests__/` — mocks test-impact/analyzer, build/discovery, path-security
- `src/mutation/__tests__/` — mocks state
- `src/agents/` — mocks node:fs/promises
- `src/background/` — mocks vulnerability trigger

## Dead-code _internals Seams

The following source modules export `_internals` but have no test consumers (as of this writing). They are harmless but may be removed in future cleanup:

- `src/tools/secretscan.ts`
- `src/tools/knowledge-recall.ts`
- `src/tools/lint.ts`
- `src/tools/sast-scan.ts`
- `src/tools/sast-baseline.ts`
- `src/mutation/gate.ts`
- `src/mutation/equivalence.ts`
- `src/mutation/engine.ts`
- `src/db/qa-gate-profile.ts`
- `src/config/schema.ts`
- `src/config/index.ts`
- `src/commands/registry.ts`
- `src/background/manager.ts`
- `src/background/event-bus.ts`
- `src/agents/critic.ts`
