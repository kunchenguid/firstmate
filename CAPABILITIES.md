# Capabilities manifest

This is the living manifest of every tool, MCP server, skill, and quality gate this firstmate actually uses, plus what each one does and its known limits.
It exists because a fleet that keeps no record of what it can do cannot reason about what it is missing, and improvements that are not anchored to a named capability chase symptoms.

This manifest is one half of a loop; [`PROBLEMS.md`](PROBLEMS.md) is the other.
The loop: a problem is reported and named in the registry, a candidate tool or fix is evaluated, the capability is added here, and the manifest plus the relevant playbook are updated.
The captain feeds both ends of that loop with two skills: `report-problem` names a recurring problem, and `propose-tool` proposes a better alternative tool.

**Keep it living.**
When a tool, MCP, skill, or gate is added, removed, upgraded, or hits a new limit, update the matching row here in the same change.
Versions below are the ones observed in this environment; treat them as a snapshot, not a pin, and refresh a row when you notice it has moved.
New capabilities usually arrive through the loop: a proposal in the "Proposed tools" section at the bottom is evaluated and, if adopted, graduates into the relevant category above with its limits recorded.

## Crewmate harnesses

The agent runtimes firstmate dispatches crewmates and secondmates on.
The active crewmate harness is `config/crew-harness` (absent or `default` mirrors firstmate's own); per-task overrides are allowed.
Never dispatch on an unverified adapter - see the `harness-adapters` skill for the verified set and the mechanics.

| Harness | Status here | Notes |
| --- | --- | --- |
| claude | installed, active | firstmate's own harness and the default for crewmates. |
| codex | installed | per-task override; also runs the optional pre-PR review pass (`codex` CLI). |
| opencode | adapter verified, not installed | launch via `harness-adapters`; install before dispatch. |
| pi | adapter verified, not installed | launch via `harness-adapters`; install before dispatch. |

Known limits: only adapters verified in `harness-adapters` may be dispatched; an unverified `config/crew-harness` falls back to firstmate's own harness.

## Agent-ergonomic CLIs (the `*-axi` wrappers)

Ergonomic wrappers preferred over the raw underlying tools; each carries session hooks and `--help` as the source of truth for flags.

| Tool | Version | What it does | Known limits |
| --- | --- | --- | --- |
| gh-axi | 0.1.21 | all GitHub operations (issues, PRs, runs, releases, repos, labels). | needs `gh auth login` once; a `#number` is not a clickable link, always relay full PR URLs. |
| chrome-devtools-axi | 0.1.24 | all browser / DevTools automation. | drives a real Chrome session; needs the browser available. |
| lavish-axi | 0.1.31 | rich, annotatable HTML review surfaces for captain decisions and structured reports. | `poll` long-polls and must be left running (re-run if killed); only native controls and `[data-lavish-action]` stay clickable, nested iframes are not injected. |

## Quality gate

| Gate | Version | What it does | Known limits |
| --- | --- | --- | --- |
| no-mistakes | v1.30.1 | the validation pipeline a crewmate drives to ship: review, test, document, lint, push, PR, CI. The pipeline owns every fix (in its own worktree); the crewmate only advances gates with `no-mistakes axi respond`. | serializes per repo - one run per repo at a time, holding the slot until its PR is merged or aborted, so concurrent ship tasks on one repo must be sequenced. `axi run`/`axi respond` block synchronously for many minutes. |

`no-mistakes` is the gate for `no-mistakes`-mode projects (including this repo); `direct-PR` and `local-only` projects skip it.

## Worktree and fleet management

| Tool | Version | What it does | Known limits |
| --- | --- | --- | --- |
| treehouse | v1.8.0 | pooled, isolated git worktrees - one clean worktree per crewmate. | use `--lease` for a non-interactive, durable acquire; pooled clones keep frozen local default refs, so diff against the authoritative base via `bin/fm-review-diff.sh`. |
| git | 2.50.1 | underlying VCS for every clone, worktree, and the firstmate repo itself. | firstmate's primary checkout must stay on its default branch (worktree-tangle guard in `bin/fm-guard.sh`). |

## Backlog

| Tool | Version | What it does | Known limits |
| --- | --- | --- | --- |
| tasks-axi | 0.1.1 | markdown backlog backend pinned by `.tasks.toml` to `data/backlog.md`; mutate the backlog through its verbs when present. | compatible only at 0.1.1+; when absent or incompatible, hand-edit `data/backlog.md` in the documented format. Secondmate handoffs always go through `bin/fm-backlog-handoff.sh`, never bare `tasks-axi mv`. |

## MCP servers

Model-context servers reachable from firstmate and its crewmates (schemas load on demand).

| Server | What it provides | Notes |
| --- | --- | --- |
| claude-in-chrome | browser automation (navigate, click, read, screenshot, console/network). | prefer `chrome-devtools-axi` first; avoid triggering blocking JS dialogs. |
| context7 | live library / framework / SDK / CLI documentation. | prefer over web search and over memory for library docs. |
| open-design | local-first design workspace (OD): artifacts, files, runs. | drive same-project iteration via the `od` CLI to avoid the start_run prompt-drop. |
| xcodebuild | Apple platform build / simulator / device / UI automation. | only simulator workflow tools enabled by default; verify session defaults before first build. |
| mobbin | mobile app design reference search (flows, screens, sections). | reference only. |
| refero | design reference search (screens, flows, styles, similar screens). | reference only. |
| socialcrawl | social-platform data (endpoints, monitors, requests). | metered; check balance. |
| vercel | deploys, runtime logs, project/domain ops, docs. | outward-facing actions need captain consent. |

## Mobile / iOS

| Tool | Version | What it does | Known limits |
| --- | --- | --- | --- |
| baguette | 0.1.75 | iOS simulator control, including custom named device sets so parallel crews get isolated sims. | a custom `fm-sim` device-set is invisible to the xcodebuild MCP, so give each parallel iOS crew its own DEFAULT-set named sim. |
| fm-sim | not built | planned iOS v2 helper (`fm-sim.sh`) for per-crew simulator management. | **not yet on PATH** - tracked as a gap in the iOS v2 plan; do not assume it exists. |

## Skills

Skills are invocable capabilities; firstmate's own live under `.agents/skills/` (`.claude/skills` symlinks to it).

**Captain-invocable** (the captain runs these by name):

| Skill | What it does |
| --- | --- |
| afk | enters away-mode supervision: the sub-supervisor daemon self-handles routine wakes and batches escalations. |
| updatefirstmate | fast-forward self-update of firstmate and every secondmate home, then re-read and nudge. |
| propose-tool | records a structured proposed-tool entry (tool, what it replaces, why better) in this manifest and queues an evaluation. |
| report-problem | records a structured problem entry (problem, symptom, impact, suspected root cause) in `PROBLEMS.md` and queues an evaluation. |

Harness built-ins are also captain-invocable (for example `no-mistakes` to validate, `code-review`, `security-review`); they are not firstmate-owned and live in the harness, not `.agents/skills/`.

**Agent-only references** (firstmate loads these at the trigger points in AGENTS.md section 13, never the captain):

| Skill | Load before |
| --- | --- |
| harness-adapters | spawning/recovering a crewmate or secondmate, trust dialogs, harness-specific skill calls, interrupt/exit/resume, verifying a new adapter. |
| stuck-crewmate-recovery | a stale wake, looping pane, repeated confusion, answered-by-brief question, unresponsive crewmate, or failed steer. |
| secondmate-provisioning | creating, seeding, validating, recovering, handing backlog to, or retiring a secondmate home, or editing `data/secondmates.md`. |

## firstmate helper scripts (`bin/`)

The committed toolkit firstmate drives the fleet with; read each script's header before first use.

| Area | Scripts |
| --- | --- |
| startup & recovery | `fm-bootstrap.sh`, `fm-lock.sh`, `fm-wake-drain.sh`, `fm-harness.sh` |
| task lifecycle | `fm-spawn.sh`, `fm-brief.sh`, `fm-peek.sh`, `fm-send.sh`, `fm-teardown.sh`, `fm-promote.sh`, `fm-project-mode.sh` |
| delivery & review | `fm-pr-check.sh`, `fm-review-diff.sh`, `fm-merge-local.sh`, `fm-ensure-agents-md.sh` |
| supervision | `fm-watch.sh`, `fm-watch-arm.sh`, `fm-guard.sh`, `fm-supervise-daemon.sh` |
| fleet & sync | `fm-fleet-sync.sh`, `fm-home-seed.sh`, `fm-update.sh`, `fm-backlog-handoff.sh` |
| registries | `fm-registry.sh` (backs `propose-tool` and `report-problem`) |
| shared libraries | `fm-ff-lib.sh`, `fm-marker-lib.sh`, `fm-tangle-lib.sh`, `fm-tasks-axi-lib.sh`, `fm-tmux-lib.sh`, `fm-wake-lib.sh` |

## Known limits and gaps (cross-cutting)

These are the standing constraints worth remembering across categories; recurring ones are tracked with full schema in [`PROBLEMS.md`](PROBLEMS.md).

- no-mistakes serializes per repo, so concurrent ship tasks on one repo must be sequenced.
- The watcher (`fm-watch.sh`) is one-shot and must be re-armed every wake/recovery turn via `fm-watch-arm.sh`; the durable wake queue and `fm-guard.sh` are the backstops.
- Long sessions grow context and can degrade the harness; see `PROBLEMS.md`.
- `fm-sim` is planned but not yet built; iOS sim isolation today relies on baguette named device sets.

## Proposed tools (pending evaluation)

Candidate tools the captain has proposed but firstmate has not yet evaluated.
The `propose-tool` skill appends entries here through `bin/fm-registry.sh propose-tool`; an adopted proposal graduates into the relevant category above and is removed from this section.

Each entry uses this schema:

- **Tool:** the proposed tool and where to get it.
- **Replaces:** the current capability or tool it would replace or augment.
- **Why better:** the concrete advantage (speed, correctness, fewer failures, lower cost).
- **Notes:** optional extra context.
- **Status:** `proposed` -> `evaluating` -> `adopted` | `rejected`.
- **Proposed:** the date it was filed.

<!-- propose-tool entries are appended below this line by bin/fm-registry.sh; none yet -->

