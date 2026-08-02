# Worktree allocation safety verification

Audience: maintainer verification.

This record supports the pre-allocation guard in `bin/fm-worktree-guard.sh` and its call site in `bin/fm-spawn.sh`.
It records only the treehouse behavior the guard's placement and shape depend on, so a treehouse version bump can be re-checked against it.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The regression coverage is `tests/fm-worktree-guard.test.sh`.

## Why the guard runs before `treehouse get`, not after

Verified 2026-08-02 against treehouse v2.1.0, in an isolated throwaway pool.

`treehouse get` resets the slot while acquiring it, before it returns a path.
The binary states this itself:

```
$ treehouse enter --help
Unlike 'get', enter does not acquire, reset, or return the worktree: it
```

Measured directly: a slot on a branch with an unlanded commit and a clean working tree was handed out, and its HEAD moved from the branch to the default branch.

```
--- slot2 before: branch=fm/composer-nbsp-fix-sim sha=12ad5b2 dirty=[]
=== get
handed out -> .../repo-5c2ced/2/repo
--- slot2 after:  branch=HEAD sha=4fe9d25
--- branch ref still exists? 12ad5b23b8b976f4e773d1415e3a234978e5610e
```

`bin/fm-spawn.sh` learns the worktree path by polling the pane's current path, which only changes after that reset.
A check placed where the path becomes known therefore inspects a slot whose evidence has already been erased, and passes every time.
This is why the guard is a pre-allocation check over the slots treehouse reports allocatable, not a post-acquire inspection of the accepted worktree.

## What treehouse already protects, and what it does not

Verified 2026-08-02 against treehouse v2.1.0.

Uncommitted content is protected by treehouse itself.
A dirty slot is reported `dirty`, is skipped by `get`, and is not reclaimed even when every slot in an exhausted pool is dirty:

```
$ printf 'max_trees = 2\nroot = "./"\n' > treehouse.toml   # both slots dirty, unleased
$ treehouse get --lease
all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml
--- slot1 after: [ M f.txt ?? untracked-precious.txt ]
--- slot2 after: [ M f.txt ]
```

Commits unreachable from the default branch are not considered.
The same slot that `get` detached above is reported allocatable while it still holds the branch:

```
$ treehouse status --json
[{"name":"2","status":"available","path":".../2/repo",...}]   # while on fm/composer-nbsp-fix-sim
```

So the exposure the guard closes is specifically a clean working tree plus commits not reachable from the default branch.
`get` also prefers reusing an available slot over creating a new one below `max_trees`, so an at-risk available slot is the next one handed out rather than a remote possibility.

## Why `--json` and not the status table

Verified 2026-08-02 against treehouse v2.1.0.

The human-readable table abbreviates paths under `$HOME` to a leading `~` and appends per-slot process continuation lines, so it is not a parseable contract:

```
1     in-use       ~/.treehouse/kun-agent-workspace-8bf1b0/1/kun-agent-workspace
                   bash (44801), claude (44970)
2     dirty        ~/.treehouse/kun-agent-workspace-8bf1b0/2/kun-agent-workspace
```

`treehouse status --json` reports absolute paths and a stable per-slot schema, and prints `[]` for a pool with no slots.
An empty stdout is therefore never a valid empty-pool signal, and the guard refuses rather than treating it as one.
This is why `jq` is required on the crewmate spawn path and its absence is a refusal.

## Ownership is a process identity, not a pid

A recorded pid alone cannot establish ownership across a restart: the kernel reissues pid numbers, so a pre-restart pid often resolves to an unrelated live process and reads as falsely alive.
`bin/fm-spawn.sh` therefore records `worktree_owner_pid` and `worktree_owner_identity` in `state/<id>.meta`, and the guard compares the recorded identity with `fm_pid_identity` (`bin/fm-wake-lib.sh`) rather than probing the pid.

Only an identity match reads alive, and only a recorded identity that no longer matches reads dead.
An absent record reads unresolved, never as a released slot, so a home that has never recorded an identity cannot have its slots reclaimed on that basis.

## Boundaries this guard does not cross

The guard never resets, cleans, forces, discards, or releases a slot; it only refuses a spawn.
`bin/fm-teardown.sh` remains the sole releaser of a slot holding work and the owner of the complete landed-work test.
The guard deliberately asks the strictly weaker, offline question "is this slot demonstrably empty?", so it neither restates nor weakens that contract.
Every git read uses `--no-optional-locks` so inspecting another lane's worktree never writes its index.
