# Gate Review: AGY auth-required quota handling

- recommendation: APPROVE
- blockers: []
- originalIntent: Accept quota-axi schema v5 snapshots whose provider-level quota status is `unknown` while a structurally valid named sub-scope is `known`, then keep AGY `auth_required` evidence non-authorizing and cause-visible across dispatch and quota monitoring.
- desiredOutcome: Live AGY snapshots no longer fail shared validation; known `gemini_only` evidence can be ranked when authentication is valid; `auth_required` AGY cannot produce a dispatch profile and produces a terminal quota error carrying the authentication cause.
- userOutcomeReview: The shipped artifacts satisfy the stated behavior. The shared validator still applies unconditional per-row structural validation. The resolver treats `gemini_only` as applicable, but short-circuits AGY `auth_required` before quota evidence can rank. The simple chooser rejects AGY before quota evaluation. Provider-specific and aggregate quota monitoring classify it as error and include the exact cause. No newly introduced reachable defect was found.

## Criteria checked

- C1 — accept provider `unknown` plus valid known sub-scope: PASS. `bin/fm-quota-axi-lib.sh:45-91`; regression fixtures in `tests/fm-quota-choose.test.sh:285-302` and `tests/fm-dispatch-resolve.test.sh:310-318`.
- C2 — preserve per-row structural validation: PASS. `bin/fm-quota-axi-lib.sh:65-88` still validates known percentages/runway and unknown-row shape unconditionally.
- C3 — never authorize AGY while `state.status == auth_required`: PASS. `bin/fm-dispatch-resolve.sh:308-313,382-395`; `bin/fm-quota-choose.sh:349-358` rejects AGY before evaluation; tests at `tests/fm-dispatch-resolve.test.sh:320-363`.
- C4 — surface exact authentication cause in quota monitoring: PASS. `bin/fm-procevent-quota.sh:114-184`; tests at `tests/fm-procevent-quota.test.sh:226-237`.
- C5 — inspect relevant history, callers, and prior review decisions without executing tests: PASS. Commits `9e5fdbf..9dd1473`, resolver/chooser/process-event call sites, current no-mistakes review logs, and prior evidence were inspected. No tests were run.

## Independent programming and slop pass

- No useless deletion-only, tautological, implementation-mirroring, or prose-pin tests were introduced in the quota series. The tests drive the executable shell surfaces and assert observable selection/classification output.
- No new dependency or speculative abstraction was introduced. The small jq predicates are local to the consumers that need distinct behavior.
- NOTE: the broad requested range includes unrelated earlier commits and `git diff --check` reports a blank line at EOF in `tests/fm-ensure-agents-md.test.sh:440`; this is not tied to the quota success criteria and is not a blocker.
- NOTE: `fm-quota-choose.sh` does not treat `gemini_only` as an applicable ordinary AGY scope. The stated intent targeted the typed resolver, and the helper's documented contract covers provider-wide and exact model/product scopes, so this is outside the stated criterion rather than a failed requirement.

## Checked artifacts

- Diff: `1bb72cc5f88014c86e3d03244efa0bb26c22d001..9dd1473248d12481f6b560a5cee0dc6fa9e7175e`
- Production: `bin/fm-quota-axi-lib.sh`, `bin/fm-dispatch-resolve.sh`, `bin/fm-quota-choose.sh`, `bin/fm-procevent-quota.sh`
- Tests: `tests/fm-quota-choose.test.sh`, `tests/fm-dispatch-resolve.test.sh`, `tests/fm-procevent-quota.test.sh`
- Contracts: `.agents/skills/quota-array-dispatch/SKILL.md`, `.agents/skills/process-event-sources/SKILL.md`, `docs/configuration.md`, `docs/scripts.md`
- Prior evidence (local paths redacted): manifest.json, agy-auth-required-live-quota.json, fm-dispatch-resolve-auth-required.log, and two review.log runs.

## Exact evidence gaps

- No current code-review report explicitly documents the required programming/remove-ai-slops perspective; this independent gate pass supplies that coverage.
- No manual QA matrix or notepad artifact was provided for this attempt.
- Tests were intentionally not executed under the assignment constraint. Existing executor logs are treated only as prior evidence, not reproduced test proof.
