---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  Where Pi's supervision branch or an attended supervision host already keeps routine wakes off the conversation, it enters nothing and says so.
  Elsewhere it sets the same durable away/quiet-mode flag as /afk, in `quiet` mode, so the sub-supervisor daemon self-handles routine wakes and escalates captain-relevant events exactly as away mode does, but ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356): the same token-saving
daemon tradeoff as `/afk`, made explicit for a captain who is staying,
watching the session, and does not want to exit the mode just by chatting.

Where a daemon runs, this skill is a thin wrapper.
The `afk` skill owns the daemon's injection, busy/composer guards, and reliability properties; quiet mode uses that machinery while the captain remains present.
For captain-held rechecks under quiet, see [architecture](../../../docs/architecture.md).

## What it does

0. **First check whether quiet mode needs anything here.**
   On Pi or pi-signed, enter nothing: the attended branch already keeps routine wakes out of this conversation (the `afk` skill's step 2); tell the captain so.
   Everywhere else run `bin/fm-afk-launch.sh quiet-check`; its header's QUIET MODE owns what each result means.
   - Exit 0: enter nothing - no record, no flag, no daemon, and `/quiet off` then needs nothing either.
     Tell the captain in `AGENTS.md` section 9 language that supervision here already works that way: routine fleet events stay off this conversation, while decisions, failures, credentials, and review-ready work still reach them.
     When its line says the supervision session is paused, say instead that routine updates reach them until it recovers, and when it next retries.
   - Exit 2: an away record is live, so the captain has returned: run the `afk` skill's return and clear its catch-up gate, then run `quiet-check` again and follow its new result.
   - Exit 1: go on to step 1; if it printed a line, first tell the captain plainly what keeps supervision from already being quiet here.

1. **Enter the lifecycle through `bin/fm-afk-launch.sh`, exactly as `/afk`
   does, with `FM_AFK_MODE=quiet` set first.**
   Follow the `afk` skill's record entry, daemon launch, and announcement steps,
   except that on a home that runs the supervision host its `/afk` no-daemon rule does not apply
   after `quiet-check` exits 1. Never arm a separate `fm-watch.sh`. Export
   `FM_AFK_MODE=quiet` in the shell that invokes `bin/fm-afk-launch.sh enter`
   and `start` (or `start-native`), so the record notes quiet mode and
   `state/.afk`'s first line reads `quiet` instead of `away`.
   On a home that runs the supervision host, launch the daemon on the path
   this harness uses without the host; `start` and `start-native` take quiet
   mode from the record `enter` wrote.
   Keep `FM_AFK_MODE=quiet` on a quiet refresh: an `/afk` entry, even without new words, replaces a quiet record with an away record and starts hold-for-return.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is active; I will batch routine updates and surface work needing attention - ordinary chat will not exit this, say `/quiet off` when you want normal per-wake responses back."
   The `afk` skill's Classification policy owns which wakes need attention.

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

Quiet mode changes how aggressively firstmate surfaces things, never who approves what.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy.

The captain is present, so quiet mode holds nothing for a return.
The record a quiet entry writes carries quiet mode (`bin/fm-afk-contract.sh mode`), and its entry, read-back, and session-start lines say so.
Every action the captain asks for or standing authority covers - landing local-only work, a merge, a dispatch - proceeds now exactly as it would without quiet mode; the `afk` skill's away holds never apply to a quiet record.

## Must not hide a decision or a failure

Per the issue's own author triage: quiet mode is presentation only.
Progress, retries, and internal mechanics stay below deck exactly as in away
mode, but review-ready work, findings, decisions, failures, and credentials
escalate every time, through the same classification policy `/afk` owns.
Quiet mode is opt-in and never the unconsented default; only an explicit
`/quiet` invocation enters it.
