# First Mate Lite

First Mate Lite gives a teammate three Firstmate ideas without the Firstmate runtime: a multi-repository registry, one isolated Git worktree per task, and a brief that any coding agent can follow.
It does not supervise agents or run a fleet.
It has no dependency on `FM_HOME`, treehouse, a watcher, a state machine, or a particular model or harness.
Its only runtime dependency is Git on macOS or Linux.

## Install

Clone this repository, then run one command from its root:

```sh
./bin/fm-lite-install.sh
```

This copies the self-contained `fm-lite` command to `~/.local/bin/fm-lite`.
If `~/.local/bin` is not on your `PATH`, either add it or invoke the command by that full path.
The installed file does not need the Firstmate repository after installation.

## The three-step workflow

### 1. Register a repository

Register an existing local clone once:

```sh
fm-lite project storefront ~/code/storefront
```

Or give it a Git URL and let Lite create a managed clone:

```sh
fm-lite project payments git@github.com:your-team/payments.git
```

Repeat this command with a different name for every repository you use.
Lite stores the registry and managed clones under `${XDG_DATA_HOME:-$HOME/.local/share}/firstmate-lite`, so one local registry supports navigation across many repositories.
Run `fm-lite project storefront` at any time to print the registered clone path.

### 2. Create a task

Use a short task name that is also suitable for a Git branch:

```sh
task_dir=$(fm-lite new storefront improve-checkout)
cd "$task_dir"
```

Lite creates the isolated worktree, checks out `feature/improve-checkout`, and scaffolds these files:

```text
.firstmate/tasks/improve-checkout/
├── brief.md
├── decisions.md
└── verification.md
```

Fill in the task description, acceptance criteria, and constraints in `brief.md` before implementation.
Open Claude Code, Codex, or any other coding harness in the worktree and ask it to read `.firstmate/tasks/improve-checkout/brief.md` before working.
Record implementation choices in `decisions.md`, commands and results in `verification.md`, then commit all three files with the code.

The convention is one sentence: each task keeps its brief, decisions, and verification under `.firstmate/tasks/<task>/`, committed on the feature branch with the code.

The `.firstmate/` directory is intentional shared repository content, not a dirty local artifact and not something to add to `.gitignore`.
It goes through the MR or PR with the implementation so reviewers see the task contract and evidence, and future teammates can recover why a change was made without finding an old private conversation.

### 3. Clean up merged work

After the MR or PR is merged, update the registered clone so its current `HEAD` contains the task branch, then clean it:

```sh
cd "$(fm-lite project storefront)"
git pull --ff-only
fm-lite clean storefront improve-checkout
```

Cleanup removes the task worktree and its local `feature/improve-checkout` branch.
It refuses if the worktree has uncommitted, untracked, or ignored files, or if the registered clone's current `HEAD` does not contain the task branch.
Those refusals protect unfinished work instead of deleting it.

## Command reference

Lite intentionally has only three command families:

```text
fm-lite project <name> [<path-or-url>]
fm-lite new <project> <task>
fm-lite clean <project> <task>
```

Run `fm-lite --help` for the same compact reference.
Project and task names may contain ASCII letters, digits, dots, underscores, and hyphens, and must start with a letter or digit.
Each task starts from the registered clone's current `HEAD`.
Normal Git commands still own commits, pushes, MRs or PRs, and updates to the registered clone.

## Boundary with full Firstmate

First Mate Lite and full Firstmate can be installed on the same machine because they do not share runtime state or commands.
Lite stores only its registry, managed clones, and worktrees in its XDG data directory.
Full Firstmate keeps its existing `FM_HOME`, treehouse pools, lifecycle state, supervision, fleet, and agent dispatch behavior unchanged.
