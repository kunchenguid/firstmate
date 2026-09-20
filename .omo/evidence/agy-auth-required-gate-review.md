# AGY auth_required gate review

recommendation: APPROVE

## originalIntent

Review the stated source diff read-only and trace an AGY `auth_required` quota snapshot through rule floors, candidate ranking, the legacy chooser, and process-event wake classification.

## desiredOutcome

Every changed auth-required branch must be reachable from its public boundary and must avoid treating stale quota values as dispatchable evidence. Resolver candidates must remain eligible but unranked, expose the exact authentication cause, fabricate no quota values, and emit no AGY dispatch profile.

## userOutcomeReview

The resolver and process-event paths satisfy the requested snapshot behavior. `fm-dispatch-resolve.sh` makes an AGY auth-required rule floor unverifiable before selection, then makes the candidate eligible/unranked before stale rows can veto or rank it; rendering preserves the exact cause and cannot emit an AGY profile when it is the only candidate. `fm-procevent-quota.sh` excludes auth-required AGY rows from quota classification, returns a terminal `error`, and carries the exact auth cause in details.

The chooser path is intentionally resolver-only. Public AGY candidates fail the shared harness/provider validation with `unknown harness: agy` before quota evaluation, and the current chooser has no AGY auth-required branch. Its regression preserves that boundary.

## notes

- `bin/fm-dispatch-resolve.sh:291-313,357-365,382-420` correctly preserves unknown floors, unranked ranking, exact cause, and no AGY profile.
- `bin/fm-procevent-quota.sh:113-146,151-185,244-270` correctly classifies auth-required AGY as a terminal error wake while excluding stale quota rows from `best`.
- Slop/overfit pass: the current chooser has no AGY auth-required branch; `tests/fm-quota-choose.test.sh:563-569` locks the resolver-only rejection boundary. No blocking overfit, tautological, deletion-only, implementation-mirroring, or unnecessary abstraction issue was found in scope.
- No tests were run, per assignment.

## checkedArtifacts

- `bin/fm-dispatch-resolve.sh`
- `bin/fm-quota-axi-lib.sh`
- `bin/fm-quota-choose.sh`
- `bin/fm-procevent-quota.sh`
- `tests/fm-dispatch-resolve.test.sh`
- `tests/fm-quota-choose.test.sh`
- `tests/fm-procevent-quota.test.sh`
- commits `384c69f^..9dd1473`
- `review.log` (local path redacted)

## evidenceGaps

- No original brief, success-criteria artifact, manual-QA matrix, or notepad was present in the worktree/evidence directory.
- The available review log contains repeated empty findings with no reviewed paths or evidence, so it does not demonstrate an independent programming/slop pass.
- Runtime tests were intentionally not executed; conclusions are source-trace only.
