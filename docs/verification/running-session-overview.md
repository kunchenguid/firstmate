# Running-session overview verification

Audience: maintainer verification.

This record supports the live-session verdict in [`bin/fm-session-inventory.sh`](../../bin/fm-session-inventory.sh), rendered by [`bin/fm-session-view.sh`](../../bin/fm-session-view.sh).
Operator behavior and active limits remain in [`docs/configuration.md`](../configuration.md).
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Why this check is harness-dependent

Whether a background process is a live session working in one home is the only judgement in that inventory that depends on real harness behavior.
A harness pre-warms pooled processes and turns one into a session by claiming it, so the question is which claimed processes belong to this home.

## Claimed processes keep their pool argv

Checked on 2026-09-09 with Claude Code 2.1.236 on macOS 25.5.0, against a home running four concurrent background sessions.

Every one of the four live sessions still presented the argv it was started with as an unclaimed pool process:

```
claude bg-spare --bg-spare /tmp/cc-daemon-501/<daemon>/spare/<claim>.claim.sock
```

Their working directories had all moved to the home they were claimed for, while genuinely unclaimed processes under the same harness stayed in the daemon's own spare directory:

```
claimed    cwd: /Users/koenmuller/Projects/firstmate
unclaimed  cwd: /private/tmp/cc-daemon-501/<daemon>/spare
```

Observed result: argv cannot distinguish a claimed session from an idle spare on this release, and the working directory can.
Reading argv reported those four live sessions as zero, which is the failure the overview exists to prevent; the working-directory rule reported four sessions in the home and sixteen processes belonging elsewhere.

This is why the verdict is built on the working directory, a kernel fact, rather than on any vendor-supplied argv token.

## Refreshing this record

The portable regression in [`tests/fm-session-inventory.test.sh`](../../tests/fm-session-inventory.test.sh) pins the logic in CI with real processes and no harness, including a claimed pool process, two concurrent claimed sessions in one home, and a contradictory argv that must not decide the role.

The live guard exercises every installed harness for real and fails naming the harness and version:

```sh
FM_SESSION_ROLE_DRIFT=1 FM_SESSION_ROLE_HOME=<home> tests/fm-session-inventory-live-e2e.test.sh
```

Run it after every harness upgrade, and before trusting the per-harness observation above.
It refuses a pass that checked nothing and reports an absent harness explicitly rather than passing silently over it.
