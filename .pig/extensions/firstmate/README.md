# Firstmate PiG extension

This Go extension targets the released PiG v0.4.1 SDK (`github.com/MichaelKinsy/PiG/extensions/sdk` v0.3.1).

## Supported behavior

- Firstmate session-start integration, watcher controls, and turn-end/pre-tool guards.
- The `/calm` preference and Firstmate's animated working-row widget.
- Firstmate-owned tool rendering and skill command handoff.

Build and test from this directory with `go test ./...`.

## PiG v0.4.1 limits

The released SDK exposes display-only Markdown transforms and per-message or per-entry renderers, but no global transcript-presentation API; Calm therefore cannot hide host transcript rows and controls only Firstmate's working-row widget.

The SDK exposes the active host session's `NewSession`, `Fork`, and `SwitchSession` operations and a read-only `SessionManager`, but it does not expose managed `AgentSession` creation for an isolated supervisor conversation.
Its `ToolRenderContext` also has no export flag, so a tool renderer cannot distinguish a transcript being displayed from one being exported.
This extension therefore does not run a separate supervision branch; actionable watcher notifications are delivered to the main conversation.

These limits follow the released SDK surface: [`extension.go`](https://github.com/MichaelKinsy/PiG/blob/v0.4.1/extensions/sdk/extension.go), [`context.go`](https://github.com/MichaelKinsy/PiG/blob/v0.4.1/extensions/sdk/context.go), [`session_manager.go`](https://github.com/MichaelKinsy/PiG/blob/v0.4.1/extensions/sdk/session_manager.go), and [`tool_renderers.go`](https://github.com/MichaelKinsy/PiG/blob/v0.4.1/extensions/sdk/tool_renderers.go). Full Pi parity requires PiG SDK and host support for global transcript presentation, managed agent sessions, and export-aware rendering. Do not substitute a locally modified SDK while claiming compatibility with the released v0.4.1 runtime. The harness reference and runtime-backend verification record own installed-runtime claims.
