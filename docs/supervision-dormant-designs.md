# Supervision dormant designs

Larger supervision architectures that were considered, deliberately not built, and preserved here with the evidence that would justify revisiting them.

[`architecture.md`](architecture.md) owns how supervision actually works.
This file owns why it is not something larger, so a future contributor inherits the argument rather than only the outcome.

A record here is not a backlog item and not a promise.
Each one names the problem it would solve, the evidence for and against it today, and a measurable trigger.
A record without a trigger stated as a number against a named metric is a graveyard entry, not a dormant design, because nothing would ever cause anyone to look at it again.
Where a trigger cannot be measured with what the system currently records, that is stated too, along with the instrument it needs.

## What supervision instruments today, and why only that

Three measurements were added alongside the supervision fixes, all of them riding logs that already existed.
Every stale wake reason carries the classification rule that produced it, which the arm layer records in the existing cycle-exit ledger.
The watcher writes a slow-poll line only once a poll's classification work reaches `FM_SLOW_POLL_SECS`, and stamps this home's recorded endpoint count onto the rare no-change heartbeat line.
The wake drain records how many distinct wakes a turn was handed and how long the oldest of them waited.

The rule applied was to collect only what an actual gate below depends on, and to reuse an existing surface wherever one would serve.
The alternative - a supervision telemetry subsystem sized for the metrics a dormant record might one day want - was rejected on its own terms: a second collector is a second component that must agree with the first, and this fleet has been bitten twice by duplicate ownership of the same facts.
Continuous per-poll sampling was rejected for a concrete reason rather than a stylistic one.
Stamping every poll would write roughly 5,700 lines a day into the absorbed-wake log and evict the history that log exists for, well inside its own size bound, so the instrument would have destroyed the evidence it was added to produce.
Threshold-triggered and heartbeat-cadence sampling answer the same questions, because every gate below is stated as a level sustained over days rather than as an instantaneous reading.

Two metrics were deliberately left uncollected.
A human-intervention rate would require classifying captain messages, which is outside the supervision runtime.
An average fan-out cannot exist until a batch does, and the batch record below is the reason none does.

## The wake-outcome ledger

Nothing records what a wake led to.
Without that, "the classifier could not decide and a human judgement was needed" has never been counted, and neither has the false-positive share of any wake class.
This gates the model-supervisor record below, and it is the only honest measure of whether a supervision change removed noise rather than signal.

It is not built because it is the only proposed instrument that costs the coordinator something on every turn, which makes adopting it a captain decision rather than an implementation one.
Until it exists, any claim that a supervision change reduced useless work rather than useful work is an estimate, and should be written as one.

## Batch abstraction - deferred, not rejected

**What it would be.** A `batch=` grouping key in task metadata plus a plan-document schema covering independence basis, verification, maximum concurrency, failure budget and base revision, so that a fan-out of related tasks is a first-class object rather than N unrelated ones.

**Why it is not built.** The usual argument for defining an interface before it is exercised is that a later migration is expensive.
Measured here, it is not.
Task metadata is a flat key-value file that has already absorbed at least four independent field additions from four different writers, with no migration, no version, and no schema; readers use targeted line lookups rather than a parser.
Adding a grouping key when a real batch first exists is a non-event, so the compatibility benefit that would fund building it now is close to zero.

The cost, by contrast, is concrete.
The plan-document schema is where an unexercised interface ossifies, and every semantic field in it is currently a guess.
A failure budget assumes batch failures are countable and fungible.
A maximum-concurrency field assumes the batch rather than the scheduler owns capacity, which contradicts the standing separation between deciding who does work and deciding when it runs.
A scoring of twenty real backlog items found four that justify parallel fan-out, and all four are the same shape - mechanical transformation against disjoint targets with a machine verifier - so a schema written against them would encode that one shape as if it were general.

**What is preserved instead.** This record, and the implementation staying shaped so the key can be added later without rework: nothing in supervision assumes a task is unrelated to every other task, and nothing would have to be undone to group them.

**Measurable trigger.** Revisit when all three hold for three consecutive days: actionable wakes per hour attributable to per-task supervision branches reach 30; concurrent active workers reach 12; and watcher per-poll duration reaches two thirds of the poll interval, meaning the loop can no longer hold its cadence.
The first and third are collectable now, from the branch tag and the slow-poll line.
The second is collectable now from the heartbeat fleet stamp, and has no history before it.

**If it is ever built.** It must be a pure consumer of the existing fleet snapshot, never a second classifier, or it recreates the duplicate-ownership failure this fleet has already paid for twice.

## Speculative-parallel execution - dormant and structurally blocked

**What it would be.** Running competing attempts at the same task and keeping the winner, to buy wall-clock on task classes with a low first-attempt success rate.

**Why it is disabled rather than merely unbuilt.** Every losing arm of a speculative round is, by definition, a worktree holding unlanded work.
Cleanup refuses to discard unlanded work without explicit captain authority, and that refusal is one of the strongest safety boundaries this fleet has, because unlanded work has been lost before.
So an N-way speculative round costs N-1 explicit captain authorizations, every round, forever.

