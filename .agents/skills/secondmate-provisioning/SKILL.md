---
name: secondmate-provisioning
description: >-
  Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers local leases, whole-home remote routes, transactional seeding, record intake for an existing or inherited domain, project clone restrictions, secondmate harness pins, inherited local-material push, idle charter, handoff helper, and teardown safety.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## Routing table

`data/secondmates.md` has one parser-compatible line per persistent second mate.
A local route uses:

```markdown
- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

A whole-home remote route uses:

```markdown
- <id> - <one-sentence charter summary> (host: <ssh-alias>; root: <absolute-remote-code-root>; home: <absolute-remote-home>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

Each registry entry stays concise and single-line: the summary is one sentence naming the durable charter, `scope:` is the natural-language intake responsibility, `projects:` is the non-exclusive clone list, and any extra prose is limited to genuinely domain-specific hard rules that change routing or safety for that secondmate.
Natural-language summary and `scope:` text may contain parentheses and semicolons; keep the generated `(home: ...; scope: ...; projects: ...; added ...)` suffix intact so operational consumers resolve its explicit field markers.
The `home:` path points to the seeded home containing `data/charter.md`; no extra registry pointer field is needed.
For a remote route, `host:` is an OpenSSH config alias and `root:` is that host's separate tracked Firstmate code root.
A remote second-mate agent always runs on the Herdr backend and every seed, launch, and liveness relaunch first gates its host on `bin/fm-remote-doctor.sh` readiness, so an unready host refuses with that doctor's own gap text rather than half-creating a route; the workers that second mate supervises keep the home's ordinary backend selection.
This release places whole secondmate homes remotely and never individual workers.
[`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md) owns current operator setup and transport behavior.
The home-seeded `data/charter.md` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts, so point to that charter rather than restating those contracts in the registry entry.
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
Keep custom charter text focused on the persistent responsibility, available project clones, and genuinely domain-specific hard rules.
The scaffolded charter, later copied to `data/charter.md`, owns the standard lifecycle and escalation wording.
Preserve the generated charter sections unless the domain genuinely needs a hard rule.

Provision a local persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

Provision a whole remote home through its configured SSH host with:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

You resolve each project's origin yourself - from the captain, the project registry, a clone that exists elsewhere, `gh-axi`, or an explicit paste - and name it as `<project>=<origin-url>`; the seed validates and transports what you supply.
A remote seed therefore creates nothing in this home beyond the route, the charter brief, and a launch record once it is launched: never clone a project into `projects/`, initialize no-mistakes here, or run a fleet sync just to seed a remote secondmate.
A bare `<project>` remains a convenience for a project this home already has cloned, whose configured origin is read instead.
[`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md#provision-a-route) owns the rest of the operator contract, and [`bin/fm-project-origin-lib.sh`](../../../bin/fm-project-origin-lib.sh) owns the accepted origin forms.
Pass `--no-projects` in the project position to seed the project-less home described above; the same mutual-exclusion and fail-loud-on-omission rules apply.
It may only seed a home with no project clones or project-registry entries, and refuses conversion of populated homes without changing them.
`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
It also writes the gitignored `.fm-secondmate-parent` durable binding before the required `.fm-secondmate-home` identity marker; the parser header in [`bin/fm-secondmate-parent-lib.sh`](../../../bin/fm-secondmate-parent-lib.sh) owns the record contract, and both files must remain in place.
`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.

`config/secondmate-harness` may also pin a concrete model and effort for the secondmate agent, in the SAME file rather than a new one: the format is a single whitespace-separated line `<harness> [<model>] [<effort>]`, with only the first non-empty, non-comment line parsed.
A bare `<harness>` (today's format, e.g. `claude`) behaves exactly as before - harness only, no model/effort flag - so this is fully backward-compatible.
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent/`default`/harness-only); they read only `config/secondmate-harness`, never `config/crew-harness`, which stays a bare adapter name.
For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
For a local route, an explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`.
A remote route accepts only a verified harness adapter and refuses a raw launch command at the host boundary.
When the file's tokens do apply, an explicit per-spawn `--model` or `--effort` flag always wins over the file's token for that axis.
Because this resolves from the file on every spawn, the pin is durable across every respawn (recovery, `/updatefirstmate`, restart) exactly like the harness axis itself - e.g. `config/secondmate-harness` containing `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.
This is secondmate-only: crewmate/scout model resolution is untouched by this file.

This section is the single owner of the secondmate sync and inherited-local-material propagation contract; `AGENTS.md` sections 3 and 4 point here.
Before a local launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
The locked session-start deferred network stage runs the same bootstrap sweep for every live local secondmate home, discovered from `state/<id>.meta` records with `kind=secondmate` (`data/secondmates.md` only backfills `home=` for older records).
That no-fetch path is a purely local fast-forward of tracked files, never an origin fetch, and it never touches the gitignored operational dirs, so a secondmate's backlog, projects, and in-flight work are never disturbed; a linked worktree advances immediately, while a standalone clone that lacks the target receives firstmate updates through `/updatefirstmate`'s origin refresh.
A remote launch and the deferred bootstrap sweep hand the configured host the primary's own default-branch commit and ask it to fast-forward the persistent home to exactly that commit, under the same clean, ancestry, and branch guards a local home gets.
A remote home is a standalone clone on another machine, so that host imports the one commit it was given - already present, else from that host's own Firstmate copy without moving it, else from the home's origin - and skips with an actionable reason when none of them holds it, which is what an unpushed primary commit looks like from there.
Neither path moves the host's Firstmate copy, and the host-local launch never re-targets that copy after the parent has already synced the home.
`/updatefirstmate` is the one path that still follows that copy: it first updates the remote code root from its own origin, then syncs the home to that refreshed code-root commit.
SSH exit 255 preserves the route and reports unknown completion; it never triggers local respawn or failover.
The same placement-specific launch and deferred bootstrap sweep also propagate the primary's inherited local material declared by [`fm_config_inherit_items`](../../../bin/fm-config-inherit-lib.sh), whose owner also defines which items are session-scoped.
Because these paths are gitignored, that propagation is a separate, primary-authoritative copy independent of the tracked-files fast-forward: it re-converges every live home whether or not its tracked files advanced, and it touches only the declared items.
Propagation failures warn without blocking a local secondmate launch or session-start continuation; a remote prelaunch transfer failure refuses that launch.
The destination keeps whatever safely validated state the helper left behind.
For inherited config files, local propagation and the remote sender preserve the destination item on source inspection errors and mirror only proven absence; [`fm-config-inherit-lib.sh`](../../../bin/fm-config-inherit-lib.sh) owns this boundary.
Inheritance copies the literal `config/crew-harness` file, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter such as `codex`; an unset or `default` value has nothing concrete to inherit, and the secondmate's own crewmates fall back to the secondmate's own or detected harness instead.
Inherited `config/backend` becomes that secondmate home's local runtime-backend default for future spawns only; it never retargets, rewrites, migrates, stops, or restarts an already-live worker endpoint.
A present primary value always converges byte-exact into validated secondmate homes, and primary absence removes the destination so those homes keep runtime auto-detection.
Explicit per-spawn `--backend` and `FM_BACKEND` remain stronger than every home's local `config/backend`, including an inherited default.
`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
`data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes.
Its primary file header must state that the file is main-authoritative, read-only in secondmate homes, must not be edited there, and that new captain-preference discoveries are routed to the main firstmate through marked status or a document pointer.
Every propagation point converges the secondmate copy to the primary bytes; when the primary file is absent, any existing secondmate copy is quarantined and removed so absence converges too.
The helper rejects unsafe directories, symlinked or nonordinary source or destination artifacts, and hardlinked destination files.
Between propagation runs, the secondmate copy is filesystem read-only; the helper may make its owned destination writable only around a guarded update and restores read-only mode on success, unchanged bytes, and recoverable failure paths.
Before replacing divergent secondmate bytes, the helper hash-compares source and destination, quarantines the secondmate-local version to a collision-safe private dated sibling file, and emits a `SECONDMATE_SYNC:` diagnostic naming the home and quarantine artifact.
Never copy any secondmate `data/captain-shared.md` back into the primary.
Keep each home's `data/captain.md` domain-local.
After first propagation to an existing home, trim that home's local `data/captain.md` by hand to domain-specific content plus pointers to `data/captain-shared.md`; do not automate or silently delete private content.
Keep every `data/learnings.md` fully local by captain decision; route fleet-general machinery facts into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation.
No AGENTS.md reread nudge is needed at spawn or respawn because the agent reads instructions fresh on launch; only the bootstrap sweep's running-home instruction-surface advance needs that AGENTS.md re-read.
Bootstrap reports successful AGENTS.md re-read sends as `BOOTSTRAP_INFO:` and only emits `NUDGE_SECONDMATES:` when that send fails and needs retry.
A separate, literal-content config reread is required whenever inherited `config/*` material changes under an already-running secondmate.
For a local home, after each successful allowlisted config write, both the locked bootstrap convergence path and mid-session `bin/fm-config-push.sh` use the shared propagation report to build one per-home generation-specific private instruction file from the validated destination post-write bytes for only the declared config items that actually changed for that home, in declaration order.
Each changed path is printed with clear begin/end delimiters and the destination file's full exact new bytes unparsed, or the explicit token `ABSENT` when propagation removed the destination copy.
The instruction uses only minimal framing that these are defaults/rules and do not remove judgment; it never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation.
`data/captain-shared.md` is not a config file and is never inlined into this instruction file or message.
Homes whose allowlisted config files were all unchanged receive no config-reread message when no retry is pending.
Different homes may receive different changed-file sets based on their pre-push destination bytes.
Delivery uses the existing routed secondmate path (`fm-send`) with only a single-line `CONFIG_REREAD: <absolute generation-specific instruction path>` pointer; a failed instruction publication retains the generated exact bytes in a bounded private retry queue when possible, legacy retry reports remain recoverable, a failed publication or retry-marker write retains the exact generation until it can be delivered, a failed send records a per-generation durable retry marker when possible, and all failures surface a concrete `CONFIG_REREAD:` diagnostic without claiming the live agent already re-read the values.
The propagation, generation publication, and pointer-delivery sequence holds one per-home inheritance lock, so concurrent mid-session pushes cannot deliver an older generation after a newer one.
A newly launched or relaunched secondmate already reads its files at launch, so its pending config-reread generations are discarded or quarantined after cleanup failure and it needs no redundant live-agent config nudge unless propagation changes files after launch.
Quarantined pre-relaunch generations are retained in bounded private history, and cleanup skips creating an empty quarantine generation.
Successfully delivered generations are retained only within a bounded per-home state history, while pending generations remain until delivery succeeds or a launch supersedes them.
A remote home receives the same allowlisted bytes through `fm-remote-inherit.sh` and gets one marked re-read instruction after a changed transfer.
The parent records that nudge before delivery, retains it after a failed send, and retries the exact same route during locked bootstrap convergence.
It does not receive a pointer to a primary-local generation path that cannot exist on that host.
Inherited harness and runtime-backend defaults must not harden `fm-spawn` to reject a deliberate runtime choice that differs from those defaults.
The [worker launch environment contract](../../../docs/configuration.md#worker-launch-environment-configlaunch-env-allowlist) separately governs explicit environment grants.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited local-material change without running the tracked-file fast-forward.
It uses the same live-home discovery and propagation helper as bootstrap, reports each item as `pushed`, `unchanged`, `skipped`, or `error`, and follows the config-reread contract above for changed or pending generations.
`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; its header owns the complete validation and refusal mechanics.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

## Record intake for an existing or inherited domain

Classify the domain before seeding, because this step applies to only one of the two cases.
A greenfield domain has no delivered domain work yet: nothing already shipped in its projects, no live deployment, and no predecessor records to import.
Seed a greenfield domain normally; there is nothing to reconcile and this section adds no work to it.
An existing or inherited domain is any domain whose product is already in development, and any predecessor's domain a new mate takes over, including a consolidation after a retirement.
Both of those cases require record intake before the new mate acts on any inherited plan.

For an existing or inherited domain, the creating agent must:

1. Reconcile every inherited plan against the domain's authoritative shipped state, which is `origin/main` for each relevant project plus the live deployment.
   A fetched clone of each relevant project is a precondition of that reconciliation, so wire the home to its projects before reconciling rather than on first task.
   The imported backlog, the predecessor's own notes, instruction-surface prose, and an absent or unfetched local view are all inadmissible as shipped-state evidence.
2. Seed the new home with only genuinely open work plus the domain's durable knowledge, meaning the learnings, decisions, and delivery posture that are still live.
3. Never inherit a plan backlog blind.
   A plan row whose work is already shipped is dropped, or recorded as done with the merged evidence that settles it, and is never carried forward as open.

A live backlog keeps only the configured recent Done entries by design, so an inherited queue structurally over-represents plans and under-represents deliveries.
Treat an inherited queue that carries plans with no matching delivery record as unreconciled rather than as open work, and record whatever could not be reconciled as an explicit residual-uncertainty list in the new home rather than leaving that gap silent.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
For an existing or inherited domain, complete record intake first so no already-shipped plan row is handed off as open work.
For a local route, the helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
For a remote route, the same helper first moves the dependency-closed set atomically from the main backlog into `data/handoff/<id>.outbox.md`, then transfers that backlog-format outbox through `fm-on.sh` and lets the remote home's `fm-backlog-receive.sh` move every not-already-present key under the destination lock.
After a new local placement or a remote outbox receipt becomes durable, the helper sends one marked routed-work instruction through the receiving secondmate's recorded endpoint; missing or failed delivery makes the command fail loudly with the moved work intact, and the same handoff command retries known-undelivered wake intent without moving an already-present item again.
An unresolved delivery attempt is never blindly resent.
For a remote route, the outbox remains until both backlog receipt and receiver wake are confirmed; `--resume-pending` retries unfinished outboxes, while the script header owns its stable wake-correlation recovery state.
There is no two-phase handoff journal and no tasks-axi release beyond the already-required atomic `mv` capability.
Bootstrap retries pending outboxes when mutation is authorized and emits `SECONDMATE_HANDOFF:` for any that remain.
This delegated route remains required when `config/backlog-backend=manual`, which controls only routine firstmate backlog edits.
It moves each queued item's whole block - the `- [ ] <id> ...` header plus every following two-or-more-space-indented body line and blank separator, up to the next item or column-0 section heading - byte-exact under the same section, treating an indented `## ...` line as body rather than a section boundary, so neither the header nor its body is duplicated or orphaned.
It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog.
It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries.
Done records stay with their home for pruning or archiving.
It is idempotent; an item already in the secondmate backlog is skipped.
After a successful move it warns for any moved key that still owes a public relay reply bound to `main/<key>`, because that binding no longer names the home owning the work; rebind the commitment to `secondmate:<id>` through the `fmx-respond` promised-final procedure, which owns those commands.
That same rule governs routing generally: a Relay-linked request whose work goes to a secondmate cannot use the home-local mention link at all and needs a promised-final commitment bound to that secondmate's home.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For local `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent home.
For a remote route, the same command probes and relaunches only on the configured host.
An SSH transport failure or unreadable remote endpoint remains unknown and must be reconciled on that host; never launch a local replacement.
`stuck-crewmate-recovery`'s remote-secondmate note owns why the endpoint-dead and send-failed verdicts that seem to justify this are themselves unreliable.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inherited local material, so recovered secondmates converge inherited config items and shared captain preferences whenever their home validates; tracked-file sync remains guarded separately.
If the secondmate is already running and only inherited local material changed, prefer `bin/fm-config-push.sh` over respawning.
To move a live LOCAL secondmate onto a newly pinned harness, model, or effort without a full recovery, set `config/secondmate-harness` and then relaunch it with `bin/fm-control.sh <id> relaunch`, which re-resolves that pin, stops the agent, and launches the replacement in the same home ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane refuses a remotely placed secondmate by name, because its agent runs on another host where none of the plane's postconditions can be read.
Move a REMOTE one with `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness> <model|default|-> <effort|default|->`, which runs that same control-plane relaunch on its host; pass the profile explicitly and use `default` for an absent pin, because `config/secondmate-harness` is not inherited and the copy on that host belongs to a different home ([`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md)).
A successful update restarts every live mate of both placements on its own, including one already on the target commit; the `/updatefirstmate` skill owns that pass, and `bin/fm-secondmate-restart.sh` owns its persist gate and failure vocabulary.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent second mate.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
A remote route delegates the same guard to its configured host and additionally refuses while the primary has a pending handoff outbox or unresolved routed reply.
SSH exit 255 preserves the route and local records because remote completion is unknown.
When safe, teardown kills the direct endpoint, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.
Before either return or direct removal, teardown asks the target home's process-event runner to retire its registrations and physically owned machine-wide claims through the safe generation-bound path.
It refuses retirement while that cleanup is uncertain or unavailable, preserving the home and retirement records for a later retry.
Raw deletion is unsupported because a blocking process-event child can outlive its home.

With `--force`, teardown is the explicit discard path.
The worktree-slot ownership contract in `bin/fm-teardown.sh` still applies: `--force` never authorizes returning a descendant pool slot that another task may own.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
If forced teardown contends with a fresh task publication in any affected home, one command refuses without publishing or removing task state; treat that refusal as terminal and inspect the other operation before retrying.
Relaunch and non-forced teardown remain outside that serialization.
Never use `--force` unless the captain explicitly said to discard the work.
