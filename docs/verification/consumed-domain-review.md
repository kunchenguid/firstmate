# Consumed domain-review verification

- **Evidence date:** 2026-08-13
- **Extension contract:** `firstmate-domain-review-consumption.v1`

## Scope

This record verifies the neutral boundary between Firstmate delivery and an explicitly selected external domain-review consumer.
Provider-specific adapters, schemas, identities, findings, and evidence remain outside tracked core and are intentionally not recorded here.

## Commands

Run the focused behavior and documentation checks with:

```sh
bin/fm-test-run.sh tests/fm-domain-review-consume.test.sh
bin/fm-test-run.sh tests/fm-brief.test.sh
bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

Expected guarantees are:

- a trusted external consumer receives the opaque handoff, exact clean product root, and independently resolved repository identity;
- an accepted result passes only when its neutral protocol version, repository identity, current product head, strategy, and digest shapes match;
- a dirty product worktree stops before external provider code runs, and a worktree the consumer moved or dirtied stops before any accepted result is emitted;
- an unreadable worktree state refuses instead of admitting an unverified tree;
- a repository mismatch, stale accepted head, incompatible protocol version, malformed result, or nonaccepted outcome cannot authorize a review skip;
- provider-owned review and quality labels remain visible without a provider-specific core allowlist;
- provider-private fields beyond the normalized protocol are not forwarded;
- consumer blocked, invalidated, and error exits and output remain unchanged;
- a no-mistakes brief permits only an explicit policy-approved skip of the duplicate review step and retains every other pipeline stage;
- direct-PR and local-only briefs gain no review or skip behavior;
- every maintained prose surface and owner pointer remains classified.

## Recorded result

Refresh this section with the exact final-head output from the commands above whenever the extension contract changes.
The private task audit retains task chronology and provider-specific migration evidence; neither belongs in this upstream-facing maintainer record.
