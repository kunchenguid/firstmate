# The decider lane

The decider lane walks the captain-hold queue on a timer so a hold cannot sit unread.

It exists because a hold is written and then nothing happens to it.
The governing order is "nothing should be held up without workers".
A hold is legitimate only when the work is done and the single remaining act is the captain's: a click, a send, a spend, a signature.
If work remains, the item is not held, it is stalled, and a worker is dispatched to finish it.

The lane enforces one invariant: at any moment every held item is either at the one-act boundary waiting on the captain, or owned by a live worker.
There is no third state, and a held item with no worker and no one-act boundary is a defect the lane fixes on sight.

## What counts as a captain call

The semantic policy is owned once by `.agents/skills/captain-hold-lifecycle/SKILL.md`.
The lane does not re-derive it; it applies the two-axis test that policy implies.

**Readiness** asks whether the deliverable is finished.

- `ready` means the reason describes a finished artifact plus one captain act.
- `work` means the reason describes work still owed.
- `unknown` means neither pattern fired, and the lane must resolve it by reading the task note and the artifact it names.

**Class** asks whose act the remainder is.

- Class B is the closed list: new spend or a vendor contract; logins or credentials only the captain holds; legal signatures or sends under his name; irreversible customer-data destruction; a security change judged risky; and any explicit captain instruction, or any switch the record names as his.
- Class A is everything else, which the lane rules and executes.

The captain-instruction rule is kept narrow on purpose.
A standing grant the fleet already holds is not a call to return, so "the captain's standing grant covers PRs that pass QA" stays Class A while "the captain said do not merge it" does not.

The classifier is deliberately biased toward Class B.
A false Class B costs one line in a digest; a false Class A sends the captain's own call to the fleet.

A hold also carries a `hold-until` date when it was set as a time gate.
A hold whose date has passed is expired, not live: the gate opened and nobody walked through it.
Expired holds leave the queue, because counting them inflates it and would have the lane rule items that are no longer held; `--include-expired` still reports them.
A `hold-kind: future` hold is a dated reminder rather than a captain call, so it is Class A with rule `dated-reminder`.

Readiness ignores quoted spans, because a quoted option value describes a choice rather than the state of the work: "the report is complete; say 'arm' or 'not yet'" is ready, not work.

## The four layers

`bin/fm-hold-scan.py` is layer one: a deterministic classifier with no model and no network.
It reads the active home's backlog, extracts every active hold, and emits one JSON object per hold carrying the rule that fired, so every classification is auditable.
The rule table is data, not code, so widening or narrowing Class B is a reviewed diff rather than a runtime decision.

`bin/fm-decider.sh record` is layer two: the ruling ledger.
Each ruling is one append-only line in `data/decider/rulings.md`:

```
<id> | <ruling> | <reason> | <evidence> | <revert>
```

A ruling is reversible by the captain for 24 h, and silence is consent.
Every ruling must carry its revert, so `record` refuses an empty one.

`bin/fm-decider.sh apply` is layer three: execution.
It lifts the hold on every Class A row that already has a ledger ruling, and prints, never runs, the dispatch line for every row whose readiness is `work`, because dispatching a worker is the chair's authority.
It refuses to lift a Class A hold with no ruling and never touches a Class B row.

`bin/fm-hold-digest.py` is layer four: the one captain-facing surface.
It renders Class A rulings already made, then every Class B item as exactly one line carrying its single smallest act, grouped by class and capped per group so the digest stays answerable in one sitting.

## Commands

```
bin/fm-decider.sh scan [--json|--summary] [--class A|B] [--readiness R] [--ids]
bin/fm-decider.sh digest [--cap N] [--out PATH]
bin/fm-decider.sh record <id> <ruling> <reason> <evidence> <revert>
bin/fm-decider.sh rulings
bin/fm-decider.sh plan
bin/fm-decider.sh apply [--yes]
bin/fm-decider.sh status
bin/fm-decider.sh arm
```

`scan` refreshes the durable snapshot at `data/decider/holds.jsonl` unless a filter is given.
It reports live holds only; pass `--include-expired` to see the time gates that already opened.
`digest` writes `data/decider/digest-<YYYY-MM-DD>.md` and prints its path.
`plan` prints what `apply` would do and changes nothing; `apply` without `--yes` is the same dry run.
`status` reports the whole queue on one line.

## Cadence

Hourly, `bin/fm-decider-check.sh` runs as a registered custom check.
It prints one line only when the lane has work it can do without the captain: a Class A hold with no ruling, or a hold whose readiness is `work`.
It stays silent when every hold is already at the one-act boundary, because that is the healthy state and the daily digest is what carries it to him.

Arming the check is a chair action, run from the home that holds the lock:

```
install -m 0700 bin/fm-decider-check.sh state/decider.check.sh
bin/fm-check-register.sh decider
```

Retire it with `bin/fm-check-unregister.sh decider`.

The daily digest is the only thing that reaches the captain about holds.
The weekly review compares the rule table against the rulings made and proposes diffs.

## Guardrails

The lane never decides a Class B item; it recommends and never rules.
It never sends a legal letter, formal response, or legal-position statement to any outside party, and never re-queues an item whose only remaining act is a legal send.
It never widens its own authority at runtime.
Every ruling carries its revert.
If the scan finds zero Class A items it says so and exits rather than inventing work.

## Where the state lives

Runtime state is private to the home and gitignored, under `data/decider/`: the scan snapshot, the ruling ledger, and the dated digests.
The lane's code is tracked, so a home picks it up through the ordinary update path.
