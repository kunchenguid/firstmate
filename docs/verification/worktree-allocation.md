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

So the exposure the guard closes is specifically a clean working tree plus content that no landing target carries.
`get` also prefers reusing an available slot over creating a new one below `max_trees`, so an at-risk available slot is the next one handed out rather than a remote possibility.

## What "unlanded" is measured against

Verified 2026-08-03, against git 2.53.0 in isolated throwaway pools.

A remote-tracking ref is the landing target only for a fleet that pushes to that remote and refetches it, and neither repository in this fleet does.
`origin` here fetches from an upstream but pushes to a fork, so `refs/remotes/origin/main` tracks upstream while the fork trunk is the local branch.
A slot sitting on the fork trunk exactly, with zero content difference from it, was refused:

```
$ git -C slot1 rev-parse HEAD; git -C proj rev-parse main     # identical
597f72c...                                                    597f72c...
$ fm-worktree-guard.sh check proj
    found: detached HEAD with 3 commits not on remotes/origin/main
```

The same defect was measured the same day in a second, unrelated pool whose remote is simply never advanced, because that project replays and fast-forwards locally by design.
Its slots refused with 286, 360, 361 and 362 `commits not on remotes/origin/v1.2-recovery`, while on every one of them the working tree was clean, `merge-base --is-ancestor HEAD v1.2-recovery` passed, and `rev-list --count v1.2-recovery..HEAD` was 0.
One slot in that same pool was a genuine true positive carrying three real unlanded commits, so the guard was never simply broken; it was measuring against the wrong ref.
The defect is therefore remote-tracking ref versus local trunk in general, not anything fork-specific, and `tests/fm-worktree-guard.test.sh` case (o5) pins both verdicts surviving in one pool.

Commit reachability is also the wrong instrument on its own, because a squash merge leaves a landed branch permanently "ahead":

```
$ git -C slot2 rev-list --count refs/heads/main..HEAD         # after its content was squash-merged
2
```

`bin/fm-landed-lib.sh` therefore tests whether a ref already CONTAINS what HEAD introduces, by 3-way merging and comparing trees, and the guard accepts a slot when any ref carrying the default branch's name contains it.
Containment in any trunk proves the content outlives the slot.
That widening cannot launder unlanded work: content no candidate carries is reported contained by no candidate, which `tests/fm-worktree-guard.test.sh` cases (q) and (q2) pin against a slot in this same stale-remote shape.

## What the guard writes

Verified 2026-08-03, against git 2.53.0.

`git merge-tree --write-tree` writes its merged tree into the object store, so the containment test is not purely read-only.
Measured on a slot whose merge result was a genuinely new tree:

```
loose objects: 25 -> 26   (delta 1)
merged tree 696a3ec... type=tree
referenced by any ref? 0
HEAD/index/worktree still untouched: HEAD=f1f9fd9 dirty=''
```

The one object it adds is a dangling tree that no ref reaches, so `git gc` collects it, and no ref, HEAD, index, or working-tree file changes.
This is the same instrument `bin/fm-teardown.sh` already runs against these repositories.

## Why `--json` is preferred, and why a fallback is still required

Verified 2026-08-02 against treehouse v2.1.0 and v2.0.1.

`treehouse status --json` reports absolute paths and a stable per-slot schema, and prints `[]` for a pool with no slots.
An empty stdout is therefore never a valid empty-pool signal on that format, and the guard refuses rather than treating it as one.
`jq` is required whenever that format is used, and its absence is a refusal.

That flag does not exist before v2.1.0, and `bin/fm-install-treehouse.sh` pins v2.0.1 for CI:

```
$ treehouse --version
v2.0.1
$ treehouse status --json
unknown flag: --json
$ treehouse status --help
Flags:
  -h, --help   help for status
```

The same defect is present there - v2.0.1 also reports a clean slot holding an unlanded branch as `available` - so the guard must still inspect the pool on that build rather than refuse every spawn.
Capability is probed from `status --help` advertising `--json`, not from the error text and not from a version string.

The fallback parses the human-readable table, which needs two compensations the machine format does not.
A path under `$HOME` is printed abbreviated with a leading `~`, and a slot may be followed by indented per-slot process continuation lines:

```
1     in-use       ~/.treehouse/kun-agent-workspace-8bf1b0/1/kun-agent-workspace
                   bash (44801), claude (44970)
2     dirty        ~/.treehouse/kun-agent-workspace-8bf1b0/2/kun-agent-workspace
```

An empty pool prints nothing at all in this format, unlike `[]` in the machine format.
Every non-blank, non-indented line must parse as a slot row; an unparseable one refuses rather than being skipped, since dropping a row would silently leave a slot uninspected.

## treehouse must be executable from fm-spawn's own environment

Before this guard, `bin/fm-spawn.sh` never ran `treehouse` itself: it sent the literal text `treehouse get` into the task pane, so only the pane's shell needed it on `PATH`.
The guard runs `treehouse status --json` from fm-spawn's own process before allocating, so `treehouse` and `jq` must both resolve there.
Either one not being resolvable is a refusal with the missing dependency named, not a silent pass.

## Ownership is a process identity, not a pid

A recorded pid alone cannot establish ownership across a restart: the kernel reissues pid numbers, so a pre-restart pid often resolves to an unrelated live process and reads as falsely alive.
`bin/fm-spawn.sh` therefore records `worktree_owner_pid` and `worktree_owner_identity` in `state/<id>.meta`, and the guard compares the recorded identity with `fm_pid_identity` (`bin/fm-wake-lib.sh`) rather than probing the pid.

Only an identity match reads alive, and only a recorded identity that no longer matches reads dead.
An absent record reads unresolved, never as a released slot, so a home that has never recorded an identity cannot have its slots reclaimed on that basis.

## Boundaries this guard does not cross

The guard never resets, cleans, forces, discards, or releases a slot; it only refuses a spawn.
`bin/fm-teardown.sh` remains the sole releaser of a slot holding work and the owner of the complete landed-work test.
The guard deliberately asks the strictly weaker, offline question "is this slot demonstrably empty?", so it neither restates nor weakens that contract.
It shares only the containment instrument with teardown, never teardown's policy: teardown refreshes the remote first and measures against it, which the guard must not do because it inspects every available slot before every spawn.
Every git read uses `--no-optional-locks` so inspecting another lane's worktree never writes its index, and the single dangling tree object recorded above is the only thing it adds.
