# Recoverable primary-session handoff

Firstmate can transfer primary orchestration away from an idle local Paseo-hosted Claude or Codex session without weakening the live session lock or losing the provider transcript.
The transfer soft-archives the exact recoverable provider session, proves its captured process tree has stopped, acquires the unchanged numeric lock through the ordinary stale-owner path, and runs normal session start for the successor.

Use the command family directly or let the first mate follow the agent-only `primary-session-handoff` procedure:

```sh
bin/fm-primary-session.sh scan
bin/fm-primary-session.sh takeover <paseo-agent-id>
bin/fm-primary-session.sh restore <receipt-id>
```

Run `bin/fm-primary-session.sh --help` for the authoritative command mechanics, inputs, outputs, and receipt-state contract.

## Safety boundary

`state/.lock` remains the sole authoritative primary lock.
Successful ordinary acquisition also publishes `state/.lock.owner`, a replaceable identity descriptor that binds the numeric owner and process-identity hash to its harness and local Paseo identity when present.
The takeover command serializes against ordinary acquisition, proves the requested visible session is the live lock owner, and never unlinks or overwrites a live owner's lock.

A pre-descriptor session can qualify only when its exact persistent provider-session id appears as a complete argument in the lock-owner command and is unique among visible Paseo agents.
If either proof is missing or ambiguous, takeover refuses.

Before suspension, structured Paseo inspection, persisted lifecycle state, current provider quota, timestamps, parent/child relationships, pending permissions, and attention markers produce one deterministic classification.
Only `idle` and `paused-rate-limited` are eligible for transfer.
`waiting-on-captain`, `busy`, `wedged`, `unknown`, and `unsupported` refuse without provider lifecycle mutation.

The privacy-safe receipt is stored under `data/primary-session-handoffs/`.
It contains session identifiers, provider and harness identity, classification, timestamps, a home fingerprint, and a process-identity hash, but no credentials, prompts, titles, permission descriptions, or transcript text.
Task metadata, worktrees, wake records, secondmate homes, and provider transcripts are outside the transaction and remain untouched.

## Restoration

Restoration is an explicit second operation after the successor primary has exited.
It refuses while any pid in the recorded lock is alive or cannot safely be treated as exited.
The command records `restore-requested` before asking Paseo to reload the archived provider and verifies that the provider becomes visible again.

Reload is not lock authority.
The restored Claude or Codex session must receive its tracked native session-start nudge and complete `bin/fm-session-start.sh` before any Firstmate mutation.
If another primary already owns the lock, ordinary startup refuses and dual orchestration never begins.

## Supported combinations

| Visible primary host | Provider harness | Recoverable handoff |
| --- | --- | --- |
| Local Paseo | Claude | Supported when persistence and identity proofs are available |
| Local Paseo | Codex | Supported when persistence and identity proofs are available |
| Local Paseo | OpenCode, Pi, `pi-signed`, Grok, or Kimi | Unsupported in v1 |
| Codex Desktop or unmanaged terminal | Any | Unsupported in v1 |
| Remote Paseo host | Any | Unsupported in v1 |

The task runtime backend is orthogonal to primary-provider ownership.
The command does not start, stop, inspect, or reconfigure tmux, Herdr, Zellij, Orca, or cmux endpoints.

## Read-only captain-action scan

`scan` checks all visible local Paseo sessions for pending permissions or structured captain-action markers.
Its table and JSON forms include only external session id, provider, lifecycle status, action kind, pending-permission count, and parent id.
The scan performs no writes and no provider lifecycle calls.

Current empirical verification and the hermetic regression entry point live in [`verification/primary-session-handoff.md`](verification/primary-session-handoff.md).
