# Fleet vocabulary-collision registry

This file is the fleet's single owner of words that carry more than one meaning across the fleet, the Agentic Engineering platform, and the vendor tools both depend on.
A row here records a ruled disposition, not an opinion: what the senses are, who owns each, what was decided, and what a contributor must write instead.
When a word acquires a second live sense anywhere the fleet reads or writes, add a row here rather than resolving it locally in the file where it surfaced.

The platform keeps the mirror of this registry as Register 3 of its `docs/architecture/governance-registers.md`.
Neither registry is authoritative over the other's repository: each records the dispositions its own repository must honor, and a cross-repository row states both sides.

## Dispositions

The vocabulary of this column follows the platform's Register 3 precedent.

- **NO RENAME** - both senses keep the word; the row exists so the ruling is findable.
- **QUALIFY** - both senses keep the word, but each must always be written in its qualified form.
- **NO-CONTACT** - the senses cannot reach each other, and the row records the evidence for that.
- **DISSOLVED BY RENAME** - one sense was renamed; the row records both names and the retirement point of the old one.
- **DISSOLVED BY SPLIT** - one overloaded identifier was split into independent fields; the row records the axes and the retirement point of the old identifier.

## Rows

Every row below was ruled by the captain on 2026-08-07 against the measured census in the CFVC-16 naming proposal.

### `axi`

| | |
|---|---|
| **Disposition** | NO RENAME |
| **Fleet sense** | the `*-axi` CLI family - `gh-axi`, `lavish-axi`, `chrome-devtools-axi`, `quota-axi`, `tasks-axi` |
| **Platform sense** | the Agent Interface Layer |
| **Third sense** | the upstream `axi` "Agent eXperience Interface" discipline, external to both repositories |

The fleet does not own the identifier: the `*-axi` tools are third-party package names, so a fleet-side rename would be a fork rather than a rename.
The platform's own row (Register 3, added 2026-07-23) already rules the convergence deliberate.
Write the tool name in full (`gh-axi`, never "axi") whenever the fleet means a tool.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 3 names the tool family; every `bin/fm-*.sh` that shells out to one of them.

### `skill`

| | |
|---|---|
| **Disposition** | QUALIFY (fleet side); DISSOLVED BY RENAME (platform entity sense only) |
| **Fleet sense** | a procedure directory under `.agents/skills/<name>/SKILL.md`, loaded by name |
| **Fleet sense** | a public installer-facing procedure under `skills/<name>/SKILL.md`, never loaded by a running firstmate |
| **Platform sense** | an engineering procedure under its `harness/skills/<name>/SKILL.md` |
| **Platform sense** | the `EngineeringSkill` entity, renamed platform-side to `EngineeringTechnique` |
| **Vendor sense** | the harness vendor's `Skill` tool and the literal `SKILL.md` discovery filename |

Five senses, not the three the platform's Register 3 first recorded.
The markdown senses are not renameable by either repository, because `SKILL.md` is the vendor's discovery filename and `Skill` is the vendor's tool name.
Fleet-side the word always takes a qualifier - "agent-only skill", "public skill", "the `Skill` tool" - and never stands alone in a document either repository may read.
The platform's persisted `skill_id` / `SKILL-*` wire identity intentionally lags the renamed type and is not rewritten.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) sections 2 and 13; the `.agents/skills/` and `skills/` split recorded in section 2's layout.

### `watch`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Fleet sense** | the supervision daemon - always written **`watcher`**, never bare "watch" |
| **Platform sense** | the governance view - always written **`Watch Register`**, never bare "Watch" |

Neither side renames.
The two vocabularies meet only in cross-repository assessment documents, and both already write the qualified form there.
The residual overlap is the bare English verb, which no rename removes.
A contributor writing about the fleet's supervision means `watcher`; a hyphenated compound (`watch-arm`, `watcher-beat`, `watch-checkpoint`) is already qualified and needs no change.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 8 and its captain-facing translation table in section 9; [`docs/watcher-continuity.md`](watcher-continuity.md); `bin/fm-watch*.sh`.

### `promotion`

| | |
|---|---|
| **Disposition** | DISSOLVED BY RENAME (fleet sense) |
| **Platform sense** | **Promotion Law**, a canonized law with a declared firing threshold and recorded firings - keeps the word, unchanged |
| **Fleet sense** | the scout-to-ship operation, renamed **`reflag`** (`bin/fm-reflag.sh`) |
| **Fleet sense** | model promotion and demotion between routing tiers, which keeps the word |
| **Other platform senses** | evidence-class promotion; census promotion trigger; the authority-ladder promotion of a managed trading project |

The platform's sense is canonized law, so renaming it would be a constitutional-tier act; the fleet's sense had the smallest measured footprint of any collision in the census and no captain-vocabulary cost, because the captain never hears either word.
`reflag` says what the operation does: a vessel is reflagged when its registry and contract change while hull and crew stay, which is exactly the scout-to-ship operation - the worker keeps its window, worktree, and loaded context, and only the delivery contract changes.
The fleet's own model-promotion sense, in `.agents/skills/model-onboarding/SKILL.md`, is a distinct fifth sense that surfaced while this row was being written; it keeps the word because it is a promotion in the platform's own sense - evidence earning a durable position - and it never meets the task vocabulary.

