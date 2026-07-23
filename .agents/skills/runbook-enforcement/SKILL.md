---
name: runbook-enforcement
description: Enforce durable, execution-first runbooks for delegated or long-running work. Use when starting, supervising, retrying, or reporting work that needs a command, observable evidence, a deadline, and an unambiguous completion condition.
---

# Runbook Enforcement

## Commit the runbook first

Before saying work is underway, durably record a manifest in the task record, issue, or repository state.
Include every field:

```markdown
- command: <exact command or action>
- receipt: <where command start, exit, and result are recorded>
- artifacts: <expected output paths, IDs, logs, or PRs>
- freshness predicate: <how to prove artifacts came from this run>
- timeout: <deadline and clock>
- safe retry: <idempotent retry command and preconditions>
- terminal predicate: <observable success or failure condition>
```

Do not use an undurable plan, a pane-only claim, or a generic state such as "investigating," "monitoring," or "in progress."
Name the command, evidence, and terminal condition instead.

## Execute and prove

Start the recorded command before spending tokens on commentary or diagnosis.
Treat a diagnostic command as execution only when it is in the manifest and has its own receipt and terminal predicate.

Use artifact existence, contents, timestamps, exit status, process health, and the freshness predicate as truth.
Treat pane text, spinners, and agent claims as hints only.

At the deadline, declare the run **stalled** durably.
Do not extend the deadline silently.
Retry only with the recorded safe retry after its preconditions hold; record the retry receipt and a new explicit deadline.
Otherwise report the stall with the missing artifact or failed health evidence.

## Follow up cheaply

Use zero-token polling for routine follow-up: watchers, exit checks, artifact checks, process probes, and CI/status APIs.
Wake an agent only for a terminal result, a deadline, a failed predicate, or a decision that changes the runbook.

Declare completion or failure only when the terminal predicate and freshness predicate are both satisfied.
Preserve receipts and artifacts with the final status so the result remains auditable after the pane disappears.
