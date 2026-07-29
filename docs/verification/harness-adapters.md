# Harness adapter verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active harness launch guarantees.
The `harness-adapters` skill owns current harness facts, and `bin/fm-spawn.sh` owns launch mechanics.
Task chronology, temporary paths, branch names, and delivery transcripts stay in private reports or PR evidence.

## OpenCode worker agent selection

OpenCode worker-agent selection was verified on 2026-07-29 with OpenCode 1.18.9 on the same interactive `--prompt` path that Firstmate launches.
The probe used a scratch git repository, a throwaway tmux session, and the same injected `OPENCODE_CONFIG_CONTENT` prefix used by `bin/fm-spawn.sh`.
The TUI footer rendered the active agent at startup, so the probe spent zero model tokens.
The footer was rechecked after 25 seconds and 40 seconds.

Command shapes:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt '<throwaway prompt>'
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --agent build --prompt '<throwaway prompt>'
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --agent zzz-not-an-agent --prompt '<throwaway prompt>'
opencode agent list
```

Observed output:

```text
no --agent footer: Gentle-Orchestrator · GPT-5.6 Sol
--agent build footer: Build · GPT-5.6 Sol
--agent zzz-not-an-agent footer: Gentle-Orchestrator
opencode agent list includes: build (primary)
```

The first row proves that an OpenCode launch without `--agent` inherits the configured `default_agent`.
The second row proves that `--agent build` selects the built-in worker agent on the interactive launch path.
The third row proves that an unknown `--agent` value silently falls back to `default_agent` instead of failing or warning.
The fallback behavior is the critical residual risk: if a later OpenCode version removes or renames `build`, OpenCode crewmates would again launch as the configured default agent with no CLI signal.
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

The regression coverage is `tests/fm-spawn-dispatch-profile.test.sh` for ship, scout, and secondmate launch commands, plus `tests/fm-kimi-harness.test.sh` for the byte-pinned adapter launch template inventory.
