---
name: primary-session-handoff
description: >-
  Agent-only procedure for scanning primary-provider captain actions and safely transferring or restoring the live Firstmate primary session.
  Use after a live session-lock refusal when the current provider is idle but unavailable, or whenever primary takeover, suspension, restoration, or a fleet-wide permission scan is requested.
user-invocable: false
metadata:
  internal: true
---

# primary-session-handoff

Use this procedure after a live session-lock refusal when the current provider is unavailable, or whenever primary takeover, suspension, restoration, or a fleet-wide permission scan is requested.

Load `harness-adapters` before this skill performs a provider suspend or resume.
Read `bin/fm-primary-session.sh --help` before the first command because that script owns supported providers, exact mechanics, receipt states, and flags.

## Read-only triage

Run the command's fleet-wide scan before considering a transfer.
The scan reports structured pending permissions and captain-action markers without prompt, title, or permission prose.
Treat every listed action as unresolved until the owning session or captain resolves it.

Identify the exact external session requested for takeover from the visible provider inventory.
Do not infer identity from a title, transcript, terminal label, provider name, or working directory.

## Takeover

Invoke the owned takeover command with the exact external session id.
Do not call a provider archive command separately, pass a force flag, delete `state/.lock`, or edit the owner descriptor.

Only `idle` and `paused-rate-limited` are eligible outcomes.
`waiting-on-captain`, `busy`, `wedged`, `unknown`, and `unsupported` are refusals, not invitations to approximate the operation manually.

After success, read the ordinary session-start digest once and follow its emitted supervision block.
Preserve the printed receipt path so the suspended provider can be restored later.

## Restore

Restore only from the receipt created by the owned takeover command.
Ensure the successor primary has exited normally before requesting restoration, because a live or ambiguous lock owner is a hard refusal.

Invoke the owned restore command and do not call the provider reload command separately.
The reloaded provider remains mutation-ineligible until its native session-start nudge runs the ordinary lock-acquisition contract.
If another primary wins that acquisition, the restored provider stays read-only and reports the normal lock refusal.

## Unsupported or failed operations

Report an unsupported combination with the command's exact classification.
Leave the provider, numeric lock, owner descriptor, receipt, fleet state, task worktrees, and wake queue untouched after a refusal.
Never turn an incomplete suspension receipt into permission to delete or overwrite a live lock.
