# afk: the return, brief and catch-up gate

No `/back` is needed. The first genuine message is the return signal:

- A message that is none of the internal forms listed under "Recognizing the return" in `SKILL.md`, and **not** starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back.
  That script owns the correct-ordered daemon shutdown where a daemon ran, the archive of the posture record, durable wake presentation and post-handling acknowledgement, escalation and wedge evidence, the return brief, and the return-catch-up gate.
  Relay every section of the return brief in its emitted order and in section 9 language; `bin/fm-afk-return.sh` owns that order.
  The gate keeps every open `blocked:` event until that blocker's own resolution is proven: remediate each immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Captain-verdict outcomes are listed under "waiting on you", but do not exempt open blockers: per-blocker provenance is deferred with no owner, and the gate fails safe by keeping every open blocker.
  Once the record is archived, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  A Bearings request may be answered while the gate is open, and the digest surfaces the catch-up state as a Charted Next `(return-catchup)` warning row naming what still holds it.
  Acting on the fleet - dispatching, steering, merging, or any other ordinary captain work - still waits until the check exits successfully.
  Once it does, close every task the brief lists under "Landed, cleanup due" through ordinary teardown (`bin/fm-teardown.sh <task>`, never forced; a refusal is a stop-and-investigate result) and tell the captain those workers are closed in outcome language.

Bias ambiguous cases toward exit: a present captain beats token savings, and a false exit is self-correcting (the captain re-runs `/afk`).
When the captain wants this same token-saving supervision while staying present and chatting - ordinary messages should NOT exit it - that is `/quiet` (kunchenguid/firstmate#2356), not `/afk`.
