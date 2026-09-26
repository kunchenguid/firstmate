---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  On Pi or a home whose attended supervision host runs, it enters nothing: the attended posture already is quiet mode.
  Elsewhere it sets the same durable away/quiet-mode flag as /afk, in `quiet` mode, so the sub-supervisor daemon self-handles routine wakes and escalates captain-relevant events exactly as away mode does, but ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356) keeps routine wakes off a present captain's conversation.
On homes that need a daemon, it is the same token-saving tradeoff as `/afk`, made explicit for a captain who is staying and does not want to exit the mode just by chatting.

This skill is a thin wrapper for the daemon-backed path.
Every mechanism of that path - the daemon, its injection, its busy/composer guards, its classification policy, its reliability properties - is owned once by the `afk` skill and is IDENTICAL in quiet mode; nothing here restates it.
The only things quiet mode changes are which mode the flag declares and what exits it.

## What it does

0. **Check whether quiet mode needs anything here.**
   If an away record `state/.afk-contract` is live and `state/.afk` is not already in quiet mode, first follow the `afk` skill's return and clear its catch-up gate before handling `/quiet`; then continue below.
   On Pi or pi-signed, enter nothing: the in-process attended branch already keeps routine wakes off main (the `afk` skill's "What it does" step 2); tell the captain supervision is already quiet while they are present.
   Otherwise run `bin/fm-afk-launch.sh quiet-check` first.
   It exits 0 with one line where the attended supervision host runs (`docs/supervision-host.md` "Quiet mode"): enter nothing - no record, no daemon, no flag - and tell the captain in `AGENTS.md` section 9 language that supervision here already works that way: routine fleet events stay off this conversation, while decisions, failures, credentials, and review-ready work still reach them.
   When that line instead says the supervision session is paused after repeated engine errors, still enter nothing, and tell the captain plainly that routine updates reach them until it recovers, and when it next retries.
   `/quiet off` then needs nothing either.
   When it exits 1, continue with step 1; if it printed a line, first tell the captain plainly what keeps supervision from already being quiet here.
   When it exits 2, its line names this home's live away record: follow the return rule above, then run `quiet-check` again and follow its result.

1. **Enter the lifecycle through `bin/fm-afk-launch.sh`, exactly as `/afk`
   does, with `FM_AFK_MODE=quiet` set first.**
   Follow the `afk` skill's "What it does" steps 1-3 verbatim (terminal-
   backed vs harness-native entry, daemon-already-running refresh, never
   arming a separate `fm-watch.sh`) with one addition: set
   `FM_AFK_MODE=quiet` on every `bin/fm-afk-launch.sh` call of this entry -
   `enter`, then `start` (or `start-native`) - so `enter` can refuse where
   quiet mode needs nothing and `state/.afk`'s first line reads `quiet`
   instead of `away`.
   Leaving `FM_AFK_MODE` unset on a bare refresh of an already-running quiet
   daemon is also correct and does nothing wrong: `fm_afk_flag_write`
   preserves the on-disk mode when no explicit mode is given, so a plain
   `/afk`-shaped refresh call never resets quiet back to away underneath the
   captain.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work - ordinary chat will not exit this, say
   `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal - that is the entire
point of this mode (AGENTS.md section 8's away-mode stub, quiet branch).

- Only an explicit `/quiet off` (or the captain plainly asking to leave quiet
  mode / resume normal supervision) exits it: run `bin/fm-afk-return.sh`
  unchanged, exactly the procedure `/afk`'s "How to exit afk" section
  documents for its own return path (correct-ordered daemon shutdown,
  durable wake presentation and acknowledgement, escalation/wedge evidence,
  and the return-catch-up gate).
  That script does not read or care about the flag's mode, so it needs no
  quiet-specific variant.
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
Daemon-backed quiet mode is opt-in and never the unconsented default; only an explicit `/quiet` invocation enters it.
