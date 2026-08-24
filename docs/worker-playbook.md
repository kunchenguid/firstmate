<!--
Worker SOFT playbook - the swappable working-style layer spliced into every
generated crewmate brief by bin/fm-brief.sh (the HARD skeleton names no skill;
this doc names them). A per-home override at config/worker-playbook.md replaces
this file wholesale when present. Editing this doc changes the fleet's worker
working style with no code change (story fmops-07 §2; architecture.md §7).
Derived from the epic playbook draft; keep it model-invoked only (no dependency
on the `ak` CLI binary) and keep the firstmate engine the coordination substrate.
-->

# Worker playbook - the delivery spine

The phase SEQUENCE is HARD: the brief skeleton enforces ground-reality -> plan
-> plan-review GATE -> implement -> test -> review -> ship, and it names the
native report path.
WHICH skill runs each phase is this SOFT map, and a home swaps any cell by
editing one file.
Every skill here is model-invoked (`Skill(...)` / `/ak:name`) or fires from a
harness hook; nothing depends on the `ak` CLI binary, which is not installed.

```
scout ─▶ [brainstorm] ─▶ plan ─▶ «GATE» ─▶ implement ─▶ test ─▶ review ─▶ [security] ─▶ commit ─▶ ship
ak:scout   ak:brainstorm  ak:plan  firstmate   ak:cook    ak:test  ak:code-  ak:security   ak:git   delivery
           (open approach)         plan-review             review   (auth/PII/tokens/IO)             path
```

Bug tasks insert `ak:debug -> ak:fix` after scout.
ponytail (the lazy-senior laziness ladder, a SessionStart mode) governs HOW
every phase runs: reuse before build, smallest correct diff, one runnable check.
`ck:*` is excluded - it is being removed in favor of `ak:*`.

## Use-case -> skill route

| Use-case | Route (model-invoked skills) | Verify / gate |
|---|---|---|
| Build a feature | `ak:scout` -> `ak:brainstorm` (if approach open) -> `ak:plan` -> **GATE** -> `ak:cook` -> `ak:test` -> `ak:code-review` (-> `ak:git`) | independent review before ship; mandatory at high risk |
| Fix a bug / red CI | `ak:scout` -> `ak:debug` -> `ak:fix` -> `ak:test` | root-cause not symptom (ponytail); `ak:debug` again after 2 failed attempts |
| Investigate / understand (scout task) | `ak:scout` -> `ak:ask`/`ak:debug` -> report | no mutation links; report at the native path |
| Refactor | `ak:scout` -> `ak:plan` -> **GATE** -> `ak:cook` -> `ak:test` (+ simplify pass) | regression tests; simplify changed code only |
| Research a technology | `ak:research` (or `ak:docs-seeker` for library docs) | evidence-backed; artifact, not code |
| Review code / PR | `ak:code-review` (pending/PR/commit) | independent reviewer for cross-module/security |
| Security-sensitive surface | `ak:security` (STRIDE+OWASP) or `ak:security-scan` | insert whenever auth/PII/tokens/external I/O are touched |
| Write / refresh docs | `ak:docs` (root context file via `ak:docs`; subfolder via `ak:folder-context`) | accuracy checked against the change |
| Domain build | pull the domain skill by intent: `ak:backend-development`, `ak:frontend-development`/`ak:frontend-design`, `ak:mobile-development`, `ak:databases`, `ak:web-frameworks`, `ak:better-auth`, `ak:payment-integration`, ... | domain skill rides inside the `implement` phase |
| Commit / open PR | `ak:git` (conventional commits, secret scan) or `ak:github` (`gh` lifecycle) | secret scan before push |

The worker does not need the `ak` CLI for any of these - they are skill packs
the model loads on demand, and the worker's own harness hooks (ponytail
SessionStart + the kit's UserPromptSubmit rules router) supply the live bundle at
runtime, so the worker runs the current tools even with no override.
