# Problem registry

This is the registry of recurring problems firstmate hits, named before they are fixed.
We name the underlying problem first - slow execution, bad output, repeated failures - so that fixes target the cause instead of chasing symptoms.

This registry is one half of a loop; [`CAPABILITIES.md`](CAPABILITIES.md) is the other.
The loop: a problem is reported and named here, a candidate tool or fix is evaluated, the capability is added to the manifest, and the manifest plus the relevant playbook are updated.
The captain feeds the loop with the `report-problem` skill (names a problem) and `propose-tool` (proposes a candidate tool); firstmate then evaluates and closes it.

## Entry schema

Every entry uses these fields, in this order, so the registry stays scannable and machine-appendable:

- **Problem:** a one-line title naming the problem (not the symptom).
- **Symptom:** what is actually observed - the failure, error, or degraded behavior.
- **Impact:** who or what it costs, and how much (wasted turns, blocked work, lost messages, wrong output).
- **Suspected root cause:** the best current hypothesis for why it happens.
- **Candidate fix / tool:** the proposed remedy - a tool, a script, a process change - or `TBD - to be evaluated`.
- **Status:** one value from the vocabulary below.
- **Reported:** the date the entry was filed.
- **Resolved:** the date it was resolved; optional, added only when **Status** becomes `resolved` (or `wontfix`).

The `report-problem` skill emits every field except **Resolved**, which firstmate appends by hand when the entry closes.

Each entry is a `### <id> - <problem title>` heading followed by those fields as a bullet list.
Hand-authored seed entries below use readable ids; entries the `report-problem` skill appends use a timestamped id (`P-<YYYYMMDD-HHMMSS>-<slug>`) for uniqueness.

## Status vocabulary

`reported` -> `triaging` -> `evaluating` -> `fix-identified` -> `resolved` | `wontfix`

- **reported** - filed, not yet looked at.
- **triaging** - being reproduced and scoped.
- **evaluating** - a candidate fix or tool is under evaluation.
- **fix-identified** - the fix is known and queued or in flight.
- **resolved** - fixed and verified; record the landing PR or change.
- **wontfix** - acknowledged but intentionally not addressed; record why.

## Scope: tracked taxonomy vs fleet-local incidents

This tracked file is the **general taxonomy**: problems any firstmate fleet can hit, plus the schema above.
**Fleet-specific incidents** - this captain's one-off breakages, project quirks, and private context - stay local in `data/` (gitignored), not here.
When a fleet-local incident turns out to be general, promote a sanitized version into this file.

## How entries get added

The captain files entries with the captain-invocable skills, which call `bin/fm-registry.sh`:

- `report-problem` -> `bin/fm-registry.sh report-problem --problem ... --symptom ... --impact ... --cause ... [--fix ...]` appends an entry below, status `reported`, and queues an evaluation in the fleet-local queue.
- `propose-tool` files a candidate tool against a capability in `CAPABILITIES.md` (and is often the candidate fix for an entry here).

firstmate then evaluates the queued item, advances the entry's **Status**, and on resolution updates `CAPABILITIES.md`.

## Registry

Seed entries are the general firstmate taxonomy; the `report-problem` skill appends new `###` entries below them.

### P-seed-watcher-rearm-gap - Supervision stops when the watcher is not re-armed

- **Problem:** the one-shot watcher silently stops supervising the fleet.
- **Symptom:** crewmate signals, stale panes, and merge checks stop waking firstmate; long gaps with no fleet action despite in-flight work.
- **Impact:** in-flight tasks go unsupervised for extended periods; decisions and ready PRs are missed.
- **Suspected root cause:** `fm-watch.sh` is one-shot and a turn ended without re-arming it via `fm-watch-arm.sh`, or it was fire-and-forgotten with a shell `&` and reaped.
- **Candidate fix / tool:** always re-arm through the harness's tracked background mechanism every wake/recovery turn; the durable wake queue, `fm-guard.sh` liveness banner, and the `/afk` daemon are the backstops.
- **Status:** fix-identified
- **Reported:** 2026-06-27

### P-seed-nomistakes-repo-serialization - no-mistakes serializes per repo

- **Problem:** only one no-mistakes validation pipeline can run per repo at a time.
- **Symptom:** a second ship task's run on the same repo blocks until the first run's PR is merged or aborted.
- **Impact:** concurrent ship tasks on one repo stall; a finished-but-unmerged run holds the slot indefinitely.
- **Suspected root cause:** the pipeline holds a per-repo slot for the lifetime of a run, by design, to keep validation coherent.
- **Candidate fix / tool:** sequence concurrent ship tasks on the same repo; abort finished-unmerged runs to release the slot; keep cross-repo work parallel.
- **Status:** wontfix
- **Reported:** 2026-06-27

### P-seed-worktree-tangle - Primary checkout stranded on a feature branch

- **Problem:** firstmate-on-itself work lands in the primary checkout instead of an isolated worktree.
- **Symptom:** the firstmate primary (`FM_ROOT`) is on a named non-default branch; `fm-guard.sh` raises the worktree-tangle banner and bootstrap prints a `TANGLE:` line.
- **Impact:** the primary is off its default branch, which can confuse later fleet actions and other crewmates.
- **Suspected root cause:** a crewmate sent to work on firstmate itself branched or committed in the primary rather than its own treehouse worktree.
- **Candidate fix / tool:** the non-destructive restore `git -C <root> checkout <default>`, then re-validate in a real worktree; prevented upstream by `fm-spawn` isolation assertion and the ship-brief first step.
- **Status:** fix-identified
- **Reported:** 2026-06-27

### P-seed-long-session-context-growth - Long-session context degrades the harness

- **Problem:** very long sessions grow context until the harness misbehaves.
- **Symptom:** on Opus, a tool-call decoder-flip can leak malformed tool calls to the captain (tracked as firstmate issue #95).
- **Impact:** garbled captain-facing output and unreliable tool calls late in long sessions.
- **Suspected root cause:** unbounded context growth crossing a threshold the decoder handles poorly.
- **Candidate fix / tool:** context-threshold session breaking; until then, keep sessions bounded and lean on durable state (backlog, status files, meta) so a restart is a non-event.
- **Status:** triaging
- **Reported:** 2026-06-27

### P-seed-stale-crewmate - Crewmate stalls without reporting

- **Problem:** a crewmate stops making progress without appending a status line.
- **Symptom:** a `stale` wake; the pane is waiting, looping, confused, or unresponsive.
- **Impact:** the task stops silently; without intervention it never completes.
- **Suspected root cause:** the crewmate hit an obstacle it cannot self-resolve, a trust/interrupt dialog, or a question already answered by its brief.
- **Candidate fix / tool:** the `stuck-crewmate-recovery` playbook - peek, one-line steer, harness interrupt, relaunch with a progress note, then `failed` with evidence.
- **Status:** fix-identified
- **Reported:** 2026-06-27
