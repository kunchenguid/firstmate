# Harness adapter verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active harness launch guarantees.
The `harness-adapters` skill owns current harness facts, and `bin/fm-spawn.sh` owns launch mechanics.
Task chronology, temporary paths, branch names, and delivery transcripts stay in private reports or PR evidence.

## OpenCode worker agent selection

OpenCode worker-agent selection was verified on 2026-07-31 with OpenCode 1.18.9 on the interactive startup path.
The TUI footer rendered the active agent at startup, so the probe spent zero model tokens.

Exact command and output:

```sh
opencode --version
```

```text
1.18.9
```

Exact command and relevant footer output:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode
```

```text
Gentle-Orchestrator · GPT-5.6 Sol OpenAI
```

Exact command and relevant footer output:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --agent build
```

```text
Build · GPT-5.6 Sol OpenAI
```

Exact command and popup plus relevant footer output:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --agent zzz-not-an-agent
```

```text
Agent not found: zzz-not-an-agent
Gentle-Orchestrator · GPT-5.6 Sol OpenAI
```

Exact command and output:

```sh
opencode agent list | python3 -c 'import sys; [print(line, end="") for line in sys.stdin if line.startswith("build ")]'
```

```text
build (primary)
```

The default startup proves that an OpenCode launch without `--agent` inherits the configured `default_agent`.
The explicit build startup proves that `--agent build` selects the built-in worker agent on the interactive launch path.
The unknown-agent startup proves that OpenCode reports the unknown agent in the TUI and then uses the configured default agent without failing the process.
The fallback behavior is the critical residual risk: if a later OpenCode version removes or renames `build`, OpenCode crewmates would again launch as the configured default agent after a TUI error.
Firstmate therefore pins `--agent build` for OpenCode ship and scout launches, while secondmate launches omit it so persistent firstmate homes retain primary-agent semantics.

Applicability was reviewed across all seven supported harnesses.

- Claude is not affected because its launch template does not select OpenCode agents.
- Codex is not affected because its launch template already branches on secondmate state for Codex-specific mechanics.
- OpenCode is affected, and ship plus scout launches now add `--agent build` while secondmate launches omit it.
- Pi is not affected because its launch template selects Pi extensions rather than OpenCode agents.
- pi-signed is not affected because it shares Pi launch semantics under the signed wrapper identity.
- Grok is not affected because its launch template has no OpenCode agent selection surface.
- Kimi is not affected because it launches through its Kimi-specific readiness and pointer-delivery path.

Applicability was reviewed across all five supported runtime backends.

- Tmux is not affected because backend routing receives the already-rendered launch command and does not interpret harness-specific `--agent` flags.
- Herdr is not affected because backend routing receives the already-rendered launch command and does not interpret harness-specific `--agent` flags.
- Zellij is not affected because backend routing receives the already-rendered launch command and does not interpret harness-specific `--agent` flags.
- Orca is not affected because backend routing receives the already-rendered launch command and does not interpret harness-specific `--agent` flags.
- cmux is not affected because backend routing receives the already-rendered launch command and does not interpret harness-specific `--agent` flags.

The regression coverage is `tests/fm-spawn-dispatch-profile.test.sh` for ship, scout, and secondmate launch commands.
