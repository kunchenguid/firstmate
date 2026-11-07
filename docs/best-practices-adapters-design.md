# Best-practices pack adapters: the design

This document is the full design behind the pull request that proposes best-practices pack adapters.
The pull request description carries the problem, one diagram of the flow, the proposal in summary, the outcome evidence, and the open questions; this document carries everything in full.
What it proposes is the mechanism, with every adapter gated on evidence that it beats the baseline on real work.
It is a proposal: once the mechanism lands, the implementation's own documents own the current contract, and this document stays as the record of the design and the reasons behind it.

## TL;DR

I want a project to say which best-practices pack its work follows the same way it says which forge it publishes to: `best-practices=addyosmani/agent-skills` on the registry line, beside `+yolo`, `branch=`, and `forge=`.
The value is the pack's repository, not its plugin name, because one pack shows up under several marketplace entries and a name says nothing about who published it.
This repository carries one reviewed adapter per supported pack.
The adapter says what the pack does at each position in firstmate's SDLC flow: extend it, replace it, or pair with it, firstmate's practice first or the pack's first.
It can also insert a facet the pack has and firstmate does not, at any point in firstmate's flow, and reorder the worker's stages, TDD before implementation for instance.
Whatever the adapter does not mention stays as it is, and firstmate's safety rules are off limits to every adapter: the destructive and outward-facing ones, merge authority, the worker's isolation and no-push rule, and the isolation check first and the done report last.
The pack itself stays the runtime's own install, and an adapter supports every harness that both firstmate and the pack support, not a hand-picked pair.
The token comes up the way the forge does when you add a project: firstmate proposes it from what the project already enables, writes it only after you confirm it, and checks the pack itself the way it checks a tool login, so you only hear about it when something is wrong.
The worked sample is an adapter for Addy Osmani's agent-skills 0.6.14, on the nine harnesses both firstmate and the pack support.
It is a sample, not a recommended pack: it did not beat the baseline on the first evaluation, at 1.61 times the cost per task for the same quality.

## What I ran into

The generated worker brief says how to isolate, branch, report, and drive the pipeline.
It says nothing about how to engineer.
A direct-PR or local-only task runs no checks at all unless the project's own instructions ask for them.

I adopted Addy Osmani's agent-skills and tried both ways of bringing a pack in.
Neither is governed.
Hand-wiring means a block in `config/brief-include.md` per home, `export` lines in shell startup for toggles, and preference lines in `data/captain.md` for the firstmate-side habits, copied across homes with no pin and no per-project scope.
On `main` `127f0f30` a bare direct-PR brief grows from 11.4 KB to 21.9 KB with a 44-line block, for every task in the home, whether the project wants it or not.
Installing the pack as a runtime plugin puts its skills, commands, and hooks into every worker session on that runtime, where they overlap the brief on review, git workflow, worktrees, and human gates, and nothing decides which side wins at an overlap.

VISION says new capability ships as an option to enable, never as behavior that assumes consent.
Both paths break that, one by hand and one by default.

## Proposal

### The token is a project fact, like `forge=`

`best-practices=<owner>/<repo>` goes on the project's line in `data/projects.md`, order-independent beside `+yolo`, `branch=`, and `forge=`.
One value: a project follows one pack, as it has one forge.

