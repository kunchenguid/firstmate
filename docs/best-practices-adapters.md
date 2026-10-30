# Best-practices adapters

A project can say which best-practices pack its work follows, the way it says which forge it publishes to: `best-practices=<owner>/<repo>` on its line in `data/projects.md`.
This repository carries one reviewed adapter per supported pack, and the adapter decides what the pack does at each of firstmate's lifecycle facets.
This document owns the design: the facets and flow positions an adapter works against, what it can do at them, what it can never reach, how routing and detection work, and how to add or change an adapter.
[`docs/configuration.md`](configuration.md#best-practices-pack-dataprojectsmd-best-practices-token) owns the operator setting, and [`bin/fm-best-practices.sh`](../bin/fm-best-practices.sh)'s header owns the commands.

## What lives where

| Owner | Holds |
| --- | --- |
| [`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh) `--best-practices` | The one parser of the registry token and its refusals |
| [`.agents/skills/best-practices-adapters/SKILL.md`](../.agents/skills/best-practices-adapters/SKILL.md) | The router: its load trigger, where each position runs, and the `best-practices-adapter-routing-v1` catalog of packs |
| `.agents/skills/best-practices-adapters/references/<owner>/<repo>/` | One adapter: `manifest.json` and the text it contributes at each position |
| [`bin/fm-best-practices-lib.sh`](../bin/fm-best-practices-lib.sh) | The closed sets of facets and positions, the manifest check, the per-harness read, and composition |
| [`bin/fm-best-practices.sh`](../bin/fm-best-practices.sh) | The commands: catalog, manifest check, read, add-time check and proposal, the spawn's version read, and routing |
| [`bin/fm-decision-provider-lib.sh`](../bin/fm-decision-provider-lib.sh) | The typed-decision provider code routing shares with [`bin/fm-dispatch-resolve.sh`](../bin/fm-dispatch-resolve.sh) |
| [`bin/fm-brief.sh`](../bin/fm-brief.sh) `--best-practices` | The token on the brief's Delivery contract line and the practice section after the home include |
| [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) | The registry agreement, the two launch exports, and the one notice |

Nothing from a pack is vendored or executed.
The pack stays the runtime's own install, and the adapter's worker text names the pack's skills rather than copying them.

## Facets and positions

The eight facets are the places firstmate already composes text or acts: `intake.question`, `brief.practice`, `brief.done`, `launch.env`, `scout.report`, `handoff.review`, `landing.post-merge`, and `cleanup.record`.
They sit in a flow of eleven positions, in order:

1. `intake.question`
2. `brief.practice` and `brief.done`, composed together into the brief
3. `launch.env`
4. worker `start`: the isolation assertion and the inbox check, from the brief's Setup
5. worker `work`: implement on a ship, investigate on a scout
6. worker `verify`: the checks the brief requires before done
7. worker `deliver`: the pipeline run, the push and PR, or the clean branch; on a scout it is `scout.report`
8. worker `report`: the done line
9. `handoff.review`
10. `landing.post-merge`
11. `cleanup.record`

Worker-side contributions (`brief.practice`, `brief.done`, the worker positions, `scout.report`, and inserted worker steps) are composed into the brief's practice section.
Firstmate-side contributions (`intake.question`, `handoff.review`, `landing.post-merge`, `cleanup.record`) are references the router loads at the trigger firstmate already has for that position.
`launch.env` is the two exports the spawn writes for every adapter and nothing else.

## What an adapter does

At each facet its manifest names, an adapter does one of three things:

- extend: firstmate's practice stays and the adapter's contribution is folded into it;
- replace: the adapter's practice stands in for firstmate's at that facet;
- pair: both run whole, `firstmate-first` or `pack-first`; on the worker side the pack's half is a skill the runtime loads from the enabled pack, named and never copied, and on the firstmate side it is the adapter's reference.

It can also insert a step the pack has and firstmate does not, and reorder the worker flow, which are one mechanism: the manifest's `flow` lists the worker positions plus its inserted ones in the order the brief tells the worker to run them, and the brief states that whole order whenever it differs from firstmate's own.
A firstmate-side insert is a reference loaded before or after a firstmate-side position, because those positions are triggers and nothing runs between them.
A facet or position the adapter does not name is unchanged, which is also what every project without the token gets, and a home or project cannot change what an adapter does.

## Off limits

No adapter can replace, pair with, insert around, or reorder anything that would get past these, and review refuses an adapter that reaches for one.

- Destructive: discarding unlanded work (`AGENTS.md` hard rule 3 and `bin/fm-teardown.sh`, whose `--force` is its one override); destructive, irreversible, or security-sensitive merges, which escalate even under `yolo` (`AGENTS.md` section 7 and `bin/fm-pr-merge.sh`'s attended-only waivers); and project removal (`project-management`).
  None of those is pre-authorizable in away mode, runnable straight from a Relay mention, or bindable to an automated watch.
- Outward-facing: creating a GitHub repository only with consent to its exact name, owner, and visibility; publishing to firstmate's own upstream only under `config/firstmate-role` or a one-task consent (`bin/fm-role-lib.sh`); and a Relay public reply only under Relay's own consent.
- Merge authority in general: no merge without the captain's word, `+yolo` the only standing relaxation, no red merge without a named waiver, Gerrit and `forge=external` never under `yolo`, `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` the only merge paths, and workers never merge.
- The worker's no-push rule and isolation: rule 1 and rule 2 of every generated brief, and the isolation assertion its Setup runs first.
- The isolation check staying first and the done report staying last.

None of those lives at a facet or a position: they live in script refusals and the supervisor contract's hard rules, and an adapter's output is only brief text and router references.
The router loads references at the eleven positions only, and `bin/fm-best-practices.sh manifest-check` refuses a manifest that names any other facet or position, a `flow` that moves `start` from first or `report` from last, a replace or pair at either, or a `launch.env` that adds anything, so nothing an adapter writes is read by the teardown, merge, role, project add or remove, away, Relay, or process-event paths.
On the worker side the practice section is the brief's last section and ranks itself below every section above it, so no step it adds can outrank rule 1 or rule 2; on the firstmate side a reference is instruction text ranked below `AGENTS.md`'s hard rules.
No facet sits at the merge decision: `handoff.review` comes before it and `landing.post-merge` after.

## Routing

An adapter may declare routing rows per facet, each naming a condition and the reference blocks it selects.
A row whose condition is a fact firstmate already holds (task kind, delivery mode, forge) is a `fact` row read in code, and the requester's own words a row names (`words`) are matched in code on word boundaries and win.
Every other row goes to the typed-decision provider through [`bin/fm-decision-provider-lib.sh`](../bin/fm-decision-provider-lib.sh), the same key handling, never-send check, and POST that [`bin/fm-dispatch-resolve.sh`](../bin/fm-dispatch-resolve.sh) uses, with all of a composition's rows in one request carrying the brief's task sections as state.
A mutually exclusive pick is a `choice` with a fixed `none` option firstmate adds; a yes-or-no, and each label of a multi-label pick, is a `noul` thresholded in code at the row's `min_confidence`, 0.6 by default.
A confident answer narrows what is composed; low confidence, no key, a never-send match, an error, or a timeout keeps each row's declared `fallback`, which is the adapter's static behavior, so routing never composes less than the adapter would without it.
Routing happens only when firstmate composes, at intake and on the filled brief, never inside a worker, so a worker's brief stays fixed for its life.

## Detection and proof

A pack is checked where the worker's harness keeps it, through the repository the token names, for three answers: installed, enabled, and which version.
The read differs by install shape: a plugin registry (Claude Code's and Oh My Pi's `installed_plugins.json` tied through their marketplace records, Codex's `config.toml` tables and plugin cache, Antigravity's `agy plugin list --json` tied through the installed copy's manifest) or a skills directory, where installed means every one of the pack's skills is where the harness loads them and enabled means the harness's own switch, when it has one, disables none of them.
Which version is read from the content, not the runtime's label: the manifest's `fingerprints` hold the SHA-256 of each `SKILL.md` the adapter's own references name, with line endings normalized, generated from each reviewed tag's release by `bin/fm-best-practices.sh fingerprints` and never by hand, and the installed copy's files are hashed the same way in every install shape.
A copy whose files all match a reviewed tag reads as that tag (the runtime's label only picks which tag to try first); one with any file that differs or is absent reads as `unreviewed`, naming those skills against the nearest reviewed tag; one holding none of them is no usable copy.
There is no fuzzy matching.
Enabled is judged as a worker copy will see it: user scope and what the project commits count, a gitignored local settings file does not, and committed settings and skills are read from the checkout itself, which at spawn is the prepared worker copy, so a worker whose branch differs from the clone's is read as it will run. Only a project-scope install's identity is the clone: a worker copy maps back to it through its git common directory.
The supported-version list carries release tags only, and a tag is supported only once its fingerprints are generated.

Each read is harness-dependent, so it is proven live against the real harness before the adapter ships for that harness, and the manifest records the read and its proof per harness.
A harness whose proof is `unproven` is inside the adapter's runtime list but does not ship yet: the add-time check reports it, and the spawn's version read writes `missing` for it rather than claim a pack it cannot confirm.
A proof can also exclude one scope (`unproven_scopes`), and a pack found only in that scope is treated the same way.
An adapter's runtime list is every harness both firstmate verifies and the pack ships or documents an install path for, and it is complete only when each of them has a proven read.

## Where the token takes effect

At project add, firstmate proposes the token only from what the project itself commits, writes it only after the captain confirms it, and checks the pack once (`project-management`).
After that the token is a registered fact: every ship or scout intake reads it and passes it to `bin/fm-brief.sh`, and the spawn refuses a brief that disagrees with the registry.
The spawn's version read is not a pack check and never blocks: it fills `FM_BEST_PRACTICES_VERSION` with exactly one of three values.

- A reviewed tag: the depended-on files match that tag's reviewed text, and the adapter applies as normal.
- `unreviewed`: the pack is loaded but at least one depended-on file matches no reviewed text (a local edit, a newer or older release, or an unreleased commit); the adapter still applies, because the runtime loads the pack's skills anyway and stepping aside would leave a loaded pack ungoverned, the spawn prints one notice naming the differing skills with the runtime's own label as a hint, the launch brief lists them, and the worker names them in its done summary.
- `missing`: no usable copy; the worker follows firstmate's defaults and says so, and the spawn prints one notice.

The off-limits rules hold whichever value a launch carries, and firstmate relays a notice at the start of the task.
A change to the registry line takes effect at the next launch, and a running worker keeps what it launched with.
A scout promoted with `bin/fm-promote.sh` keeps its scout composition: promoted work follows firstmate's defaults for now, and the adapter's done-summary, doubt-cycle, and constraints expectations do not apply to it at handoff.

## Adding or changing an adapter

1. Create `references/<owner>/<repo>/manifest.json` (schema `best-practices-adapter-v1`) and one reference per contributed position; worker-side references are `## <block-id>` blocks, one contribution each.
2. Add the pack to the routing object in the router skill, with the same actions, orders, and references as the manifest.
3. List the runtimes both sides support, implement any new read shape in `bin/fm-best-practices-lib.sh`, prove each read live, and record each harness's proof or its reason for being unproven.
4. Classify every new Markdown file in `docs/documentation-audiences.json`.
5. Run `bin/fm-best-practices.sh manifest-check` and `tests/fm-best-practices.test.sh`.

A pack release that changes what the adapter relies on gets an adapter change and a new supported tag; nothing tracks a pack's upstream automatically.
