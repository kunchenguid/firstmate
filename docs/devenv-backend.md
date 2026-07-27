# Devenv backend

Audience: operators.

The `devenv` backend is an experimental remote control plane for existing Expanly OrbStack VMs.
It discovers the existing environment registry, installs a commit-pinned FirstMate runtime, inspects VM state, queues work, and manages token-guarded control-plane leases.
It does not spawn tasks, prepare branches, run `make devenv-sync`, start agents, or replace the resident execution work planned for the next implementation phase.

## Configuration

Select the backend with `FM_BACKEND=devenv` or the first non-empty line `devenv` in local `config/backend`.
The general backend precedence and configuration-file ownership remain in [configuration.md](configuration.md#runtime-backend-configbackend--fm_backend).
The backend is never auto-detected and requires `ssh` and `jq` on the Mac.
The default registry path is `~/.expanly-devenvs.json`; `FM_DEVENV_REGISTRY` can point tests or an operator command at another registry.
Registry discovery validates every feature row and synthesizes the existing `main` environment without treating it as a base image or a privileged worker.

## Runtime installation

Install the current tracked FirstMate runtime into one registered environment:

```sh
bin/fm-devenv-install.sh <feature-environment>
```

Verify that the remote runtime marker matches the current local FirstMate commit without changing remote files:

```sh
bin/fm-devenv-install.sh --verify <feature-environment>
```

Installation archives only tracked FirstMate runtime surfaces from the captured commit.
The remote release is stored under `~/.local/share/firstmate-expanly/releases/<commit>` and selected through `~/.local/share/firstmate-expanly/current`.
Per-environment lease state is stored under `~/.local/state/firstmate-expanly/<environment>`.

## Protocol

The current wire protocol is `firstmate.devenv.v1`.
Each SSH connection invokes only the fixed installed `fm-devenv-remote.sh` path and sends one bounded JSON request on standard input.
The remote helper accepts only `inspect`, `claim`, `status`, and `release`.
Every response repeats the request identifier, uses the same protocol schema, and is bounded before parsing.
The script headers in `bin/backends/devenv.sh`, `bin/fm-devenv-remote.sh`, and `bin/fm-devenv-controller.sh` own the exact command and field mechanics.

## Safety boundary

Task text, branch text, and JSON payload bytes never become SSH arguments or remote shell syntax.
The registry supplies the validated SSH host, and the remote command is a client-side constant.
Claims create only a lease marker, and status or release requires the matching 64-character generation token.
Release checks the same token again before deleting the marker.
The control plane does not mutate the checkout, Docker, databases, Herdr sessions, or agent processes.
Unknown, contradictory, or unreadable observations make an environment ineligible, so the controller leaves work queued instead of guessing.
The current control plane cannot prove pipeline, interactive-agent, or unknown-checkout-process absence, which means ordinary automatic claims remain safely unavailable until resident observation is implemented.
A running `firstmate-expanly-<environment>` Herdr session is reported as a session fact only; it cannot prove that no human or agent is working in another session, so agent presence stays unpublished until the resident classifier supplies it.

## Status and diagnostics

Inspect every registered environment:

```sh
bin/fm-devenv-controller.sh inspect
```

Read the durable queue:

```sh
bin/fm-devenv-controller.sh queue
```

Read the combined queue, inspection, lease, and quarantine view:

```sh
bin/fm-devenv-controller.sh status --json
```

Every command failure prints one `fm-devenv-controller:` reason on standard error, including the read-only `queue`, `inspect`, and `status --json`, which distinguishes a busy lock that can be retried from a duplicate task, an out-of-order claim, a corrupt queue, or a fenced task that needs recovery.
Standard output stays machine-readable, so VM start narration during a claim is diagnostic output on standard error.
Claims serialize on their own dispatch lock, so an `enqueue` never waits behind a claim that is booting a stopped VM.
A claim that already holds its remote and Mac lease waits for the queue lock rather than timing out, so lock contention never leaves a live lease behind a task that needs manual recovery.

A runtime mismatch is repaired by rerunning the installer for that feature environment and then rerunning `--verify`.
An unreadable or contradictory inspection is a reason to inspect the VM directly before retrying, not a reason to bypass the controller or select another backend silently.
Selecting `devenv` for a generic task spawn reports that task spawning is not supported yet.

## One-VM verification

The opt-in smoke test requires an explicitly clean feature environment and an already-running dedicated Herdr session that is neither `default` nor the current ambient session.
It snapshots both the dedicated and ambient Herdr sessions, verifies the pinned runtime, inspects the VM, claims one `control-plane-test` lease, performs status through a fresh SSH request with the same token, releases, verifies the marker is absent, and requires both snapshots to remain byte-identical.

```sh
FM_DEVENV_SMOKE_ENV=<clean-feature-environment> \
FM_DEVENV_SMOKE_SESSION=fm-devenv-protocol-lab \
bin/fm-test-run.sh tests/fm-backend-devenv-smoke.test.sh
```

The maintained version-scoped result is in [runtime backend verification](verification/runtime-backends.md#devenv).