Why the repository and not the plugin name.
The case on record: `superpowers` is one plugin published under one name through three marketplaces.
[claude-plugins-official](https://github.com/anthropics/claude-plugins-official) lists it with the git URL `https://github.com/obra/superpowers.git`; [superpowers-marketplace](https://github.com/obra/superpowers-marketplace) lists it with the same URL; and the `superpowers-dev` marketplace inside [obra/superpowers](https://github.com/obra/superpowers) itself lists it as the relative path `./`, the repository it sits in.
A runtime records an install as `<name>@<marketplace>`, so which entry a user installed from is a registry fact, and the pack behind all three is one repository.
That is why the token resolves through the marketplace entry to a repository, which is also what the plugin manifest names in `repository`.
The risk, not seen anywhere yet and stated as a risk: two different packs sharing one plugin name.
A name says nothing about who published it, so `addyosmani/agent-skills` and `obra/superpowers` could share a plugin name tomorrow, and the repository would still tell them apart.
Codex already takes `owner/repo[@ref]` as a marketplace source in `codex plugin marketplace add`, so the token's form is one the runtime speaks.

The adapter for that repository, not the user, knows the plugin name and the marketplaces each runtime records it under.
"Detection" below says how it ties them together from the registry files.

Mechanics follow the forge path exactly.
`bin/fm-project-mode.sh --best-practices <project>` reads the token back as `--forge` reads its binding, firstmate passes it to `bin/fm-brief.sh --best-practices` at intake the way it passes `--mode` and `--forge`, the generated ship or scout brief carries it on its `Delivery contract:` line, and `bin/fm-spawn.sh` refuses a brief whose value disagrees with the registry.
Which pack a project follows is never a per-task choice.
A value naming a repository this firstmate has no adapter for is refused by the parser, as an unknown forge is; the add flow below is where firstmate keeps you from writing one.

One place it differs from a forge, on purpose: it composes with every mode, local-only included, and with every forge, because it says how the work is engineered rather than how it is published; `yolo` is untouched.

How the token comes up is the add flow in "How it comes up when you add a project" below.

### An adapter lives in this repository

Adapters take the shape `harness-adapters` already gives per-tool knowledge.
The always-loaded skill index grows by one entry in total, not one per pack, and everything lands inside what `AGENTS.md` section 12 says a running firstmate loads (`AGENTS.md`, `bin/`, `.agents/skills/`), which is also what self-update treats as the instruction surface.
No top-level `adapters/` directory.
Nothing from a pack is vendored or executed, and each adapter is reviewed and shipped like any other tracked material.

- One agent-only router skill, `.agents/skills/best-practices-adapters/SKILL.md`.
  Its description is its load trigger (a task whose project registers `best-practices=`), and it carries a machine-readable routing object in the shape of `harness-adapters`' `harness-adapter-routing-v1`: per pack, each facet or position to what the adapter does there and to the reference that holds the contribution.
- `references/<owner>/<repo>/` inside that skill, one directory per adapter mirroring the token (`references/addyosmani/agent-skills/`).
  It holds the manifest (the pack's repository, its plugin name and marketplaces per runtime, the supported tags, each with a hash per file of the skills the adapter depends on at that tag, the supported runtimes, what the adapter does at each facet or position, and the flow when it inserts or reorders) and the text the adapter contributes.
  A firstmate-side contribution is a reference the router loads at its facet, the way `harness-adapters` loads its references, not a separately catalogued skill.
- Mechanics in `bin/fm-best-practices.sh` and `bin/fm-best-practices-lib.sh`: the read per runtime, a plugin registry or a skills directory, the pack check by content fingerprint, the subcommand that writes a tag's hashes from a checkout of the pack at that tag, and the manifest check that refuses an extend, replace, or pair target that is not a name at the flow's eleven positions, an inserted name that collides with one of them or is not anchored to one of them, replace or pair on `brief.done`, `launch.env`, `start`, `deliver`, or `report`, and any flow that moves a position it must not, with the script header owning the exact commands as `firstmate-coding-guidelines` requires.
  `bin/fm-project-mode.sh --best-practices` is the one parser of the token beside its posture, `--forge`, and `--branch-prefix` queries; `bin/fm-brief.sh` and `bin/fm-spawn.sh` consult it only when a project registers a pack.
- A maintainer-architecture document classified in `docs/documentation-audiences.json`, a `docs/configuration.md` section beside the forge section, one line in `project-management`'s add flow beside the forge line, and `tests/fm-best-practices.test.sh` mapped in `bin/fm-test-run.sh`, exercising the behavior through the executables, with the test that fails when a manifest's hashes disagree with the tag they claim.

For the first adapter: repository `addyosmani/agent-skills`, plugin name `agent-skills` in both of the pack's manifests, registry identities `agent-skills@addy-agent-skills` on Claude Code and `agent-skills@agent-skills` on Codex.
The marketplace names come from the marketplace files the pack itself ships, `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`.

### Outcome evidence, before an adapter ships

Being wired correctly is not the bar.
An adapter changes how every task on a project is engineered, and a plausible practice can make an agent worse: on the DeepSWE eval Kun published ([his post](https://x.com/kunchenguid/status/2108030810691629403)), banning agent-written unit and integration tests raised success a little while cutting time and tokens, which nobody would have predicted from reading the practice.
So an adapter ships only when it beats the baseline on real work, and the plan that shows it is part of the adapter, not a nice-to-have after it.

The first evaluation is a small Next.js todo app in the TodoMVC shape ([todomvc.com](https://todomvc.com/)): small enough that one person can read every diff, with a spec everyone already knows.
One set of real tasks on it, features and bug fixes of the kind a project actually gets, each run twice from the same base commit in isolated copies, with the same harness, model, and effort and the project's own delivery path: once with the project line as it is, once with `best-practices=addyosmani/agent-skills` added.
Grading is by tests the worker never sees: hidden end-to-end acceptance tests written for each task before any run, and the TodoMVC regression suite over the whole app after it.
A run is judged against what the user would do, never against tests the worker wrote, which are a second copy of the worker's own reading of the task.

Per task, both arms are measured on:

- Success: the hidden acceptance tests pass, the regression suite still passes, and the change landed through the delivery path.
- Rework: review findings per pipeline step, from the `steps[]` table with a `findings` count per step that a no-mistakes run already reports, plus the steers and relaunches in the task's status log.
- Time: dispatch to done, from the fleet ledger's `task.dispatched` and `task.status` records, which carry Unix timestamps (`docs/fleet-ledger.md`).
- Tokens: from the harness's own session record for the task.
  Firstmate does not collect tokens today; the evaluation reads them where the harness writes them, and a harness that writes none reports tokens as unmeasured, never estimated.
- Alignment: a side-by-side of what each arm produced, the behavior covered, the edge cases handled, the tests and docs written, and what one arm did that the other did not, with a plain statement of how closely the no-adapter result matches the adapter result.

A project is worked by more than one agent over time, so the team measures come next, and a single task cannot show them:

- A chain: several dependent tasks run in order on one branch, each arm its own chain, measuring what a later contributor's change costs and breaks on top of the earlier ones.
- Consistency: the same task run more than once per arm, and how far the results spread.
- Reviewability: each run's change size, done summary and PR text, verification story, follow-ups, and decision records, scored blind against a fixed rubric by someone who does not know which arm produced it.
- Handoff: whether another agent, given only what a run left behind, the branch, the summary, and the records, can continue the work.

The verdict rule.
If the two arms are essentially the same, or the no-adapter arm covers everything the adapter arm did and more, the setup without the pack is the better one, being simpler and cheaper, and the record says so.
An adapter is recommended only where it adds something the baseline misses, and the record names that something.
Equal everywhere is a loss, because an adapter is review and maintenance for nothing.
A task set too small to separate the two arms is reported as too small, not as a pass.

The record lives in `docs/verification/best-practices-adapters.md` beside the resolver's record, per adapter and per reviewed tag, with the task set and the rubric named, so the next reviewer re-runs it rather than trusts it.
The test that fails on a stale hash proves the adapter is wired to the text it reviewed; this proves the text was worth wiring.

The first evaluation ran this plan on Addy's agent-skills 0.6.14, and the adapter did not clear the bar.
Mean quality was 0.998 without the pack and 1.000 with it (p = 1.0), and maintainability was the same.
Cost was higher with the pack: 1.61 times per task, 1.80 times per feature along a chain, and 1.32 times the cost of ownership.
The pack's practices were followed and did not change outcomes.
By the verdict rule the setup without the pack is the better one, so agent-skills is this design's worked sample, not a recommended pack, and this result does not make its adapter ready to ship.
Both arms hit the ceiling on these tasks, so the result rules out a benefit at this difficulty, not on harder work.
Both setups hit or nearly hit the ceiling on the first evaluation, so I am preparing a more complex test, in the hope that it shows which setup performs better at a larger scale.
The bar stays as written.

The evaluation can be rerun for any later pack or version: its bar, tasks, hidden grader, review material, and run plans are published with both builds.
I will also run the sample implementation on my own work for the next week or so and report back, as the test on harder work that the first evaluation could not show.
The results are published where a reader can check them: the evaluation report arrives as its own pull request to this repository, beside the pull request that proposes this design and the one that carries the sample implementation, and it links the two builds, the [base version built without the adapter](https://github.com/ahcarpenter/firstmate-eval-todomvc-baseline) and the [version built with Addy's agent-skills through it](https://github.com/ahcarpenter/firstmate-eval-todomvc-agent-skills).
The plan, the bar, and the verdict are stated here; the full numbers live there.

### Extend, replace, or pair with firstmate's SDLC facets; insert into or reorder its flow

Firstmate runs its lifecycle through these facets, each a place where it already composes text or acts.
They, and the worker stages `work` and `verify` and the other positions in the flow below, are what an adapter can extend, replace, or pair with:

| Facet | Where firstmate composes or acts today |
| --- | --- |
| `intake.question` | The one concise question firstmate asks at intake when an ask is ambiguous |
| `brief.practice` | The practice section, written as the last section of ship and scout briefs, after the home brief additions, with its own precedence line ranking it below every section above it; when it is present the home section's precedence sentence excludes it, so the home additions outrank it with no mutual yield |
| `brief.done` | The generated Definition of done for the task's delivery mode, which carries the delivery instructions and the `done:` report contract and stays firstmate's; an adapter can only extend it, and its text lands in the practice section |
| `launch.env` | The worker launch environment at the site where `bin/fm-spawn.sh` exports `FM_TASK_INBOX`, which survives a compound raw launch and the allowlist's `env -i` |
| `scout.report` | The report structure the scout brief and `scout-completion` expect; an adapter's text lands in the practice section |
| `handoff.review` | What firstmate checks when a worker reports done, under `validation-supervision` and `ship-landing` |
| `landing.post-merge` | What firstmate does after `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh` lands, under `ship-landing` |
| `cleanup.record` | What firstmate records on the work item before `bin/fm-teardown.sh` |

At each facet or position the adapter's manifest says one of three things, and `brief.done`, `launch.env`, `start`, `deliver`, and `report` accept extend only:

- Extend.
  Firstmate's practice at that facet stays and the adapter's contribution is folded into it.
  One practice, firstmate's, with more in it.
  A done summary that also names the checks run is an extension.
  On the worker side its text is written in the practice section, so the generated sections above it stay firstmate's.
- Replace.
  The adapter's practice stands in for firstmate's at that facet.
  On the worker side its text still lands in the practice section, so it cannot displace a section above it.
- Pair.
  Both run whole, in the order the adapter declares: firstmate's practice first and then the pack's matching one, or the pack's first and then firstmate's.
  On a worker-side facet the pack's matching one is a skill or command the runtime loads from the enabled plugin, named by the adapter and never copied.
  On a firstmate-side facet it is the reference the adapter carries for it, because firstmate's own runtime need not have the plugin.

Two more things an adapter can do, both against the flow those facets sit in.
The flow has positions, so "any point" and "reorder" point at something concrete.
The firstmate-side positions are the triggers firstmate already has; the worker-side positions are the stages the generated brief already puts in order (`bin/fm-brief.sh` writes Task, Setup, Rules, and the Definition of done, and the worker runs them in that order).
In order:

1. `intake.question`
2. `brief.practice` and `brief.done`, composed together into the brief
3. `launch.env`
4. worker `start`: the isolation assertion and the inbox check, from Setup
5. worker `work`: implement on a ship, investigate on a scout, from the Task
6. worker `verify`: the checks the brief requires before done
7. worker `deliver`: the pipeline run, the push and PR, or the clean branch, per the Definition of done; the report for a scout, which is `scout.report`
8. worker `report`: the done line
9. `handoff.review`
10. `landing.post-merge`
11. `cleanup.record`

- Insert.
  An adapter can add a facet the pack has and firstmate does not, at any of those positions.
  On the worker side it becomes a step the practice section tells the worker to run at that point, carrying the pack's skill by name.
  On the firstmate side it becomes a reference the router loads before or after the facet at the nearest trigger, because firstmate's positions are its triggers and nothing runs between them.
- Reorder.
  An adapter can state the flow as an ordered list, firstmate's positions plus its inserted ones, and that order is what the practice section tells the worker to run.
  Insert and reorder are one mechanism: the adapter writes the list.
  The case I want is TDD before implementation.
  The pack's test-driven-development skill becomes a `tdd` facet, and the list puts it before `work`, so the failing test is written before the code.
  Moving an existing stage works the same way; `verify` before `deliver` is where it already is, `verify` before `work` is a different flow.
  Only worker positions move, and three of them are fixed: worker `start` stays first, worker `report` stays last, and `deliver` stays after `verify`.
  Firstmate's positions, `handoff.review`, `landing.post-merge`, `cleanup.record`, and the rest, keep their order, and the manifest check refuses any flow that moves them.

A position the adapter does not name keeps its place, and a facet it does not mention is unchanged, which is also what every project without the token gets.
When an adapter inserts or reorders, the practice section states the whole order explicitly, because today that order is only implicit in the brief's sections; with no adapter, the brief is as it is.
A home or project cannot change what an adapter does at a facet or where it puts a position; that is the adapter's review to decide.

Off limits.
No adapter can replace, pair with, insert around, or reorder anything that would get past the destructive and outward-facing rules firstmate ships, and `bin/fm-best-practices.sh` refuses a manifest that tries at the places one could.
Destructive: discarding unlanded work (`AGENTS.md` hard rule 3, and `bin/fm-teardown.sh`, which refuses before any destructive step and has `--force` as its one override site); destructive, irreversible, or security-sensitive merges, which escalate even under `yolo` (`AGENTS.md` section 7, `bin/fm-pr-merge.sh` with its attended-only waivers); project removal (`project-management`, an explicit removal decision plus the unlanded-work preflight); and none of those is pre-authorizable in away mode (`afk`), runnable straight from a Relay mention (`fmx-respond`), or bindable to an automated watch (`process-event-sources`).
Outward-facing: creating a GitHub repository only with consent to the exact name, owner, and visibility (`project-management`); publishing to firstmate's own upstream only with the maintainer opt-in in `config/firstmate-role` or a one-task consent (`bin/fm-role-lib.sh`); a Relay public reply only under Relay's own consent, with a destructive ask from a mention escalating first (`fmx-respond`).
Also off limits: merge authority in general (`AGENTS.md` hard rule 2 and section 7: no merge without the captain's word, `+yolo` the only standing relaxation, no red merge without a named waiver, Gerrit and `forge=external` never under `yolo`, `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` the only merge paths, and workers never merge); the worker's no-push rule (rule 1 of every generated brief, which `bin/fm-dod-lib.sh`'s `fm_ship_rule_one` writes per mode and forge, and `bin/fm-brief.sh`'s scout rule 1); the worker's isolation (rule 2, stay inside the isolated copy, and the isolation assertion the brief's Setup runs before anything else); and the isolation check staying first and the done report staying last.
How the design keeps them out of reach, with nothing new.
The merge, destructive, and outward-facing rules live in script refusals and in the supervisor contract's hard rules, and an adapter's output is only brief text for the worker, the two `launch.env` exports, and references for the router.
The rest sit in what firstmate generates for the worker, which an adapter can reach by name, so those names accept extend only: `brief.done` is the generated Definition of done, which carries the delivery instructions and the `done:` report contract; `launch.env` is the site that exports `FM_TASK_INBOX`, and an adapter adds only the two exports firstmate writes there; and `start`, `deliver`, and `report` are the isolation assertion, the delivery steps, and the done line.
The manifest check refuses replace and pair on all five, and an adapter's `brief.done` and `scout.report` text lands in the practice section, never in the generated Definition of done, which stays firstmate's.
The router loads a reference at the eleven positions and nowhere else, and `bin/fm-best-practices.sh` refuses a manifest whose extend, replace, or pair target is not a name at those positions, or whose inserted name collides with one or is not anchored to one, so nothing an adapter writes is read by `bin/fm-teardown.sh`, `bin/fm-pr-merge.sh`, `bin/fm-role-lib.sh`, the project-management add and remove flows, away mode, Relay, or a process-event binding.
On the worker side all of an adapter's text, `brief.done` and `scout.report` included, lands in the practice section, which is the brief's last section, after the home brief additions, and `bin/fm-best-practices-lib.sh` writes it with its own precedence line: every section above it, the home brief additions included, takes precedence over anything in it that conflicts, so an inserted or reordered step cannot outrank the brief's safety rules or the home's standing additions.
When a practice section is present, the home section's precedence sentence, which `bin/fm-brief.sh` writes, excludes it, so the home additions outrank the practice section with no mutual yield.
On the firstmate side a reference the router loads is instruction text ranked below `AGENTS.md`'s hard rules by the contract's own order, with no path to a script's refusal.
For the four that follow the list: no facet or position sits at the merge decision, `handoff.review` comes before it and `landing.post-merge` after, `bin/fm-best-practices.sh` refuses a list that moves either, and the two merge scripts read nothing an adapter writes; rule 1 and rule 2 of the brief sit above the practice section and outrank it by that precedence line, so no inserted or reordered step can push, open a PR, merge, or leave the isolated copy; and worker `start`, the isolation assertion, is fixed as the first worker position and worker `report`, the done line, as the last, whatever an adapter's ordered list says, and `deliver` stays after `verify`, with `bin/fm-best-practices.sh` refusing a list that moves any of them or inserts a worker step before the first or after the last.
The maintainer document carries this list, so a review of an adapter that reaches past it has a named reason to refuse.

Worker-side facets compose into the brief's practice section.
Firstmate-side facets compose into the reference the router loads at a trigger firstmate already has.
The `launch.env` contribution is two exports that name the pack and what the spawn found of it, `FM_BEST_PRACTICES=<owner>/<repo>` and `FM_BEST_PRACTICES_VERSION=<value>`, made at launch by the read "Detection" describes against the runtime's registry or skills directory, so the practice text and the done summary can say what was active.
No switches.
The version is never empty, and it is one of exactly three values, each with one rule:

- A reviewed tag, `0.6.14` for instance.
  The files of the skills the adapter depends on match that tag's reviewed text, and the adapter applies as normal.
- `unreviewed`.
  The pack is loaded, but at least one file the adapter depends on matches no reviewed text: a local edit, a newer release, or an unreleased commit.
  The adapter still applies.
  The runtime loads the pack's skills whatever firstmate does, so stepping aside would not take the pack out of the worker's hands, it would only take the governance off a pack that is already in them.
  The spawn prints one notice naming the skills that differ, with the runtime's own version label beside them as a hint to what happened, and the practice section tells the worker to name those skills in its done summary.
  The off-limits rules hold either way; a worker at `unreviewed` is bound exactly as one at a tag.
- `missing`.
  No usable copy, not installed or installed but disabled.
  The practice section firstmate composes for any adapter carries one line for that case: if the version reads `missing`, the pack is not loaded, so follow firstmate's defaults and say so in the done summary.
  The spawn prints one notice here too.

Nothing quietly claims the pack ran, and nothing quietly claims a reviewed pack ran when an edited one did.

### Routing inside an adapter, through Jev

Between a facet and the adapter's contributions sits an optional routing table, declared by the adapter per facet.
Each row names a condition and the contribution it selects: which of the pack's on-demand skills a task needs, whether an edit is trivial for the floor exemption, whether the project deploys from its default branch.
A row whose condition is a fact firstmate already holds, the delivery mode, the task kind, the forge, is read in code, and Jev is asked only the fuzzy conditions, such as whether a task is a bug fix or which domain skills it touches.

This is a constrained pick over predefined options, which is exactly what `bin/fm-dispatch-resolve.sh` already uses Jev for, so the adapter reuses that provider code as is (`docs/configuration.md`, "Typed dispatch resolution"): typesafe.ai `v1/systemone` with `jev-latest`, or OpenRouter's `alpha/decisions` with a configured model; the key held in a private variable and unset for children; every request string checked against `config/dispatch-never-send`; the same 0.6 confidence floor with a per-row `min_confidence` and runner-up fallback.
The request carries the brief's task sections as state, as the resolver does today, and all of a facet's conditions in one request, because the API's `questions` map evaluates several questions independently and in parallel at about the latency of one.
Each condition is typed as the API types it: a mutually exclusive pick is a Choice with a fixed none option, a yes-or-no such as "trivial edit" is a Noul whose probability is thresholded in code, and a multi-label pick, such as a task that touches security and an API at once, is one Noul per label, since no multi-select type exists.

A confident pick narrows what is composed to the selected contributions.
Low confidence, no key, a never-send match, an error, or a timeout falls back to the adapter's static behavior, the full table.
Nothing gets worse than the adapter without routing.
Cost, from the resolver's recorded request size of about 600 input tokens: under a hundredth of a cent per composition at the published $0.042 per million input tokens, and about 100 to 350 ms.
Jev routes only when firstmate composes, never mid-task inside a worker, so a worker's brief stays fixed for its life as every launch-time setting does.
Before the routing layer ships, the evidence plan is the one the resolver already follows in `docs/verification/dispatch-resolve.md`: run the first adapter's table over real past briefs, record agreement with a model's judgment per condition, and keep or raise each row's floor where they disagree.

### The pack stays the runtime's own install

The user installs the pack the way the pack's own setup document for that harness says, and the harness loads the pack's skills into the worker session by itself, so the adapter's worker text carries no copy of the pack.
It says which firstmate rules win where the pack overlaps them, states the floor the pack adds, and routes the pack's skills by condition.
One overlap rule holds for every adapter: where a pack's skill names a tool firstmate has its own for, the worker uses the skill's method with firstmate's tool.
`chrome-devtools-axi` where `browser-testing-with-devtools` and `performance-optimization` say Chrome DevTools MCP, `gh-axi` where a skill says `gh`.
That same fact bounds what an adapter governs.
What the harness loads from the pack, its commands and any hooks it registers, is the harness's and the user's choice; the adapter's supported-pack notes say what that pack brings along.

An adapter supports every harness that both firstmate and the pack support, and nobody picks that list by hand.
Firstmate's side is its verified harness list (`AGENTS.md` section 4: `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `omp`, and `agy`, plus `muse`, `gemini`, `rovo`, `devin`, `commandcode`, `polytoken`, and `cortex` for crewmates and scouts).
The pack's side is what it ships or documents for a harness: a plugin manifest or marketplace entry, or a setup document that names where its skills go on that harness; a generic "installs into 70+ agents" line counts for a harness only when the pack names that harness's location.
The intersection is the adapter's runtime list, and it grows when either side adds a harness.
Addy's pack at 0.6.14 ships four install shapes for harnesses firstmate verifies, in its [README](https://github.com/addyosmani/agent-skills/blob/0.6.14/README.md) and [docs/](https://github.com/addyosmani/agent-skills/tree/0.6.14/docs): a plugin on Claude Code, Codex, Oh My Pi, and Antigravity; a skills directory its CLI installs on Gemini CLI (`gemini skills install`) and Command Code (`cmd skills add`); a skills directory the user copies on OpenCode and Cursor; and a package Pi's own installer fetches from git (`pi install git:github.com/addyosmani/agent-skills`, in `docs/other-hosts.md`), which covers firstmate's `pi` and `pi-signed`.
Nine harnesses.
It also documents Copilot, Windsurf, Kiro, fx, and Dojo Workspace, which firstmate does not verify, so they sit outside the intersection until firstmate does; its generic line that it installs into 70 or more agents names Cline with no location, so Cline does not count.

### Detection, from the registry files

When firstmate checks a pack, it finds it where the worker's harness keeps it, a plugin registry or a skills directory, through the repository the token names, and asks three questions: installed, enabled, and which reviewed tag the files of the skills the adapter depends on match, with `unreviewed` the answer when they match none.
The read differs by install shape, and each harness's read is proven live before the adapter ships for that harness, as the repository requires of every harness-dependent check.
"Enabled" is judged as the worker's isolated copy will see it.
User scope and what the project commits count; a gitignored local settings file does not, because it is not in the copy.

Claude Code.
`~/.claude/plugins/installed_plugins.json` keys each plugin as `<name>@<marketplace>` and records, per install, its `scope` (`user`, `project`, or `local`), `installPath`, and `version` ([plugin loading reference](https://code.claude.com/docs/en/plugins/loading#check-which-stage-a-plugin-reached)).
The tie from the token to that key runs through the marketplace.
`~/.claude/plugins/known_marketplaces.json` records each marketplace's own `source`, a `github` object with `repo` for a marketplace added as `owner/repo`, and the marketplace's `.claude-plugin/marketplace.json` records each plugin's source in one of the shapes the [marketplace reference](https://code.claude.com/docs/en/plugins/marketplace-reference#plugin-sources) lists.
The packs named here use three: a GitHub `repo` (`addyosmani/agent-skills` in the pack's own `addy-agent-skills` marketplace), a git `url` (`https://github.com/obra/superpowers.git` in `claude-plugins-official` and in `superpowers-marketplace`), or a relative path such as `./` meaning the marketplace's own repository (`superpowers` in the `superpowers-dev` marketplace inside `obra/superpowers`).
An install counts when its marketplace entry resolves to the token's repository by any of those shapes.
The installed copy's `.claude-plugin/plugin.json` `repository` field is corroboration, never the tie, because the pack writes it.
Enablement is the `enabledPlugins` entry for that key in `~/.claude/settings.json` (user) merged with the project's committed `.claude/settings.json` (project), `true` enables and `false` disables, project over user ([settings reference](https://code.claude.com/docs/en/settings-reference#enabledplugins)).
`.claude/settings.local.json` and a `local`-scope install record are not consulted.
`claude plugin list --json` reports the same ids with their status.
A user-scope install counts, and so does a project-scope install made for the project's clone under `projects/`, the one its committed settings enable.
Detection runs against the project, never the copy's path: every worker copy is a worktree of that clone and maps back to it through its git common directory, and the copy carries the project's committed settings, so the runtime sees the same enablement there.
That the runtime loads the pack inside a copy at another path is a runtime-dependent fact proven live before the adapter ships, as the repository requires of every harness-dependent check.

Codex.
`~/.codex/config.toml` carries `[marketplaces.<name>]` with `source_type` and `source`, and `[plugins."<name>@<marketplace>"]` with `enabled`, which `codex plugin add` writes as `true`; `codex plugin marketplace add owner/repo` records the marketplace as the git URL `https://github.com/owner/repo.git`, and the install lives in the plugin cache under `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` (the plugin manager in [openai/codex](https://github.com/openai/codex/tree/main/codex-rs/core-plugins)).
The pack's `.agents/plugins/marketplace.json` names its Codex marketplace `agent-skills` with the plugin's source the local path `./`, the marketplace's own repository, so the tie is the marketplace's `source` resolving to the token's repository.
The exact record that add writes for the pack's marketplace is a live proof before the adapter ships for Codex.
The first version reads the user-level configuration only.

Antigravity.
The pack's setup document ([docs/antigravity-setup.md](https://github.com/addyosmani/agent-skills/blob/0.6.14/docs/antigravity-setup.md)) installs it with `agy plugin install https://github.com/addyosmani/agent-skills.git` into `~/.gemini/config/plugins/agent-skills/` and lists it with `agy plugin list`.
What that record carries, and whether it names the repository the plugin came from, is read and proven live before the adapter ships for Antigravity; until the record proves to carry the repository, the tie there is the installed copy's own manifest `repository` field, the weaker tie, and the manifest says so.
Oh My Pi.
The pack documents `omp plugin marketplace add addyosmani/agent-skills` and `omp plugin install agent-skills@addy-agent-skills` ([docs/other-hosts.md](https://github.com/addyosmani/agent-skills/blob/0.6.14/docs/other-hosts.md)), the marketplace shape Claude Code uses.
Its record is read and proven live before the adapter ships for it.
Pi.
The same document installs the pack as a package with `pi install git:github.com/addyosmani/agent-skills`.
Where Pi records an installed package, whether it is enabled, and what it keeps of the source are read and proven live before the adapter ships for Pi; `pi` and `pi-signed` share that read.
Skills directories.
Gemini CLI's `gemini skills install` puts the pack's skills in `~/.gemini/skills/` or the workspace's `.gemini/skills/`; Command Code's `cmd skills add` writes `~/.commandcode/skills/` or `.commandcode/skills/`, with `/skills` as its enable and disable switch; OpenCode reads `~/.config/opencode/skills/`, `.opencode/skills/`, and the `.claude/skills` and `.agents/skills` paths; Cursor reads `~/.cursor/skills/` and `.cursor/skills/`, each from the pack's setup document for that harness.
For a skills directory, installed means the pack's skills are present where that harness loads them, at user level or committed in the project; enabled is presence, unless the harness has a switch as Command Code does; the version label is the pack's `plugin.json` when the copy carries it, and the fingerprint decides either way.
A copied skills directory carries no version record at all; it passes when the skills the adapter depends on hash to a supported tag, and that match is its tie to the repository, the content itself rather than a record about it.

What the fingerprint buys is a supply-chain fact.
A pack's skills run inside the agents, as instructions, and the hash says the text that runs is the text someone reviewed, whichever install shape or version label it came through.
The supported list carries tags only, and the check is by content, not by label.
For each supported tag the adapter's manifest carries a hash per file of the skills the adapter depends on, the ones it names or adapts, and nothing else from the pack, so a release that touches only other skills still matches.
A `bin/fm-best-practices.sh` subcommand writes those hashes from a checkout of the pack at that tag when the adapter adds the tag, never by hand, with line endings normalized before hashing, and a test fails when the manifest's hashes disagree with the tag they claim.
At check time firstmate hashes the same files in the installed copy and compares, for every install shape alike, a plugin registry or a skills directory.
The runtime's version label, `version` in the Claude Code registry, the `<version>` in Codex's cache path, `plugin.json` in a copied directory, is a fast path and never the truth: a supported label whose files match is confirmed at once, an edited install under a supported label is caught, an exact copy with no label passes, and an install whose record carries a commit rather than a tag, which is what Claude Code writes when neither the manifest nor the marketplace entry sets a version, passes when its files match a tag.
The result names what matters.
A match reports the reviewed tag, the newest when several match.
No match is `unreviewed`, reported as a fact and never as a refusal: it names the skills whose files differ from the reviewed tag, a skill the adapter depends on that is absent among them, with the runtime's version label beside them when there is one, as a hint to what happened.
There is no fuzzy matching, a file matches a tag's hash or it does not, and there is no fourth word: a loadable copy is at a reviewed tag or it is `unreviewed`, and no loadable copy at all is `missing`.
A harness outside the intersection is unsupported by that adapter, because firstmate has not verified it or the pack ships nothing for it.
A harness inside it is supported, and firstmate's read for it is proven live before the adapter ships for that harness; the manifest records the read and the proof per harness, and the adapter is complete only when every harness in its intersection has both.

### How it comes up when you add a project

It is not a fixed screen or prompt.
It is one line in the instructions firstmate follows when you ask it to add a project (`.agents/skills/project-management/SKILL.md`, "Add or clone an existing project"), beside the forge line, so firstmate decides how it comes up.
Here is the flow when you say something like "add github.com/org/repo", with the two new steps marked:

1. Confirm the basics with you in chat.
   Firstmate proposes the source URL, the local name, the delivery mode, and whether it may merge on its own, stating a default for each instead of asking you to come up with one: a project with a remote defaults to `no-mistakes-prod-only`, and merging on its own defaults to off.
2. Clone it into `projects/<name>`, once that name is known to be unused.
3. Propose the forge.
   Once the copy exists, firstmate runs `bin/fm-forge-detect.sh`, which can suggest gerrit.
   Forgejo cannot be detected, so firstmate asks you if it might be one.
   A `forge=` token is written only after you confirm it.
4. Propose the pack (new).
   Once the copy exists, firstmate reads what the project commits for its harness (`.claude/settings.json`, a `.gemini/skills/` or `.cursor/skills/` directory, and so on) and the harness's registry or skills directory from "Detection", and proposes `best-practices=<owner>/<repo>` when a supported pack is enabled for that project.
   A pack that is only installed on the machine, or enabled only in your user settings, proposes nothing, the way a forge is proposed from a protocol fact and never from a guess.
   You can also name a pack yourself; if this firstmate carries no adapter for it, firstmate names the repositories it does carry and proposes nothing.
   A `best-practices=` token is written only after you confirm it.
5. Add the line to the project list with your confirmed settings.
6. Set up validation if the project uses no-mistakes.
7. Check the command-line tool login.
   Firstmate checks it itself, for example `glab auth status` for GitLab or `tea login list` for Forgejo.
   You only see this step if the tool is not logged in.
   Then it is a login you provide, and since it is interactive you run it yourself with `! glab auth login` or `! tea login add`.
8. Check the pack (new).
   Firstmate checks it itself, from the registry or the skills directory: the home's crew runtime is one both firstmate and the pack support, the pack is installed there, it is enabled as the worker's isolated copy will see it, and the files of the skills the adapter depends on match a supported tag.
   You only see this step if something is wrong, and then it is one of these:
   - The crew runtime is not one both support: firstmate says which side is missing, its own verification or the pack's install path, and names the harnesses both support; you dispatch that project on one of them or drop the token.
   - Not installed: firstmate names the runtime's install command.
     Then it is an install you provide, with `claude plugin install <id>` or `codex plugin add <id>`.
   - Installed but not enabled: firstmate says where it is disabled.
     Then you enable it there, with `claude plugin enable <id> --scope user`, or on Codex, which has no enable command, `enabled = true` in that plugin's table in `config.toml`.
   - Unreviewed: the pack is loaded, but the files of one or more skills the adapter depends on match no reviewed tag.
     Firstmate reports that as a fact, never as a refusal: the reviewed tags the adapter supports, the skills that differ from them or are absent, and the runtime's version label when there is one.
     The token is kept, and the adapter applies at `unreviewed` as "Detection" describes.

After that the token is a registered fact and firstmate treats it like the forge.
Every ship or scout intake reads it from the registry and passes it to the brief, the spawn checks the brief against the registry, and nothing re-runs the pack check per task; the spawn only reads the same files to fill the export with one of its three values, the reviewed tag the files match, `unreviewed` when the pack is loaded but a file the adapter depends on matches none, or `missing` when it finds no loadable copy, and prints one notice to firstmate for either of the last two, naming the differing skills and the runtime's version label at `unreviewed`.
That notice is the result of the read the spawn already makes, not a new check, and it does not block the launch.
A change to the line takes effect at the next launch, because `bin/fm-project-mode.sh` reads `data/projects.md` on every call and a running worker keeps the brief and environment it launched with until it is relaunched, as with every registry token.
A project without the token never causes a plugin registry read.

If the pack is uninstalled or disabled after that check, the harness stops loading it.
The spawn's read sees that, writes `FM_BEST_PRACTICES_VERSION=missing`, and prints its one notice, so firstmate can relay it at the start of the task instead of finding out from the done line; the worker, reading `missing`, follows firstmate's defaults and says so in its done summary.
If the pack is updated or edited after that check, the harness keeps loading it, now with files nobody has reviewed against the adapter.
The spawn's read sees that too, writes `FM_BEST_PRACTICES_VERSION=unreviewed`, and prints its one notice naming the skills that differ, with the runtime's version label as the hint; the adapter still applies, because those skills are in the worker's hands either way and the alternative is a loaded pack with nothing governing it, and the worker names the unreviewed skills in its done summary.
Same shape as a tool login that expired after the add, surfaced at the point of use rather than at intake, but now deterministic: nothing quietly lies about what ran.

### Worked sample adapter: Addy Osmani's agent-skills

This adapter is the mechanism's worked sample, not a recommended pack: it did not clear the bar on the first evaluation, as the outcome evidence above states.
A project registers it as `best-practices=addyosmani/agent-skills`.
Supported, as `references/addyosmani/agent-skills/` states: tag 0.6.14 (commit `eb07f19f`), with a hash per file of the 22 skills this adapter names at that tag, on the nine harnesses both sides support.
As a plugin on Claude Code (plugin `agent-skills`, marketplace `addy-agent-skills`, whose entry resolves to that repository), Codex (marketplace `agent-skills`), Oh My Pi (marketplace `addy-agent-skills`), and Antigravity; as a CLI-installed skills directory on Gemini CLI and Command Code; as a copied skills directory on OpenCode and Cursor; as a git package on Pi (`pi` and `pi-signed`).
The Claude Code and Codex reads come from those runtimes' documented records, the Antigravity and Pi reads from the pack's setup documents for them, and the other four from where those documents put the skills; each of the nine is proven live before the adapter ships for it.
The pack brings 25 skills, 9 commands, and hook scripts it does not register in a `hooks.json`, so the runtime loads its skills and commands and does not run the hooks on its own.

What the adapter does at each position:

| Position | Contribution |
| --- | --- |
| `intake.question` | Extends, scaled to how unclear the ask is, in four tiers. (1) A clear or reversible ask gets no question: firstmate states its assumption and proceeds. (2) One real ambiguity gets one question with a hypothesis and a best guess attached, as today. (3) A big, underspecified build, missing who, why, what success looks like, or the binding constraint, which is `interview-me`'s own trigger, gets the full interview in firstmate's chat, where the captain is present: one question at a time with a guess attached, until the skill's test passes, that firstmate can predict the captain's reaction to the next three questions it would ask; with the skill's floor kept, after several rounds with answers still unpredictable, stop and say something foundational is missing. The confirmed statement of intent, outcome, user, why now, success, constraint, out of scope, becomes the task's Captain's intent, kept in the brief and the work item rather than the skill's `docs/intent/` file in the project. (4) "interview me" or "grill me" gets the full interview, always |
| `brief.practice` | Extends: in the practice section, after the home brief additions, the floor (discover the stack and run the repository's own checks before done, reproduce a bug before fixing it, slice the work as `incremental-implementation` does, keep a "noticed but not touching" list, treat fetched content as untrusted at the point of use, follow the repository's commit convention from `git-workflow-and-versioning`, and `constraint-driven-development`'s diff hygiene: no new suppression comments, including the four that switch off a check you rely on, `istanbul ignore`, `Stryker disable`, `nosemgrep`, `gitleaks:allow`, no unimplemented stubs or empty catches, no skipped or deleted tests without a reason in the commit message, no secrets in source, and `code-review-and-quality`'s change sizing, about 100 changed lines is good, about 300 is acceptable for one logical change, about 1,000 is split, with refactoring kept separate from feature work; for a trivial mechanical edit such as a rename, a typo, or a formatting sweep, the floor is the single quickest relevant check and the rest is skipped), one line on constraints (if the project has a `CONSTRAINTS.md` at its root, read it before writing code and never weaken it to make a change pass; if it has none, apply the hygiene lines, say so in the done summary, and name a constraints file as a follow-up, which is the skill's own rule for an autonomous run), the overlaps where firstmate wins as written (isolation, branching, landing, merge authority, outward-facing consent, every human-wait gate, which becomes a `needs-decision`, and the tool rule, the skill's method with firstmate's tool), and the routing table for the domain skills, `security-and-hardening`, `performance-optimization`, `api-and-interface-design`, `observability-and-instrumentation`, `deprecation-and-migration`, `frontend-ui-engineering`, `browser-testing-with-devtools`, and `ci-cd-and-automation`, with `code-simplification` routed when the task itself is a refactor and `source-driven-development` routed when Jev says the task depends on version-specific framework or library behavior, an upgrade, a migration, or a new library, all selected by condition rather than listed in the brief; when `source-driven-development` is routed, the versions come from the lockfile, and only when they are still ambiguous does the worker send firstmate a `needs-decision`, in place of the skill's ask-the-user; plus one routed rule read in code, applied only when the change touches a dependency manifest or lockfile: `code-review-and-quality`'s dependency discipline, prefer what the stack already has, upgrade one dependency per change or a small related group, read its changelog, review the lockfile diff, keep the tests green before and after, and never bundle an unrelated upgrade; and `shipping-and-launch`'s flag rule, applied by the worker only where it finds the project already uses feature flags: new user-facing behavior goes behind the project's existing flag, the tests cover both states, and no flag system is ever introduced |
| `brief.done` | Extends, in the practice section: the done summary also names the checks run, the author's own review, `code-review-and-quality`'s verification story (the tests run, whether the build passed, what was tested by hand, and screenshots with a before and after for a UI change), the doubt cycles run and whether cross-model was skipped, whether a `CONSTRAINTS.md` was present and followed, the pack version the export carried, naming the unreviewed skills when it read `unreviewed`, the sources `source-driven-development` cited when it was routed, and the follow-up list, which also carries any code the change left unused, in place of the skill's "ask before deleting" stop. On a project that deploys from its default branch, a risky change also carries, in the done summary and the PR, `shipping-and-launch`'s two plans in short written form: a rollout plan (the stages, what to watch at each, when to hold) and a rollback plan (its trigger, its steps, and whether any database change can be reversed). Risky is a fuzzy call, one Noul for Jev at composition over the task as `doubt-driven-development` defines irreversible blast radius, a production deploy path, a data migration, a public API change; low confidence writes the plans, since the static fallback applies the full table |
| `launch.env` | Extends: `FM_BEST_PRACTICES=addyosmani/agent-skills` and `FM_BEST_PRACTICES_VERSION=0.6.14` when the files match that tag, `unreviewed` or `missing` otherwise, as the spawn's read decides |
| `reproduce` | Inserted before `work`, only when the routing table says the task is a bug fix: make the failure happen first, as `debugging-and-error-recovery`'s Step 1 says, as close to how the user hit it as possible and as a failing check, before touching code; a bug that will not reproduce is documented as such rather than fixed blind |
| `work` | Extends, only on a `no-mistakes` project, read from the delivery mode in code: `doubt-driven-development`'s in-flight cycle on non-trivial decisions as the skill defines them, adapted in two places: the cross-model offer is skipped and the skip announced, which is the skill's own rule for a non-interactive context, and three unresolved cycles become a `needs-decision` to firstmate instead of a question to a user. Otherwise untouched: the slicing it needs is already in the floor. No TDD before work |
| `verify` | Extends: the repository's own checks from the floor, plus `code-review-and-quality`'s five axes (correctness, readability, architecture, security, performance) as the author's own checklist before handoff, not a review gate, with the skill's answer-by-experiment check on the tests (flip one condition the change adds, run the suite, restore the file; a test that stays green names a missing test case), and `constraint-driven-development`'s guard over the task's own diff, also the author's own: a test got easier, a checker got silenced, work left unfinished, and, when a `CONSTRAINTS.md` exists, a threshold moved or an exception appeared, plus the change compared against any ratchet values in the file's "Measured, not yet enforced" table, using the commands the file names; fix what it finds or name it in the done summary. Two more of the author's own passes, from `shipping-and-launch`'s pre-launch checklist: the docs, that the README, the API docs, and the user-facing docs reflect what the change did, which catches documentation drift on the fast paths that have no documentation step, with a generated changelog followed by its convention and never hand-edited; and the code-side infrastructure items, a health endpoint exists, logging and error reporting are wired in, and any migration comes with a rollback plan, routed by a fact read in code rather than a question for Jev: the change touches deploy config, infrastructure definitions, or a migration, which the worker reads from its own diff at `verify`, as it reads the dependency rule, because the diff exists by then and the task's words may not say. Then, once the checks pass, one behavior-preserving simplification pass over the worker's own diff from `code-simplification`, its five principles scoped to what changed, with `code-review-and-quality`'s Structural Remedies as the moves for what the five-axis check found, and the checks run again after it |
| `scout.report` | Pairs, firstmate first, in the practice section: the report firstmate expects, then the spec and plan in the pack's shape from `spec-driven-development` and `planning-and-task-breakdown`: success criteria, slices with acceptance criteria, a "Not doing" list, and the spec's open questions. The pack's gates (approve the spec, then stop your turn; review the plan with a human before proceeding) move to firstmate's existing step rather than disappearing: the scout writes and finishes, and finishing is the stop; firstmate brings the report to the captain and holds each open question as a captain decision (`captain-hold-lifecycle`, `bin/fm-captain-hold.sh hold`); nothing is built until the captain's word, because a scout report is evidence, not authorization, and implementation then goes through `bin/fm-promote.sh` or a new ship. For an idea to explore rather than a direction to build, the report takes `idea-refine`'s one-pager shape instead, as the paragraph below says |
| `handoff.review` | Extends: firstmate also checks the done summary carries what the floor names and files the follow-up list as work items |
| `landing.post-merge` | Pairs, firstmate first: firstmate's landing, then, on a project that deploys from its default branch, the adapter's reference has firstmate file one work item and dispatch a small verification scout through the path it already has (`bin/fm-brief.sh <id> <project> --scout`, `bin/fm-spawn.sh <id> <project-dir> --scout`, the report back through `scout-completion`), because firstmate does no project work itself. The scout runs `shipping-and-launch`'s post-launch checks as observation only: the health endpoint returns 200, no new error types in monitoring, no latency regression, the critical user flow works when tried by hand, logs flowing and readable, and, when the project has an SLO dashboard, the error-budget burn rate, reported and never gated on. The sixth item, the rollback dry run, is converted: the scout reports whether a rollback path exists and, where a dry run is warranted, raises it as a `needs-decision` instead of running one, because a dry run can change production and that sits with the off-limits rules. Its findings reach the captain as findings, the way every scout's do |
| `cleanup.record` | Extends: a decision record with rejected alternatives on the work item, in the shape `documentation-and-adrs` gives it, when the project keeps no record of its own |

Intake scales with the ask, and the interview never runs inside a worker.
`interview-me` needs a live, responsive user by its own rule, and tells an agent in a non-interactive context to flag an underspecified ask as a blocker rather than guess; a worker that finds one does exactly that, with its `blocked:` line.
The interview is firstmate's, in chat, at intake, before the brief exists.
Which tier applies is a fuzzy call, so it is one routing row at intake, a Choice over the first three tiers asked of Jev, with low confidence or no key falling back to the one question of today; the captain's own words are read in code and win over it, "skip the interview" to tier one and "interview me" or "grill me" to tier four.
The interview does not block work: firstmate may start a research scout on the parts already clear while it runs, the knowledge-only kind section 7 allows, and writes the brief once the intent is confirmed.
For big work it comes before the staged map scout below, so the map is drawn against a confirmed intent.

An idea to explore, rather than a direction to build, gets `idea-refine`, firstmate-side like the interview.
The skill calls itself an interactive dialogue, so it never runs inside a worker; what a worker can do is the research.
Whether an ask is an idea with no direction yet is a fuzzy call, one more Noul in the intake request, with the captain's "ideate" or "refine this idea", the skill's own triggers, read in code and winning.
When it applies, firstmate dispatches a scout whose report takes the skill's one-pager shape: a problem statement, a recommended direction, key assumptions to validate, MVP scope, a "Not doing" list with the why, and open questions.
The two or three directions the skill converges on go on a review page for the captain to pick from, the board firstmate already uses for a visual deliverable, and the open questions are held as captain decisions, the same way a spec's are.
The one-pager stays in firstmate's records, the scout's report and the work item, rather than the skill's `docs/ideas/` file in the project.
The chain, in the skill's own words: `interview-me` when the captain is unsure what they want at all, `idea-refine` with an idea but no direction, `spec-driven-development` once the direction is chosen.

Big work gets a staged scout.
`spec-driven-development` says a request that spans several independently testable capabilities gets a capability map before any spec, module boundaries, dependency direction, and build order in ten reviewable lines, and that the human reviews the map before any module spec is written.
In firstmate that gate lives at the handoff, never inside a worker.
Whether the map applies is a fuzzy question, so it is one routing row at scout intake, gated by a fact read in code, the task is a scout, and asked of Jev as a Noul; low confidence or no key means no map stage, one scout with one spec, as today.
When it applies: the first scout's `scout.report` is the map only, in the pack's shape; firstmate brings it to the captain at `handoff.review` and holds the approval as a captain decision; after the captain's word, firstmate dispatches one scout per module through the same scout path, each with its own spec scoped to that module, in the map's build order, so a module's scout starts after the modules it depends on have their spec, which is the one true dependency section 7 lets firstmate serialize on.
That follow-on dispatch is firstmate intake, after position 9 of the map scout's flow, and each module scout is its own task with its own flow.
The approved map and the module specs land in the project where the pack says, at the root, through the ship that later implements them, since a scout commits nothing to the project.

A project's constraints file is a task, not adapter behavior.
`constraint-driven-development` writes a project's quality bar to `CONSTRAINTS.md` after a four-question interview, and its own rule says the interview needs a live user and must not run in an autonomous run.
So the adapter never interviews and no worker writes the file on its own.
When the captain wants a project's bar written, firstmate takes it as a task: it asks the skill's four questions in chat, where the captain is present and each question carries its stated default, and the file is written only with the captain's explicit approval of its content, through the project's normal delivery.
The same task carries the skill's tooling, proposed as one project change for the captain's approval and shipped the same way: the tool installs of Step 4 as dev dependencies or CI steps, with machine-wide tools such as gitleaks and osv-scanner in CI only, which the skill itself allows; the check scripts, `check:fast`, `check:task`, and `check:full`, in the project's own scripts, so the floor's "run the repository's own checks" line and no-mistakes' test step pick them up with no new adapter mechanism; and the skill's floor-guard reference, adapted into the project and reviewed like any other code, never run from the pack.
That is the skill's own escalation path, written and then scripted, where it says most projects should stop.
The adapter installs and runs nothing from the pack, block-or-warn gating stays with CI and no-mistakes, and worker hooks stay firstmate's, so the post-edit hook the skill mentions is not wired.
The line the skill would add to the project's `AGENTS.md` or `CLAUDE.md` stays a deliberate human edit, section 6; the adapter reads `CONSTRAINTS.md` directly, so no pointer is needed.

`deliver` and `report` are untouched, and so is the pipeline's review at the deliver stage.
This adapter replaces nothing, never puts the pack first, and inserts one position, `reproduce`, for bug fixes only.
Its firstmate-side actions beyond composing text are dispatches through the scout path firstmate already has: the verification scout at position 10 of a ship task's flow, and the per-module scouts after the captain approves a map.
Each such scout is its own task with its own flow, intake to brief to launch to its work to report to `handoff.review` to `cleanup.record`, with no deliver or landing of its own, and the ship's own `cleanup.record` does not wait for the verification scout.
The pipeline's own instructions are untouched, because no-mistakes owns its rigor; the doubt cycle and the author's checklist run inside the worker before anything reaches the pipeline, and neither is a gate.
Left out of this adapter on purpose: the pack's human-wait gates as gates, the `using-agent-skills` router, `context-engineering`, the commands as commands, and everything in `git-workflow-and-versioning` beyond its commit-convention line, its raw worktree and reset steps included.
Each one either stops a turn for a person or works against isolated parallel work.
`test-driven-development` is not inserted before `work`.
From `constraint-driven-development`, moved into the constraints task rather than left out: its interview, which needs a live user by its own rule; the writing of `CONSTRAINTS.md`, which no worker does on its own; and its tool installs, its check scripts, and its floor-guard reference, none of which a worker runs from the pack.
Its ratchets are read at `verify` once the file records them.
Out altogether: block-or-warn gating, which stays with CI and no-mistakes, and the pack's post-edit hook, because worker hooks stay firstmate's.
From `code-review-and-quality`, out: its process for reviewing someone else's change, because no-mistakes owns independent review and the fast paths deliberately have none; its multi-model pattern, because reviewer models are pipeline setup; and its reviewer checklist template, because firstmate writes its own PR and handoff text.
From `shipping-and-launch`, out: running a staged rollout, flipping flags in production, running a rollback, and setting up production dashboards or alerts, all outward-facing; and its error-budget gate as a merge gate, because merge authority is off limits to every adapter, though the project's own CI may enforce it as project-owned policy.
Its code-level instrumentation is already the routed `observability-and-instrumentation` skill, and its pre-launch checklist is covered by the floor, `verify`, which now carries its documentation group and its code-side infrastructure items, and the routed domain skills; the production-side items stay out, setting production environment variables, applying migrations, DNS, SSL, and the CDN, because each one is outward-facing.

## Open questions

1. Placement.
   I put this where I think you would put it: `.agents/skills/best-practices-adapters/` with `references/<owner>/<repo>/` per adapter, `bin/fm-best-practices.sh` and `bin/fm-best-practices-lib.sh`, `bin/fm-project-mode.sh --best-practices`, a `docs/configuration.md` section beside the forge section, and `tests/fm-best-practices.test.sh`, on the `harness-adapters` precedent and `AGENTS.md` section 12.
   Is that where you would put it, or do you want it elsewhere?
2. Stacked review.
   Section 7 says no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI, and that work is never held outside it for a manual clean verdict or stacked serial reviews.
   The Addy adapter runs `doubt-driven-development`'s cycle inside the worker on its own in-flight decisions, and `code-review-and-quality`'s five axes as the author's own checklist, both before anything reaches the pipeline and neither as a gate.
   I read that as the author checking their own work, not a stacked review.
   If you read section 7 the other way, say so and the adapter drops the doubt cycle.

Related: #959 (complementing an external skills pack), #5148 (opt-in lifecycle seams), #7221 (a plugin tool reaching workers through the launch environment), #3924 (per-brief declared extras).
