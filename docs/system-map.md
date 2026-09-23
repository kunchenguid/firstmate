# System map

One navigable map of firstmate's loaded extensions and skills, and how they connect to scripts, state, and each other.
This document cross-references owners; it never restates a contract.
`docs/architecture.md` owns the runtime mechanics; this owns the extension and skill inventory and its wiring.

## Extension layer (Pi)

Firstmate ships four Pi extensions under `.pi/extensions/`.
They load only inside a Pi-family session and are discovered once the project is trusted.
Their load state is reported by `bin/fm-session-start.sh`; the turn-end guard writes `state/.pi-turnend-extension-loaded` as its live marker.

| Extension | Role | Owned contract |
|---|---|---|
| `fm-primary-pi-watch.ts` | Arms and supervises the zero-token watcher child; generation-bound ownership | `docs/watcher-continuity.md` |
| `fm-branch-supervision.ts` | Persistent in-process supervision branch that handles actionable wakes | `docs/pi-supervision-branch.md` |
| `fm-primary-turnend-guard.ts` | Blocks a blind turn-end while work is under way | `docs/turnend-guard.md` |
| `fm-calm.ts` | Calm presentation toggle and animated working boat | `docs/calm.md` |

Shared modules under `.pi/extensions/lib/` are imported or spawned by those extensions and carry no load surface of their own:

- `fm-branch-dispatch.ts` - wake handshake between watcher and supervision branch.
- `fm-operational-input.ts` - operational-input classification shared with `bin/fm-operational-input.sh`.
- `fm-native-contract.ts` - registers a FirstMate tool onto the native Pi event-bus boundary.
- `fm-async-exec.ts` - off-thread replacement for `spawnSync` so a child process cannot freeze the TUI.
- `fm-branch-model-picker.ts` - ordering and filtering for the supervision-branch model picker.
- `fm-calm-visibility.ts`, `fm-calm-working-ship.ts`, `fm-calm-assistant-layout.ts`, `fm-calm-operational-user-layout.ts` - Calm presentation adapters.
- `fm-calm-preservation.ts`, `fm-calm-working-ship-sprite.ts` - Calm policy and sprite geometry shared with the Claude Code Calm mod, reached through tracked symlinks.
- `fm-sessionstart-supervisor.mjs` - spawned by the turn-end guard to run the sessionstart hook under supervision on non-Windows platforms.

## Skill layer

Skills live in `.agents/skills/` (internal, loaded by firstmate) and `skills/` (public installer-facing, not loaded by firstmate).
Each skill carries YAML front matter with `name`, `description`, `user-invocable`, and `metadata.internal`.
The public `skills/` counterpart is a deliberately independent file with no shared code.

### Agent-only reference skills

Loaded only on their declared trigger, each listed with its trigger condition.

- `bootstrap-diagnostics` - on an actionable bootstrap or network diagnostic line.
- `diagnostic-reasoning` - before scoping a reported bug or acting on a diagnostic report.
- `ask-user-authority` - before deciding any ask-user finding.
- `quota-array-dispatch` - before choosing among a matched dispatch profile array.
- `harness-adapters` - before spawning, recovering, steering, interrupting, exiting, or resuming a worker.
- `firstmate-orca` - before Orca-backed work.
- `firstmate-codexapp` - before Codex Desktop work.
- `firstmate-coding-guidelines` - before changing firstmate shared tracked material.
- `project-management` - before adding, creating, removing, or initializing a project.
- `stuck-crewmate-recovery` - on a dead endpoint, stale wake, or unresponsive worker.
- `secondmate-provisioning` - before any secondmate lifecycle step.
- `captain-hold-lifecycle` - before completing an investigation or visual review, or on a record-divergence line.
- `process-event-sources` - before arming a long-poll source or a condition-to-action watch.
- `fmx-respond` - on a Relay mention, Relay error, or public-followup wake.

### Captain-invocable skills

- `afk` - `/afk`, going afk, `state/.afk`, or an away-mode injection marker.
- `ahoy` - `/ahoy`.
- `bearings` - `/bearings` or a status request.
- `quiet` - `/quiet`, a quiet-mode request, or `state/.afk` already in quiet mode.
- `stow` - `/stow`.
- `updatefirstmate` - `/updatefirstmate`.

`decision-hold-lifecycle` is a renamed pointer to `captain-hold-lifecycle` and carries no procedure.

## Connection fabric

The layers connect through three stable seams.

### Skill to script and doc

A skill's procedure calls `bin/` scripts and points at `docs/` owners without owning the mechanics itself.
`bin/fm-brief.sh` is the scaffold that produces worker instructions; skills such as `harness-adapters` and `secondmate-provisioning` add task-specific contract detail on top of it.

### Extension to script and state

Each extension delegates real side effects to `bin/` scripts and reads or writes `state/` files, never inverting that ownership.
The watcher extension runs `bin/fm-watch-arm.sh`; the branch extension reports through `bin/fm-branch-outcome.sh`; the turn-end guard runs `bin/fm-turnend-guard.sh`.

### Prose classification

`docs/documentation-audiences.json` is the single machine-consumed owner of which audience every prose surface belongs to.
The extension and skill files themselves are `agent-runtime` surfaces; their operator-facing and maintainer-facing contracts are separate classified docs.
Adding a new skill or doc means adding it to that inventory.

## Discovery

- `bin/fm-session-start.sh` reports whether the running Pi session loaded both required extensions.
- The harness surfaces the internal skill inventory with each skill's front matter.
- `docs/documentation-audiences.json` lists every classified prose surface, including each skill and extension doc.
