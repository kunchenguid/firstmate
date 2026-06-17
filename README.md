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
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in tmux windows, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
There is no app to install; the whole orchestrator is an `AGENTS.md` file that any terminal coding agent can follow.

- **One liaison** - you never talk to a worker agent.
  The first mate dispatches, supervises, escalates only real decisions, and reports plain outcomes about work that is ready, blocked, or needs your call.
- **A visible crew** - every crewmate lives in a tmux window.
  Watch any of them work, or type into their window to intervene; the first mate reconciles.
- **Guarded by construction** - the first mate is read-only over your projects except for clean local default-branch refreshes, safe pruning of local branches whose remote is gone, and approved `local-only` fast-forward merges; crewmates work in disposable [treehouse](https://github.com/kunchenguid/treehouse) worktrees.
  Ship tasks follow each project's delivery mode, and scout tasks produce local reports without pushing anything.

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
 │ reads projects/; writes guarded     │
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
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

- **Event-driven supervision** - a zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and wakes the first mate only when a crewmate reports, stalls, a PR merges, or an internal heartbeat review is due.
  Routine watcher polling, restarts, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle crew costs you nothing.
  A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if tasks are in flight and that watcher stops running.
- **Worktrees, not branches in your checkout** - crewmates never touch your clone; treehouse pools clean worktrees so parallel tasks on one repo cannot collide.
- **Two task shapes** - ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
- **Project modes are explicit** - `data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
  `no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
- **Project memory belongs to projects** - durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
  Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
- **Local clones stay fresh** - bootstrap and PR-based teardown refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.
- **Restart-proof** - all state lives in tmux, status files, and local markdown under `data/`.
  Kill the first mate session anytime; the next one reconciles and carries on.

## The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.

| Script            | Description                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh` | Detect missing toolchain pieces; refresh clones best-effort; install tools only after consent |
| `fm-fleet-sync.sh` | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-brief.sh`     | Scaffold a ship brief, or a report-only scout brief with `--scout`                          |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it    |
| `fm-guard.sh`     | Warn when tasks are in flight but the watcher liveness beacon is stale or missing           |
| `fm-spawn.sh`     | Window → treehouse worktree → agent launched with its brief; records ship/scout task kind   |
| `fm-project-mode.sh` | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`               |
| `fm-merge-local.sh` | Fast-forward a `local-only` project's local default branch after approval                  |
| `fm-review-diff.sh` | Review a crewmate branch against the authoritative base, with optional `--stat` output    |
| `fm-watch.sh`     | Block until supervision work is due; exits with one reason line                             |
| `fm-send.sh`      | Send one literal line (or `--key Escape`) to a crewmate window                              |
| `fm-peek.sh`      | Print a bounded tail of a crewmate pane                                                     |
| `fm-pr-check.sh`  | Record a PR-ready task and arm the watcher's merge poll                                     |
| `fm-promote.sh`   | Promote a scout task in place so it becomes a protected ship task                           |
| `fm-teardown.sh`  | Return the worktree and kill the window; protects ship work and requires scout reports      |
| `fm-harness.sh`   | Detect the running harness; resolve the effective crewmate harness                          |
| `fm-lock.sh`      | Single-firstmate session lock                                                               |

## Configuration

The shared orchestrator behavior lives in `AGENTS.md` - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.
Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` during bootstrap.
Harness support is a table in section 4: claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial task before joining the table.

Runtime tuning via environment variables (defaults shown):

```sh
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_GUARD_GRACE=300      # seconds a stale watcher beacon may age before guard warnings
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.'   # busy-pane signatures, extend per harness
```

## Development

Tracked changes to firstmate itself, including `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and agent skill files, ship through the `no-mistakes` pipeline on a feature branch and require the captain's explicit merge approval.
When supervising live crewmates, keep long validation or build work in the background so watcher wakes can still be handled.
Human-authored pull requests targeting `main` must be raised through `git push no-mistakes`; see `CONTRIBUTING.md` for the enforced contributor workflow.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory instead.

```sh
bash -n bin/*.sh                          # syntax-check the toolbelt
shellcheck bin/*.sh                       # lint the toolbelt; CI enforces this
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch.sh  # watcher smoke test (prints "heartbeat")
```
