# PR-stack inventory

The first bounded PR-stack orchestrator surface is a read-only Git inventory with a local SQLite catalog.
It does not publish stacks, contact GitHub, run Mergify, fetch, or mutate refs, branches, commits, remotes, worktrees, reviewer state, or queues.

## Run inventory

From any linked worktree, run:

```sh
bin/fm-pr-stack.py inventory
bin/fm-pr-stack.py inventory --json
bin/fm-pr-stack.py inventory --base <revision> --json
```

The human view summarizes the selected integration base, linked-worktree state, and every local branch.
The JSON form is the stable agent interface and includes `schema_version`, `observed_at`, the selected base identity, repository HEAD, every linked worktree, and deterministically ordered branch items.
Diagnostics use stderr, so successful JSON stdout remains parseable.

Without `--base`, inventory selects `refs/remotes/origin/HEAD` when it resolves to a commit.
If that symbolic ref is absent, exactly one local `main` or `master` branch is accepted.
If neither exists or both exist, inventory stops with an actionable diagnostic and requires `--base`.

Every local branch appears in `items` with its full ref, short name, head OID, configured upstream when any, checked-out worktree information, cleanliness when checked out, base reachability, and a `base..head` unique-commit count.
A branch with unique commits is `unregistered` until a future declaration workflow registers or explicitly ignores it.
Branches without unique commits are retained as `ignored` with the reason stated; they are not silently filtered.
Detached and prunable linked worktrees remain visible in the top-level `worktrees` array.

## Catalog and authority

The command stores the catalog at `pr-stack/orchestrator.sqlite` under Git's common directory, so every linked worktree uses the same database.
The database schema version is also stored in SQLite `user_version`, and schema upgrades run in the same writer transaction as reconciliation.
Foreign keys are enabled for each writer connection, WAL is requested where SQLite supports it, and a bounded immediate transaction serializes refreshes.
If another writer remains active beyond the timeout, inventory exits with a retry diagnostic instead of exposing a partial refresh.

Git remains authoritative for refs, worktrees, ancestry, upstreams, and cleanliness.
Each invocation observes Git again and transactionally replaces only the catalog's current observation rows.
The catalog is authoritative only for future orchestrator declarations and operations, while the append-only `events` and `reconciliations` tables preserve refresh evidence.

The version-one schema includes current worktree and branch observations plus minimal `branch_declarations`, `operations`, and append-only `events` foundations.
This stage deliberately exposes no command that creates declarations or operations.
Mergify publication, GitHub reconciliation, review scheduling, history rewriting, pushes, cleanup, and queue actions remain deferred.
