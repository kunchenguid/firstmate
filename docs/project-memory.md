# Project memory

A project firstmate did not start usually keeps most of what makes it workable outside the clone.
Local commits nobody pushed, knowledge documents nobody committed, agent memory the project's own `.gitignore` excludes, and - for some projects - simply everything, because their real home is a directory on one machine and the repository is a mirror nobody has fed in months.
Every worker firstmate dispatches into the clone starts without all of it, while the captain's own sessions in that directory stand on all of it.
That gap, not model quality, is what makes an individual session on such a project feel sharper than an orchestrated one.

This page is the operator's map of the capability that closes it.
Each script's own header and `--help` remain the authority on its exact flags, formats, and mechanics.

## A project's knowledge home

Firstmate records, per project, where the project was worked before it had a clone, and which of the two places is actually the project's home:

```sh
bin/fm-project-memory.sh source set <project> /path/to/the/checkout
bin/fm-project-memory.sh source set <project> /path/to/the/checkout --canonical source
```

`canonical=repo`, the default, means the repository history is the home; anything sitting only in that checkout is a leak, and the fix is to get it versioned.
`canonical=source` means the checkout itself is the home; the repository is a mirror, and standing apart from it is how the work is done rather than a defect to repair.
Do not infer the second from a quiet remote alone - ask.

`bin/fm-project-memory.sh home <project>` prints whichever directory that record makes the project's knowledge home, and everything that has to read a project's committed agent memory or recipe catalog resolves it through that command instead of assuming the clone.
A home that is the checkout and is not reachable right now - the disk behind `/mnt/c` is down - is never quietly answered with the clone, which is only a stale mirror of it: `home` and `activity` fail and say so, and a spawn goes ahead without the digest while telling the worker the recorded home by name and that it was not verified.
Having no record is a normal state, not an error; a project created from nothing has no earlier home.
`bin/fm-project-memory.sh source clear <project>` forgets a record.

The record lives in `config/project-sources/<project>` because it is machine-local: the path exists only on the host holding that checkout, so it is not inherited by a secondmate home, which may run somewhere else.
It is deliberately not a field in `data/projects.md`, which is fleet navigation prose whose delivery-posture parser must stay as narrow as it is.

## Detecting what did not travel

```sh
bin/fm-project-memory.sh scan <project>
bin/fm-project-memory.sh scan --all
```

The scan reports, in bounded lists, what the source checkout holds that the clone does not: commits never pushed to any remote, uncommitted and untracked documents that look like durable knowledge, tracked knowledge files modified but not committed, agent-memory paths the project excludes from its own history, and ignored directories that actually hold material.
Working material and modified source are counted separately from knowledge and never drive the verdict, so a project whose only divergence is media assets or build output reads as parity rather than as a problem.
Scratch is counted and not listed at all.

The verdict says which of three situations this is: `parity` (nothing to recover), `divergent` (a real leak, with a decision to take), or `source-canonical` (the divergence is expected, and the material reaches workers through the local store below instead of through a commit).

**The scan never writes to the source checkout.**
That directory is the captain's live working state and routinely holds uncommitted work.
Every read goes through one gated function that refuses any git subcommand outside a read-only allowlist and runs git so that not even an index refresh is written; a read added later cannot reach that checkout without passing the same gate.

A source checkout on a Windows filesystem reached through `/mnt/c` is supported and is the case this was built against.
Every walk is either a single git call or a bounded count, because an unbounded directory walk there is expensive.

## A live home is shared, and never assumed still

When a project's home is a local folder rather than a repository, there is no isolated copy standing between a worker and the captain.
He runs his own sessions in that same folder while firstmate has work going there, and the two have already come within a minute of colliding: a worker was writing into the AutoEvals folder while he was running tests under `active/repro_weekday/` of it.
Nothing in this capability assumes that folder is still.

That is why every command here only ever reads it, and why the one command that writes into a project directory refuses when someone is mid-operation there.

```sh
bin/fm-project-memory.sh activity <project>
bin/fm-project-memory.sh activity --home /path/to/the/folder --window 300
```

It reports two independent signals, either of which alone means the folder is in use: a file changed inside the window, and a git operation in flight (an index lock, a merge, a rebase, a cherry-pick, a revert, a bisect).
It exits `0` when quiet and `3` when active, so it can gate a script without anyone parsing prose.
The file walk stops at the first hit, so the "he is working" answer costs almost nothing and names one changed path as an example rather than the newest; only the quiet answer walks the tree, which is why the window is small.

This is deliberately not a locking scheme.
A lock neither side can be sure the other honors is worse than an honest reading of what the folder is doing, and the captain's own sessions would never take one.
What the mechanism gives instead is a check any authorized write consults first, an unambiguous refusal when a git operation is in flight, and a sync that says so when it read a folder that was being written rather than presenting a possibly torn file as clean.

## Carrying what cannot be committed

