# Delivery posture

The registry records the project's standing delivery posture and optional ship-branch prefix, which are the captain's defaults rather than any task's answer.
`AGENTS.md` section 7 owns how each task's concrete mode, yolo, and branch prefix are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
- `no-mistakes-prod-only` is a conditional policy rather than one flat mode: genuinely internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`.

`no-mistakes-prod-only` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch, and record a flat mode instead whenever they ask for one.
Existing registry entries keep the meaning they already have and are never migrated or reinterpreted, so a legacy entry with no bracket stays `no-mistakes`.
Registering a conditional policy is a one-time choice and never requires classifying any change; the per-task surface classification happens at each task's intake, and internal-only is never inferred from file location or project name.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

The optional `forge=` token records which forge the project's remote actually is; its values are `forge=gerrit`, `forge=forgejo`, and `forge=external`.
It is orthogonal to the mode and to `+yolo`, so it is never derived from either, and it is never inferred at use time from a remote name, host, port, or push target.
At add or create intake, run `bin/fm-forge-detect.sh projects/<name>` once the clone exists and propose its answer alongside the posture; the captain's confirmation is what binds it, and the registry token is the durable record of that confirmation.
Never register the binding from detection alone, and never re-derive it later from the clone.
`bin/fm-forge-detect.sh` never proposes `forge=forgejo`, so for a remote that may be Forgejo or Gitea ask the captain and register `forge=forgejo` only on that confirmation.
A forge composes with `no-mistakes`, `direct-PR`, and `no-mistakes-prod-only` (`forge=external` with `direct-PR` only), and the registry refuses it on `local-only`, which publishes nothing; a Gerrit-hosted project kept local registers `local-only` with no forge token.
`yolo` is inactive on a `forge=gerrit` project, so never propose `+yolo` alongside it.
`forge=external` marks a project whose review tool uploads its own snapshot, so workers never push a task branch to its shared origin: it is never detected, so register it only on the captain's confirmation, as `[direct-PR forge=external]` with no `+yolo`, and only once the home has `config/external-review.md` (`docs/configuration.md` "External review tool").
`bin/fm-project-mode.sh`'s header owns the binding and `bin/fm-dod-lib.sh` owns what it changes for a worker.
The optional `pr=manual` token marks a `no-mistakes` project whose PR title and body a person writes, so the pipeline's `pr` step must not rewrite them; register it only on the captain's confirmation, with no `forge=` token (`docs/configuration.md` "PR text selection").
