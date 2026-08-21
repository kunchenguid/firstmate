# Verification: treehouse worktree pools across firstmate homes

Active empirical evidence for the pool facts firstmate's single-owner guarantees rest on.
[`docs/configuration.md`](../configuration.md) owns the operator-facing behavior and `bin/fm-pool-root.sh` owns the mechanics; this record owns how the underlying treehouse behavior was established.

## Subject

| Field | Value |
|---|---|
| Tool | `treehouse` v2.0.0 (`treehouse --version`) |
| Pinned for CI | v2.0.1 (`bin/fm-install-treehouse.sh`) |
| Verified | 2026-08-16 |
| Platform | macOS arm64 (Darwin 25.3.0) |

Every run below used throwaway repositories and explicit `root` values under a scratch directory, so no run touched a real pool.
`bin/fm-pool-root.sh` is referenced below as `fm-pool-root.sh`.

## Verified facts

### A pool is keyed by clone name plus repository, not by the checkout

Two clones of one origin, one per home, with the same clone directory name - exactly the shape firstmate produces, because it clones every project to `$FM_HOME/projects/<name>` - are pooled together and handed adjacent slots:

```
$ (cd homeA/projects/proj && treehouse get --lease --lease-holder homeA)
.../shared/.treehouse/proj-dbcb21/1/proj
$ (cd homeB/projects/proj && treehouse get --lease --lease-holder homeB)
.../shared/.treehouse/proj-dbcb21/2/proj
```

The pool directory name carries the clone's own basename, so two clones named differently do not collide:

```
$ (cd homeA-proj && treehouse get --lease --lease-holder homeA)
.../shared/.treehouse/homeA-proj-83944f/1/homeA-proj
$ (cd homeB-proj && treehouse get --lease --lease-holder homeB)
.../shared/.treehouse/homeB-proj-83944f/1/homeB-proj
```

That is why the guarantee cannot rest on clone naming: firstmate's own layout makes the names match.

### `root` is the only knob that separates two homes' pools

After each clone is given its own root, the same two clones no longer share a pool:

```
$ FM_HOME=.../homeA fm-pool-root.sh .../homeA/projects/proj
$ FM_HOME=.../homeB fm-pool-root.sh .../homeB/projects/proj
$ (cd homeA/projects/proj && treehouse get --lease --lease-holder homeA)
.../pools/homeA-4b5fe151/.treehouse/proj-dbcb21/1/proj
$ (cd homeB/projects/proj && treehouse get --lease --lease-holder homeB)
.../pools/homeB-0f7ece37/.treehouse/proj-dbcb21/1/proj
```

### A worktree already leased is unaffected by a later root change

Returning a worktree from the old shared pool still succeeds after its clone has been re-rooted, and frees exactly that slot:

```
$ (cd homeA/projects/proj && treehouse return --force .../shared/.treehouse/proj-dbcb21/1/proj)
🌳 Worktree returned to pool.
$ # .../shared/.treehouse/proj-dbcb21/treehouse-state.json
[('1', False, None), ('2', True, 'homeB')]
```

This is what makes the separation safe to apply to a live fleet: existing leases keep their absolute paths, drain normally, and only new leases move.

### A clean worktree whose holder is gone is re-leased and reset

The damage mechanism itself. Slot 1 holds a clean copy with an unlanded commit on its own branch and no live owner:

```
$ git -C <slot 1> log --oneline -1 ; git -C <slot 1> rev-parse --abbrev-ref HEAD
2cd3d54 unlanded work
fm/unlanded
$ # treehouse-state.json: [('1', None, False)]  - no owner_pid, not leased
```

Another clone asking for a worktree is handed that exact path, detached back onto the base commit:

```
$ (cd homeB/projects/proj && treehouse get)
.../relerase/.treehouse/proj-dbcb21/1/proj
ae48ecd init
```

The branch ref survives, so the commits are recoverable, but the copy now has two owners: whichever task is cleaned up first returns it and hard-resets what the other is doing.
A copy left dirty is skipped rather than re-leased, so uncommitted work is not what this loses - committed, unlanded work in a clean copy is.

## Refreshing this record

Re-run the sequence above against the installed `treehouse` after any upgrade past v2.0.0, and update the version row plus any output that changed.
The portable half of the same guarantees is enforced continuously by `tests/fm-worktree-custody.test.sh`, including rejection of the unsafe literal-root override; its real-treehouse case self-skips when the binary is absent.
