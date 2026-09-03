# Model-routing benchmark gates

Firstmate's three-track model-routing benchmark decides standing routes, so a wrong result changes how every future task is dispatched.
An independent adversarial review of its design found that its safety properties were promises rather than enforcement, and produced a correction set that must hold before any entrant launches.
This document owns why each gate exists and where its authority stops.
Exact flags, schema keys, and directory layout live in `bin/fm-bench-gate.sh`'s header and `--help`, which is their single owner.

## The enforcement principle

Every gate recomputes its own evidence rather than reading a declared verdict.
Content addresses are recomputed from stored bytes, run and judge counts are derived from the frozen plan, isolation probes are executed inside the declared confinement, and archived bundles are restored into a fresh repository and rebound to their recorded tree.
A gate that cannot obtain its evidence refuses; an unproven denial is never treated as a denial.

## What each gate enforces

| Gate | The review finding it closes |
|---|---|
| `plan-check` | Three packets run twice are not six independent samples; 5/6 and 4/6-plus-margin have uncalibrated false-promotion rates; candidate-specific judge exclusions make candidates incomparable; every track positively declares its baseline, neutral-capture, and specification capabilities; the capture field produces exactly 30 records; every required specification seat names an author and provides complete independent pre-freeze audits; the normalized deterministic and panel composite weights plus their common finite score scale are frozen; an inconclusive result is "no standing route", never an adaptive ninth sample. |
| `freeze` / `freeze-check` | Every planned packet and matching ground-truth input must exist, the scoring and judge-prompt stores must be non-empty, and those inputs plus model tuples, the randomisation seed, and the failure policy are fixed before labels exist. |
| `provenance-check` | A historical security packet may be replayed only after every original author, reviewer, and judge is either positively identified by task, resolved model id, family, and session or positively declared absent with a reason. "No record found" fails. |
| `isolation-verify` | Opaque labels and a transcript grep hide metadata but neither prevent nor detect sibling access. The gate accepts evidence only from the trusted launch-capable confinement wrapper with supported arguments, runs the exact bypasses the grep missed, and requires each to be denied. |
| `evaluator-verify` | A described evaluator is not a reproducible measurement. The environment lock, published score map, zero-weight validity gates, identical dry-runs, finite positive per-dimension mutation calibration, and exactly one bound capture record for every planned candidate head are all required. |
| `manifest-build` / `manifest-check` | The original run, judge, capture, and cost arithmetic did not add up, and cost and elapsed time were tie-breakers while unmeasurable. Every count is now derived, and cost is low/base/high arithmetic rather than a quoted range. |
| `promote-evaluate` | Only a six-of-six paired sweep computed with the frozen composite weights on the common score scale, the predeclared margin, no blocker-class failure, and no regression below the fixed zero mean floor or beyond the declared zero-or-one loss bound is eligible; a void carries only central failure and timing facts, needs its own result record, and is complete only when its finite supersession chain resolves to exactly one terminal scored attempt; the captain still gives the word. |
| `archive-verify` / `restore-drill` / `cleanup-gate` | A git bundle alone cannot be rejudged after cleanup; structured archive identities preserve a stable attempt id, each identity's attempts must form one finite acyclic supersession chain ending in exactly one terminal scored attempt covering its planned output, and linked prior void attempts remain auditable through their content-addressed failure and timing evidence; scored sample roots and entries must be real directories or regular files; each scored evidence group must carry its distinct role-specific artifacts; every evidence file except its sample's own top-level manifest is content-addressed beneath its sample directory, including the executable evaluator; every restored scored sample must carry a valid evaluator declaration and scored-input set, while bounded execution reruns a deterministic sample in an opaque confinement that must reproduce the genuine result and prove dependence on at least one scored input through a gate-owned pure-data perturbation; cleanup is authorised only while the archive verifies both before and after the rerun. |
| `preflight` | Composes every pre-launch gate and writes the receipt that the launch refusal reads. The receipt carries one canonical evidence digest over the sorted path, type, mode, and bytes of every artifact preflight validated - plan, isolation layout, freeze, manifest, allowance, provenance, and the evaluator program, configuration, and fixtures - and `launch-check` recomputes it at the spawn boundary. A preflight that refuses or stops for the captain also revokes any receipt already on disk, so evidence degrading outside the plan cannot leave a stale clearance standing, and evidence edited without a rerun withdraws the clearance rather than riding it. |

An omitted capability is never an exemption.
Every frozen track positively declares whether it needs a baseline, neutral capture, and a specification, every candidate positively declares its metered provider or that it is unmetered, and each declaration emits a visible verdict.
Neutral capture is itself a specification-requiring design seat, so a capture track cannot opt out of its author and audit evidence.
Every track emits a spec-seat verdict, while a specification-required track must name its author and family, keep that author out of its judging and entrant seats, disclose same-family adjacency, and carry one independent accepted pre-freeze audit per packet.

