<h1 align="center">Juggernaut</h1>
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

<h3 align="center">Ship like it's a game.</h3>

## What it is

You can run one coding agent easily.
But the moment you want three missions running at once - fixes, recons, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

Juggernaut flips the model.
You talk to a single agent - the Overwatch - and it runs the squad for you: spawning autonomous operators in a visible session backend, giving each a clean git worktree, supervising them to the objective, and handing you finished PRs, approved local merges, or standalone recon reports.
For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated Juggernaut homes on this machine or another SSH-reachable host.

Juggernaut is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
Juggernaut is an agent distro for running a squad of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled Juggernaut skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it for your primary session instantiates your Overwatch - and makes you the Captain.

## Features

- **One liaison** - you talk only to the Overwatch; it dispatches, supervises, escalates only real decisions, and reports plain objectives secured.
- **A visible squad** - every operator works in its own tmux window or Herdr tab, or in an experimental Zellij tab, experimental cmux workspace, or experimental Orca terminal you can watch or type into; the Overwatch reconciles.
- **Disposable worktrees** - each mission runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two mission shapes** - ship missions deliver authorized changes; recon missions leave standalone findings when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag, an optional `branch=<prefix>` override for the default `fm/` ship-branch prefix, and an optional `forge=gerrit` binding under which the operator publishes a Gerrit change instead of opening a pull request.
- **Self-repo boundary** - a home runs as a Juggernaut user/operator by default, so a Juggernaut bug is diagnosed and patched locally but never pushed, PRed, issued, commented, or forked upstream on its own; publishing to Juggernaut's own repository needs the `config/firstmate-role` maintainer opt-in or a per-mission Captain consent ([schema](docs/configuration.md#juggernaut-role-configfirstmate-role)).
- **Optional secondmates** - opt in to persistent second mates that run from isolated Juggernaut homes with their own `FM_HOME`, state, projects, and session lock, either locally or as a whole home on an SSH-reachable host, with guarded updates and recovery that never turns an unavailable remote route into a local replacement.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the Overwatch only when something needs you; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is under way and supervision is not live.
- **Optional Relay** - opt in with one local `.env` pairing token so Juggernaut can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state that is reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Strict project boundary** - the Overwatch is read-only over your projects except for the narrow guarded and Captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; operators make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected); the next session reconciles after a restart, while ordinary supervision recovers confirmed-dead secondmate operators without waiting for one.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- A verified primary agent harness: Claude Code, Grok, Pi, `pi-signed`, Oh My Pi (`omp`), Codex, OpenCode, or Cursor Agent CLI.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default.

