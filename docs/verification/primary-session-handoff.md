# Primary-session handoff verification

Audience: maintainer verification.

This record supports the current recoverable primary-session handoff guarantee.
Operator behavior, supported combinations, and current limits remain in [`../primary-session-handoff.md`](../primary-session-handoff.md).

## Incident-derived contract

The missing primitive was reproduced on 2026-07-29 with Paseo 0.1.104 and Claude Code 2.1.219.
A live but idle credit-exhausted provider still correctly owned Firstmate's numeric lock, so another primary was refused even though a recoverable soft archive could safely stop that provider.
The manual incident recovery established the shipped ordering: prove visible-session ownership and idle safety, soft-archive the exact provider, prove its process tree has exited, use ordinary stale-lock acquisition, and require the restored provider to reacquire through normal session start.

No live provider lifecycle command is part of repository verification.
All suspend, reload, quota, permission, child-agent, and process-tree behavior is exercised through an isolated disposable Firstmate home and fake Paseo executable.

## Deterministic regression

Run:

```sh
bin/fm-test-run.sh tests/fm-primary-session.test.sh
```

The suite covers external-session and process-identity owner mismatch, busy and pending-action refusal, unknown and wedged classification, attached-child refusal, provider suspend failure, a surviving owner pid, successful stale-lock takeover, concurrent attempts, restore refusal under a live successor, restored normal lock reacquisition, fleet-state preservation, and the privacy-safe read-only scan.

The expected terminal lines include:

```text
ok - primary-session: concurrent takeover attempts admit one suspension and one successor
ok - primary-session: archived provider reload remains recoverable and reacquires through normal session start
ok - primary-session: fleet-wide captain-action scan is read-only and omits prompt/title prose
```

Related lock, startup, and native-nudge regressions are:

```sh
bin/fm-test-run.sh \
  tests/fm-claude-stop-autoarm.test.sh \
  tests/fm-session-start.test.sh \
  tests/fm-sessionstart-nudge.test.sh \
  tests/fm-watcher-lock.test.sh
```

Repository structural validation remains:

```sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
bin/fm-test-run.sh --lane portable-parallel-1 --jobs 4
bin/fm-test-run.sh --lane portable-parallel-2 --jobs 4
bin/fm-test-run.sh --lane portable-serial
```

The real-Herdr lifecycle lane is separate and opt-in. It is not part of this
handoff verification because the task's Herdr lifecycle safety gate was not
enabled.
