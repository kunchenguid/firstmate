<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Deliver with a team.</h3>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the Director - and it runs the team for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For ongoing project context, you can opt in to persistent Project Directors that remain ordinary direct reports but run from their own isolated Firstmate homes on this machine or another SSH-reachable host.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
Firstmate is an agent distro for running a team of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it for your primary session instantiates your Director.

## Roles

- **Director** - the primary cross-project coordinator and the user's single interface.
- **Project Director** - the persistent context owner for one project.
- **Builder** - an implementation worker that produces an authorized project change.
- **Investigator** - a knowledge-only worker that produces a standalone report.

Existing `fm-*` commands, `ship`/`scout`/`secondmate` task kinds, configuration keys, filenames, persisted records, and runtime labels such as `2ndmate-*` remain supported as compatibility identifiers.
New prompts, documentation, and user-visible output use the Director role names.

## Features

- **One liaison** - you talk only to the Director; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible team** - every worker works in its own tmux window or Herdr tab, or in an experimental Zellij tab, experimental cmux workspace, experimental Tern block, experimental Orca terminal, or experimental T3 Code thread you can watch or interact with; the Director reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - Builder tasks deliver authorized changes; Investigator tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project is delivered via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag, an optional `branch=<prefix>` override for the default `fm/` Builder-branch prefix, and an optional `forge=gerrit` binding under which the Builder publishes a Gerrit change instead of opening a pull request, plus an optional `pr=manual` token under which the Builder writes the PR title and body instead of the pipeline.
- **Self-repo boundary** - a home runs as a Firstmate user/operator by default, so a Firstmate bug is diagnosed and patched locally but never pushed, PRed, issued, commented, or forked upstream on its own; publishing to Firstmate's own repository needs the `config/firstmate-role` maintainer opt-in or a per-task user consent ([schema](docs/configuration.md#firstmate-role-configfirstmate-role)).
- **Optional Project Directors** - opt in to persistent Project Directors that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, either locally or as a whole home on an SSH-reachable host, with guarded updates and recovery that never turns an unavailable remote route into a local replacement.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the worker system and wakes the Director only when something needs you; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is in progress and supervision is not live.
- **Optional Relay** - opt in with one local `.env` pairing token so firstmate can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state that is reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Strict project boundary** - the Director is read-only over your projects except for the narrow guarded and user-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including worker system sync's guarded safe branch pruning; workers make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (see [backend selection](docs/configuration.md#backend-selection-order)); the next session reconciles after a restart, while ordinary supervision recovers confirmed-dead Project Director agents without waiting for one.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Oh My Pi (`omp`), Codex, OpenCode, Cursor Agent CLI, or Antigravity CLI (`agy`).
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default.