The Overwatch detects and offers to install supported missing tools after you approve.
Backend-specific setup is linked in [Documentation](#documentation).

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary Juggernaut session, with `pi-signed` supported as Pi's distinct signed-wrapper identity.
Claude Code uses a tracked Stop hook for tokenless watcher re-arm and rewake, Grok uses background-notify wake cycles, and Pi uses its tracked primary watcher extension.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Oh My Pi (`omp`), a Pi fork, is verified as a primary with the same extension-owned watcher model as Pi and a stronger turn-end guard: its blocking `session_stop` hook compels a continuation instead of requesting one.
Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.
Cursor Agent CLI is verified as a primary too, using a tracked project-scope `.cursor/hooks.json` whose `stop` hook parks on the watcher between turns, closest in shape to Claude Code's.
Launch it with `--trust`, or none of its project hooks load; it also has no turn-end hook in headless `cursor-agent -p`, so run the primary session interactively.

### Install and launch

```sh
gh auth login
git clone https://github.com/umeranjum17/juggernaut
cd juggernaut
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
The `/calm` toggle on Pi, and on Claude Code behind its default-off early-access function-hooks flag, hides supported transcript chrome, including canonically classified Juggernaut operational user rows, and uses a Calm-only animated working boat during active runs while preserving all model context and session data.
Calm changes only presentation, not the user-role delivery, ordering, authority, persistence, or exports of the operational inputs it hides.
The preference persists for the effective Juggernaut home, and toggling it off restores ordinary rendering.
[Calm's current behavior and supported limits](docs/calm.md) are separate from its [version-scoped maintainer evidence](docs/calm-mode-feasibility.md).
Pi's `/supervision-model` command pins a cheaper model and a shallower reasoning effort for the supervision branch alone, from the eligible models and thinking levels Pi itself reports, and with no pin the branch normally follows your own conversation's model and effort; see the [configuration schema](docs/configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# Juggernaut checks its toolchain (asking your consent before installing anything),
# clones the project under projects/ and spawns two isolated operators in the active backend.
# Minutes later:

  PR ready for review, Captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the Captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ Juggernaut          (this repo)     │
 │ reads projects/ + Juggernaut routes │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │operator│   │operator│      │operator│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated secondmate home
     │
     ├─ mission: project mode ► PR/local merge ► cleanup
     │
     └─ recon: report at data/<id>/report.md ► decision inventory ► relay findings ► cleanup
```

You chat with the Overwatch.
It routes each request to an operator in its own session endpoint and git worktree, supervises the squad with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or recon reports.
Optional secondmates extend this to persistent local or whole-home remote second mates, dispatch profiles let you steer which harness handles which mission, and opt-in Relay lets the same squad answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional Relay, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Juggernaut ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: Pi's in-process branch, a [supervision host](docs/configuration.md#supervision-host-configsupervision-host) beside the other primaries (on by default for Claude), or the daemon handles wakes while you step away; see the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract |
| `/quiet`           | Keep routine wakes off main while staying and chatting; requested actions proceed now rather than waiting for your return. Where Pi's branch or an [attended supervision host](docs/supervision-host.md#quiet-mode) already does this, it only says so; otherwise it starts the quiet daemon, which stays active through ordinary chat until `/quiet off` |
| `/ahoy`            | Recap visible session events since the prior real Captain message plus visibly unanswered Captain decisions, then guide the Captain through any open decisions one at a time in agent-judged impact order; fall back to the sitrep when invoked as the session's first real Captain message |
| `/bearings`        | Generate a concise four-section chat sitrep from bounded fleet state, including registered remote-home ledgers and measured follow-up for owned contributions; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/updatefirstmate` | Guardedly update the running Juggernaut and its secondmates - fast-forward, or reconcile a redundant post-squash-merge divergence - then persist and restart every live mate successfully left on the target commit - including already-current homes - with an honest re-read nudge only when restart cannot be proven |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered second mates, and report what is safe to reset |

Bearings invocation examples:

- `/bearings` returns the fresh four-section sitrep in chat only.
- Owned-contribution follow-up comes from the cached coverage projection; `include PRs` remains the opt-in for repository-wide live PR enrichment.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat sitrep.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by Juggernaut at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Juggernaut's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus Juggernaut's agent-only reference skills). Every one of these assumes a live Juggernaut home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how Juggernaut itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of Juggernaut.
  Each one is a self-contained skill with no dependency on Juggernaut's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the Juggernaut-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Proof and decision tools

Three companion tools fit Juggernaut without changing it, and each also works with no Juggernaut at all.
Every hook below is optional and does nothing until you add it.

**[done-done](https://github.com/umeranjum17/done-done-axi) - proof that "done" is real.**
Install it and its Juggernaut files with these commands:

```sh
npx skills add umeranjum17/done-done-axi --skill done-done -g -a claude-code -y
npm install -g --allow-git=all github:umeranjum17/done-done-axi
cat "$(npm root -g)/done-done-axi/integrations/firstmate/brief-include.md" >> "$FM_HOME/config/brief-include.md"
cp "$(npm root -g)/done-done-axi/integrations/firstmate/merge-gate" "$FM_HOME/config/merge-gate"
```

Run the `cat >>` line once: each run appends the brief include again, duplicating it in every brief.

- `config/brief-include.md` is appended to every ship and recon brief, so every operator proves its change with done-done ([details](docs/configuration.md#home-brief-include-configbrief-includemd)).
- `config/merge-gate` is enforced by the merge-card add-on when it is installed; without the add-on, core does not check it. The gate runs `done-done check` against the mission's PR, or its `data/<task-id>/checks.md` when there is no PR, with the default-branch rules, then `receipt --verify <head>`. A nonzero exit refuses the merge and shows its output. Run `git fetch origin` first, since the gate reads local origin refs.

**[sign-off](https://github.com/umeranjum17/sign-off) - answer decisions with one click.**
Install its skill with `npx skills add umeranjum17/sign-off --skill sign-off-axi`.
Run `bin/fm-procevent-signoff.sh arm` once in a home: from then on every mission held in a home where sign-off is armed raises a card on the sign-off board; arm each secondmate home the same way, and your click comes back to Juggernaut as the answer to that hold ([details](docs/configuration.md#process-to-event-sources-stateprocevent)).
The adapter needs `sign-off-axi` on your PATH; open the board with `sign-off-axi open`, and turn the link off with `bin/fm-procevent-signoff.sh retire`.

**[learn-from-mistakes](https://github.com/umeranjum17/learn-from-mistakes) - stop repeated mistakes.**
Install its skill with `npx skills add umeranjum17/learn-from-mistakes --skill learn-from-mistakes -g`.
Point it at the records your fleet already keeps, such as a defect log or failed pipeline steps, and it counts the causes that keep coming back and proposes changes that cite the real records.
It needs no Juggernaut hook.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the squad, supervision, worktrees, secondmates, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - current setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/calm.md](docs/calm.md) - current `/calm` behavior on Pi and Claude Code and its supported presentation limits.
- [docs/voice-relay.md](docs/voice-relay.md) - the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) - the opt-in activity ledger outside tools can read to follow a home's missions, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - current setup, socket security, and limits for the experimental cmux backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - the current blocked Codex App backend boundary and rollout contract.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/gerrit-forge-integration.md](docs/gerrit-forge-integration.md) - maintainer architecture for the forge axis: why change-shaped review is not a forge variant, the mode/forge/shape composition test, and where responsibility for forge mechanics sits.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/gerrit-change-watch.md](docs/gerrit-change-watch.md) - maintainer verification for watching Gerrit changes read-only, and why the merge path refuses one.
- [docs/forgejo-tea-integration.md](docs/forgejo-tea-integration.md) - maintainer verification for watching and merging Forgejo/Gitea pull requests via `tea`.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, omp, Grok, Cursor, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervision contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
Juggernaut is a fork of [Firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen; the original MIT copyright and licence notice are preserved in [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=umeranjum17%2Fjuggernaut&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=umeranjum17/juggernaut&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=umeranjum17/juggernaut&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=umeranjum17/juggernaut&type=date&legend=top-left" />
 </picture>
</a>
