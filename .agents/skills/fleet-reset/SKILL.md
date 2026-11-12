---
name: fleet-reset
description: >-
  Run a full fleet restart after harness updates: stow, update, tear down landed work, restart every secondmate, then hand main's restart back to the captain.
  Use when the captain asks for a fleet restart or reset after upgrading harness CLIs, or invokes /fleet-reset by name.
user-invocable: true
metadata:
  internal: true
---

# fleet-reset

Restart the whole fleet onto freshly upgraded harnesses, and shed context from long-running workers by removing finished work whose substance is already on disk or in memory.
This skill owns only the order of the steps and the teardown rules below.
Every step's mechanics stay with the skill or script named in it; do not restate them here.

## Order

1. **Remind, never run, the harness upgrade.**
   The captain upgrades the harness CLIs (for example `mise upgrade`) themselves, because claude, codex, and pi never self-update.
   Ask whether that is done; firstmate runs no harness upgrade.
2. **Stow.**
   Run the `stow` skill in this home.
   Its cascade has every secondmate curate its own memory and persist its open records.
3. **Update.**
   Run the `updatefirstmate` skill's updater and re-read step, but defer its restart step to step 5 so the mates restart once, after teardown.
   A home skipped as diverged or dirty needs a manual reconcile; report it and keep going without that home.
4. **Tear down finished work** under the rules below, in this home and in each secondmate's home.
5. **Restart the secondmates.**
   Finish `updatefirstmate`'s restart step with `bin/fm-secondmate-restart.sh`.
   A mate it refuses because its composer holds unsent text is retried later in this step, never forced or skipped; if it still refuses, report that mate and what the captain must clear.
6. **Hand back.**
   Tell the captain, in plain outcomes, that main is safe to restart only when the `stow` completion receipt from step 2 claims reset-safe and no mate was skipped or left unrestarted.
   Otherwise report what still prevents a safe reset (an unreachable memory tier, an unresolved over-budget decision, an unfiled open record, a skipped or unreached mate) and do not tell the captain to restart.
   Name anything left running and why.
   Durable records, held captain calls, the backlog, and unread status survive a restart, and `bearings` restores the picture.

## Teardown rules

Tear down only work whose result is already durable.
Use `bin/fm-teardown.sh`, which owns the landed-work test; never pass `--force` and never discard.
A refusal for unlanded or uncommitted work is a stop-and-ask: leave that task alone and put it in the hand-back.

- **Ship:** tear it down only once its work has landed in the default branch, as `ship-landing` defines.
- **Scout:** tear it down only once its report exists and was delivered to the captain, and every captain call it raised is already a held task (`captain-hold-lifecycle`).
  A scout whose report is undelivered or whose call is unrecorded stays.
- **Anything else** (work under way, a draft, an unanswered finding) stays.
- **Secondmate homes:** do not reach into a mate's tree.
  Send each mate one marked request with `bin/fm-send.sh fm-<id> "<request>"` asking it to apply these same rules to its own delivered scouts and landed ships, and to reply on its parent channel with what it removed and what it kept.
  Read the reply from its status or the document it points to, never from its chat.
  Wait for each mate's answer before restarting it.
