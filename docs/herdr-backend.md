# Herdr backend

Herdr is Firstmate's default runtime backend.
No `config/backend` file is required.
An explicit `--backend herdr`, `FM_BACKEND=herdr`, or `config/backend` value still selects it, while supported alternative values remain `zellij`, `orca`, and `cmux`.

## Requirements

Install treehouse and a stable Herdr release before spawning work.
The verified clean Linux and macOS installer command is:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

The installer places `herdr` in `${HERDR_INSTALL_DIR:-$HOME/.local/bin}`.
Set `HERDR_INSTALL_DIR` when validating or packaging into an isolated prefix.
Homebrew users may instead run `brew install herdr`.
Firstmate requires Herdr protocol 14 or newer, and this guide's full acceptance run verified Herdr 0.7.3 with protocol 16.
The guarded lab helper also requires `lsof`, `ps`, `jq`, and standard POSIX process utilities to prove session ownership.
Firstmate ensures that the selected named Herdr server is running before it creates a task endpoint.
Firstmate requires session-scoped workspace, tab, pane, agent, event, send, capture, and close operations.
Every Firstmate call passes an explicit trailing `--session <name>`.

Never scope operational automation only through ambient `HERDR_SESSION`.
Lifecycle verification must use a named non-default lab session and a guarded helper that refuses the `default` session immediately before stop and delete.

## Configuration and readiness

Herdr itself works without a configuration file for Firstmate's required operations.
No integration install is required for the built-in Claude, Codex, OpenCode, Pi, and Grok detection paths.
Firstmate also needs no `config/backend` file because Herdr is the default.
Writing `herdr` to the active Firstmate home's `config/backend` is supported when an explicit local declaration is preferred.
The adapter checks the client protocol and ensures the selected named server is running before creating a workspace or task tab.
Do not start or stop the default session merely to validate readiness.

## Selection and metadata

Backend selection precedence is `--backend`, `FM_BACKEND`, `config/backend`, runtime detection, then Herdr.
`HERDR_ENV=1` selects Herdr before cmux runtime signals are considered.
Zellij and Orca are never auto-detected.

