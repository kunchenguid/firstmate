# Calm-mode harness feasibility

This document owns the version-scoped feasibility evidence for implementing Firstmate calm mode in each verified harness.
The README owns the user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, keep the toggle session-local, redraw already-rendered built-in tool rows, restore the harness's ordinary rendering, and leave tool execution, model context, session storage, exports, diagnostics, and expansion state unchanged.
Replacing a built-in tool, patching harness internals, filtering persisted events, or claiming coverage outside a supported renderer does not satisfy that boundary.

## Verification record

The following inspection was performed on 2026-07-22.

```text
$ claude --version
2.1.216 (Claude Code)
$ codex --version
codex-cli 0.144.6
$ opencode --version
1.17.18
$ pi --version
0.80.10
$ grok --version
grok 0.2.106 (bde89716f679)
```

The inspected commands were `claude --help`, `claude plugin --help`, `claude plugin validate --help`, `codex --help`, `codex plugin --help`, `codex features list`, `opencode --help`, `opencode debug --help`, `opencode debug config`, `pi --help`, `grok --help`, and `grok plugin --help`.
The inspection also covered the tracked project hook and plugin definitions for all five harnesses and Pi 0.80.10's installed public TypeScript declarations.

| Harness | Conclusion | Evidence |
| --- | --- | --- |
| Claude Code 2.1.216 | Not feasible through the inspected supported project surface. | Project hooks can observe lifecycle and tool events, while the plugin CLI packages supported components; neither inspected surface exposes a transcript-row renderer or a transcript-wide redraw API. |
| Codex CLI 0.144.6 | Not feasible through the inspected supported project surface. | The tracked hooks expose session, pre-tool, and stop handling, while the plugin and feature inventories expose no TUI tool-row renderer or transcript redraw control. |
| OpenCode 1.17.18 | Not feasible without violating the preservation boundary. | Plugins expose events and tool execution hooks, not a built-in transcript-row renderer. A same-name custom tool can replace a built-in tool, but that changes the tool definition and execution path rather than presentation alone. |
| Pi 0.80.10 | Feasible and implemented. | Public declarations expose `registerTool`, `ToolDefinition.renderCall`, `ToolDefinition.renderResult`, `renderShell`, `setToolsExpanded`, terminal input handling, and extension commands. The focused renderer test and interactive terminal E2E exercise the supported path. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract. `--minimal` changes the session's overall screen mode and does not provide selective, reversible transcript-row control. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the required renderer API.

## Pi verification

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock Pi renderers, verifies all seven built-ins, exercises already-rendered rows, checks the disclosed image and custom-tool boundaries, covers session reset reasons, proves exports remain ordinary, and drives a genuine interactive terminal session.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the installed Pi 0.80.10 declarations.

The relevant commands are:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
```
