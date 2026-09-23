---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  It sets the same durable away/quiet-mode flag as /afk, in `quiet` mode, so the sub-supervisor daemon self-handles routine wakes and escalates captain-relevant events exactly as away mode does, but ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356): the same token-saving
daemon tradeoff as `/afk`, made explicit for a captain who is staying,
watching the session, and does not want to exit the mode just by chatting.

This skill is a thin wrapper.
Every mechanism below - the daemon, its injection, its busy/composer guards,
its classification policy, its reliability properties - is owned once by the
`afk` skill and is IDENTICAL in quiet mode; nothing here restates it.
The only things quiet mode changes are which mode the flag declares and what
exits it.

## What it does

Quiet mode is NOT the away posture.
The away posture is `state/.afk-contract`, and quiet mode never requires, writes, or coexists with it, so never run `bin/fm-afk-launch.sh enter` for `/quiet`: that would put the home into away mode, where the next ordinary captain message counts as a return.
If an away-posture record stands when `/quiet` arrives, that message is the captain's return: run the return in the `afk` skill's "How to exit: the return" section first, then enter quiet mode.

1. **Start the daemon on the path the `afk` skill's "Entering: `/afk [words]`" step 2 names for this harness, with `FM_AFK_MODE=quiet` set on the launcher call, and skip that skill's step 1.**
   - **Pi and pi-signed**: nothing to launch; the attended supervision branch already keeps routine wakes out of this conversation.
   - **Harness with a native in-pane tracked-background tool** (claude, grok): run `FM_AFK_MODE=quiet bin/fm-afk-launch.sh start-native`, then `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool; if the native launch fails, run `bin/fm-afk-launch.sh stop` to roll back.
   - **Every other harness**: run `FM_AFK_MODE=quiet bin/fm-afk-launch.sh start`.
   The launcher writes `quiet` as `state/.afk`'s first line and refuses a quiet start while an away-posture record stands; its header owns the mode rules.
   A bare refresh of an already-running quiet daemon with `FM_AFK_MODE` unset keeps quiet, because `fm_afk_flag_write` preserves the on-disk mode when no record stands.
   As with `/afk`, do not separately arm `fm-watch.sh` where the daemon runs.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work - ordinary chat will not exit this, say
   `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal - that is the entire
point of this mode (AGENTS.md section 8's away-mode stub, quiet branch).

- Only an explicit `/quiet off` (or the captain plainly asking to leave quiet mode / resume normal supervision) exits it: run `bin/fm-afk-return.sh` unchanged, the same return the `afk` skill's "How to exit: the return" section documents (correct-ordered daemon shutdown, durable wake presentation and acknowledgement, escalation and wedge evidence, and the return catch-up gate).
  It needs no quiet-specific variant; with no away-posture record its brief reports that no away instructions were recorded for the window, which is expected.
  On Pi and pi-signed nothing was launched, so there is nothing to stop.
- A marked daemon escalation, or a message beginning `/quiet` while already
  in quiet mode (refresh, not exit) -> stay in quiet mode and process it, the
  same two carve-outs `/afk` documents for away mode.
- Every other message while in quiet mode is simply answered as ordinary
  work; the flag and daemon are left untouched.

## Orthogonal to approval authority

Identical to `/afk`: quiet mode changes how aggressively firstmate surfaces
things, never who approves what.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and
a needs-decision finding keeps the `ask-user-authority` policy.

## Must not hide a decision or a failure

Per the issue's own author triage: quiet mode is presentation only.
Progress, retries, and internal mechanics stay below deck exactly as in away
mode, but review-ready work, findings, decisions, failures, and credentials
escalate every time, through the same classification policy `/afk` owns.
Quiet mode is opt-in and never the unconsented default; only an explicit
`/quiet` invocation enters it.
