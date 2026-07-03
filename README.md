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

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: domain supervisors that are still ordinary direct reports, but run from their own isolated firstmate homes.
There is no app to install; the orchestrator is `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.

This is not an agent harness. This is not a single skill. This is not a CLI.
This is.. a directory that turns any agent into your firstmate, and you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own tmux window or experimental herdr/zellij tab you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver a change; scout tasks investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **Optional secondmates** - opt in to persistent domain supervisors that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, kept on the primary firstmate version by guarded local fast-forwards.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you.
- **Optional X mode** - opt in with one local `.env` token so firstmate can answer your public `@myfirstmate` mentions, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post one public-safe completion follow-up without changing non-X behavior; dry-run preview records would-be replies and dismissals locally before go-live.
- **Guarded by construction** - the first mate is read-only over your projects outside guarded clone refreshes, safe branch pruning, and approved `local-only` fast-forward merges; crewmates make every project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr when selected or auto-detected, zellij when explicitly selected); kill the session anytime and the next one reconciles and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

**Requirements:** a verified agent harness (claude, codex, opencode, pi, or grok), git with GitHub auth, and tmux for the reference session backend.
Experimental herdr spawns additionally require `herdr` and `jq`, checked at spawn time.
Experimental zellij spawns additionally require `zellij` and `jq`, checked at spawn time.
Primitive-only Orca terminal capture, text send, Enter/Ctrl-C keys, and close require the `orca` CLI only when `backend=orca` is selected, but Orca cannot spawn tasks yet.
The first mate detects and offers to install everything else.

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude   # launch your harness here; AGENTS.md takes over
```

Then just talk:

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in the active backend
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

With the default tmux backend, run it inside tmux for the best experience: launching your harness from inside tmux puts every crewmate window in your own session, where you can watch the crew work in real time or type into any window to intervene.
Outside tmux, default-backend crewmates land in a detached `firstmate` session you can attach to.
When firstmate is running natively inside herdr and no backend override is set, it auto-detects herdr, prints an opt-out notice, and spawns into the experimental herdr backend.
With experimental herdr, attach to the selected `HERDR_SESSION` and switch between firstmate-home workspaces.
The primary home uses `firstmate`; each secondmate home uses `2ndmate-<secondmate-id>`, with that home's task tabs inside its own space.
With experimental zellij, select it explicitly with `--backend zellij`, `FM_BACKEND=zellij`, or `config/backend`; attach to the selected `FM_ZELLIJ_SESSION` or the default `firstmate` session.
All zellij tasks share that one session's tab bar, with one `fm-<id>` tab per task.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows or herdr/zellij tabs you can watch
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Persistent secondmate homes are linked firstmate worktrees; locked session start syncs live ones and secondmate launch syncs the target home to the primary default-branch commit without fetching from origin when it is safe.
Crewmate dispatch can stay on a static `config/crew-harness` or use optional natural-language profiles in local `config/crew-dispatch.json` to choose a per-task harness, model, and effort.
When that profile file exists, crewmate and scout spawns must pass the resolved harness explicitly so `config/crew-harness` is not used as an unnoticed bypass.
Secondmate launch can use a separate local `config/secondmate-harness`, whose first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]` to durably pin that secondmate's launch profile.
The runtime session-provider backend is selected from explicit `--backend`, `FM_BACKEND`, local `config/backend`, runtime auto-detection from `$TMUX` or `HERDR_ENV=1`, then the hard `tmux` default.
`tmux` is the verified reference backend.
`herdr` and `zellij` are experimental task-spawn backends; herdr can also be auto-detected, while zellij is selected only explicitly.
`orca` currently exposes capture, text send, Enter/Ctrl-C keys, and close for existing terminals only.
Secondmate homes inherit the primary's declared local config, including `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, at launch, during the locked session-start bootstrap step, or during an explicit `bin/fm-config-push.sh` run, so their own crewmates, dispatch profiles, and backlog backend use the primary settings.
When a routed request goes to a secondmate, firstmate marks it so the answer returns through status or a document pointer; direct typing into that secondmate window stays conversational.
A presence-gated sub-supervisor (`/afk`) can self-handle routine events and batch only what matters while you step away.
An opt-in X mode can also use the watcher check path to answer your public `@myfirstmate` mentions and act on normal reversible mention requests from the current fleet state, with `FMX_DRY_RUN` available to test the poll -> compose -> would-post loop without publishing.
The relay routes only the owner's own mentions to that owner's firstmate home; parent-thread context may still include other public accounts.
The token is standing authorization for those autonomous replies and eligible lifecycle actions; destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
Requests that finish immediately get one public-safe outcome reply.
Requests that spawn longer-running work get an acknowledgement first, a task link in local state, and one completion follow-up within the relay's 24h window when that task lands, reports, or fails.
It preserves parent-tweet context for conversational replies and dismisses pure acknowledgments at the relay without posting.
Replies can attach one local image with `--image <path>` when there is a visual artifact; long replies split into bounded numbered threads when needed, with the image attached only to the opener tweet.
When firstmate works on itself, spawn-time isolation checks and a primary-checkout tangle alarm keep the operating checkout on its default branch and stop a crewmate that did not land in a separate worktree.

Full architecture - the supervision engine, worktree isolation, secondmates, project modes, optional X mode, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash and escalates only captain-relevant events as one batched digest, cutting supervision cost while you step away |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |
| `/stow`            | Sweep the session for uncaptured durable knowledge, route each finding to its disk home per AGENTS.md, file undone next steps to the backlog, and report what is now safe to reset |

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback in the current directory, and closes with a resume pointer for the next session.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, worktrees, secondmates, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional X mode, the files you set, and harness support.
- [docs/herdr-backend.md](docs/herdr-backend.md) - experimental herdr backend verification notes and known gaps.
- [docs/zellij-backend.md](docs/zellij-backend.md) - experimental zellij backend verification notes and known gaps.
- [docs/orca-backend.md](docs/orca-backend.md) - proposed Orca backend adapter contract before an implementation PR.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [`AGENTS.md`](AGENTS.md) - firstmate's full operating manual for the orchestrator agent.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
