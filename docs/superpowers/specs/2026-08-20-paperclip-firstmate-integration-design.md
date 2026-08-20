# Paperclip–FirstMate Integration Design

## Purpose

Enroll the existing FirstMate coding crew as the implementation worker in Paperclip, while preserving FirstMate's isolated-worktree model and Paperclip's durable task history.

## Architecture

Paperclip will hold a dedicated `FirstMate` agent that reports to `OpenClaw`. Its runtime identity is separate from the Hermes and OpenClaw identities. A small Paperclip adapter/service will submit eligible implementation tasks to the existing authenticated FirstMate realtime bridge on `coding.vthq.net`; FirstMate continues to run work in its existing tmux session and isolated git worktrees.

Hermes remains the user-facing coordinator. It creates and clarifies work in Paperclip. FirstMate implements it. OpenClaw reviews the outcome, may make bounded corrective changes, and sets the Paperclip task outcome. Hermes reports the resulting state to the user.

## Boundaries

- Reuse the current FirstMate runtime and bridge; do not create a VM or a second coding fleet.
- Do not change UFW, router, or other firewall policy.
- Do not expose credentials in Paperclip configuration, source control, logs, or task comments.
- Give each runtime its own scoped Paperclip key; revoke only that key if the integration is retired.
- Preserve the existing uncommitted Paperclip source changes.

## Data Flow

1. Hermes creates an implementation task in Paperclip and assigns it to FirstMate.
2. The FirstMate adapter fetches only that agent's assigned, actionable task.
3. It sends a normalized brief over the existing authenticated bridge.
4. FirstMate executes through its normal worktree and crew lifecycle, then emits status and completion evidence.
5. The adapter posts a concise status/result back to the task.
6. OpenClaw receives the completed task for review, records its outcome, and returns it to FirstMate only when rework is needed.
7. Hermes summarizes the final result to the user.

## Failure Handling

- If the bridge or FirstMate is offline, leave the task actionable and record a retryable transport status; do not mark it complete.
- Deduplicate dispatch by Paperclip task/run identifier so restarts cannot create duplicate worktrees.
- Fail closed for missing credentials, untrusted bridge responses, or unsupported task states.
- The initial validation task is read-only and makes no repository or production changes.

## Verification

- Verify FirstMate bridge authentication and health without submitting work.
- Verify one Paperclip task reaches FirstMate and receives a structured status update.
- Run one bounded no-change task end-to-end: Hermes → FirstMate → OpenClaw → Hermes.
- Confirm no secrets enter Paperclip task content or logs.
