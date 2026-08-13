# Consumed domain reviews

The agent-runtime policy for deciding whether a prior domain review may replace delivery's duplicate independent review is owned by [`consumed-domain-review`](../.agents/skills/consumed-domain-review/SKILL.md).
This page owns the neutral extension protocol and maintainer-facing integration boundaries without copying that decision procedure.

## Ownership

A provider-specific consumer owns its handoff schemas, artifact integrity, evidence requirements, exact head and diff rules, modes, finding disposition, and invalidation state.
Provider adapters, private product names, provider allowlists, and operational evidence remain with that producer or under Firstmate's gitignored home-local `config/` and `data/` surfaces.
Tracked Firstmate core does not discover a consumer from handoff bytes or carry provider-specific semantics.

[`bin/fm-domain-review-consume.sh`](../bin/fm-domain-review-consume.sh) invokes one explicitly selected external consumer and preserves its nonzero result.
It adds Firstmate-side checks for a clean exact repository root, current product head, and the repository identity Firstmate resolved independently at intake.
On acceptance it emits only allowlisted neutral fields, so extra provider data cannot cross into delivery by accident.
Its header and `--help` output own the exact command and exit mechanics.
It neither reviews code nor runs delivery.

`AGENTS.md` owns the always-loaded trigger and the invariant that consumption replaces only an independent review.
[`bin/fm-brief.sh`](../bin/fm-brief.sh) reinforces that a no-mistakes worker may omit exactly its review step only after Firstmate supplies an accepted result under the policy.
The installed no-mistakes skill and current `axi` help remain authoritative for skip syntax, fixes, tests, documentation, lint, push, pull request creation, CI, and branch custody.

## Consumer protocol

Firstmate invokes the trusted executable as `<consumer> consume <handoff> --repo <exact-root> --repository <expected-identity>`.
The handoff remains opaque to core.
A successful consumer prints exactly one JSON object whose provider-independent fields are:

```json
{
  "ok": true,
  "schema_version": "firstmate-domain-review-consumption.v1",
  "status": "accepted",
  "repository": "independently-comparable-identity",
  "receipt_sha256": "64 lowercase hexadecimal characters",
  "product_head_sha": "the exact 40- or 64-character Git object id",
  "diff_sha256": "64 lowercase hexadecimal characters",
  "review_mode": "provider-owned nonempty label",
  "quality_label": "provider-owned nonempty label",
  "review_strategy": "consume-existing-exact-head-domain-review",
  "independent_review_required": false
}
```

The adapter rejects every other protocol version, status, strategy, repository identity, head, or digest shape.
It allows provider-defined review and quality labels because their semantics and acceptance belong to the selected consumer, then preserves those labels visibly in the normalized result.
Fields beyond the listed normalized result are discarded after validation rather than forwarded to the delivery worker.
A provider that cannot emit this contract needs a provider-local adapter instead of a new core branch.

The consumer executable and handoff must each be regular non-symlink files.
Firstmate selects the consumer independently of untrusted artifact content.
The exact worktree must be clean before provider code runs, and the accepted head must still equal that worktree's current `HEAD` after the consumer returns.

## Runtime and delivery applicability

The admission decision and adapter use data, process exit, Git, and JSON rather than rendered runtime output, hooks, trust dialogs, or runtime-specific skill commands.
The same protocol therefore applies across supported primary and worker runtimes.
The provider's review mode describes the review that produced the handoff and need not equal either runtime.

Which delivery paths an accepted result affects, and what it may never change, is owned by [`consumed-domain-review`](../.agents/skills/consumed-domain-review/SKILL.md).

## Verification

Behavioral coverage lives in [`tests/fm-domain-review-consume.test.sh`](../tests/fm-domain-review-consume.test.sh), and active extension-contract evidence lives in [`docs/verification/consumed-domain-review.md`](verification/consumed-domain-review.md).
Run the documentation classification check after changing any of these owner pointers.
