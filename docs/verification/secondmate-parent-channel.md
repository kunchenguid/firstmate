# Secondmate parent channel: verification status

Maintainer-verification status for the guarantee in [`secondmate-parent-channel.md`](../secondmate-parent-channel.md): a captain-facing outcome recorded inside a secondmate home reaches the parent channel without the mate model writing it.
After changing any publisher named in `bin/fm-parent-channel-lib.sh`, refresh the portable regression owners below and record a new live run separately if one is performed.

## Retired live evidence

The dated 2026-09-03 transcript is no longer retained because its fixture encoded a retired delivery mode in task metadata and every emitted status line.
The historical output was removed rather than rewritten because no replacement experiment was run.
There is currently no maintained live transcript for this channel.

## Current regression owners

[`tests/fm-inactive-reconcile.test.sh`](../../tests/fm-inactive-reconcile.test.sh) covers mode-independent child outcome delivery, receipt idempotence, the remote route, and the real watcher poll.
[`tests/fm-captain-hold-lifecycle.test.sh`](../../tests/fm-captain-hold-lifecycle.test.sh) covers a mate home's hold, answer, and re-hold publication.
[`tests/fm-pr-merge.test.sh`](../../tests/fm-pr-merge.test.sh) covers PR-ready registration and merge-outcome publication.
[`tests/fm-teardown.test.sh`](../../tests/fm-teardown.test.sh) covers final child delivery with a current local-only fixture and refusal while the parent channel is unavailable.
[`tests/fm-pending-reply.test.sh`](../../tests/fm-pending-reply.test.sh) covers correlated local and remote replies, guarded restatement, and wrong-home handling.
[`../secondmate-parent-channel.md`](../secondmate-parent-channel.md) remains the architecture owner for the channel contract and its generic safety boundary.