## Where the refusal actually bites

A gate an operator can forget to run is not enforcement.
`bin/fm-bench-launch-lib.sh` is sourced by `bin/fm-spawn.sh` and refuses any task id under the reserved `bench-` prefix unless a passing preflight receipt exists and still matches `benchmark.json`'s current bytes.
Before delivery, the same launch boundary also verifies `isolation.json` against its receipt hash, resolves the matching entrant, requires the actual worktree and every private path to still equal the preflight-proven layout, and wraps the harness command in the same verified confinement argv that the probes cleared.
An unavailable wrapper or changed path refuses the launch rather than falling back to the ordinary shell command.
Because the verified wrapper and private paths are local evidence, a remote secondmate route refuses a `bench-` entrant rather than silently crossing to an unconfined remote launch.
Editing the plan after a pass invalidates every receipt written against it, so a relaxed threshold or a swapped packet cannot ride an old clearance.
Task ids outside that prefix cost one string comparison and are otherwise untouched.
This mirrors the chokepoint pattern in `bin/fm-gate-refuse-lib.sh`, including its documented test-harness hatch.

## Isolation is proven, not declared

`bin/fm-bench-confine.sh` is the control and `bin/fm-bench-probe.sh` is the attack.
`isolation-verify` pins the network-disabled replay `exec_wrapper` and the entrant-only `launch_wrapper` to that executable and their supported `{root}` contracts, so a probe-specific wrapper cannot earn evidence that the real launch would not enforce.
The entrant wrapper requires a pinned runtime container and resolves a distinct Docker-internal network plus dedicated credential-holding provider proxy from each preflight-proven entrant record, while the replay wrapper keeps networking disabled.
Because no two entrants may declare the same network or proxy container, a complete concurrent field cannot reach sibling entrants over its provider-egress path.
Provider credentials stay at the proxy boundary and are never copied into the entrant environment.
The gate never trusts the mechanism name: it runs each probe unconfined first as a positive control, and only a probe that demonstrably reaches its target can then prove anything by being denied.
A mechanism this host cannot enforce therefore surfaces as a refused launch naming the concrete unmet requirement, never as a silent downgrade to cooperative isolation.

Only a mechanism with its own PID namespace confines processes as well as storage and filesystem.
`docs/verification/model-routing-benchmark.md` records the dated per-mechanism result.

No declared path is trusted either.
Each entrant's private object store, temp, home, and session space deliberately resolves within that entrant's root so the proven confinement wrapper owns the complete private layout and cannot silently substitute a shared external path.
Each private path must also be ignored by Git and absent from the candidate index, so routine candidate commits and the tree later bound as `tree_binding.original_tree` cannot absorb object data, temporary files, home configuration, or session state.
An external private path, an unignored path, or private material already present in the candidate index is refused during `isolation-verify` rather than later at launch or scoring.
Because a denial against an empty directory proves nothing, every declared private store must hold material the probe reaches unconfined, and a store that holds none is refused by name.

The gate also resolves each clone's `objects/info/alternates` itself.
An alternate is a second object database bound into the clone, so an entrant whose alternate escapes its own private storage is reachable by a route no probe walking the sibling root would ever visit; that alternate is refused and handed to the sibling probes as a target.

The process probe reads its marker from material written inside the entrant's permitted private session path.
The marker value never crosses a gate-created process argv, including the confinement wrapper, while the positive control still reports a genuinely visible sibling marker process as a leak.

