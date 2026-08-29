# Verification: the agy (Google Antigravity CLI) crewmate adapter

Active empirical evidence for firstmate's agy adapter.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established.

## Subject

| Field | Value |
|---|---|
| Version | `Antigravity CLI 1.1.22` |
| Verified | 2026-08-29 |
| Binary | `/home/blake/.local/bin/agy` |
| Platform | Linux x86_64 (Linux 6.8.0-60-generic) |

The binary is an ELF 64-bit LSB executable compiled with Go:

```
$ which agy
/home/blake/.local/bin/agy

$ file /home/blake/.local/bin/agy
/home/blake/.local/bin/agy: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=..., for GNU/Linux 3.2.0, not stripped
```

## Verified facts

### Process identity and child markers

`agy` sets child process environment markers on tool and hook processes:

```
ANTIGRAVITY_AGENT=1
ANTIGRAVITY_LS_VERSION=cli-1.1.22
ANTIGRAVITY_SOURCE_METADATA=...
ANTIGRAVITY_CONVERSATION_ID=...
ANTIGRAVITY_AGENTAPI_EXE=...
```

`bin/fm-harness.sh` detects `agy` from those environment markers with precedence before process ancestry walk (`ps -o comm=` reporting `agy`).
Launch sanitization in `bin/fm-spawn.sh` unsets `ANTIGRAVITY_AGENT`, `ANTIGRAVITY_LS_VERSION`, and `ANTIGRAVITY_SOURCE_METADATA` when launching non-agy adapters to prevent marker pollution.

### Model discovery and effort rules

`agy models` lists available models and marks the default model (`gemini-3.7-flash-high`):

```
$ agy models
Available models:
  - gemini-3.7-flash-high (default)
  - gemini-3.7-flash-thinking
  - gemini-3.7-flash
  - gemini-3.1-pro-high
  - claude-sonnet-4-6
  - claude-opus-4-6-thinking
  - gpt-oss-120b-medium
```

`--effort low|medium|high` is valid only for Gemini models.
When tested with non-Gemini models, `agy` rejects `--effort`:

```
$ agy --model claude-opus-4-6-thinking --effort high -p "test"
Error: invalid model selection (--model "claude-opus-4-6-thinking" --effort "high"): --effort is not supported for model "claude-opus-4-6-thinking"
```

When a model already specifies an effort suffix (e.g. `gemini-3.7-flash-high`), passing a conflicting or redundant `--effort` causes:

```
$ agy --model gemini-3.7-flash-high --effort low -p "test"
Error: invalid model selection (--model "gemini-3.7-flash-high" --effort "low"): --model gemini-3.7-flash-high conflicts with --effort=low
```

For base Gemini models without effort suffix (e.g. `gemini-3.7-flash`), `--effort low` succeeds.
Therefore `effort_flag_for_harness` emits `--effort <level>` only for base `gemini-*` models and omits it for non-Gemini models or models with embedded effort suffixes.
Unsupported effort levels `xhigh` and `max` are capped to `high`.

### Launch template and prompt attachment

The prompt flag must be attached with `=`: `--prompt-interactive="$(...)"`.
A detached argument after other flags is misparsed by the CLI argument parser.

Raw verified launch template:

```sh
env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--prompt-interactive="$(__OPINPUT__ encode launch-brief < __BRIEF__)"
```

### Folder trust dialog

On first launch in a fresh workspace, `agy` renders an interactive folder trust prompt:

```
Accessing workspace:
/path/to/workspace

Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit

  ↑/↓ Navigate · enter Confirm
```

Option 1 (`Yes, I trust this folder`) is preselected; sending `Enter` confirms trust.
Trusted workspace paths are recorded in `~/.gemini/antigravity-cli/settings.json` under `trustedWorkspaces`.

### Hooks and busy state lifecycle

`agy` loads workspace-level hooks from `<workspace>/.agents/hooks.json`.
The hooks configuration supports `PreInvocation` and `Stop` events.
`PreInvocation` receives metadata including `conversationId`, `modelName`, `invocationNum`, `workspacePaths` and returns `{}`.
`Stop` receives metadata including `fullyIdle`, `terminationReason`, `error` and returns `{"decision":"allow"}`.

Firstmate configures `.agents/hooks.json` during task spawn:
- `PreInvocation` calls `fm-busy-event.sh apply <state> <id> busy --gen <gen> --source agy-hook --event pre-invocation`.
- `Stop` calls `touch <turnend>` and `fm-busy-event.sh apply <state> <id> idle --gen <gen> --source agy-hook --event stop`.

