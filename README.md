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

<h3 align="center">The only agent you need to talk to.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.jpg" width="100%" />
</p>

You can run one coding agent well.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in tmux windows, giving each a clean git worktree, supervising them to completion, and handing you finished PRs or standalone investigation reports.
There is no app to install; the whole orchestrator is an `AGENTS.md` file that any terminal coding agent can follow.

- **One liaison** — you never talk to a worker agent. The first mate dispatches, supervises, escalates only real decisions, and reports when PRs or scout reports are ready.
- **A visible crew** — every crewmate lives in a tmux window. Watch any of them work, or type into their window to intervene; the first mate reconciles.
- **Guarded by construction** — the first mate is read-only over your projects; crewmates work in disposable [treehouse](https://github.com/kunchenguid/treehouse) worktrees. Ship tasks go through the [no-mistakes](https://github.com/kunchenguid/no-mistakes) validation pipeline, and scout tasks produce local reports without pushing anything.

This is not an agent harness. This is not a skill. This is not a CLI.

This is.. a directory that turns any agent into your firstmate, and you the captain.

## Quick Start

```sh
$ git clone https://github.com/kunchenguid/firstmate && cd firstmate
$ claude   # launch your agent harness here; AGENTS.md takes over

> ahoy! clone github.com/you/yourapp, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in tmux windows
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/yourapp/pull/42
  (fix flaky login test - risk: low - CI green)

> merge it
```

## Install

**Prerequisites** (the first mate detects everything else and offers to install it):

```sh
# 1. a verified agent harness - claude, codex, opencode, or pi
# 2. git + GitHub auth
# 3. tmux - the crew lives in tmux windows (firstmate offers to install it if missing)
gh auth login
```

**Get firstmate:**

```sh
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude
```

That is the whole install.
On first launch the first mate detects what its toolchain is missing (tmux, treehouse, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi), lists it with the exact install commands, and installs only after you say go.

**Run it inside tmux for the best experience.**
firstmate works from any terminal - outside tmux, crewmates land in a detached `firstmate` session you can attach to - but launching your harness from inside tmux puts every crewmate window in your own session, one per task, where you can watch the crew work in real time or type into any window to intervene.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/, never writes them  │
 │ backlog.md ── briefs ── watcher     │
 └──┬──────────────┬───────────────┬───┘
    │ tmux send-keys / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows you can watch
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree (clean, disposable, parallel-safe)
     │
     ├─ ship: /no-mistakes ► PR for the captain ► merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

- **Event-driven supervision** — a zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and wakes the first mate only when a crewmate reports, stalls, or a PR merges. An idle crew costs you nothing.
- **Worktrees, not branches in your checkout** — crewmates never touch your clone; treehouse pools clean worktrees so parallel tasks on one repo cannot collide.
- **Two task shapes** — ship tasks change projects and end in a validated PR; scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
- **Validation is non-negotiable for shipping** — every project gets `no-mistakes init`; every ship task ends with its pipeline. Human-judgment findings escalate to you through the first mate.
- **Restart-proof** — all state lives in tmux, status files, and local markdown under `data/`. Kill the first mate session anytime; the next one reconciles and carries on.

## The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.

| Script            | Description                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh` | Detect missing toolchain pieces; install them only after consent                            |
| `fm-brief.sh`     | Scaffold a ship brief, or a report-only scout brief with `--scout`                          |
| `fm-spawn.sh`     | Window → treehouse worktree → agent launched with its brief; records ship/scout task kind   |
| `fm-watch.sh`     | Block until a crewmate needs attention; exits with one reason line                          |
| `fm-send.sh`      | Send one literal line (or `--key Escape`) to a crewmate window                              |
| `fm-peek.sh`      | Print a bounded tail of a crewmate pane                                                     |
| `fm-pr-check.sh`  | Record a PR-ready task and arm the watcher's merge poll                                     |
| `fm-promote.sh`   | Promote a scout task in place so it becomes a protected ship task                           |
| `fm-teardown.sh`  | Return the worktree and kill the window; protects ship work and requires scout reports      |
| `fm-harness.sh`   | Detect the running harness; resolve the effective crewmate harness                          |
| `fm-lock.sh`      | Single-firstmate session lock                                                               |

## Configuration

The orchestrator's behavior lives in `AGENTS.md` - edit it like any prompt.
Harness support is a table in section 4: claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial task before joining the table.

Watcher tuning via environment variables (defaults shown):

```sh
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.'   # busy-pane signatures, extend per harness
```

## Development

Tracked changes to firstmate itself, including `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and agent skill files, ship through the `no-mistakes` pipeline on a feature branch and require the captain's explicit merge approval.
Human-authored pull requests targeting `main` must be raised through `git push no-mistakes`; see `CONTRIBUTING.md` for the enforced contributor workflow.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory instead.

```sh
bash -n bin/*.sh                          # syntax-check the toolbelt
shellcheck bin/*.sh                       # lint the toolbelt; CI enforces this
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch.sh  # watcher smoke test (prints "heartbeat")
```
