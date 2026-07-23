# Evidence-backed operating control plane

`bin/fm-control-plane.sh` is the captain-facing and supervisor-facing reconciliation surface for registered software work.
The complementary daily discovery of open GitHub issues and pull requests for `data/projects.md` is owned by [`repository-intake.md`](repository-intake.md) and feeds this same supervision loop without becoming another task store.
It extends Firstmate's existing custody, backlog, wake queue, and supervision loop rather than creating another task store, watcher, or action executor.

```sh
FM_HOME=/path/to/firstmate-home bin/fm-control-plane.sh
FM_HOME=/path/to/firstmate-home bin/fm-control-plane.sh --json
FM_HOME=/path/to/firstmate-home bin/fm-control-plane.sh --attention-fingerprint
```

The human view answers what matters now, what is progressing, what is stuck or waiting, what needs the captain, which explicitly authorized action can run next, and which outcome stages lack proof.
The JSON view emits schema `fm-control-plane.v1` for agents and tooling.
The fingerprint view is the stable, minimal watcher integration surface.

## Guarantee boundary

The control plane is deterministic over the registered sources that were observable during a reconciliation run.
Every source record exposes its locator, trust domain, access mode, retention policy, observed time, freshness expectation, and current availability.
Every retained observation exposes a source pointer, observed time, freshness, and a `proved`, `inferred`, `stale`, `conflicting`, or `unknown` classification as applicable.
Unregistered systems, inaccessible sources, stale evidence, and external reality that no connector observed remain explicit unknowns.
The command does not claim omniscience, and it never turns an absence of evidence into evidence of absence.
Completion claims require registered proof and fail closed when current sources disagree.

## Canonical ownership

Firstmate keeps its existing canonical owners.

- `data/backlog.md` owns queued, in-flight, and historical task placement.
- `state/<id>.meta`, `bin/fm-crew-state.sh`, and `fm-fleet-snapshot.v1` own direct-report custody and normalized current runtime state.
- Native Claude and Codex transcript UUIDs and paths own durable agent-session identity.
- Git common directories, worktree paths, and commits own repository and implementation identity.
- `state.md` and `.ai/HANDOFF-*.md` remain project continuity inputs, but a newer native transcript makes their freshness conflict visible.
- `data/<id>/control.json` owns the task's purpose, outcome chain, next action, authority, freshness expectation, and proof definition.
- External connectors own production, user, and revenue facts when those connectors are eventually registered.

The control plane derives a view from those owners and does not write back to them.

## Source registration and scope

Registration is an explicit local opt-in at `config/control-plane-sources.json` using schema `fm-control-plane-sources.v1`.
The file stays private and gitignored with other fleet configuration.
The tracked example is [`examples/control-plane-sources.json`](examples/control-plane-sources.json).

Every source requires an ID, kind, trust domain, access policy, retention policy, freshness expectation, and capability list.
Supported first-slice kinds are `firstmate-home`, `git-project`, `worktree`, `claude-session`, `codex-session`, `claude-transcript-root`, and `codex-transcript-root`.
Explicit session registrations bind native UUIDs to optional work items and projects.
Transcript-root registrations are discovery scopes only and turn matching unregistered sessions into loud `UNREGISTERED_SESSION` violations.
Git project registrations discover worktrees and turn matching unregistered worktrees into loud `UNREGISTERED_WORKTREE` violations.
Disabled or planned connectors remain visible in `connectors[]` instead of silently shrinking the meaning of "all work."

`firstmate-home.backend_observation` defaults to false.
That setting makes fleet reconciliation metadata-only and explicitly reports runtime state as unknown, which is required for read-only audits that must not touch a live session backend.
An operator can enable backend observation only where the registered source policy permits it.

## Work-item control and proof record

Each active or queued task can add `data/<id>/control.json` using schema `fm-control-item.v1`.
The tracked example is [`examples/control-item.json`](examples/control-item.json).
The record provides a bounded checkpoint that survives pane changes, process restarts, and conversation loss.

The required control fields are:

- `owner` identifies accountable custody.
- `next_action` names one atomic capability and its prompt-composable outcome.
- `authority` records the existing Firstmate or project authority gate.
- `updated_at` and `freshness_seconds` define when the checkpoint becomes stale.
- `proof_requirements` defines every outcome stage, including explicit non-applicability with a reason.
- `proofs` stores minimal evidence pointers and observations rather than copied source content.

