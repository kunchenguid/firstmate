# Captain HUD

`bin/fm-hud.sh` is a read-only, project-agnostic status dashboard for whatever this firstmate home is doing right now.
It answers, at a glance: what task is active, is the worker actually alive, what has been safely banked, and how much AI subscription capacity is left before the next window resets.

It costs nothing to run: it never calls a model, never invokes `claude`, `codex`, or `gnhf` itself, and never mutates backlog, task metadata, git state, or the wake queue.
It only reads local, durable evidence.

## Usage

```
bin/fm-hud.sh                    watch mode, redraws every few seconds (Ctrl+C to exit)
bin/fm-hud.sh --once             a single snapshot
bin/fm-hud.sh --json             the normalized state as JSON, no ANSI
bin/fm-hud.sh --task <id>        select an explicit task instead of auto-discovery
bin/fm-hud.sh --project <name>   filter to one project by display name
bin/fm-hud.sh --home <path>      point at a different FM_HOME (defaults to $FM_HOME, then the repo root)
```

With no flags it auto-selects a task: the sole actively-running item under `## In flight`, falling back to the sole in-flight item if none is actively running.
When more than one candidate ties, it prints `ACTIVE TASK: AMBIGUOUS` with a compact list rather than guessing - pass `--task` to disambiguate.

## What each section means

- **MISSION** - the selected task's project, title, current status, and git branch/HEAD/dirty-file count for its recorded worktree.
- **BANKED** - a checklist of the task's own declared checkpoints (see "Progress and checkpoints" below), with the commit each one banked at.
- **WORKER** - whether a GNHF-driven task's worker process is currently alive (a recorded `tmux` session, or a live process referencing the worktree), and how long since its run directory last changed.
- **AI ENERGY** - subscription quota per provider, split into the SESSION (five-hour) and WEEKLY windows, which one is currently binding (limiting) further work, and quota-axi's own runway projection.
- **PROVIDERS** - the configured implementer/reviewer roles (read from `~/.no-mistakes/config.yaml`'s `review_agents` block, or `config/crew-dispatch.json`'s default array, when present) plus the workstation's standing pay-as-you-go policy.
- **RECOVERY** - the watcher's last liveness beat and whether it is inside its grace window (mirrors `bin/fm-guard.sh`'s `FM_GUARD_GRACE`, default 300s) - a simplified liveness read, not the full model-aware supervision verdict `bin/fm-guard.sh` computes.

## Task discovery (why it never needs a project name)

Discovery reads `data/backlog.md`'s `## <Section>` / `- [ ] <id> - <title> (kind: ...)` shape and, for each item, its `state/<id>.meta`.
Nothing about a specific project, task id, branch, or slice name is encoded - a brand-new project registered through the normal workflow is discovered the moment it has a backlog entry, with no HUD change required.
`tests/fm-hud.test.sh` proves this against a fabricated, non-BinBuddy project fixture.

## Progress and checkpoints

Progress is never a fabricated percentage.
It comes from an optional, already-in-use meta convention: a key `<label>_run=...` records a named checkpoint, and a companion `<label>_banked=YES...` (whose value may embed `Commit <sha>`) marks it done.
The HUD groups whatever such keys a task's own meta happens to declare, in the order they were recorded, and shows the most recently recorded *unbanked* one as the next checkpoint.
A task that uses none of this convention correctly reports `Progress: UNKNOWN` - that is the honest answer, not a bug.

## Quota: session vs. weekly vs. the composite row

`quota-axi --json` reports each provider's specific windows (a `session` window and a `weekly` window, keyed by `kind` since the window `id` differs per provider) plus a composite `all_models` scope in `quotaSemantics`.
The HUD always renders the two named windows directly and only uses the composite scope to find which named window is the current binding limiter - it never substitutes the composite percentage for a missing or lower named window.
`tests/fm-hud.test.sh` includes a regression fixture for exactly this (a provider whose composite row reads 99% while its only real window is at 4%).

Subscription quota, model context-window usage, and API billing tokens are three different things.
The HUD only ever shows subscription quota percentages as quota-axi reports them - it never invents an absolute token count, and it never touches API billing (this workstation's standing policy is subscription-only; see `pay-as-you-go API: LOCKED` in the PROVIDERS line).

## When telemetry is unavailable

Every collector (git, tmux/process liveness, quota-axi, provider-policy config) is isolated: if one fails or returns nothing usable, that field prints `UNKNOWN`/`UNAVAILABLE`/`NOT RUNNING` and the rest of the HUD still renders.
A collector failure is never turned into a fabricated zero, a false `DEAD`, or a crash.
If quota-axi itself is missing or erroring, `AI ENERGY` reports `TELEMETRY UNAVAILABLE` and `Launch safety: UNKNOWN`.

## Machine-readable output

`bin/fm-hud.sh --json` emits the same normalized state the text renderer consumes, with no ANSI formatting - useful for scripting or a future non-terminal surface without re-parsing the box-drawn view.
