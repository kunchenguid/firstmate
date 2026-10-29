---
name: secondmate-provisioning
description: >-
  Load when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## Path contract and references

The skill directory is the directory containing this `SKILL.md`.
Load a reference below only at its trigger; files under `references/` are resources of this skill, not additional catalogued skills.
Markdown links inside a reference resolve relative to that reference file.

- [`references/charter-and-seed.md`](references/charter-and-seed.md) - scaffolding a charter, seeding a local or remote home, the secondmate harness, model, and effort pin, and seed validation, rollback, and project-list limits.
- [`references/sync-and-inheritance.md`](references/sync-and-inheritance.md) - launch and bootstrap sync, inherited local-material propagation, shared captain preferences, config re-read delivery, and mid-session `bin/fm-config-push.sh`.
- [`references/backlog-handoff.md`](references/backlog-handoff.md) - moving in-scope queued main-backlog items into a secondmate home.

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
Before moving a live LOCAL secondmate onto a newly pinned harness, model, or effort, check replacement support in [`docs/agent-control.md`](../../../docs/agent-control.md#fail-closed-boundaries).
On a supported backend, set `config/secondmate-harness` and relaunch it with `bin/fm-control.sh <id> relaunch`, which re-resolves that pin, stops the agent, and launches the replacement in the same home.
The same relaunch and recovery paths honor the durable [per-secondmate account pin](../../../docs/configuration.md#per-secondmate-account-pins).
That plane refuses a remotely placed secondmate by name, because its agent runs on another host where none of the plane's postconditions can be read.
Move a REMOTE one with `bin/fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->`, which runs that same control-plane relaunch on its host and then republishes this primary's own route metadata from the identity the host confirmed; pass the profile explicitly and use `default` for an absent pin, because `config/secondmate-harness` is not inherited and the copy on that host belongs to a different home ([`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md)).
Never call `fm-remote-secondmate-control.sh relaunch` through `fm-on.sh` directly for this: it leaves this primary's own record naming the runtime the mate used to run.
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
Non-forced retirement also refuses while any parent pending-reply for that id is still unresolved.
A remote route delegates the in-flight guard to its configured host and additionally refuses while the primary has a pending handoff outbox.
SSH exit 255 preserves the route and local records because remote completion is unknown.
When retirement proceeds, teardown kills the direct endpoint, removes every parent pending-reply record for that id including resolved leftovers and its delivery confirmation, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
An endpoint close that could not be made stops the retirement before any record naming that endpoint is removed, so a cleanup never reports success for an agent that may still be live with nothing left on disk naming it.
[`bin/fm-teardown.sh`](../../../bin/fm-teardown.sh)'s `endpoint_close_refusal` contract owns backend-specific `--force` limits; [endpoint-close verification](../../../docs/verification/runtime-backends.md#endpoint-close) records what each backend can prove.
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
`fm-spawn.sh --relaunch` and non-forced teardown remain outside that task-set serialization; [`fm-secondmate-liveness-lib.sh`'s header](../../../bin/fm-secondmate-liveness-lib.sh) owns automatic recovery serialization.
Never use `--force` unless the captain explicitly said to discard the work.