Authority levels are `observe`, `worker`, `routine`, and `captain`.
`observe` permits read-only reconciliation only.
`worker` permits the already-dispatched worker's bounded task action.
`routine` is available only when existing Firstmate and project policy already grants standing routine authority.
`captain` remains required for merges without standing authority, deploys, publishing, external communication, destructive actions, credentials, and security-sensitive choices.
The control plane can identify a safe next action but cannot widen that authority or execute around Firstmate's guarded commands.

## Outcome stages

The outcome ladder is deliberately non-collapsing.

1. `active` means a registered work item exists.
2. `implemented` requires code or artifact proof.
3. `validated` requires the task's defined test or review proof.
4. `release_ready` requires all declared release gates.
5. `in_production` requires current environment or deployment proof.
6. `real_users` requires privacy-safe evidence of real use.
7. `revenue` requires an authorized business-system record.

A merged pull request can prove implementation or release readiness when the task defines it that way.
It cannot by itself prove production, users, or revenue.
A later-stage proof with an unproved required predecessor is an invariant violation.

Supported first-slice proof kinds are `file`, `git_commit`, and `external_record`.
File and commit proofs are verified locally on every reconciliation.
External records remain minimal pointers with an explicit `proved`, `absent`, or `unknown` result and their own freshness expectation.

## Normalized state and invariants

The JSON output separates source observations from derived judgments.
It inventories projects, worktrees, Firstmate tasks, and native sessions with stable identities that do not depend on pane IDs.
It preserves source conflicts instead of resolving them through prose or last-writer-wins summaries.

The deterministic invariant checker reports at least these classes:

- active custody without a present worktree or endpoint;
- missing owner, atomic next action, proof definition, authority, or freshness expectation;
- stale custody or control records;
- completion without required evidence or conflicting completion claims;
- later outcome proof with a missing prerequisite;
- unavailable or stale registered sources;
- native transcripts newer than Position or handoff state;
- idle sessions whose linked work remains incomplete;
- observable in-scope sessions or worktrees without registration.

Invariant violations are first-class records and attention items.
They cannot disappear into a narrative summary.

## Supervision and recovery

The existing watcher remains the single supervision cycle.
Authoritative task status and backend events keep their current immediate wake paths.
The existing bounded heartbeat also asks the control plane for a stable attention fingerprint as recovery and drift detection.
A new or changed fingerprint is appended to the existing durable wake queue as `check` key `control-plane` before its surfaced marker advances.
An unchanged fingerprint is not enqueued again after a watcher or Firstmate restart.
If the reconciler fails, the watcher surfaces one fail-closed `reconcile-error` attention state instead of treating the fleet as healthy.

The supervisor queue contains invariant failures, proved stuck work, declared external waits, and explicit next actions whose recorded authority allows the existing worker or routine path.
The captain queue contains unresolved decisions and authority-sensitive conflicts.
Real steering still goes through `fm-send`, worker gates, merge guards, deployment rules, and target-project policy.
The control plane never sends a command to a project session.

## Agent capability parity

The captain and an agent can run the same read-only command and receive the same source-backed orientation.
Atomic surfaces are:

- `fm-control-plane.sh` for the human outcome view;
- `fm-control-plane.sh --json` for bounded machine context and exact completion signals;
- `fm-control-plane.sh --attention-fingerprint` for the existing watcher;
- existing Firstmate commands for any separately authorized action.

The JSON `attention.fingerprint`, invariant records, stable IDs, exact pointers, and per-stage proof status provide explicit completion and checkpoint signals.
Each run reloads live registered sources, so agents do not depend on stale conversation context.
Source and record bounds keep context proportional to the declared scope.

## Security, privacy, and later connectors

The first slice retains transcript metadata only: provider, native UUID, path, current working directory, size, and observed time.
It reads bounded transcript head and tail regions only to recover that metadata and never emits message bodies or command output.
Secret-like keys or values in source and control records are rejected, and secret-like text in displayed fields is redacted.
Source revocation is removal or explicit disabling in the local registry, after which the source no longer participates in reconciliation.
Git history provides auditability for tracked code, while the local source registry and private proof records retain only exact pointers needed for operational custody.

Future Gmail, Zoho Mail, Google Drive, iCloud Drive, calendar, and business-system connectors must each register a separate trust domain, access mode, retention policy, freshness expectation, and capability map.
They must emit minimal typed observations through the same provenance contract rather than copy mailbox, document, family, child, finance, identity, or credential content into a flattened data lake.
Cross-domain joins require an explicit work-item link and the authority of both source scopes.
Connector deletion and revocation must remove retained connector indexes without rewriting unrelated domains.
Until a connector implements those rules, it remains visibly `unregistered` and its outcome stages remain unknown.
