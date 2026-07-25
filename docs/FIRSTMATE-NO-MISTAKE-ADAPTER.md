# FirstMate Phase 2 — No Mistake Adapter

## Locate

```bash
command -v no-mistakes   # -> ~/.local/bin/no-mistakes
no-mistakes --version    # v1.41.2 on Cerberus audit
no-mistakes axi --help
```

## Adapter

```bash
bin/fm-phase2-no-mistake.sh <task-id> --repo-path <worktree> [--intent "..."] [--dry-run]
```

Writes:

- `data/<id>/packet/NO-MISTAKE-INPUT.md`
- `data/<id>/packet/NO-MISTAKE.md`
- task field `no_mistake=`

Exit `3` if binary missing (**does not pretend it ran**).

## Policy mapping

| Severity | Action |
|----------|--------|
| Critical | Block completion |
| High | Block unless proven false with evidence |
| Medium | Fix or document |
| Low | Record |
| Unverified AC | Incomplete |

No Mistake does not replace unit tests, CI, or browser validation.
