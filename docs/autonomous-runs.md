# Autonomous runs

Firstmate's `/afk-*` modes are one run engine with several front ends, not several orchestration systems.
Each mode freezes a machine-readable manifest, then works only inside what that manifest permits.

`/afk` itself is unchanged and is not a run: it is away-mode supervision, owned by the `afk` skill.

| Mode | What it produces | Change authority |
| --- | --- | --- |
| `/afk-research` | A bounded answer to one question, with evidence | none |
| `/afk-app <project> --mode audit` | Read-only findings about a running application | none |
| `/afk-app <project> --mode fix-known` | A reviewable branch fixing reproduced defects | one isolated worktree |
| `/afk-obsidian-projects` | Progress on an explicitly authorized AI Project Manager task list | none; Firstmate alone writes the vault |
| `/afk-session-review` | Recovered intent and recurring-mistake findings from session archives | none |
| `/afk-jira-research` | Read-only work-pattern metrics over a frozen Jira and Confluence scope | none |

`bounded-improvement` is specified but deferred: the engine refuses it at preflight until the `fix-known` pilots pass and the captain authorizes enabling it.

## What the engine enforces

A mode's read-only claim is whatever `bin/fm-run.sh` will actually permit, not what the mode's instructions say.
Six invariants are mechanical:

- **The manifest is frozen.** After `fm-run.sh freeze`, `set` and `add` refuse, and every later command re-checks the manifest against the hash recorded at freeze. An edit from any source stops the run rather than widening it.
- **Tools come from a closed allowlist.** A tool nobody thought to deny is still refused, because permission comes only from the allowlist. A compiled-in floor no manifest can lower sits underneath it.
- **Writes reach declared areas only.** A read-only run may write only its own evidence directory. Paths are compared after physical resolution, including the final component, so neither a symlinked parent nor a symlinked leaf can launder a write into the area. A write target that is itself a symlink is refused rather than resolved, because a link checked now can be repointed before the write lands.
- **Reads stay inside the frozen roots.** A read-only run must freeze at least one `source.readRoots` entry, and preflight refuses it otherwise: the gate bounds reads to the roots the manifest names, so a run that named none would be bounded by nothing. Reads are judged on the physically resolved target, so a symlink is followed to the file it would actually open.
- **One owner mutates a run.** Every state-changing command holds a run-scoped lock, so claiming custody is one compare-and-swap rather than a separate read and write that two contenders can both win. A second owner may take over only from a quiesced run, so a failed transfer converges to one owner or none.
- **Every decision leaves a receipt.** Refusals are recorded alongside permitted calls, which is what makes `prove-no-write` meaningful. Each receipt is built first and appended in one write, so concurrent gates cannot interleave halves of two records.

## Run layout

Runs live under the active `FM_HOME`, namespaced away from task directories:

```
data/runs/<run-id>/manifest.json      the frozen manifest
data/runs/<run-id>/manifest.sha256    the hash recorded at freeze
data/runs/<run-id>/run.state          engine state, custody, checkpoints, stop rule
data/runs/<run-id>/receipts.jsonl     append-only receipt log
data/runs/<run-id>/evidence/          the run's write area
data/runs/<run-id>/checkpoints/       durable checkpoint snapshots
```

`bin/fm-run.sh`'s header owns the exact commands and flags; `bin/fm-run-lib.sh`'s header owns the layout and receipt record.

## Inspecting a run

```sh
bin/fm-run.sh list                      # every run in this home, with state and generation
bin/fm-run.sh summary <run-id>          # frozen identity, state, custody, receipt counts
bin/fm-run.sh show <run-id> .source     # any part of the frozen manifest
bin/fm-run.sh prove-no-write <run-id>   # assert no outside write was RECORDED through the gates
```

`prove-no-write` reads the receipt log, so it establishes that nothing was *recorded* as written outside the evidence area.
It cannot speak for a process that wrote without calling the gate, and its own output says so; it is not a filesystem audit.

