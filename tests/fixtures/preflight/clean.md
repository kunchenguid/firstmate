You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
Add a `--json` flag to `bin/fm-boot-context.sh` so the digest can be consumed by
a machine as well as read by a human. Cover it with a test under `tests/`, and
record the flag in `docs/specs/2026-07-08-boot-recon-digest.md`.

# Setup
You are in a disposable git worktree, at a detached HEAD on a clean default branch.

1. First action: create your branch: `git checkout -b fm/fixture-k3`

# Rules
1. Never push to the default branch. Never merge a PR.
2. Stay inside this worktree; modify nothing outside it.
4. Report status by appending one line:
   `FM_HOME='~/firstmate' FM_STATE_OVERRIDE='~/firstmate/state' bash '~/firstmate/bin/fm-status.sh' 'fixture-k3' "{state}: {one short line}"`
   (Reporting is a verb: this appends to ~/firstmate/state/fixture-k3.status from inside the script, and the command pins that home itself so the line always lands there. A direct `>>` redirect into that path is refused by the permission profile and your report would be silently lost.)

# Project memory
If `AGENTS.md` or `CLAUDE.md` already exists, run `~/firstmate/bin/fm-ensure-agents-md.sh .` in the worktree.

# Definition of done
Gate check: run `bash ~/firstmate/bin/fm-gates-lib.sh .` from the repo root.
A gate that is red but declared in `gates/accepted-red.md` is accepted on purpose.
