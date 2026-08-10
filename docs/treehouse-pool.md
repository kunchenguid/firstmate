# Per-home treehouse worktree pools

Measured facts about how treehouse chooses a worktree pool, why two firstmate
homes on one machine used to share one, and the plan for moving existing clones
onto per-home pools.
`bin/fm-project-pool.sh`'s header owns the contract and the exact mechanics;
this file is the evidence behind it.

All measurements are treehouse `v2.1.0`, Linux, 2026-08-11, against scratch
pools under a sandboxed `$HOME`.

## The collision

treehouse places its pool at `$HOME/.treehouse/<clone-basename>-<hash6>`, where
`hash6` is `sha256(<origin remote URL>)[:6]`.
That key has no dimension for which firstmate home is asking.
The primary home and every secondmate home keep their own clone of the same
repo, all clones carry the same origin URL, and on a single machine they share
one `$HOME`, so they all resolve to one pool.

Each pool slot is a `git worktree add` from whichever clone was the current
directory when that slot was first created, and it stays bound to that clone for
the rest of its life.

Reproduced directly with two clones of one origin, both named `proj`:

```
$ cd $LAB/A/projects/proj && treehouse get --lease --lease-holder a1
/…/fakehome/.treehouse/proj-dbc838/1/proj
$ cat /…/proj-dbc838/1/proj/.git
gitdir: /…/A/projects/proj/.git/worktrees/proj

$ cd $LAB/B/projects/proj && treehouse get --lease --lease-holder b1
/…/fakehome/.treehouse/proj-dbc838/2/proj          # same pool

# both returned, then B asks again:
$ cd $LAB/B/projects/proj && treehouse get --lease --lease-holder b2
/…/fakehome/.treehouse/proj-dbc838/1/proj
$ cat /…/proj-dbc838/1/proj/.git
gitdir: /…/A/projects/proj/.git/worktrees/proj     # home A's clone
```

That is the whole bug: home B was handed a linked worktree of home A's clone.
It is intermittent because it only happens when the free slot the pool picks was
created by the other home, so the same home and repo can succeed once and fail
the next time.

`bin/fm-spawn.sh`'s `spawn_worktree_isolated` compares physical git common dirs
and refuses to launch on such a worktree, which is the only thing that caught
this.
Without it the crewmate would create branches and commits inside another home's
clone.
The refusal is correct and is unchanged, but a refusal only rejects: the work
stays undispatchable until the shared pool itself is split.

## The lever, and two that do not work

A `treehouse.toml` at a repo root supports `root = "<absolute path>"`, and
treehouse then places its pool at `{root}/.treehouse/` instead of `$HOME`.
Measured: with `root = "/tmp/th-alt"` the pool appeared at
`/tmp/th-alt/.treehouse/thtest-116c01/` and nothing appeared under
`$HOME/.treehouse`.

Two nearby levers were measured and do NOT work:

- `TREEHOUSE_DIR` in the environment does not relocate the pool.
  The string exists in the binary, but with it set the pool was still created
  under `$HOME/.treehouse/`.
- The config is not discovered by walking up parent directories.
  A `treehouse.toml` in the clone's parent directory was ignored and the pool
  went to `$HOME`; it must sit at the clone root itself.

`treehouse get` has no flag that selects a pool or a source repo (only
`--lease`, `--lease-holder`, `--json`), so the config file is the only lever.

## Returning a worktree survives the repoint

This is what makes it safe to write the config into a clone that already has
worktrees checked out of the shared pool.

`treehouse return <path>` resolves the pool from the PATH argument, not from the
calling repo's configured root.
Measured: a lease taken from the shared pool was released cleanly by a
`treehouse return` issued from a clone whose `treehouse.toml` pointed at a
different root, and `--if-lease-holder` still read that pool's own lease record
(a wrong holder was refused, naming the shared pool's path).

So an in-flight task worktree, and a leased secondmate home, keep working across
the change: they stay exactly where they are and stay returnable.
`fm_treehouse_pool_state_file` in `bin/fm-treehouse-lib.sh` derives the pool from
`<worktree>/../..` rather than from `$HOME`, so firstmate's own path handling is
location-agnostic too.

## Home leasing is deliberately untouched

Secondmate homes are themselves pool worktrees, leased by
`bin/fm-home-seed.sh` with `treehouse get --lease` run from `$FM_ROOT`, and
released with `treehouse return`.
`$FM_ROOT` and `<home>/projects/firstmate` have the same origin URL, so today
they resolve to the same pool.

`bin/fm-project-pool.sh` is applied to project clones only, never to `$FM_ROOT`.
Consequences, all deliberate:

- Every existing home lease keeps working, because its pool did not move.
- A home lease and a `projects/firstmate` task worktree stop sharing one pool,
  which removes an existing way for a firstmate-project spawn to be handed a
  slot the home-lease path created.
- The residual is that two independent PRIMARY installations on one machine
  would still lease homes from one pool.
  That is a different resource with live leases riding on it; splitting it is
  not bundled here.

Verified end to end in a sandboxed home on 2026-08-11: a secondmate home was
leased, its seeded project clone received the secondmate's own pool root, tasks
spawned from the primary home and from the secondmate home for the same repo
landed in different pool roots each bound to its own clone, and both task
worktrees and the leased home were returned cleanly.

## Backfilling existing clones

`bin/fm-project-pool.sh backfill [--home <home>] [--all] [--dry-run]` is the
migration.
It writes the config, never touches a worktree: it does not prune, destroy, or
return anything, and it reports every worktree the clone still has outside the
new pool root so the leftovers are visible rather than silent.

Run it under supervision, in this order:

1. `bin/fm-project-pool.sh check --home <home> --all` - read what is affected.
2. From each affected clone, `treehouse status`, and record which slots are
   `in use` or `leased`.
   Those slots keep working after the backfill and must not be touched.
3. `bin/fm-project-pool.sh backfill --all --dry-run` - confirm the list.
4. `bin/fm-project-pool.sh backfill --all` - apply.
   A clone whose project commits its own `treehouse.toml`, or which carries one
   firstmate did not write, is reported as `SKIPPED` and left alone; that one is
   a captain decision.
5. Leave every pre-existing worktree in the old shared pool where it is.
   Each keeps working and each returns normally at teardown.
   The slots they leave behind become unused directories in the old pool that
   nothing will hand out again, because no clone points at that root any more.
   Clean those up later, separately, only after `treehouse status` from a
   temporarily unconfigured checkout shows them free.

Legacy pools keyed by repo PATH rather than origin URL exist from an older
treehouse version and are not part of this migration; leave them alone.
