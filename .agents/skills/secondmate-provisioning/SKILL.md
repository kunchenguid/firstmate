---
name: secondmate-provisioning
description: >-
  Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited config into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers home leases, transactional seeding, project clone restrictions, secondmate harness pins, inherited config push, idle charter, handoff helper, and teardown safety.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited config into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## Routing table

`data/secondmates.md` has one line per persistent domain supervisor:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a secondmate charter with:

```sh
bin/fm-brief.sh <id> --secondmate {<project>...|--no-projects}
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Pass `--no-projects` instead of a project list to scaffold a project-less charter for a domain whose subject is the firstmate repo itself, whose home is a firstmate worktree and whose crews take pooled worktrees of the same repo.
`--no-projects` is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed.
Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `data/projects.md` entries.
Retire or clean that home first, and re-scaffold a stale project-bearing charter with `--no-projects` before seeding.
Keep the charter focused on the persistent responsibility, available project clones, escalation back to the main firstmate status file, and the requests-from-main-firstmate contract.
The scaffold's definition of done encodes the idle-by-default contract: on startup the secondmate reconciles only its own in-flight work and then waits for routed tasks, never self-initiating a survey or audit.
Preserve that wording when filling the charter, including the marker rule that marked supervisor requests return through status or a doc pointer while unmarked captain messages stay conversational.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

Pass `--no-projects` in the project position to seed the project-less home described above; the same mutual-exclusion and fail-loud-on-omission rules apply.
It may only seed a home with no project clones or project-registry entries, and refuses conversion of populated homes without changing them.
`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
It also writes the required `.fm-secondmate-home` identity marker, which is gitignored and must remain in place for home validation.
`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.

`config/secondmate-harness` may also pin a concrete model and effort for the secondmate agent, in the SAME file rather than a new one: the format is a single whitespace-separated line `<harness> [<model>] [<effort>]`, with only the first non-empty, non-comment line parsed.
A bare `<harness>` (today's format, e.g. `claude`) behaves exactly as before - harness only, no model/effort flag - so this is fully backward-compatible.
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent/`default`/harness-only); they read only `config/secondmate-harness`, never `config/crew-harness`, which stays a bare adapter name.
For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
An explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`.
When the file's tokens do apply, an explicit per-spawn `--model` or `--effort` flag always wins over the file's token for that axis.
Because this resolves from the file on every spawn, the pin is durable across every respawn (recovery, `/updatefirstmate`, restart) exactly like the harness axis itself - e.g. `config/secondmate-harness` containing `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.
This is secondmate-only: crewmate/scout model resolution is untouched by this file.

This section is the single owner of the secondmate sync and inheritable-config propagation contract; `AGENTS.md` sections 3 and 4 point here.
Before launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
The locked session-start bootstrap sweep runs the same guarded fast-forward for every live secondmate home, discovered from `state/<id>.meta` records with `kind=secondmate` (`data/secondmates.md` only backfills `home=` for older records).
That no-fetch path is a purely local fast-forward of tracked files, never an origin fetch, and it never touches the gitignored operational dirs, so a secondmate's backlog, projects, and in-flight work are never disturbed; a linked worktree advances immediately, while a standalone clone that lacks the target receives firstmate updates through `/updatefirstmate`'s origin refresh.
The same launch and the same locked bootstrap sweep also propagate the primary's declared inheritable local config, currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, into the secondmate home's `config/`.
Because `config/` is gitignored, that propagation is a separate, primary-authoritative copy independent of the tracked-files fast-forward: it re-converges every live home whether or not its tracked files advanced, and it touches only the declared items.
Inheritance copies the literal `config/crew-harness` file, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter such as `codex`; an unset or `default` value has nothing concrete to inherit, and the secondmate's own crewmates fall back to the secondmate's own or detected harness instead.
`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
No reread nudge is needed at spawn or respawn because the agent reads `AGENTS.md` fresh on launch; only the bootstrap sweep's running-home instruction-surface advance needs one.
Bootstrap reports successful sends as `BOOTSTRAP_INFO:` and only emits `NUDGE_SECONDMATES:` when that send fails and needs retry.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited-config change without running the tracked-file fast-forward or nudging the agents.
It uses the same live-home discovery and propagation helper as bootstrap and reports each item as `pushed`, `unchanged`, `skipped`, or `error`.
`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
The helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
This delegated route remains required when `config/backlog-backend=manual`, which controls only routine firstmate backlog edits.
It moves each queued item's whole block - the `- [ ] <id> ...` header plus every following two-or-more-space-indented body line and blank separator, up to the next item or column-0 section heading - byte-exact under the same section, treating an indented `## ...` line as body rather than a section boundary, so neither the header nor its body is duplicated or orphaned.
It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog.
It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries.
Done records stay with their home for pruning or archiving.
It is idempotent; an item already in the secondmate backlog is skipped.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent on-disk home.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inheritable config, so recovered secondmates converge to the primary firstmate version and local dispatch, crew-harness, and backlog-backend settings whenever their home can be cleanly fast-forwarded.
If the secondmate is already running and only inherited config changed, prefer `bin/fm-config-push.sh` over respawning.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent supervisor.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct tmux window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.

With `--force`, teardown is the explicit discard path.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
Never use `--force` unless the captain explicitly said to discard the work.