Preflight executes the content-addressed evaluator from frozen `scoring/` bytes under the network-disabled wrapper.
Each execution binds two structurally distinct frozen records: an `fm-bench-evaluator-input.v1` fixture under `ground-truth/evaluator-inputs/` and an `fm-bench-evaluator-output.v1` expected result under `ground-truth/evaluator-outputs/`.
Every execution is blinded: the gate stages the evaluator's own frozen code package - the whole `scoring/` tree plus its frozen `evaluator/lock.json` and `evaluator/score-map.json` calibration, so a multi-file evaluator keeps the siblings it imports - into a fresh gate-owned scratch root beside the frozen input under an opaque file name, and exposes only that root to the confinement.
The evaluator therefore never learns which record it is being asked to derive, an answer table keyed on the input path matches nothing, and the frozen expected outputs and the `evaluator/execution.json` mapping that keys them are outside the cage entirely.
Only lstat-verified directories and regular files are staged, so a symlink planted under `scoring/` cannot resolve an expected-output record back inside the cage.
The evaluator receives only that opaque input, its stdout must equal the separately frozen expected output, and that expected output must bind the evaluator evidence record byte for byte.
The two records carry different schemas, live under different frozen roots, and are refused when their bytes coincide, so a program that merely cats or echoes its input cannot clear preflight for any choice of fixture bytes.
Reproducibility is then executed rather than declared: the same frozen golden input is run a second time through a different opaque path and must reproduce byte-identical output, and there is no authored tolerance that can stand in for that.
Input dependence is executed too: the gate builds its own form- and length-preserving edit for every perturbable scalar of that golden input, runs them in a stable pointer order, and stops at the first edit that moves the output.
An evaluator is called input-blind only when no edit to any perturbable scalar changes what it emits, so an evaluator that legitimately ignores one value is not mistaken for one that reads nothing.
Mutation movement and capture bindings are then derived from the executed result rather than from a detached record.
Every confined invocation - probes, preflight evaluator executions, and restore-drill replays alike - hands the wrapper the operator's own environment, because the wrapper resolves its container runtime there and a stripped environment loses the endpoint an operator on colima, a remote Docker context, or rootless podman actually uses.
Nothing is granted by doing so: `bin/fm-bench-confine.sh` scrubs the environment that reaches the confined command down to its own allowlist, so the evaluator sees the same fixed environment either way.
A wrapper that exits non-zero is reported by its own exit code and a bounded, control-character-free tail of its stderr before any attempt to parse its stdout, so an unresolvable runtime is never disguised as malformed evaluator output.

The restore drill treats archived evaluator bytes as untrusted candidate output.
It restores, rebinds, and statically validates each sample in a short-lived workspace, then releases that repository and worktree immediately while retaining only the bounded selection's copied tree for later execution.
Only differential execution is bounded: the drill selects the first sample in the archive's stable lexical order and records that selection in the receipt.
Both evaluator executions use the same preflight-proven `bin/fm-bench-confine.sh` mechanism with networking disabled, a scrubbed environment, and one independently generated opaque run root as the only writable candidate-data bind.
The archive and repository are not mounted for the evaluator, and the genuine and perturbed runs expose the same internal layout without a role-bearing path, environment value, or recognizable perturbation marker.
The gate supports pure-data JSON-value, source text-token, and PNG-pixel declarations for JSON, TypeScript, JavaScript, CSS, HTML, and non-interlaced 8-bit PNG inputs.
Every opaque run root is materialised in the same stable path order, then matching ownership, permissions, normalized access and modification times, directory order, byte length, and bytes are compared before execution so only the declared perturbation can differ.
Every gate-owned perturbation preserves byte length, and a declaration such as a JSON boolean that cannot change at equal serialized width is refused rather than exempted from the prepared-tree comparison.
JSON and source inputs retain their archived bytes in the genuine run, while PNG inputs are decoded within a 128 MiB raster limit and both copies pass through the same deterministic equal-length encoder before one filtered pixel byte changes.
The recorded result hash therefore covers archived bytes for JSON and source inputs, and the gate-prepared genuine encoding for a declared PNG input.
Only a successful genuine run and a successful single-input perturbation with identical output prove that an evaluator ignored that declared perturbable input.
Every evaluator must prove dependence on at least one scored input, while another input without a declared supported perturbation remains visibly unproven per input in the gate output and drill receipt.
A restore-drill attempt revokes its earlier receipt before any check runs, so every refusal leaves cleanup held even when a required restore dependency has disappeared.

## The two captain-stop conditions

Exit code 3 is reserved for a new fact the captain must rule on, and neither may be resolved by substituting a packet or expanding a budget:

- every historical packet in a track fails its contamination check, and
- the measured high-cost case exceeds the approved cost class.

Everything else is either a pass or an ordinary refusal naming the correction that is not yet met.

Promotion treats each result file as an archive-attempt locator, not a score authority.
For scored attempts it recomputes the composite and blocker state from content-addressed sample evidence after matching the planned neutral panel, candidate tree, evaluator output, capture hash, timing intervals, and failure status.
For void attempts it requires only the approved central failure class and both timing intervals, and every archived void attempt must carry its own result record.
Each sample identity must then form one finite supersession chain: a single root attempt, one successor per void, no fork, no cycle, no dangling link, and exactly one terminal scored attempt, so an arbitrarily long void-to-void-to-scored chain resolves while an unlinked or branching one is refused.
For that reason `archive-verify` precedes `promote-evaluate` in the post-run gate order.
Cost arithmetic likewise requires every referenced run and auxiliary class to carry finite, nonnegative ordered bounds, and the approved class itself must be finite and positive.

## Extending this

A new correction becomes a new check inside `bin/fm-bench-gate.py`, with its refusal message naming the property it protects, plus a case in `tests/fm-bench-gate.test.sh` that proves the check bites.
A check that cannot be made to fail in a test is not enforcement; add the failing fixture first.
