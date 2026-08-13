---
name: consumed-domain-review
description: >-
  Agent-only policy for consuming a versioned exact-head domain-review result as the review input to delivery without adding or repeating an independent review. Use before treating any prior domain review as a delivery input, before authorizing a no-mistakes review skip from such a result, and whenever code or identity changes may have invalidated a consumed result.
user-invocable: false
metadata:
  internal: true
---

# consumed-domain-review

This skill is the single owner of Firstmate's consumed-domain-review decision policy.
A producer-specific consumer remains authoritative for its artifact schemas, integrity, evidence, review modes, findings, and invalidation mechanics.
Firstmate never recreates those checks from prose and never turns this exception into another review pipeline.

## Applicability

Apply this policy only when an authorized domain workflow supplies a private delivery handoff and an explicitly selected external consumer implementing the neutral protocol in [`docs/consumed-domain-review.md`](../../../docs/consumed-domain-review.md).
Provider adapters, provider allowlists, product names, internal evidence, and operating strategy stay with their producer or in the home-local gitignored `config/` and `data/` surfaces.
They do not belong in Firstmate's tracked core.
No consumer is discovered from an untrusted handoff, repository, or environment value.
A colleague-PR review, sanitized comment, report without a machine consumer, or unsupported protocol version is not consumable under this policy.

Consumption changes behavior only for a task whose selected path is `no-mistakes`.
A `direct-PR` or `local-only` path already has no independent pipeline review to replace, so a result does not add a review, remove a delivery step, or change authority.
A `no-mistakes-prod-only` registry posture has no direct runtime meaning here because intake must already have resolved it to one concrete task path.
A result is an input to one delivery attempt, never a fourth delivery mode and never a standing project posture.

The policy is independent of the primary runtime, worker runtime, and provider review mode.
Use `harness-adapters` for the worker's version-specific no-mistakes invocation form, and do not add runtime-specific receipt rules.

## Admission decision

1. Resolve the task's project and expected repository identity independently of the handoff.
   Never derive the expected identity or consumer executable from the artifact being tested.
2. Require the handoff and provider evidence to remain in their authorized private location.
   Never copy finding prose, evidence URLs, reviewer identities, credentials, or private repository names into a brief, status event, no-mistakes intent, PR, or captain-facing message.
3. Run `bin/fm-domain-review-consume.sh` with the trusted external consumer, private handoff, exact clean product worktree, and independently resolved repository identity.
   The external consumer owns provider-specific validation and emits `firstmate-domain-review-consumption.v1` only after acceptance.
   Firstmate's adapter independently enforces the clean exact repository root, expected repository identity, current HEAD, neutral protocol version, and an allowlisted output that cannot forward provider-private fields.
4. Admit the result only when that command exits zero with an accepted normalized result.
   Nonzero consumer exits retain their provider-defined meaning, while exit 13 means the extension point or Firstmate binding was incompatible.
5. Treat unresolved findings through the existing authority rules.
   The implementation worker never approves its own domain-review findings, and a nonaccepted result never authorizes a review skip.
6. On any missing or untrusted consumer, unsupported version, malformed result, repository mismatch, head mismatch, dirty worktree, changed artifact, nonaccepted review, or prior invalidation, do not consume the result.
   Route a fresh matching domain review when the task still intends to use this exception; otherwise run the selected delivery path's ordinary review behavior.

Do not accept a verbal statement that review passed, a status line, a report path, a matching branch name, a short commit id, or a pull request as a substitute for the accepted machine result.

## No-mistakes handoff

After admission, send the same task worker one exact instruction that identifies only the accepted receipt digest, product head, diff digest, review mode, and quality label.
Do not expose private provider data or repository identity in the worker instruction.
Tell the worker to use the installed no-mistakes version's `axi run --help` syntax to skip exactly the `review` step and no other step while preserving the complete accepted task intent.
The consumed domain review is the no-mistakes review input for that exact code identity, not permission to add another independent reviewer before or during delivery.

Every other no-mistakes owner and boundary remains unchanged:

- the same task worker drives the run and every response;
- no-mistakes retains branch custody and owns all in-run fixes;
- tests, documentation, lint, push, PR creation, and CI still run;
- findings still follow Firstmate's authority procedure;
- the worker does not hand-edit, commit, abort, restart, or start a second run while no-mistakes owns the branch;
- captain decisions, configured merge authority, the red-PR prohibition, and guarded landing remain intact.

A skipped no-mistakes review is valid only for the accepted result's exact head and diff.
Never convert it into a project default, a remembered exemption, or authority to skip review on a later run.

## Invalidation after admission

Any committed or uncommitted change after admission invalidates consumption, including a code, test, documentation, generated-file, or pipeline-fix change that moves the head, changes the canonical diff, or dirties the reviewed worktree.
A repository-identity mismatch also invalidates consumption even if commit and diff bytes happen to match.
Resetting to an old commit never revives a result that its producer marked invalidated.

When code identity changes before no-mistakes starts, return through the producer's invalidation and fresh-review path before choosing the review skip again.
When no-mistakes changes code under active branch custody, do not interrupt its supported response flow and do not edit around it.
Withhold delivery readiness, let the current gate or outcome settle under no-mistakes ownership, then obtain a fresh exact-head domain review for the delivered head in a clean authorized worktree.
If that review requires a fix, apply the existing no-mistakes branch-sync and custody procedure before any follow-up run.
Never let an external reviewer or implementation worker take the branch mid-run.

A pull request and green CI are not ready for captain review until the latest delivered head has both the selected delivery path's required results and an accepted matching domain-review result.
If the final head differs, report the concrete review blocker rather than presenting stale review evidence as success.
