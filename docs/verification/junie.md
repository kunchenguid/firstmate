# Verification: the junie (Junie CLI) crewmate/scout adapter

Active empirical evidence for firstmate's junie adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/junie.md`](../../.agents/skills/harness-adapters/references/harness/junie.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Junie version: 26.9.14 (3196.4)` |
| Verified | 2026-09-14 |
| Binary | `~/.local/bin/junie` (system-wide `junie` CLI executable) |
| Platform | macOS arm64 (Darwin 25.6.0) / Linux x64 |
| Role | Worker harness for crewmate and scout tasks only |

Every command below was verified inside an isolated task worktree or temporary test environment.
No captain fleet state or tracked repository files were modified.

## Detection: process ancestry

```
$ junie --version
Junie version: 26.9.14 (3196.4)
```

A live Junie CLI process reports its command name as `junie`:
- `ps -o comm= -p <pid>` returns `junie`.
- `bin/fm-harness.sh` matches the anchored process name `junie` (`comm=junie`).
- Foreign launcher markers (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`) are cleared at the launch boundary by `bin/fm-spawn.sh`.
- Process ancestry on `junie` reliably identifies the running harness regardless of inherited environment state.

## Worktree isolation and launch shape

Junie is launched with:

```bash
junie -p <worktree> --brave --prompt "<encoded-brief>" --config-location state/<id>.junie-config.json [--model <model>] [--effort <low|medium|high>]
```

1. **Worktree isolation**:
   - Passed via `-p, --project=<worktree>` (or `--project <worktree>`).
   - Verified that Junie roots its session and file tool operations strictly inside the specified `<worktree>` path.
   - Files created, edited, and read by the agent remain confined to the worktree, keeping the primary repository checkout completely clean.
2. **Prompt submission**:
   - Passed via `--prompt "<encoded-brief>"`.
   - Verified that `--prompt` launches interactive mode with the initial task brief already submitted.
   - The agent begins turn processing immediately upon launch without requiring separate typing or keystroke submission into the terminal composer.
3. **Autonomy (Brave mode)**:
   - Passed via `--brave`.
   - Verified that `--brave` sets Brave Mode (`braveMode: ON`), allowing tool execution, file edits, and terminal commands to run autonomously without interactive confirmation prompts.
   - Unattended crewmate and scout tasks execute without stalling on tool authorization dialogs.

## Model selection and reasoning effort

1. **Model flag**:
   - Passed via `--model <model>`.
   - Verified that `--model` passes catalog model identifiers (such as `gemini-3.8-flash`, `claude-opus-5`) directly to the primary agent.
2. **Effort flag**:
   - Passed via `--effort <low|medium|high>`.
   - Verified that the standard effort levels (`low`, `medium`, `high`) map directly into Junie's supported reasoning effort options without rejection or syntax errors.
   - Higher levels (`xhigh`, `max`) follow Firstmate's record-and-omit or clamp contract under `references/common/model-and-effort.md`.

## Configuration and lifecycle hooks

Task-bound configuration is passed using `--config-location <path>` pointing to `state/<id>.junie-config.json`.

1. **Project isolation**:
   - Verified that passing `--config-location` keeps configuration strictly within `state/`.
   - Nothing is written to the project's own `.junie/` directory, preventing configuration leakage and uncommitted git modifications in task worktrees.
2. **UserPromptSubmit hook**:
   - Configured in `state/<id>.junie-config.json` to run a shell command touching `state/<id>.progress`.
   - Verified that upon prompt submission and at the start of turn processing, the `UserPromptSubmit` hook fires and touches `state/<id>.progress`.
   - Provides native in-turn activity signaling for Firstmate's busy tracker (`bin/fm-busy-event.sh` and `bin/fm-watch.sh`).
3. **Stop hook**:
   - Configured in `state/<id>.junie-config.json` to run a shell command touching `state/<id>.turn-ended`.
   - Verified that when agent response generation completes and the turn finishes, the `Stop` hook fires and touches `state/<id>.turn-ended`.
   - Emits the turn-end notification event that wakes Firstmate's watcher.
4. **Teardown**:
   - Verified that `bin/fm-teardown.sh` removes `state/<id>.junie-config.json` during task cleanup, leaving no lingering state in pooled worktrees.

## Authentication methods

Junie supports three empirical authentication mechanisms, evaluated in order:

1. **Native OS Keychain**:
   - On macOS, Junie queries the OS Keychain under service name `junie-cli`.
   - When credentials exist in the keychain, authentication succeeds automatically without file reads or environment variables.
2. **Local filesystem fallback**:
   - When keychain access is unavailable (e.g. headless servers or Docker containers), Junie falls back to reading credentials from `~/.junie/secure_credentials.json`.
3. **Environment variable**:
   - Setting `JUNIE_API_KEY` in the environment provides direct token-based API authentication, bypassing both keychain prompts and local files.
4. **Unauthenticated behavior**:
   - An unauthenticated launch without available credentials prompts interactively or fails with an authentication error.
   - Under `AGENTS.md` section 9, missing credentials must be treated as a credential blocker: credentials must be pre-configured prior to launch, and an unauthenticated wedged pane must be retired rather than typed into.

## Process control and signals

1. **Interrupt**:
   - A single `Escape` keypress sent during active tool execution or response generation cancels in-flight operations.
   - The agent returns cleanly to the idle composer prompt without terminating the process or repolluting the input buffer.
2. **Exit**:
   - Submitting `/exit` or `/quit` cleanly terminates the Junie process with exit code 0.
   - The terminal pane closes cleanly under standard session management.

## What is still unproven

- No primary or secondmate supervision protocol is implemented or verified for Junie (`docs/supervision-protocols/` carries no junie protocol). Junie is verified strictly as a crewmate and scout worker.
- Session resumption via `--resume` or `--session-id` within Firstmate's pane lifecycle is unproven; recovery relies on Firstmate's deterministic relaunch and brief re-execution.
- Subagent orchestration within Junie is not integrated into Firstmate workflows; tasks operate as direct single-agent workers.
