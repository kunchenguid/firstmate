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

Recorded on Darwin 26.5.2 (arm64) with GNU bash 3.2.57, jq 1.7.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
Every consumer in these cases is a fake executable, so no provider adapter, private handoff, or provider evidence is involved.

```console
$ bin/fm-test-run.sh tests/fm-domain-review-consume.test.sh
ok - matching exact-head result is consumed without forwarding provider-private fields
ok - matching code cannot consume a result for another repository identity
ok - accepted results are bound to the exact current product HEAD
ok - dirty product worktrees stop before provider code runs
ok - the exact clean head binding is re-checked after the consumer returns
ok - an unadopted protocol version cannot broaden policy
ok - provider-owned review labels remain visible without private core semantics
ok - blocked, invalidated, and error consumer outcomes remain non-consumable
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

```console
$ bin/fm-test-run.sh tests/fm-brief.test.sh
ok - fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe
ok - fm-brief.sh: faster paths use configured authority without stacked review
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
$ bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=70 local_links=251
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

`tests/fm-brief.test.sh` covers the brief contract far beyond this extension, so only the two assertions this record depends on are reproduced above: the first owns the approved single-step skip wording, and the second holds direct-PR and local-only briefs free of any consumption step.
Re-run every command above and refresh this section whenever the extension contract changes.
The private task audit retains task chronology and provider-specific migration evidence; neither belongs in this upstream-facing maintainer record.
