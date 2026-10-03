# OpenShell Codex workers on Herdr

Firstmate can run an individual Herdr Codex ship worker inside NVIDIA OpenShell. Herdr keeps the task pane and interactive PTY; OpenShell owns the Codex process boundary. This is an explicit per-home opt-in. Firstmate does not install or start OpenShell, a gateway, or a compute service.

## Supported scope

The opt-in supports Linux Herdr Codex ship tasks using the `no-mistakes` delivery mode. It requires an installed OpenShell CLI, a registered and reachable OpenShell gateway, a gateway with the OpenShell `base` image available, and already configured providers. OpenShell's base image includes Codex. The gateway may use a supported compute driver; Firstmate uses OpenShell's sandbox upload and download operations and does not request host bind mounts or disable resource admission.

Scouts and secondmates are refused while the setting applies because their reports or home capabilities live outside the assigned task worktree. Other backends and harnesses remain unchanged. Direct-PR delivery is not supported: the task worker does not receive host `gh-axi`, and OpenShell's standard GitHub profile permits clone and fetch but denies Git push. The `no-mistakes` pipeline runs after the worker commits, with forge-specific delivery governed by the host validation handoff below.

## Setup

Create the local, gitignored file `FM_HOME/config/herdr-codex-openshell`:

```text
gateway=local
providers=codex
```

`gateway` is the name of an already registered OpenShell gateway. `providers` is a comma-separated list of one to four already configured provider instance names; it must include the instance named `codex`. Configure that instance with the OpenShell Codex provider profile and an approved credential using the mechanism supported by that profile. The worker does not inherit the host's Codex sign-in state, OAuth tokens, OpenAI environment variables, or home configuration. Add another provider only when the worker needs its reviewed credential and network policy, for example `providers=codex,github` for mediated GitHub reads.

Review each attached provider's profile, credential bindings, binary paths, and network rules before enabling the setting. OpenShell denies outbound network access by default, and the base image's default policy has no Codex network coverage. The Codex provider profile or another active OpenShell policy must explicitly allow the Codex binary to reach only the model endpoints it needs. Provider policy is scoped to the profile's named binaries and endpoints; the standard GitHub profile allows clone and fetch while keeping push denied. An active gateway-wide policy replaces the sandbox policy and suppresses provider-derived network rules; Firstmate refuses to launch when it finds an active or unverified global policy. Keep the selected gateway free of a global policy until the task sandbox is deleted. A missing provider, an invalid or incomplete policy, a gateway failure, or a Landlock failure stops the launch without retrying host Codex.

The sandbox policy sets Landlock to `hard_requirement`, which requires Landlock ABI v3 or newer on the OpenShell compute host (normally Linux 6.2 or newer). OpenShell refuses to start the worker if it cannot enforce the requested policy. Keep provider and policy setup in the gateway's normal operator workflow; this Firstmate change does not mutate gateway state.

## Files and task channels

The runner creates a private, no-hardlinks clone of the assigned task branch under `/tmp/fm-<task>/openshell-codex/workspace`. It copies tracked and non-ignored untracked task files, plus staged changes. Ignored files and submodules are unsupported. It sends the clone through OpenShell's supported file-transfer API into `/sandbox`, the only project and task data path. System paths are read-only; `/tmp` is private scratch space and `/dev/null` is writable as a device. The host worktree, shared Git directory, `HOME`, SSH state, Codex host configuration, task state directory, and other worktrees are not mounted or copied into the sandbox.