**Retirement of the old entry point.**
`bin/fm-promote.sh` is a bounded compatibility shim, not an alias.
It exists only for a firstmate turn that loaded the pre-rename instructions and has not yet fast-forwarded, so its retirement condition is: **remove it once every home that this repository serves has fast-forwarded past the commit that introduced `bin/fm-reflag.sh` and re-read its instructions.**
The shim records each use in `state/.reflag-shim-used` so that condition is settled by evidence rather than by memory; an absent marker after a full task cycle is the proof that no caller still needs it.
It is not a general-purpose entry point: it forwards, warns on stderr, and is excluded from documentation as a supported command.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 7 "Scout outcome and reflagging" and the section 9 do-not-expose list; [`docs/architecture.md`](architecture.md); [`docs/scripts.md`](scripts.md); `bin/fm-reflag.sh`.

### `execution`

| | |
|---|---|
| **Disposition** | NO-CONTACT (across the platform's managed-project boundary) |
| **Platform sense** | the execution plane - `execution_node`, ADR-0053 / ADR-0054 |
| **Platform sense** | the EI artifacts - `ExecutionUnit`, `ExecutionPlan` |
| **Platform sense** | the provider seam - `execution_provider` |
| **Managed-project sense** | order execution in the platform's trading project |

Neither side renames, and the pair originally reported as the collision is the one pair that cannot collide: the platform and its managed trading project never share an import root, so no name resolution ever reaches across.
"Execution" is also the domain-standard term for order execution, so renaming the trading sense would trade correctness for hygiene.

The collision worth recording is internal to the platform, where three of its own senses do share one import namespace; the platform's Register 3 owns that row.
The fleet's only contacts with any of these senses are deliberate disambiguations that already name the platform artifact explicitly, such as the LoopSpec contract stating that a LoopSpec is not an `ExecutionUnit`.

**Where it bites:** [`.agents/skills/loopspec/SKILL.md`](../.agents/skills/loopspec/SKILL.md); [`loopspecs/schema.json`](../loopspecs/schema.json); `bin/fm-loopspec.sh`.

### `lifecycle`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Platform sense** | the project phase lifecycle - a constitutional state machine with a durable artifact per project |
| **Fleet sense** | the task lifecycle, plus the decision-hold, secondmate, wake-daemon, and Herdr lifecycles |

The platform's sense has the deepest governance footprint measured and is not renameable at any price this work could justify.
The fleet's real ambiguity is internal rather than cross-repository - it uses the word for five different things - and the fix is the qualifier the fleet already writes almost everywhere.
Never write "the lifecycle" bare in a document either repository may read.
Write `task lifecycle`, `project lifecycle`, `decision-hold lifecycle`, `secondmate lifecycle`, `wake-daemon lifecycle`, or `Herdr lifecycle`.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 7, titled "Task lifecycle"; [`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md); the `lifecycle`-suffixed test names in `tests/`.

### `kind`

| | |
|---|---|
| **Disposition** | DISSOLVED BY SPLIT (task-metadata sense) |
| **Task-metadata sense** | the single `kind=` field of `state/<task-id>.meta`, split into `role=`, `deliverable=`, and `stage=` |
| **Backlog-hold sense** | `tasks-axi hold --kind captain`, and the admission policy's `--kind load` |
| **Wake-ledger sense** | the wake kind of a queued wake - `signal`, `stale`, `check`, `heartbeat` |
| **Operational-input sense** | the structural kind of a marked message, owned by `bin/fm-operational-input.sh` |

One `kind=` field carried three independent facts at once: who the worker is, what the task produces, and where the task stands in its life.
Every consumer had to reconstruct the axis it cared about from a value that also encoded the two it did not, and the scout-to-ship operation expressed a lifecycle transition by rewriting a deliverable type.
[`bin/fm-task-axis-lib.sh`](../bin/fm-task-axis-lib.sh) is the single owner of the three axes, their values, and the deterministic derivation from the retired field.

`kind` remains a live field name in three other unrelated fleet namespaces, listed above.
Those are separate vocabularies with their own owners and are not part of this split; do not introduce a fourth.

**The role axis is now the home for every role-typed fact about a task.**
A field describing who a worker is - including a requested agent role, which was deferred until this split existed - belongs on `role=` and never as a new dimension beside it.
That deferral was the whole reason the split had to come first: adding a role field to the old single-field vocabulary would have made a fourth conflated axis out of a field that already carried three.
No such field exists in the fleet today; the axis is what makes adding one a one-line change rather than another conflation.

**Retirement of the deprecated field.**
`kind=` is still written to every task's metadata and is still the derivation source for a record that predates the split.
Its retirement condition is: **stop writing `kind=` once no reader consults it and one full task cycle has run entirely on the three axes.**
Until then it is a dual-written deprecated alias with exactly one owner, and a metadata record whose `kind=` disagrees with its explicit axes is refused rather than silently resolved, so a stale writer that flips the old field alone cannot desynchronize a task's identity.

**Where it bites:** [`bin/fm-task-axis-lib.sh`](../bin/fm-task-axis-lib.sh); the metadata field list in [`AGENTS.md`](../AGENTS.md) section 2; [`docs/architecture.md`](architecture.md).

## Maintaining this file

Add a row when a word acquires a second live sense in any repository the fleet reads or writes, not when a rename is proposed.
A row states the senses, their owners, the ruled disposition, what to write instead, and - for a rename or a split - the retirement condition of the obsolete name, so no obsolete path is left with an open-ended life.
Keep the "where it bites" pointers current: they are the reason a contributor finds this file, and each pointed-at site carries a one-line cross-reference back rather than a second copy of the ruling.
