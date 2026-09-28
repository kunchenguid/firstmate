# Paseo Runtime Backend

Paseo is an experimental, explicit-only runtime backend for Codex, OpenCode, and host-diagnostic-gated Claude workers.
It owns each agent endpoint and its isolated task worktree inside an existing registered Paseo project.

## Setup

Install Paseo and `jq`, then ensure the existing daemon answers `paseo daemon status`.
Firstmate never starts, stops, or restarts the Paseo daemon.
Select it with `config/backend`, `FM_BACKEND=paseo`, or an explicitly authorized `--backend paseo`.
Paseo is never auto-detected and never supports secondmate spawns.

## Limits

`codex` and `opencode` map directly to Paseo providers.
Claude is accepted only when its host diagnostic has a recognized positive status and Paseo reports the provider available and enabled.
Absent providers are rejected by name rather than substituted.
Workers are root agents created with `env -u PASEO_AGENT_ID`.
Each fresh task must match exactly one registered Paseo project by the physical path of its source checkout, and Firstmate refuses to create a project when that match is absent or ambiguous.
After a Firstmate project is added or created, project management runs an idempotent Paseo registration helper only when Paseo resolves as the runtime backend for new tasks.
An explicit request to register an existing Firstmate project in Paseo uses the same idempotent helper regardless of the selected backend.
The helper requires one registry entry and a checkout under the active home's `projects/` directory, reuses one Paseo project already matching the physical checkout path, creates one when none matches, and refuses ambiguous matches.
Neither path changes spawn behavior: a task spawn only matches an existing Paseo project and never creates one.
If registration fails during project add or create, Firstmate reports the failure and keeps the successful local checkout and registry entry.
Removing a Firstmate project does not remove its Paseo project; cleanup may be added as a separate follow-up.
Firstmate uses `paseo workspace create --path` to create one worktree workspace from that checkout, with its own branch and a unique home-and-task slug, then starts the agent with `paseo run --workspace`.
The agent receives the task's unique `fm-task` label and the Firstmate home's `fm-home` label, while task metadata records the returned agent identity and the validated workspace and worktree identities.
Relaunch requires the same registered source project, a matching worktree workspace, and the recorded worktree path, then reuses that workspace without creating another one.
Paseo can answer an existing-workspace run with `Using workspace <id>` and no `workspaceId` JSON field, so Firstmate retains the workspace identity it validated before the run.
The selected workspace is passed through `--workspace`; Firstmate does not pass `--cwd` to `paseo run`.
When filtering is enabled, Firstmate passes eligible set allowlisted values to Paseo through individual `--env NAME=value` flags; these arguments are visible in process listings on the daemon host ([full forwarding contract](configuration.md#worker-launch-environment-configlaunch-env-allowlist)).
Logs are timeline output, not a verified visible viewport, and agent liveness remains `unverified` because Paseo exposes no worker pid.
Interrupt maps to `paseo stop`; exit accepts only a native `closed` or `archived` status as stop proof, otherwise archives the agent and verifies terminal status.
After a successful Paseo run, an aborted Firstmate spawn confirms the agent is stopped before checking Git and archives the agent and workspace only when the worktree is clean.
Dirty, ignored, or uninspectable worktrees are retained; stop, status, or archive failures are reported with both IDs and a reason for manual reconciliation.
If workspace creation or `paseo run` fails after reporting a created workspace, Firstmate reports its ID and leaves that workspace for manual reconciliation.
Teardown archives the agent and then its separate workspace record.

## Verification

The adapter contract is implemented in [`bin/backends/paseo.sh`](../bin/backends/paseo.sh), while project registration is owned by [`bin/fm-paseo-project.sh`](../bin/fm-paseo-project.sh).
Spawn and metadata publication live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), with dispatch in [`bin/fm-backend.sh`](../bin/fm-backend.sh).
The project-registration helper has focused fake-CLI coverage in `tests/fm-paseo-project.test.sh`; the adapter and spawn suites are `tests/fm-backend-paseo.test.sh` and `tests/fm-spawn-paseo-env.test.sh`.
Current host evidence belongs in [`verification/runtime-backends.md`](verification/runtime-backends.md#paseo).
