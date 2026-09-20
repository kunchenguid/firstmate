# Final gate review: AGY auth-required quota routing

## recommendation

REJECT

## originalIntent

Read-only security/privacy and authorization review of the branch, limited to changed code and surrounding callers, with concrete reachable sequences for whether AGY `auth_required` can authorize dispatch, expose stale quota, or misclassify failure through alternate paths.

## desiredOutcome

Every reachable dispatch path must prevent an AGY provider in `state.status: auth_required` from authorizing an AGY dispatch; stale quota from that provider must not be represented as usable; failure/event classification must preserve the actual terminal condition. Findings must be source-backed. No tests were to be run.

## userOutcomeReview

The typed resolver itself meets the narrow auth-required outcome: `bin/fm-dispatch-resolve.sh:312-313` makes AGY eligible-but-unranked before quota-row evaluation, `bin/fm-dispatch-resolve.sh:383-390` excludes unranked candidates from selection, and `bin/fm-dispatch-resolve.sh:418-420` emits a profile only for a chosen candidate. The provider-specific process-event path also suppresses stale AGY quota details at `bin/fm-procevent-quota.sh:138-143,179-184`.

The branch does not close the authoritative fallback intake path, and aggregate process-event classification can report the wrong terminal condition. Those are reachable alternate paths named by the review brief, so the user-visible outcome is not satisfied.

## blockers

### AUTH-1 — auth_required AGY must not authorize dispatch through any reachable path

- **Observation:** The auth guard exists only in the optional typed resolver. With no `TYPESAFE_API_KEY`, the resolver exits off (`bin/fm-dispatch-resolve.sh:101-107`), and the mandatory policy returns every off/non-clear result to the ordinary intake (`AGENTS.md:132`; `docs/configuration.md:498,511-513`). That authoritative intake says missing/unmodeled authentication remains eligible (`AGENTS.md:125-126`) and the skill identifies auth-required only as an attention fact (`.agents/skills/quota-array-dispatch/SKILL.md:74`) without declaring AGY `state.status: auth_required` a dispatch veto (`.agents/skills/quota-array-dispatch/SKILL.md:81-91`). A reachable sequence is: resolver key absent -> resolver off -> AGY profile in matched rule/default -> snapshot reports AGY `auth_required` -> fallback intake retains the candidate as eligible -> operator/agent may select and pass AGY to `fm-spawn`.
- **Source-boundary note:** `.agents/skills/quota-array-dispatch/SKILL.md:24-30` documents the worker helper's narrow primary-provider contract. The current `bin/fm-quota-choose.sh` has no AGY auth-required branch; `bin/fm-quota-axi-lib.sh:116-134` has no AGY mapping and `tests/fm-quota-choose.test.sh:563-569` requires every AGY candidate to fail as an unknown harness. This resolver-only boundary does not cover the authoritative fallback.
- **violatedCriterion:** AUTH-1
- **evidencePointer:** `bin/fm-dispatch-resolve.sh:101-107`; `AGENTS.md:125-126,132`; `.agents/skills/quota-array-dispatch/SKILL.md:74,81-91`; `bin/fm-quota-choose.sh:349-358`; `bin/fm-quota-axi-lib.sh:116-134`; `tests/fm-quota-choose.test.sh:563-569`

### FAIL-1 — alternate paths must not misclassify the terminal quota/auth condition

- **Observation:** Aggregate quota polling gives any AGY auth-required row unconditional precedence over all other providers (`bin/fm-procevent-quota.sh:129-136`). Concrete sequence: arm the aggregate source (no `--provider`), return AGY `auth_required` plus a Codex row with `runway.status: exhausted_now`; `classify()` would return `exhausted` (`bin/fm-procevent-quota.sh:121-127`), but it is never called because `$auth` is non-empty, so the published status is `error`. The detail retains both providers (`bin/fm-procevent-quota.sh:165-177`), but the machine-consumed terminal status is misclassified.
- **violatedCriterion:** FAIL-1
- **evidencePointer:** `bin/fm-procevent-quota.sh:121-136,165-177,244-255`

## notes

- No stale AGY percentage/profile exposure was found in the typed resolver or process-event detail paths. Resolver auth handling occurs before quota-row evidence is attached (`bin/fm-dispatch-resolve.sh:308-314`); process-event details emit `best: null` and the auth cause (`bin/fm-procevent-quota.sh:171-183`).
- Direct remove-ai-slops pass: the resolver tests assert observable profile absence and exact auth disclosure, not implementation internals. The current chooser rejects AGY before quota evaluation and contains no stale auth-required branch. No unrelated style finding is promoted to a blocker.
- Direct programming pass: auth state is interpreted separately in three shell consumers instead of being enforced at the authoritative policy boundary. This duplication is relevant because one authoritative path remains unguarded; no architecture preference beyond the stated authorization criterion is used as a blocker.
- `git diff --check` reports a pre-existing/new whitespace issue at `tests/fm-ensure-agents-md.test.sh:440`; it is outside the stated security criteria and is not a blocker.

## checkedArtifacts

- Branch diff from `merge-base(HEAD, origin/main)` through `9dd1473`
- `bin/fm-dispatch-resolve.sh`
- `bin/fm-quota-choose.sh`
- `bin/fm-procevent-quota.sh`
- `bin/fm-quota-axi-lib.sh`
- `.agents/skills/quota-array-dispatch/SKILL.md`
- `AGENTS.md`
- `docs/configuration.md`
- `tests/fm-dispatch-resolve.test.sh`
- `tests/fm-quota-choose.test.sh`
- `tests/fm-procevent-quota.test.sh`
- `programming/SKILL.md` (local path redacted)
- `remove-ai-slops/SKILL.md` (local path redacted)

## exactEvidenceGaps

- No original brief, success-criteria artifact, executor evidence directory, code-review report, manual-QA matrix, or notepad path was present in the worktree/evidence directories. The review therefore uses the user's current task text as the explicit criteria and independently inspects the artifacts.
- `omo ulw-loop status --json` returned `ULW_LOOP_PLAN_MISSING`; this report uses the required fallback evidence path.
- Tests were not run, per the user's explicit instruction. All sequences above are static reachability proofs from source and policy.
- No existing code-review report was available to confirm separate programming/remove-ai-slops coverage; the direct passes are recorded above.
