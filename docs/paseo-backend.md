# Paseo runtime backend

Paseo is a companion presentation, interaction, and sub-agent surface across Desktop, Mobile, and Web apps.
Firstmate is the orchestrator, authority, and supervisor, while Paseo provides companion visibility.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Select Paseo when you want companion visibility in the Paseo Desktop, Web, or Mobile app while Firstmate manages task execution.

Prerequisites:

- Paseo CLI and daemon installed and running.
- `jq` for JSON responses.
- `treehouse` for worktree allocation.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Paseo with local `config/backend` containing `paseo`, `FM_BACKEND=paseo` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside a Paseo agent session (`PASEO_AGENT_ID` or `PASEO_AGENT_CWD`).

Verify setup by spawning a task and confirming metadata contains `backend=paseo` and `paseo_agent_id=`.

## Task shape and metadata

Each task spawns a Paseo subagent via `paseo run --background --cwd <wt>`.
The task metadata persisted in `state/<id>.meta` records the Paseo agent ID.

```text
backend=paseo
window=<paseo-agent-id>
paseo_agent_id=<paseo-agent-id>
```

## Operations and lifecycle

Paseo agents are created with treehouse worktrees passed via `--cwd`.
Task capture reads agent activity logs via `paseo logs <id> --tail <n>`.
Prompts are submitted via `paseo send <id> --no-wait <text>`.
Interrupts (`Escape`, `Ctrl-C`) issue `paseo stop <id>`.
Task cleanup (`fm_backend_paseo_kill`) stops and archives the Paseo agent (`paseo stop` then `paseo archive`) so completed tasks leave the active Subagents view while preserving conversation history in Paseo.
Agent busy state maps `running` and `initializing` to `busy`, `idle` to `idle`, and `closed`, `error`, `failed`, `archived`, or `stopped` to `dead`.

## Regression entry points

```sh
tests/fm-backend-paseo.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#paseo) records active adapter and lifecycle evidence.