Some material must never enter a project's history: a collaborator's repository firstmate does not get to add files to, documents holding real client material, per-machine configuration, and everything outside git in a project whose home is a local checkout.
`bin/fm-project-local.sh` keeps that material per project in the firstmate home, private and gitignored with the rest of `data/`:

```sh
bin/fm-project-local.sh add <project> /path/to/file
bin/fm-project-local.sh sync <project>         # pull the manifest's paths, reading that home only
bin/fm-project-local.sh list <project>
```

`sync` reads its paths, one per line, from `data/project-local/<project>/manifest`.
It says when the home was being worked in while the copy was taken, and says separately when that could not be determined, so a possibly torn file is never presented as clean.
The store holds regular files only, so **a directory holding symlinks is not transportable** - a `herramientas/` with a Python venv inside it is the ordinary case, since a venv keeps links like `bin/python`.
`add` refuses such a path before anything is copied, so a refusal never leaves the store in a state that blocks every later spawn of the project.
`sync` names that path and the symlink it found on stderr, skips it, and carries the rest of the manifest, because one untransportable path must not keep the material a worker does need from reaching it; list the symlink-free subdirectories instead, or move what has to travel out from under the venv.

Every spawn stages the store into the task copy at `.fm-local/` before the worker starts.
Staging adds that path to the repository's exclude file and then **verifies that git reports nothing under it**; if git can still see the material, the staged copy is removed and the spawn is refused, because a worker cannot be told not to commit something git is offering it.
Staging is also refused outright when the project already tracks that path.
Teardown removes the task copy; the store is untouched.

For a project whose home is a local checkout, this is the main path rather than the exception, since there is no commit for its knowledge to land in.

## Recipes: what the project can do, and how each thing is asked for

A project can stop being software and become a toolbox whose only user is an agent - diagnose an assistant bug, audit a conversation corpus, change a prompt, run a realistic test.
For a project like that the operational recipes are the product, and they usually survive only inside one long conversation.

`bin/fm-project-recipes.sh` gives every project a catalog of those capabilities at `<project home>/.agents/recipes.md`, pointed at from every agent memory file it has to be reachable from: the project's `AGENTS.md`, and its `CLAUDE.md` whenever that is a real file that does not import `AGENTS.md`, because the captain's own sessions load `CLAUDE.md` and workers read `AGENTS.md`.
It lives with the project on purpose, so it serves the captain's individual sessions exactly as much as a dispatched worker; it is not a firstmate-private channel.
Creating it never renames or reconciles the project's memory files; a project that keeps both `AGENTS.md` and `CLAUDE.md` as distinct real files is left exactly as it is, apart from the pointer line each needs.

```sh
bin/fm-project-recipes.sh init <project-home>     # the only subcommand that writes
bin/fm-project-recipes.sh digest <project-home>
bin/fm-project-recipes.sh check <project-home>
```

Each entry names when the capability applies, the exact way it is asked for, what comes back, and its sharp edges, and carries the date it was last verified against the real project.
Every spawn renders `digest` into the launch brief, so a worker reads what this project can do and how it is invoked before it touches anything, the same way firstmate reads its own session-start digest.

When the project's home is a live local folder, the digest names the catalog there by its absolute path, so a worker never mistakes the stale mirror in its own copy for the real one, and the launch brief says plainly that the folder is not the worker's to write and the repository is not where the knowledge lands.
A recipe such a worker learns or finds wrong travels back in its report, in the catalog's own entry shape, and firstmate carries it into the catalog under the captain's approval; the copy's delivery path is never the route for it.
For an ordinary project whose home is its repository, a recipe is promoted through the task's delivery path like any other project knowledge.

The digest is bounded by `config/project-recipe-budget` (absent means the default in the script's header), using the same conservative local token estimate as firstmate's own startup memory.
`check` measures what the digest actually renders, not the catalog file, and reports how many of the catalog's entries the digest can carry; when it cannot carry all of them that is the signal to consolidate, not to raise the ceiling; without a ceiling this recreates the original problem inverted, as a wall of text.
The digest still carries an entry past that horizon, marked UNVERIFIED, so a worker never reads a lapsed recipe as current fact and may be the one who confirms or corrects it.
`check` names those entries and exits nonzero, so a recipe that stopped being true is caught rather than trusted - the catalog is curated the way `data/learnings.md` is, rewritten and pruned rather than accumulated.

## What firstmate does not do here

Firstmate never writes to a project on its own account, and this capability changes nothing about that.
Detection reports; it does not fix.
Recovering knowledge into a project - versioning it, anonymising it first, or creating its recipe catalog - is dispatched as ordinary work through that project's delivery path, or performed under a concrete captain approval like any other project write.
The [`project-management`](../.agents/skills/project-management/SKILL.md) skill owns the intake procedure and the decision firstmate brings to the captain, including the standing rule that a document holding real client material is anonymised before anything is committed, with its analysis and conclusions intact.
