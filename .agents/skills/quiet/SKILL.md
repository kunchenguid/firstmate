---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  Outside `pi` and `pi-signed` it reuses the confirmed afk posture.
  Ordinary chat does not end that posture.
  Only the exact `/quiet off` command does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356) is the afk presentation policy for a captain who stays in the session and does not want ordinary chat to end the mode.

This skill is a thin wrapper.
The `afk` skill owns the non-Pi posture record, daemon lifecycle, guards, classification policy, and reliability properties.
Quiet mode changes only the non-Pi flag mode and the exit signal.

## Entering quiet mode

1. Determine the current harness before creating an afk record.
2. On `pi` and `pi-signed`, make no file or lifecycle change and continue to the acknowledgement.
   The attended supervision branch already keeps routine wakes out of this conversation.
   Do not run `propose`, `confirm`, `start`, or `start-native`; `state/.afk-contract` would switch Pi to the away posture and relocate branch authority.
3. On every other harness, follow steps 1 through 3 in [`afk` entry](../afk/SKILL.md#entering-afk-words) to create the confirmed `state/.afk-contract` before any daemon command.
   Plain `/quiet` carries no away mandate, so use the no-words entry that `afk` permits and run `propose` and `confirm` back to back.
4. Follow the matching non-Pi harness branch in step 4 of [`afk` entry](../afk/SKILL.md#entering-afk-words).
   Set `FM_AFK_MODE=quiet` in the shell that invokes `bin/fm-afk-launch.sh start` or `start-native`, so `state/.afk` records `quiet`.
   Leave `FM_AFK_MODE` unset only when refreshing an already-running quiet daemon; `fm_afk_flag_write` then preserves the recorded mode.
   Do not arm a separate `fm-watch.sh`.
5. Acknowledge in `AGENTS.md` section 9 language: "Captain, quiet mode is active; I will batch routine updates and surface only decisions, failures, credentials, or review-ready work - ordinary chat will not exit this, say `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal.
`AGENTS.md` section 8 owns this always-loaded distinction.

- Only the exact `/quiet off` command exits quiet mode.
  On `pi` and `pi-signed`, first check for `state/.afk-contract`.
  If the record exists, its origin is ambiguous: it may be a legacy quiet record or a genuine away posture.
  Ask once whether the captain wants to end and archive the current away posture, and treat the captain's next reply only as the answer to that question.
  Follow [`afk` return](../afk/SKILL.md#how-to-exit-the-return) only after explicit confirmation.
  A decline or any other reply preserves the record and its authority; do not process that reply as an ordinary afk return or acknowledge restored supervision.
  If no record exists, acknowledge restored normal supervision without running an afk command or changing a file.
  On every other harness, run `bin/fm-afk-return.sh` through the same procedure; it stops the daemon before archiving the confirmed posture record.
- A marked daemon escalation stays in quiet mode and processes the message.
- Any message beginning with `/quiet` other than the exact `/quiet off` command refreshes quiet mode.
- Every other message, including a plain request to resume normal supervision, receives an ordinary answer while quiet mode remains active.

## Orthogonal to approval authority

As in `/afk`, quiet mode changes which events firstmate surfaces and never changes approval authority.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy.

## Must not hide a decision or a failure

The issue's author triage defines quiet mode as presentation only.
Progress, retries, and internal mechanics do not surface, but review-ready work, findings, decisions, failures, and credentials always escalate through the classification policy that `/afk` owns.
Quiet mode is opt-in and never the default; only an explicit request for quiet mode enters it.