At initial spawn, Firstmate resolves `OPENSHELL_WORKSPACE` (or OpenShell's `default` workspace when unset) to its exact gateway workspace ID and records both name and ID in task metadata and the recovery journal.
Every OpenShell operation explicitly selects that name and checks its current ID against the task record; missing identity or a workspace recreated under the same name refuses execution and cleanup.
Relaunch reuses the recorded identity regardless of the current shell selection.

The Herdr pane runs `openshell sandbox exec --tty`, preserving the interactive Codex PTY while Herdr continues to own pane and session lifecycle.
Codex uses a private `CODEX_HOME`, with its own sandbox disabled because OpenShell supplies the process boundary.
Fresh sandbox Codex defaults to `gpt-6.1-sol` with `medium` reasoning effort, while explicit task model and effort overrides take precedence.
Git identity is copied as non-secret values; the HTTPS origin is copied without credentials.

Firstmate relays only the current task's numbered inbox messages, validated one-line status appends, its fixed turn-ended marker, and a fixed validation handoff request.
The relay polls the task channel through OpenShell file transfers while Codex is active.
The sandbox cannot pass host paths or task ids to these operations.
Workspace changes are downloaded and synchronized only to the task's recorded branch using a fast-forward and compare-and-swap check.
Staged and non-ignored uncommitted changes are preserved.
File and symlink leaves can become directories, or directories can become leaves, by retiring obsolete leaves before copying replacements; unrelated directory contents refuse replacement and remain intact.

## Host validation handoff

The delivered overlay replaces the brief's host setup and validation instructions for this sandbox session.
The worker commits its project changes on the assigned branch and runs `/sandbox/.git/fm-openshell/fm-task-capability validation request` instead of appending `done`.
The request accepts no task ID, host path, command, or credentials.
The runner ends its sandbox execution, stops any remaining sandbox process, and downloads the snapshot through the workspace-bound transfer API.
A handoff requires a clean worktree with all changes committed, so synchronization returns committed tracked project files; uncommitted or non-ignored untracked files refuse the handoff and retain recovery artifacts.
After synchronization and sandbox deletion, the host records the exact HEAD and task/workspace identity in `state/<task>.openshell-validation.json` and appends the readiness status.
Herdr continues to own the task pane and session.

Firstmate supplies the task's authoritative intent in a regular host file and explicitly runs:

```sh
FM_HOME=/path/to/firstmate-home \
FM_ROOT_OVERRIDE=/path/to/firstmate-code \
python3 /path/to/firstmate-code/bin/fm-openshell-codex.py validate TASK_ID \
  --intent-file /path/to/task-intent.txt
```

This command requires the Herdr endpoint to be dead or missing, the recorded workspace ID to remain valid, the sandbox to be absent, and the host branch, clean worktree, and HEAD to match the handoff.
It resolves the recorded project's forge through `fm-project-mode.sh` and invokes `no-mistakes axi run` only in that task's host worktree, returning its exit code and output.
For a registered Gerrit project it passes exactly `--skip push,pr,ci`; all other validation phases still run, and the existing Gerrit publication contract remains on the host.
Other supported forges receive no additional skips; an invalid registered forge refuses validation.
The host must already have an initialized no-mistakes repository and its normal validation toolchain; setup failures remain explicit failures.
Firstmate handles subsequent gates and outcomes through the normal no-mistakes workflow on the host.
The sandbox receives no host validation credentials, mounts, or additional policy permissions.

## Failure and recovery

OpenShell setup, policy, TTY, provider, transfer, or synchronization failures stop this launch. Firstmate never retries as host Codex. If the runner exits unexpectedly, the sandbox may remain with an interrupted Codex process; the task's files and task metadata are retained. The worker does not resume the same Codex conversation after recovery.
A recorded validation request is completed by recovery only after its clean committed snapshot synchronizes; failed synchronization never publishes validation readiness.

After proving that the task's Herdr endpoint is dead or missing, recover the exact task sandbox with:

```sh
FM_HOME=/path/to/firstmate-home \
FM_ROOT_OVERRIDE=/path/to/firstmate-code \
python3 /path/to/firstmate-code/bin/fm-openshell-codex.py recover TASK_ID
```

If preparation failed before sandbox creation, recovery removes the journaled incomplete staging without changing the task worktree.
Otherwise, recovery stops and restarts the task's named sandbox to terminate any orphaned Codex process, downloads its persistent workspace, synchronizes the snapshot to the recorded task branch, and deletes that sandbox. It refuses if the Herdr endpoint is still live, the OpenShell gateway cannot prove the sandbox state, the branch moved, or synchronization is unsafe. Repair the reported OpenShell, gateway, or worktree condition and retry. Do not remove the task's `/tmp/fm-TASK_ID/openshell-codex*` artifacts while recovery is incomplete. After recovery, Firstmate can relaunch the task on its recorded OpenShell path; removing the opt-in never changes an OpenShell-bound task into a host Codex launch.