A run that stopped records its stop rule and its exact resumption condition in `run.state`.
Stopping writes a durable checkpoint itself, so restart safety never depends on the operator remembering a second command.
Resuming is idempotent per ownership generation, so a restart or a terminal close never starts a second loop.
A resume re-runs every start assertion before re-entering supervision: time passes while a run is stopped, and a lane can be de-registered or an evidence directory moved in the meantime.

## Account lanes

A lane binds a name to a data class and an explicit configuration root.
The engine never derives a lane from a model name, a harness name, or a path prefix; an unregistered lane is a blocker naming the exact missing registration.

Register lanes in `config/run-lanes.conf` (local, gitignored), one record per line:

```
<lane> <personal|company> <config-root>
```

`company-claude` and `personal-claude` carry built-in defaults pointing at `~/.claude` and `~/.claude-personal`.
Every other lane, including the Codex lanes, must be registered before a run can use it.

A run refuses any read into another registered lane's configuration root.
That refusal is the mechanical half of keeping company material on the company lane; the judgement half, whether a derived summary still carries a company fact, stays with the reconstruction test below.

## Cross-lane summaries

Raw content, identifiers, and derived excerpts that still carry a company fact never cross into a personal account.
Only an abstract pattern crosses, and only when no company fact or identity can be reconstructed from it.

A run that may produce one sets `privacy.crossLaneAllowed` to `sanitized-abstract-pattern-only` before freeze, and records each crossing summary:

```sh
bin/fm-run.sh cross-lane-attest <run-id> --summary-file <path>
```

The attestation records the summary's hash and the assertion that the reconstruction test passed.
A run that left `crossLaneAllowed` at its default refuses the attestation outright.

## Quota reserve governor

`bin/fm-run-governor.sh` turns `quota-axi` evidence into one dispatch class per account/model lane:

| Class | Meaning |
| --- | --- |
| `normal` | eligible dispatch, still gated by fit and machine health |
| `no-new-large` | no new large job; a small one only if it finishes inside the reserve and adds clear value |
| `checkpoint-only` | no new implementation or research rounds; reach the nearest durable checkpoint, preserve, report |
| `emergency` | supervision, state preservation, and safety recovery only |
| `unknown` | quota could not be read fresh, and is therefore not available |

```sh
bin/fm-run-governor.sh classify --lane company-codex --need-seconds 5400
bin/fm-run-governor.sh policy company-codex
bin/fm-run-governor.sh day --lane company-codex
```

The governor never passes `--allow-keychain-prompt` and never prompts, because an unattended keychain unlock is not authorized.
A lane whose quota needs attended authorization classifies as `unknown`, which starts no new large work and surfaces the exact attended requirement.
Already-running work is not disturbed merely because a lane went unknown; it reaches its next safe checkpoint under the reserve policy.

Per-lane policy lives in `config/run-governor.conf` (local, gitignored), one record per line:

```
<lane> <provider> [scope=<scope>] [floor=<percent>] [day-budget=<percentage-points>]
```

Built-in defaults cover the four named lanes: `company-codex` carries the stricter 65% floor, and both company lanes carry the 15 percentage-point per-local-day consumption budget.
The day budget applies from 2026-08-14 in Europe/Budapest, baselines at the day's first reading, rolls over at local midnight, and is released for exactly one lane and one day by:

```sh
bin/fm-run-governor.sh override --lane company-codex --day 2026-08-20 --reason "<captain's reason>"
```

Percentage is only one bound.
A job with a real duration also needs a projected runway that covers finishing and verifying it, so an unmeasurable runway or a lane burning ahead of its reset tightens the class whatever the percentage says.

## Current limits

- `/afk-jira-research` stops at preflight until `tools.surfaceProof` names a verified record that every Atlassian write tool is absent from the worker's surface. Firstmate has no prover for that yet, so the mode refuses rather than running on an unproven surface.
- `bounded-improvement` is refused at preflight until the `fix-known` pilots pass.
- The engine gates calls that are routed through it. It bounds what a run may do with declared paths, lanes, and tools; it does not intercept a tool the worker's runtime hands it directly.

Dated failure and recovery evidence for custody, resume, manifest integrity, and the governor's live-provider behavior lives in [`verification/autonomous-runs.md`](verification/autonomous-runs.md).