The Director detects supported missing or outdated tools and offers their install or upgrade after you approve.
Backend-specific setup is linked in [Documentation](#documentation).

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary firstmate session, with `pi-signed` supported as Pi's distinct signed-wrapper identity.
Claude Code uses a tracked Stop hook for tokenless watcher re-arm and rewake, Grok uses background-notify wake cycles, and Pi uses its tracked primary watcher extension.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Oh My Pi (`omp`), a Pi fork, is verified as a primary with the same extension-owned watcher model as Pi and a stronger turn-end guard: its blocking `session_stop` hook compels a continuation instead of requesting one.
Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints unless a home opts in to its model-free native Stop park, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.
Cursor Agent CLI is verified as a primary too, using a tracked project-scope `.cursor/hooks.json` whose `stop` hook parks on the watcher between turns, closest in shape to Claude Code's.
Launch it with `--trust`, or none of its project hooks load; it also has no turn-end hook in headless `cursor-agent -p`, so run the primary session interactively.
Antigravity CLI (`agy`) is verified as a primary too, using a tracked project-local `.agents/hooks.json` whose Stop hook parks on the watcher between turns like Cursor's.

### Install and launch

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

Then launch one of the co-primary harnesses; AGENTS.md takes over from there:

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
# or, when the signed wrapper is installed
FM_PI_HARNESS=pi-signed pi-signed
```

**Oh My Pi**

```sh
omp
# or, when starting from inside a Claude Code pane
FM_OMP_HARNESS=omp omp
```

Start `omp` with this checkout as its working directory: it auto-discovers the tracked `.omp/extensions/*.ts` files with no trust dialog, and naming them with `-e` as well would load each twice.

For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too.
For Pi, approve the project trust prompt once per clone on first launch so the tracked `.pi/extensions/*.ts` files auto-load.
The `/calm` toggle on Pi, and on Claude Code behind its default-off early-access function-hooks flag, hides supported transcript chrome, including canonically classified Firstmate operational user rows, and uses a Calm-only animated activity indicator during active runs while preserving all model context and session data.
Calm changes only presentation, not the user-role delivery, ordering, authority, persistence, or exports of the operational inputs it hides.
The preference persists for the effective Firstmate home, and toggling it off restores ordinary rendering.
[Calm's current behavior and supported limits](docs/calm.md) are separate from its [version-scoped maintainer evidence](docs/calm-mode-feasibility.md).
Pi's `/supervision-model` command pins a cheaper model and a shallower reasoning effort for the supervision branch alone, from the eligible models and thinking levels Pi itself reports, and with no pin the branch normally follows your own conversation's model and effort; see the [configuration schema](docs/configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).

### Talk to it

```sh
> Please look at my GitHub project xyz, then fix the flaky login test and add dark mode.

# The Director checks its toolchain (asking your consent before installing or upgrading anything),
# clones the project under projects/ and spawns two isolated workers in the active backend.
# Minutes later:

  The flaky login fix is ready for review: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux, Paseo, Rex, T3 Code, tern, hc) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the user)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ Director             (Firstmate)    │
 │ reads projects/ + routes requests   │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼
 ┌────────┐   ┌────────┐
 │fm-task1│   │fm-task2│  ...      one visible task endpoint each
 │Builder │   │Invest. │           one autonomous agent each
 └───┬────┘   └───┬────┘
     ▼            ▼
  treehouse worktree, Orca worktree, or isolated Project Director home
     │
     ├─ Builder: project mode ► PR/local merge ► cleanup
     │
     └─ Investigator: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the Director.
It routes each request to a worker in its own session endpoint and git worktree, supervises the worker system with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Optional Project Directors extend this to persistent local or whole-home remote Project Directors, dispatch profiles let you steer which harness handles which task, and opt-in Relay lets the same worker system answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, Project Directors, dispatch profiles, project modes, optional Relay, worker system sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: Pi's in-process branch, a [supervision host](docs/configuration.md#supervision-host-configsupervision-host) beside the other primaries (on by default for Claude), or the daemon handles wakes while you step away; see the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract |
| `/quiet`           | Keep routine wakes off main while staying and chatting; requested actions proceed now rather than waiting for your return. Where Pi's branch or an [attended supervision host](docs/supervision-host.md#quiet-mode) already does this, it only says so; otherwise it starts the quiet daemon, which stays active through ordinary chat until `/quiet off` |
| `/ahoy`            | Compatibility command that recaps visible session events since the prior real user message plus visibly unanswered user decisions, then guides the user through open decisions one at a time; falls back to the existing `/bearings` command when invoked as the session's first real user message |
| `/bearings`        | Generate a concise four-section chat digest from bounded worker system state, including registered remote-home ledgers and measured follow-up for owned contributions; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/updatefirstmate` | Guardedly update the running Firstmate home and its Project Directors - fast-forward, or reconcile a redundant post-squash-merge divergence - then persist and restart every live Project Director successfully left on the target commit - including already-current homes - with an honest re-read nudge only when restart cannot be proven |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered Project Directors, and report what is safe to reset |

Bearings invocation examples:

- `/bearings` returns the fresh four-section digest in chat only.
- Owned-contribution follow-up comes from the cached coverage projection; `include PRs` remains the opt-in for repository-wide live PR enrichment.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by the Director at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the Director roles, supervision, worktrees, Project Directors, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [Remote Project Directors](docs/remote-secondmates.md) - current setup, routing, transfer, recovery, and safety behavior for whole-home remote Project Directors.
- [docs/calm.md](docs/calm.md) - current `/calm` behavior on Pi and Claude Code and its supported presentation limits.
- [docs/voice-relay.md](docs/voice-relay.md) - the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) - the opt-in activity ledger outside tools can read to follow a home's tasks, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/usage-warner.md](docs/usage-warner.md) - configure the opt-in local threshold warner for Claude usage windows.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - current setup, socket security, and limits for the experimental cmux backend.
- [docs/paseo-backend.md](docs/paseo-backend.md) - current setup, terminal-name routing, and limits for the experimental Paseo backend.
- [docs/rex-backend.md](docs/rex-backend.md) - current setup, auto-detection, block-id routing, the absence proof, and limits for the experimental Rex backend.
- [docs/t3code-backend.md](docs/t3code-backend.md) - current setup, sign-in, and limits for the experimental T3 Code backend.
- [docs/tern-backend.md](docs/tern-backend.md) - current setup, surfaces capture, native-state degradation, and limits for the experimental tern backend.
- [docs/hc-backend.md](docs/hc-backend.md) - current setup, task labels, and limits for the experimental hc (herdr-core) backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - the current blocked Codex App backend boundary and rollout contract.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/gerrit-forge-integration.md](docs/gerrit-forge-integration.md) - maintainer architecture for the forge axis: why change-shaped review is not a forge variant, the mode/forge/shape composition test, and where responsibility for forge mechanics sits.
- [docs/external-review-forge.md](docs/external-review-forge.md) - maintainer architecture for `forge=external`, where a review tool uploads its own snapshot: the no-push invariant and its three layers, the personal backup remote, and the accepted residual.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/gerrit-change-watch.md](docs/gerrit-change-watch.md) - maintainer verification for watching Gerrit changes read-only, and why the merge path refuses one.
- [docs/forgejo-tea-integration.md](docs/forgejo-tea-integration.md) - maintainer verification for watching and merging Forgejo/Gitea pull requests via `tea`.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, omp, Grok, Cursor, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervisor contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=kunchenguid%2Ffirstmate&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&legend=top-left" />
 </picture>
</a>
