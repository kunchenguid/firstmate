# The return

Load this with the `afk` skill when the captain returns, after `bin/fm-afk-return.sh` has run.

Relay every section of the return brief in its emitted order and in section 9 language; `bin/fm-afk-return.sh` owns that order.
The gate keeps every open `blocked:` event until that blocker's own resolution is proven: remediate each immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
Captain-verdict outcomes are listed under "waiting on you", but do not exempt open blockers: per-blocker provenance is deferred with no owner, and the gate fails safe by keeping every open blocker.
Once the record is archived, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
A Bearings request may be answered while the gate is open, and the digest surfaces the catch-up state as a Charted Next `(return-catchup)` warning row naming what still holds it.
Acting on the fleet - dispatching, steering, merging, or any other ordinary captain work - still waits until the check exits successfully.
Once it does, close every task the brief lists under "Landed, cleanup due" through ordinary teardown (`bin/fm-teardown.sh <task>`, never forced; a refusal is a stop-and-investigate result) and tell the captain those workers are closed in outcome language.
