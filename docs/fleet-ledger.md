# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when a PR became ready for review, when their work merged, and when they were cleaned up.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the five event names below                         |
| `task`  | The firstmate task id the record is about                 |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

Example:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
```

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  These lines still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines firstmate itself writes to a task's status log, such as a recorded answer, a failed launch, a relayed pending reply, or a second mate's report line;
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines a remote second mate reports, which reach this home through firstmate's relay;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording `task.pr_ready`, `task.merged`, or `task.cleaned_up` first records that task's pending status lines.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.

## Reading lifecycle metrics

[`fm-flow.sh`](../bin/fm-flow.sh) reads retained fleet records into lifecycle, queue-reason, and bottleneck metrics, with optional live capacity observations; its header owns usage, output interpretation, timestamp provenance, and uncertainty limits.
The dashboard's Insights view consumes its output: `fm-dashboard.sh` runs the reader at each build and embeds the result as the `flow` key of `board.json`.
`fm-dashboard.sh`'s header owns that embedding and its scrubbing.
The real CLI regression journey is [`tests/fm-flow.test.sh`](../tests/fm-flow.test.sh).

## Per-model statistics

[`fm-task-outcome.sh`](../bin/fm-task-outcome.sh) appends one durable, append-only row per finished task to the home-local `data/metrics/task-outcomes.tsv`, whose header row and columns are `home`, `task`, `kind`, `project`, `models`, `started`, `ended`, `outcome`, and `pr`; give it the same trust as `state/`.
`models` lists every launch of the task in order as `harness:model:effort`, joined by `;`, sourced from the `state/<id>.models` history that `fm-spawn.sh` starts on a fresh spawn and appends to on each relaunch, so a mid-task model switch is recorded rather than lost.
`outcome` is `merged`, `closed`, `cancelled`, `scout`, or `failed`; a secondmate retirement is not a task and records nothing.
The recorder runs best-effort from `bin/fm-teardown.sh` before the task's durable presentation is retired, and never blocks cleanup.

[`fm-model-stats.sh`](../bin/fm-model-stats.sh) reads every local home's `task-outcomes.tsv` and the main home's sampled `lanes.tsv`/`prs.tsv` into `fm-model-stats.v1`: per model over 7- and 30-day windows, started, finished, merged, merge rate, time-to-merge P50/P75, first-pass rate, rework, revert, escape, cancelled/failed, and model switches, each with its sample size.
Its header owns usage (`--json [--now <epoch>]`), attribution, and uncertainty limits.
A task is attributed to the model of its final launch, and one that changed model mid-flight counts as a switch under that model.
Every recorded outcome is authoritative; a sampled lane that predates the recorder is a disclosed fallback, and merge rate is computed over recorded outcomes only so a sampled row never fabricates a rate.
First-pass, rework, revert and escape figures use the same recorded merged PRs as merge rate, since a sampled lane only proves the merges it observed and never the tasks that ended without one; the coverage line counts the sampled tasks they leave out.
The dashboard's Insights view embeds the reader as the `models` key of `board.json`, and the model/outcome sections of [`tests/fm-flow.test.sh`](../tests/fm-flow.test.sh) are its regression journeys.

## Skill statistics

[`fm-skill-stats.sh`](../bin/fm-skill-stats.sh) reads the main home's private `data/metrics/skills.tsv` (`day`, `home`, `skill`, `reads`) into `fm-skill-stats.v1`: per skill over 7- and 30-day windows, its read count and the number of homes it was read in, plus a per-home breakdown and, for each window the file's coverage spans, the known skills that had no reads in it.
Known skill names come from each local home's `skills/` and `.agents/skills/` directories; a missing file or directory contributes nothing rather than failing.
A registered remote home's reads are not readable locally and are disclosed; while one is registered the reader makes no zero-read claim, since a skill it never saw locally may still have been read there.
Its header owns usage (`--json [--now <epoch>]`), window arithmetic, and uncertainty limits; the dashboard embeds it as the `skills` key of `board.json`, and the skill section of [`tests/fm-flow.test.sh`](../tests/fm-flow.test.sh) is its regression journey.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events;
- whether a worker is currently working or idle, and when a turn ends; subscribe to the Herdr runtime's own `pane.agent_status_changed` events for that ([Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback));
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.
