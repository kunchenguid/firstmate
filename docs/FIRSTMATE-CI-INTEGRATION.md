# FirstMate Phase 2 — CI Integration

## Commands

```bash
bin/fm-phase2-ci.sh record <task-id> <sha>
bin/fm-phase2-ci.sh wait <task-id> --repo Gerlionx/northscapes-gallery [--timeout 600]
bin/fm-phase2-ci.sh logs <run-id> --repo Gerlionx/northscapes-gallery
bin/fm-phase2-ci.sh repair <task-id> --from-run <run-id> --repo Gerlionx/northscapes-gallery
```

## Flow

1. Worker commits → record SHA on task  
2. `wait` polls `gh run list --commit`  
3. On failure → transition toward repair; `repair` creates bounded child task + packet with failed logs  
4. On success → advance toward `approved` / keep `awaiting_ci` if review still pending  

## Recommended workflow levels (gallery)

| Level | Checks |
|-------|--------|
| commit / PR | format, lint, typecheck, unit, build |
| PR | + integration, migration validate, Playwright smoke |
| nightly | dependency audit, broader browser |
| release | full suite + secret scan |

Existing repo workflows remain source of truth; Phase 2 reads them via `gh`. A pushed commit is **not** complete until CI passes (and review/no-mistakes per programme gates).
