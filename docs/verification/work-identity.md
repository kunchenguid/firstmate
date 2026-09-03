# Exact work identity verification

Audience: maintainer verification.

[`bin/fm-work-identity.sh`](../../bin/fm-work-identity.sh) is the single data-contract and validation owner.
[`docs/work-identity.md`](../work-identity.md) owns current operator usage without restating that schema.

## Public-interface evidence

The current contract was verified on 2026-09-02 on macOS arm64 through public commands, lifecycle entrypoints, and fleet projections:

```sh
bin/fm-test-run.sh tests/fm-work-identity.test.sh
bin/fm-test-run.sh tests/fm-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-remote-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-brief.test.sh
bin/fm-test-run.sh tests/fm-fleet-snapshot-view.test.sh
```

Bounded completion output:

```text
ok - exact multi-work-unit intake survives instructions, metadata, snapshot, and Bearings once per worker
ok - spawn delivers validated bytes despite source and snapshot replacement
ok - dispatch publication validates, publishes, and completes under one owner lock
ok - namespaces remain distinct and version, role, duplicate, contradiction, and id syntax are closed
ok - unsafe manifests, labels, stored files, cross-home copies, and task mismatches refuse
ok - legacy tasks stay explicitly unlinked despite every fuzzy fallback signal
ok - delegated summaries preserve ids and reject unsafe home identity paths
ok - linked handoff rebinds identity for delegated decision summaries and Bearings
ok - completed unlinked handoff records one explicit intake transition
ok - delegated linked integrity failures stop parent publication
ok - schema-maximum delegated identities use bounded remote pages
ok - Bearings preserves complete IDs and labels for every bounded worker row
ok - remote handoff commits an exact destination identity and source tombstone
ok - fresh remote work gets a new wake after confirmed cleanup recovery
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fixture snapshot covers task rows, backlog rows, pointers, and stable ordering
```

The focused suite covers single and multiple work units, Work Aligner `plan_id` and `work_units`, DTM project and issue IDs, Data Team Ticket IDs, local Firstmate plans, namespace separation, complete stable IDs paired with labels, absent and filesystem-component-overlong legacy records, idempotence, exact path/task/stable-home binding, local and remote handoff rebinding, malformed versions and syntax, duplicate and contradictory IDs, unsafe paths, C1 controls, Unicode format controls, symlink and hardlink refusal, stale digest refusal, delegated fail-stop propagation, schema-maximum per-home paging under one deadline, stable snapshot output, active and held delegated-child projections, main and delegated status decisions, nested active, decision, hold, and queue omission disclosure, and every prohibited fuzzy signal.
It also covers one-capture manifest, sidecar, metadata, and instruction validation; no-clobber publication recovery; replaced storage parents and lock entries; exact endpoint creation-intent recovery; worktree-request no-resend behavior; atomic metadata publication; replacement dispatch; whole-task-set dispatch retirement; and exact cleanup authorization.
The handoff coverage validates each complete local or remote batch before mutation, preserves exact source and target receipts, rejects unsafe or unrelated records, forwards the exact captured transfer payload, and retains recoverable work until identity ownership and the receiver wake converge.

## Runtime-backend applicability

The backend review covered every spawn-capable runtime supported on 2026-09-02:

| Runtime backend | Applicability | Evidence boundary |
| --- | --- | --- |
| tmux | Applicable | The common spawn preflight snapshots and validates identity before tmux endpoint creation, then receipts the exact session, target, and stable window ID. |
| Herdr | Applicable | The same preflight receipts the exact session, workspace, tab, pane, and target for flat or presentation creation. |
| Zellij | Applicable | The same preflight receipts the exact session, tab, pane, and target after creation. |
| Orca | Applicable | The same preflight receipts the exact worktree, terminal, target, and path after creation. |
| cmux | Applicable | The same preflight receipts the exact workspace, surface, and target after creation. |

No backend parses the relation or receives a backend-specific identity format.
All five converge on the same captured launch input and schema/status/identity-digest/instruction-digest metadata fields.
A secondmate child uses the same interface in its own exact `FM_HOME`.
Local and remote parent projections consume the bounded `fm-secondmate-home-summary.v1` result rather than scanning or reconstructing that child home.

The common spawn and projection boundaries were exercised with:

```sh
bin/fm-test-run.sh tests/fm-spawn-worktree-settle.test.sh
bin/fm-test-run.sh tests/fm-spawn-batch.test.sh
bin/fm-test-run.sh tests/fm-trace-context-spawn.test.sh
bin/fm-test-run.sh tests/fm-bearings-snapshot.test.sh
```

Bounded completion output:

```text
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - batch dispatch re-execs and reports every id=repo pair
ok - relaunch reuses the recorded carrier verbatim for both the meta record and the injected export
ok - TOON and JSON are parity representations of the same model
```

## Worker-tool applicability

The launch-template review covered every verified worker tool supported on 2026-09-02:

| Worker tool | Validated launch-snapshot path | Applicability |
| --- | --- | --- |
| Claude | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Codex | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| OpenCode | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Pi | Full snapshot passed with the worker extensions | Applicable without a tool-specific parser. |
| pi-signed | Full snapshot passed through the exact signed selection | Applicable without a tool-specific parser. |
| Grok | Full encoded snapshot passed at launch | Applicable without a tool-specific parser. |
| Kimi | Full captured operational input delivered after TUI readiness | Applicable without a post-validation path reread. |
| Cursor | Full snapshot passed with the exact workspace | Applicable without a tool-specific parser. |
| Muse | Full encoded snapshot passed at launch | Applicable for its supported crewmate and scout roles. |

The worker-specific launch and recovery boundaries were exercised with:

```sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-test-run.sh tests/fm-grok-harness.test.sh
bin/fm-test-run.sh tests/fm-kimi-harness.test.sh
bin/fm-test-run.sh tests/fm-secondmate-harness.test.sh
```

Persistent secondmate agents are not work-unit workers themselves.
Their local and remote control tasks refuse linked intake before endpoint or home mutation and record the route as explicitly unlinked.
Their ship and scout children use the same worker table in the secondmate home's ordinary spawn path.
Persistent Kimi secondmates are limited to local tmux routes, while remote Herdr routes refuse Kimi launch or interrupted-delivery resume; this does not restrict Kimi ship or scout workers.
Muse remains inapplicable to the persistent secondmate role because of its pre-existing supervision limitation.
No tool may infer a relation from rendered output, process identity, endpoint labels, or status prose.