Herdr is the metadata default, so new Herdr tasks omit `backend=herdr`.
Backend-less metadata normally resolves to Herdr, while the historical removed-runtime exception and its safe migration path are owned by [`docs/configuration.md`](configuration.md#runtime-backend).
Readers must never interpret an absent backend as permission to probe an unrelated live endpoint.

## Container shape

### Task container shape

Each task uses one tab named `fm-<task-id>` and one root pane.
The metadata `window=` value records `<session>:<pane-id>`.

Treehouse provides the worktree for Herdr tasks.
Firstmate creates the tab without stealing focus, runs treehouse acquisition in the pane, verifies the pane's physical working directory, launches the selected harness, and records metadata only after the endpoint is usable.

### Workspace-per-home

Each Firstmate home has one Herdr workspace.
The primary home uses `firstmate` and a secondmate home uses `2ndmate-<id>`.

## Capabilities

The adapter supports endpoint creation, bounded capture, literal text delivery, Enter and control-key delivery, composed run-and-submit, physical current-directory reads, semantic agent busy state, agent-process liveness, native event waits, composer-state checks, interrupt, and pane teardown.
Closing the only pane also closes its task tab.
Firstmate never closes the containing workspace during ordinary task teardown.

### Workspace lifecycle, focus behavior, and label collisions

Firstmate creates a missing home workspace with `--no-focus`, captures the seeded tab ID from that same response, and prunes only that exact seeded tab.
An adopted workspace never carries a seeded-tab ID, so Firstmate cannot prune a tab from a workspace that it did not create.
Herdr does not enforce unique workspace labels, so lookup adopts the first matching workspace and task creation refuses a live duplicate task label.
The stable metadata IDs are authoritative for normal operations; label scans are recovery-only.

### Default-tab prune

The adapter may close only the seeded default tab returned by the workspace creation call that is currently executing.
It never re-derives prune eligibility from a label or visible layout.

`fm-send.sh` resolves a task through metadata, types a steer once, and verifies submission.
Slash commands and Codex skill invocations receive a short popup-settle delay before the first Enter.
The Herdr adapter retries Enter without retyping when autocomplete consumes the first key.

### Busy state

`fm-crew-state.sh` combines bounded capture with Herdr native agent state.
`fm-watch.sh` uses native agent-status events when available and falls back to bounded capture and the shared busy regex.
The away-mode supervisor supports only a Herdr supervisor pane and refuses unsupported supervisor backends.

## Composer safety

### Composer-emptiness safety (2026-07-10, fleet-wide across all four backends)

Injection occurs only when composer state is affirmatively `empty`.
Real pending input and an unreadable or dead-shell pane both defer.
`bin/fm-composer-lib.sh` owns the shared empty, pending, and unknown classification after Herdr identifies the structural composer row.
Its ANSI-aware ghost stripping removes dim or dark placeholder styling without removing bright real input.

Submission from an idle baseline is confirmed through native agent state.
Structural composer classification is the conservative fallback when native state cannot establish the transition.

### Native agent-state submit confirmation

For an `idle` or `done` baseline, the adapter confirms submission only after native agent state becomes `working` or `blocked` within a bounded poll window.
For an already-active or unreadable baseline, it falls back to structural composer state and never treats pre-existing activity as proof that the new Enter landed.
Enter may be retried, but the message text is typed only once.

### Incident (2026-07-03): autocomplete consumed Enter

A Herdr steer could previously treat a popup content change as successful submission even though the command remained in the composer.
The structural composer-state check now reports that placeholder as `pending`, so the adapter sends another Enter without retyping the command.

### Incident (2026-07-07): idle-tip submit confirmation

Composer content alone could not reliably prove that a steer started a turn when an idle harness rotated its own suggestion text.
The adapter now records the native idle baseline and confirms a real `working` or `blocked` transition across a bounded sampling window.
An unreadable target reports `unknown`, and an already-active baseline uses the conservative composer fallback.

### Incident (2026-07-08): faint idle suggestion blocked delivery

Herdr ANSI capture preserves faint prompt suggestions that plain capture cannot distinguish from typed text.
The shared ghost extractor removes faint runs before composer classification while retaining normal-intensity text.

### Incident (2026-07-10): dark truecolor placeholder blocked delivery

Grok renders its idle placeholder with a dark truecolor foreground rather than the faint attribute.
The shared extractor drops dark truecolor foreground runs below `FM_COMPOSER_GHOST_LUMA_MAX` and retains the verified bright real-input foreground.
This rule assumes the fleet's dark terminal theme and remains fail-safe by deferring when styling is unreadable.

## Native pane.agent_status_changed push escalation: immediate blocked wake

Herdr protocol 16 exposes `pane.agent_status_changed` through `events.subscribe`.
The watcher uses one bounded subscriber process to surface a fresh `blocked` edge immediately, clears per-pane dedupe on `working`, and level-reconciles after subscription acknowledgement.
Protocols below 16, a missing event schema, connection failure, or repeated runtime failure fall back to the normal polling loop.
Polling remains active as the lossless backstop.

## Agent liveness probe reuses the husk classifier

`fm_backend_agent_alive` reports a task alive only when its recorded pane exists and Herdr reports a registered agent process.
A missing pane or agent-less restored shell is replaceable; unreadable or ambiguous state fails safe and is not destroyed.

## Teardown and recovery

Teardown resolves the recorded pane, closes only that pane, returns the treehouse worktree when safe, and removes task state.
Recovery treats missing `backend=` as Herdr except for the historical removed-runtime target shape documented in [`docs/configuration.md`](configuration.md#runtime-backend), and uses the recorded endpoint rather than scanning global sessions.
A restored tab with no registered live agent is a replaceable husk; an ambiguous liveness result is left untouched.

### Session targeting: the --session flag, not HERDR_SESSION alone

Every adapter operation sets `HERDR_SESSION` and appends a trailing `--session <name>`.
Ambient `HERDR_SESSION` alone is not accepted as isolation for lifecycle verification.
The lab helper performs fresh baseline and ownership checks immediately before stop and delete, rejects default or ambiguous records, and verifies the initial default-session tripwire after cleanup.
The canonical tripwire accepts only one structurally valid JSON inventory whose initial `sessions` array is exactly empty or contains exactly one session named `default`, records its exact running state, and rejects every foreign or contradictory record.
After provisioning, the same state record binds a cryptographic launch nonce to the foreground server's socket-owning PID, process start identity, and the device/inode identity of the directory derived from the authoritative `socket_path`, without extending Herdr's inventory schema.
The guarded stop verifies the exact baseline, record, and persistent storage identity, confirms that the captured process exited and released its socket, and only then persists the stopped phase.
Delete is authorized only when teardown itself proved the live nonce-bound process and performed that stop under the same lifecycle lock.
A session stopped by an earlier operation must be reprovisioned through the helper to establish a fresh live proof before teardown, because Herdr 0.7.3 exposes no persistent instance ID.
Teardown repeats the exact stopped-record, session-specific storage, and baseline checks immediately before delete, confirms absence afterward, and refuses every ambiguous replacement.
The canonical E2E removes its temporary sandbox only after confirmed guarded teardown; a cleanup failure retains the tripwire, nonce, and sandbox path for a safe retry.

### ID stability

Recorded pane IDs are authoritative while a session is live.
Recovery scans labels because restored layouts can replace IDs, and it treats an agent-less restored task tab as a husk rather than a live task.
Workspace labels are not unique, and native agent-state accuracy depends on the harness registering with Herdr.

### Known gaps

Herdr 0.7.3 honors `XDG_CONFIG_HOME`, so the canonical acceptance uses an isolated temporary config root in addition to a generated non-default session and the guarded helper.
Workspace labels remain non-unique, and restored pane IDs may change across a server restart.

## Away-mode daemon supervisor-pane support

The away-mode daemon supports a Herdr supervisor pane selected by explicit metadata or Herdr runtime markers.
It refuses zellij, Orca, and cmux supervisor panes until their composer and submission surfaces are empirically verified.
Injection requires an affirmatively empty composer and confirmed submit transition.

## Away-mode daemon terminal launch

Harnesses without an in-pane background tool launch the daemon in a dedicated `--no-focus` Herdr workspace rather than splitting the captain's active tab.
The launcher records the exact daemon pane and workspace IDs, and stop closes only that recorded pane.

## Stale-artifact lifecycle fix

A fresh away-mode entry clears stale delivery-cache artifacts only when no daemon is already running.
Stop terminates the daemon while `state/.afk` still exists so the final flush can run, closes the recorded daemon endpoint, and clears `state/.afk` last.
Durable truth remains in the wake queue and per-task status logs.

## Isolated lifecycle verification

The removal migration was verified against a real named non-default Herdr lab session.
The verification covered a clean isolated install, required protocol, implicit and explicit backend selection, server readiness, separate-tab spawn, steer delivery, watcher signal wake, guarded stop and restart, husk replacement through recovery spawn, endpoint teardown, guarded lab teardown, and an unchanged default fleet.
CI and the no-mistakes gate both opt into that guarded acceptance; a clean runner with no default session records and preserves that absence without creating or operating on `default`.

Exact version, commands, selected output, session name, and cleanup evidence are recorded here after each release-blocking verification run.

### Removal migration record

On 2026-07-15, the hardened migration was verified with Herdr 0.7.3 in a generated non-default lab session.
The production spawn path created an isolated E2E task, omitted `backend=` from its metadata, and resolved that absent field back to Herdr.
The live endpoint accepted a steer, the watcher surfaced a signal wake, guarded stop and reprovision recovered the runtime, and production teardown removed the endpoint, worktree, and metadata.
Guarded lab teardown stopped the owned running instance, verified the exact stopped record and untouched baseline, deleted only that stopped session, and confirmed process, socket, and inventory absence.

The helper polls a bounded interval for confirmed process and inventory absence after stop and delete while rejecting default, replaced, or ambiguous session records at every destructive boundary.
Regression coverage exercises live-delete rejection, delayed deletion with a nonzero delete exit, process-survival races after stop, instance replacement, signal-safe lifecycle-lock cleanup, and fail-closed default-session protection.

### Canonical guide acceptance run

The install and lifecycle guide is encoded in `tests/fm-herdr-guide-e2e.test.sh` so the recurring mechanics remain auditable.
The generated session was exactly `fm-lab-herdr-guide-e2e-70934-31074`.
The exact command run from the repository root on 2026-07-15 was:

```bash
FM_RUN_HERDR_GUIDE_E2E=1 bash tests/fm-herdr-guide-e2e.test.sh
```

The test downloaded the stable installer, set `HERDR_INSTALL_DIR` to a fresh isolated temporary prefix, and confirmed that the installed binary was first on `PATH`.
It then used only the guarded helper for the generated non-default session and routed production adapter calls back through that helper.
The exact acceptance line was:

```text
HERDR_GUIDE_E2E_OK version=0.7.3 protocol=16 session=fm-lab-herdr-guide-e2e-70934-31074 baseline=default default=herdr configured=herdr readiness=ok spawn=ok steer=ok watcher=signal restart=recovered teardown=ok lab_teardown=ok
```

The guarded teardown succeeded on its first call and the fleet-state tripwire confirmed the identical stopped `default` session before and after the run.