That is decisive rather than merely expensive: the mechanism would *increase* the exact cost it would be adopted to reduce.
Coordinator and captain attention is the measured scarce resource, model quota is the other, and speculative execution spends both to buy wall-clock, which is not the binding constraint.

There is a second, quieter problem.
The task shape that satisfies deterministic verification - mechanical transformation with a machine verifier - is the same shape with a *high* first-attempt success rate.
The class that makes speculative execution safe is the class least likely to need it, and that is a property rather than a coincidence.

**Why no compatibility work is warranted today.** Preserving compatibility would mean either an attempt-group abstraction in dispatch, which is the batch abstraction above and rejected on its own independent grounds, or relaxing the unlanded-work refusal into a general declared-scratch mode.
The second is a change to the fleet's strongest safety boundary, with a real cost today and no measured benefit, so preserving compatibility would cost more than the thing it preserves compatibility for.

**Measurable trigger.** Revisit only when all of: a named task class shows a first-attempt success rate below 50% over at least 20 dispatches; deterministic verification exists for that class, so the winner is picked without judgement; wall-clock is identified as the binding constraint rather than attention or quota; and discarding a losing arm is cheap.
The success rate is not collectable today and needs an attempt counter in task metadata, which is independently useful for answering which task classes need rework.

**If the cleanup contract ever changes.** A scout worktree is already declared scratch at dispatch and may be discarded once its report exists and the completion gate passes.
A speculative arm could be declared scratch under that same doctrine.
That mechanism exists and can be imitated when there is a reason to; it does not need to be generalized in advance, and generalizing it in advance is exactly the safety-boundary relaxation rejected above.

## Batch supervisor process, and hierarchical supervision

**What they would be.** A second long-lived supervisor owning a fan-out, or N supervisors partitioned across the fleet.

**Why they are not built.** Both exist to answer "is this worker healthy?", and the progress-aware wedge reset made that question deterministic inside the supervisor that already exists.
Making the existing supervisor able to see forward progress removes the reason to add a tier above it.
One supervisor absorbs the overwhelming majority of events in bash at the concurrency this fleet has actually reached, and the two behavioural fixes attack precisely the pane-count-driven wake classes that would otherwise grow with the fleet.

The cost is not the classification logic, which is small.
It is that this repo already carries an arm wrapper, a guard, a turn-end guard, an auto-arm hook and a lock protocol to make *one* supervisor reliable, and every backend, harness and recovery path would gain a second component that has to agree with the first.

**Measurable trigger.** Watcher per-poll duration reaching the full poll interval at any concurrency, which is the loop failing to keep cadence; or concurrent workers reaching 20 with actionable wakes per hour at 30 after the current fixes have landed.
Both are collectable now.
Nothing in the current design forecloses a hierarchy - the durable wake queue is already the serialization point a merge would use - which is why no compatibility work is warranted for it either.

## Model-mediated supervision

**What it would be.** A model asked "is this worker stuck, confused, or working on the wrong thing?", sitting in the supervision loop.

**Why it is not built.** Every decision the supervisor makes today is a string or integer comparison.
The one genuinely interpretive question is already routed to firstmate by the deep-inspection demand, and routing it to a cheaper model first yields a second-hand judgement firstmate then has to re-derive, costing a model call *and* the coordinator turn.

The deeper objection is that the absorb model rests on every absorb decision being replayable from files.
A model verdict is not replayable, so supervision failures would stop being reproducible - which is precisely what made the misdiagnoses in this area expensive in the first place.

**Measurable trigger.** At least 20% of actionable wakes over a rolling seven days terminating in "inspected, no action needed" after the current fixes have landed, or deep-inspection demands sustained at three a day for seven days.
The first half is not collectable without the wake-outcome ledger above.
The second half is collectable now from the branch tag.

**If it is ever built.** It must sit beside the deterministic classifier as an advisory annotation on a wake firstmate already receives, never as an absorb authority.

## Structured supervision event bus

**What it would be.** Typed supervision events with schemas, consumed by more than one reader, replacing prose wake reasons.

**Why it is not built.** One reader exists.
The classification branch is carried as a tagged substring inside the existing prose reason, which cost about fifteen lines; a bus costs a schema, a version, and a second component that must agree with the first.
Build it when a second consumer exists, not before.
Until then the tag is prose and a substring match, and nothing may branch on it as if it were a field.

## Related

- [`architecture.md`](architecture.md) - how supervision works today, including the wedge reset, the pause throttle, the steer marker and the park sweep.
- [`turnend-guard.md`](turnend-guard.md) - the structural backstop beneath every harness protocol.
- `bin/fm-crew-state.sh` - owns the progress fingerprint, including which fields may never enter it and why a simpler-looking version silently breaks the wedge escalation.
