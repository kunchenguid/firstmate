# Junie CLI

JetBrains' `junie` CLI, verified end to end on 2026-09-14 with junie 26.9.14 on macOS and Linux.
Launch shape: `junie -p <worktree> --brave --prompt "<encoded-brief>" --config-location state/<id>.junie-config.json [--model <model>] [--effort <low|medium|high>]`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no junie wake protocol.
`../../../../../docs/verification/junie.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `junie` resolved from `PATH`, verified on version 26.9.14. |
| Role | Worker harness for crewmate and scout tasks only (no secondmate/primary supervision protocol). |
| Worktree | `-p, --project=<worktree>` isolates execution to the task worktree. |
| Autonomy | `--brave` enables autonomous execution without interactive tool-approval prompts. |
| Brief submission | `--prompt "<encoded-brief>"` passes the brief to start the task with the initial prompt submitted. |
| Model | `--model <model>` maps directly to the primary agent model. |
| Effort | `--effort <low|medium|high>` maps standard effort levels. |
| Configuration & Hooks | `--config-location <path>` supplies a task-bound configuration file (`state/<id>.junie-config.json`). `UserPromptSubmit` hook runs a command touching `state/<id>.progress`; `Stop` hook runs a command touching `state/<id>.turn-ended`. |
| Authentication | Native OS Keychain (`junie-cli`), fallback `~/.junie/secure_credentials.json`, or `JUNIE_API_KEY`. |
| Exit | `/exit` or `/quit`, exit status 0. |
| Interrupt | Single `Escape` cancels active execution and returns to prompt. |
| Detection | Process ancestry detection on process command name `junie` (`comm=junie`). |

## Worktree isolation and autonomy

Worktree isolation is enforced through `-p, --project=<worktree>`, which confines file operations, tool calls, and local project context to the task worktree rather than the repository root or primary checkout.
Unattended autonomy is enabled via `--brave`, which turns on Brave Mode without interactive tool-approval prompts so crewmate and scout tasks proceed without blocking on user confirmations.
Task brief submission uses `--prompt "<encoded-brief>"`, which launches interactive mode with the initial prompt pre-submitted, avoiding separate typing into the composer.

## Model and reasoning effort

Model selection uses `--model <model>`, passing catalog identifiers directly to the Junie CLI runtime.
Reasoning effort uses `--effort <low|medium|high>`, mapping Firstmate's standard effort levels (`low`, `medium`, `high`) directly into the CLI's supported effort values.
Extended effort values such as `xhigh` and `max` follow `references/common/model-and-effort.md`'s record-and-omit contract.

## Configuration and lifecycle hooks

Task-bound configuration is passed via `--config-location <path>`, pointing to a Firstmate-owned configuration file at `state/<id>.junie-config.json`.
Passing `--config-location` keeps the task configuration completely isolated within `state/` so nothing is written into the project's tracked files or `.junie/` directory, preventing configuration leaks and uncommitted changes in the worktree.
Two lifecycle hooks are defined in this configuration:
- `UserPromptSubmit`: fires when a prompt turn begins, running a shell command that touches `state/<id>.progress` to register observed native-harness activity for busy-state tracking.
- `Stop`: fires when agent processing completes, running a shell command that touches `state/<id>.turn-ended` to notify Firstmate's watcher that the turn has ended.
Teardown (`bin/fm-teardown.sh`) removes `state/<id>.junie-config.json`, ensuring no task-specific hook configuration survives into a pooled worktree.

## Credential precondition

Junie supports three credential resolution paths, evaluated in order:
1. Native OS Keychain: Junie queries the operating system keychain under the service name `junie-cli`.
2. Stored credential fallback: when the keychain is unavailable (such as headless CI or container environments), Junie falls back to `~/.junie/secure_credentials.json`.
3. Environment variable: `JUNIE_API_KEY` can be set in the ambient environment prior to session start, providing headless API authentication without keychain or file storage.

An unauthenticated launch blocks on an interactive sign-in dialog or exits with an authentication error.
Under `AGENTS.md` section 9, missing credentials must be treated as a credential blocker: configure keychain access or export `JUNIE_API_KEY` before launching, and retire a wedged unauthenticated pane rather than typing credentials into it.

## Process detection and control

`bin/fm-harness.sh` detects a running Junie process by ancestry walk on the process command name `junie` (`comm=junie`).
Because `junie` is an independent CLI executable, command name matching identifies the process cleanly without depending on launcher environment markers.
Process control operations follow standard Firstmate conventions:
- Exit: `/exit` or `/quit` exits the interactive session cleanly with exit code 0.
- Interrupt: A single `Escape` keypress cancels the in-flight operation or tool execution, leaving the process running and returning the prompt to an idle ready state.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no junie protocol, no turn-end guard adapter exists for it, and this adapter verified only crewmate and scout tasks.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar CLI, and never attempt to dispatch a primary or secondmate on Junie.
