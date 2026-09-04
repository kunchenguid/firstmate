# Verification: the Antigravity (agy) crewmate adapter

Active empirical evidence for firstmate's Antigravity (`agy`) adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Antigravity CLI 1.1.23` |
| Verified | 2026-09-01 |
| Binary | `/home/ashwin/.local/bin/agy` |
| Platform | Linux x86_64 (Linux 6.6.137) |

## Empirical evidence

### Process identity and environment

`agy` sets `ANTIGRAVITY_AGENT=1` in the environment of its child and tool processes.
Process comm is `agy`:

```
$ env | grep ANTIGRAVITY
ANTIGRAVITY_AGENT=1

$ ps -o comm= -p $$
agy
```

`bin/fm-harness.sh` detects `agy` from `ANTIGRAVITY_AGENT=1` in Layer 1 and process comm `agy` in Layer 2.
Foreign markers (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`) are cleared before launch in `bin/fm-spawn.sh`.

### Model catalog and defaults

`agy models` lists verified models and supported reasoning levels:

```
$ agy models
Model                                 ID                             Description
-----------------------------------------------------------------------------------------------------------------------------
Gemini 3.7 Flash                      gemini-3.7-flash               Fast, lightweight multimodal model for everyday tasks
Gemini 3.7 Flash (High Reasoning)     gemini-3.7-flash-high          Flash with maximum reasoning depth for complex problem-solving
Gemini 3.7 Flash (Medium Reasoning)   gemini-3.7-flash-medium        Flash with balanced reasoning for general coding tasks
Gemini 3.7 Flash (Low Reasoning)      gemini-3.7-flash-low           Flash with minimal reasoning for speed-critical tasks
Gemini 3.6 Flash                      gemini-3.6-flash               Previous generation Flash model
Gemini 3.1 Pro                        gemini-3.1-pro                 High capability model for complex coding tasks
Claude Sonnet 4.6                     claude-sonnet-4-6              Anthropic Claude Sonnet model
Claude Opus 4.6 Thinking              claude-opus-4-6-thinking       Anthropic Claude Opus with extended thinking
GPT-OSS 120B                          gpt-oss-120b-medium            Open-weights 120B parameter model
```

By default, Firstmate pins `agy` spawns economically to `gemini-3.7-flash` with `--effort medium`.
Explicit `--model` and `--effort` flags override this pin.

### Autonomy and trust

`agy --dangerously-skip-permissions` runs tool executions autonomously without prompting for approvals.
It also bypasses the workspace trust prompt on fresh worktree paths.
Interactive sessions receive the launch brief via `--prompt-interactive "$(__OPINPUT__ encode launch-brief < __BRIEF__)"`.

### Composer and delivery

The composer renders between horizontal solid rules:

```
────────────────────────────────────────────────────────
> <input>
────────────────────────────────────────────────────────
? for shortcuts          Gemini 3.7 Flash · medium
```

Delivery-busy state displays:
```
Generating...
esc to cancel
```

This is matched by `FM_DELIVERY_AGY_BUSY_REGEX_DEFAULT='Generating\.\.\.|esc to cancel'`.

### Global plugin hooks and semantic busy state

`agy` supports a global plugin hook engine under `$HOME/.gemini/config/plugins/<name>/`.
Firstmate installs a dedicated plugin at `$HOME/.gemini/config/plugins/firstmate/`:
- `plugin.json`: `{"name": "firstmate"}`
- `hooks.json`: defines `PreInvocation` and `Stop` command hooks calling `fm-turn-end.sh`.
- `fm-turn-end.d/`: private token registry authenticated per task.

Both hooks were verified live:
1. `PreInvocation` fires before model generation begins, receiving:
   `{"artifactDirectoryPath": "...", "conversationId": "...", "initialNumSteps": 1, "invocationNum": 0, "modelName": "gemini-3.7-flash-high", "transcriptPath": "...", "workspacePaths": [...]}`
   It applies `busy agy-hook` via `fm-busy-event.sh`.
2. `Stop` fires when execution finishes, receiving:
   `{"error": "", "executionNum": 0, "fullyIdle": true, "modelName": "gemini-3.7-flash-high", "terminationReason": "NO_TOOL_CALL", "transcriptPath": "...", "workspacePaths": [...]}`
   When `fullyIdle` is `true`, it touches `state/<id>.turn-ended` and applies `idle agy-hook`.
   When `fullyIdle` is `false`, it does not touch `turn-ended` and keeps the task state busy.

Both hooks always output valid JSON `{}` on stdout and exit zero.

### Lifecycle, mid-turn exit, and session resumption

During live operation, an `agy` session exited to a bare shell mid-turn (e.g. following an unhandled termination during long-running background command execution).
The session was resumed in the pane using:

```
$ agy --conversation=<conversation-id>
```

Empirical verification established:
1. `agy --conversation=<id>` restores the exact conversation history, memory context, and transcript record.
2. The agent continues seamlessly from the point of interruption without losing prior work.
3. For cross-harness fleet management, Firstmate supports both `agy --conversation=<id>` continuation and standard deterministic relaunch (`fm-control.sh relaunch`).