Observed hook payload on `PreInvocation`:

```json
{
  "artifactDirectoryPath": "/home/blake/.gemini/antigravity-cli/brain/0e9efa38-ce7f-4924-8800-2eab5276508e",
  "conversationId": "0e9efa38-ce7f-4924-8800-2eab5276508e",
  "initialNumSteps": 1,
  "invocationNum": 0,
  "modelName": "gemini-3.7-flash-high",
  "transcriptPath": "/home/blake/.gemini/antigravity-cli/brain/0e9efa38-ce7f-4924-8800-2eab5276508e/.system_generated/logs/transcript_full.jsonl",
  "workspacePaths": ["/home/blake/.gemini/antigravity-cli/scratch/test_tmux_agy"]
}
```

Observed hook payload on `Stop`:

```json
{
  "artifactDirectoryPath": "/home/blake/.gemini/antigravity-cli/brain/0e9efa38-ce7f-4924-8800-2eab5276508e",
  "conversationId": "0e9efa38-ce7f-4924-8800-2eab5276508e",
  "error": "",
  "executionNum": 0,
  "fullyIdle": true,
  "modelName": "gemini-3.7-flash-high",
  "terminationReason": "NO_TOOL_CALL",
  "transcriptPath": "/home/blake/.gemini/antigravity-cli/brain/0e9efa38-ce7f-4924-8800-2eab5276508e/.system_generated/logs/transcript_full.jsonl",
  "workspacePaths": ["/home/blake/.gemini/antigravity-cli/scratch/test_tmux_agy"]
}
```

### Interrupt and exit

- `Escape` or `Ctrl+C` immediately cancels an in-flight turn, prints `⎿ Interrupted · What should Antigravity CLI do instead?`, and returns to a clean composer prompt.
- Firstmate uses `C-c` for interrupt delivery so it works uniformly across all backends (tmux, herdr, zellij, cmux, and orca).
- `/exit` typed into the composer exits the process cleanly with return code 0.

### Composer rendering and delivery busy regex

When idle, the composer is bounded by horizontal rules (`────`) with prompt glyph `>` (or `❯` in UTF-8), and the footer displays `? for shortcuts`.
While a turn is running, the footer displays `esc to cancel`.
Firstmate registers `FM_DELIVERY_AGY_BUSY_REGEX_DEFAULT='esc to cancel'` in `bin/fm-composer-lib.sh`.

### Secondmate refusal

`agy` is verified for crewmate and scout launches only.
It provides no primary supervision protocol or daemon management required for secondmate instances.
`fm-spawn.sh` and `fm-control-lib.sh` explicitly refuse `--secondmate` for `agy`.

## Empirical proof: real write-tool turn in throwaway workspace

A spawn-shaped run was executed in throwaway git repo `/home/blake/.gemini/antigravity-cli/scratch/agy_verify_lab`.
The agent created `hello_local.txt` using its file write tool, fired both `PreInvocation` and `Stop` hooks, and touched `state/turn-ended`.

Captured pane output from the verified session:

```
  ### Execution Output

    Hello, Antigravity!

  │ Tip
  │ You can set /home/blake/.gemini/antigravity-cli/scratch as your active
  │ workspace if you'd like to work in this folder.

────────────────────────────────────────────────────────────
> Create a file named
  /home/blake/.gemini/antigravity-cli/scratch/agy_verify_lab/hello_local.txt
  with content 'local proof'

● Edit(~/.gemini/antigravity-cl...rify_lab/hello_local.txt) (ctrl+o to expand)

  I have created hello_local.txt with the content:

    local proof

────────────────────────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────────────────────────
? for shortcuts                                          Gemini 3.7 Flash · high
```

Observed state directory contents after turn completion:

```
$ ls -la /home/blake/.gemini/antigravity-cli/scratch/agy_verify_lab/state
total 8
drwxrwxr-x 2 blake blake 4096 Aug 29 18:03 .
drwxrwxr-x 5 blake blake 4096 Aug 29 18:03 ..
-rw-rw-r-- 1 blake blake    0 Aug 29 18:03 turn-ended
-rw-rw-r-- 1 blake blake    0 Aug 29 18:03 turn-started

$ cat /home/blake/.gemini/antigravity-cli/scratch/agy_verify_lab/hello_local.txt
local proof
```
