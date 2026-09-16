# DeepSeek Harness

Verified on 2026-09-16 with DeepSeek Harness 0.1.5-rc.1 (dsh-base 0.1.5-rc.2).

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Not applicable to the primary: DSH drives its own turn lifecycle, and the captain reads crewmate state from that crewmate's harness. No crewmate adapter exists yet, so nothing is armed as busy wiring. |
| Exit command | None verified: the session is a long-lived host process (`node .../.bin/dsh web`) closed from the DSH client, not by a typed slash command. |
| Interrupt | The client's own stop control; no verified key sequence, because there is no terminal to send keys to. |
| Skill invocation | Skills reach the model through the session skill catalog (`dsh-skill-filesystem` scans `.agents/skills` natively), loaded by the model rather than typed as a slash prefix. |
| Model flag | None on the command line. The session model comes from the `agent-default-model` settings section (`$DSH_HOME/settings.yaml`), overridden per session through the model picker. |
| Effort flag | None on the command line. `reasoningEffort` in the same settings section carries the effort axis. |
| Model discovery | The model picker, backed by the `llm-pi-ai` route catalog when that adapter is mounted. |
| Marker | None. DSH is a node process (`ps` reports `comm=node`) whose launcher name is visible only in argv, and it hands tool and hook subprocesses no identity variable. `FM_DSH_HARNESS=dsh` is a Firstmate-OWNED launch marker and a PRECEDENCE override, honored only when a genuine dsh process is in the ancestry. Because the ancestry verdict is `args` strength, an inherited `CLAUDECODE` outranks it, so the launch marker is load-bearing rather than a fast path. |

## Sandbox requirement

Firstmate's supervision health model is built on process inspection: `bin/fm-harness.sh` ancestry, the PID-strict watcher lock in `bin/fm-wake-lib.sh`, and `fm_afk_daemon_owns_supervision`.
DSH denies `ps` under its default `workspace-write` sandbox (`/bin/ps: Operation not permitted`), which silently degrades every one of those predicates.
The captain profile therefore selects the shipped `danger-full-access` permission preset, which bundles that sandbox mode with its approval policy.
Overriding `sandbox-policy.mode` alone is NOT equivalent: the composed sandbox and approval defaults then match no preset, and `dsh-permission-presets` refuses the profile at load with "configure defaultPreset explicitly".

## Instruction budget

`dsh-agent-instructions` bounds the injected chain with `maxBytes`, which `dsh-base` ships as 65536.
Firstmate's `AGENTS.md` is 81127 bytes, so the default silently drops sections 10 through 14 (Backlog contract, Crewmate briefs, Self-update, Agent-only reference skills, Relay) plus the captain-precedence and maintenance sections.
The captain profile raises `maxBytes` to 262144.

## Primary integration

`dsh-hooks-claude-code` runs firstmate's hook scripts unchanged, because DeepSeek Harness implements the Claude Code command-hook dialect. The registration lives in `dsh/hooks.json`, mounted by `dsh/profile.patch.yml`, and three facts about DSH change what that file may contain:

- **`UserPromptSubmit`, not `SessionStart`.** DSH's `SessionStart` hook runs detached and its `additionalContext` lands AFTER the first request as a user-shaped message (verified 2026-09-16), which is the wrong tier for a session-start digest. `UserPromptSubmit` fires before the model call and its `additionalContext` is part of that request, so `bin/fm-dsh-sessionstart.sh` rides it and gates delivery once per session id.
- **Lowercase `bash` matchers.** DSH's matcher subject is the harness tool name, and its shell tool is `bash`; Claude's `Bash` never matches. The catch-all `.*` group is unaffected.
- **No `asyncRewake`.** DSH parses command hooks only and runs them synchronously with the configured timeout, so firstmate's Stop-owned auto-arm has no equivalent. `bin/fm-turnend-guard-dsh.sh` calls the shared guard with `--dsh`, which owns a session-scoped block budget instead of trusting `stop_hook_active`, and watcher continuity rides a background job per `docs/supervision-protocols/dsh.md`.

**PreToolUse works, but the bridge version must match the runtime.** The sub-packages' npm `latest` dist-tag is stale (`0.0.1-rc.5` against a `0.1.5-rc.2` runtime), and that old bridge reads `session.events` synchronously - a read DSH deprecated after rc.5. Under the mismatch the bridge's `lastTurn()` throws before any hook is matched and EVERY tool call fails with `Error: agent.session.events is not iterable`, so the guards are both inert and tool-breaking. Install the matching build explicitly:

```sh
dsh plugin --profile <name> add @deepseek-ai/dsh-hooks-claude-code@0.1.5-rc.2
```

With the matched build, `UserPromptSubmit`, the `bash`-matcher PreToolUse rows, and the `.*` row all fire (verified 2026-09-16).

`--claude` is passed to the PreToolUse guards deliberately: it selects the deny-output dialect, not Claude-specific behavior, and DSH honours that dialect.
