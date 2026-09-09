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
Having no record is a normal state, not an error; a project created from nothing has no earlier home.

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

## Carrying what cannot be committed

Some material must never enter a project's history: a collaborator's repository firstmate does not get to add files to, documents holding real client material, per-machine configuration, and everything outside git in a project whose home is a local checkout.
`bin/fm-project-local.sh` keeps that material per project in the firstmate home, private and gitignored with the rest of `data/`:

```sh
bin/fm-project-local.sh add <project> /path/to/file
bin/fm-project-local.sh manifest <project>     # paths to pull from the project's home
bin/fm-project-local.sh sync <project>         # pull them, reading that home only
bin/fm-project-local.sh list <project>
```

Every spawn stages the store into the task copy at `.fm-local/` before the worker starts.
Staging adds that path to the repository's exclude file and then **verifies that git reports nothing under it**; if git can still see the material, the staged copy is removed and the spawn is refused, because a worker cannot be told not to commit something git is offering it.
Staging is also refused outright when the project already tracks that path.
Teardown removes the task copy; the store is untouched.

For a project whose home is a local checkout, this is the main path rather than the exception, since there is no commit for its knowledge to land in.

## Recipes: what the project can do, and how each thing is asked for

A project can stop being software and become a toolbox whose only user is an agent - diagnose an assistant bug, audit a conversation corpus, change a prompt, run a realistic test.
For a project like that the operational recipes are the product, and they usually survive only inside one long conversation.

`bin/fm-project-recipes.sh` gives every project a catalog of those capabilities at `<project home>/.agents/recipes.md`, pointed at from the project's own `AGENTS.md`.
It lives with the project on purpose, so it serves the captain's individual sessions exactly as much as a dispatched worker; it is not a firstmate-private channel.

```sh
bin/fm-project-recipes.sh init <project-home>     # the only subcommand that writes
bin/fm-project-recipes.sh digest <project-home>
bin/fm-project-recipes.sh check <project-home>
```

Each entry names when the capability applies, the exact way it is asked for, what comes back, and its sharp edges, and carries the date it was last verified against the real project.
Every spawn renders `digest` into the launch brief, so a worker reads what this project can do and how it is invoked before it touches anything, the same way firstmate reads its own session-start digest.

The digest is bounded by `config/project-recipe-budget` (absent means the default in the script's header), using the same conservative local token estimate as firstmate's own startup memory.
When the catalog outgrows the budget that is the signal to consolidate, not to raise the ceiling; without a ceiling this recreates the original problem inverted, as a wall of text.
`check` names entries unverified past the horizon and exits nonzero, so a recipe that stopped being true is caught rather than trusted - the catalog is curated the way `data/learnings.md` is, rewritten and pruned rather than accumulated.

## What firstmate does not do here

Firstmate never writes to a project on its own account, and this capability changes nothing about that.
Detection reports; it does not fix.
Recovering knowledge into a project - versioning it, anonymising it first, or creating its recipe catalog - is dispatched as ordinary work through that project's delivery path, or performed under a concrete captain approval like any other project write.
The [`project-management`](../.agents/skills/project-management/SKILL.md) skill owns the intake procedure and the decision firstmate brings to the captain, including the standing rule that a document holding real client material is anonymised before anything is committed, with its analysis and conclusions intact.
