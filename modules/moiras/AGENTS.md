# Moiras

Follow the [module pattern](../TEMPLATE.md); [README.md](README.md) owns current usage, configuration, ports and limits.

- Keep rules and scene composition pure, orchestration in `src/usecases`, and effects in `src/adapters`.
- Never perform task actions; missing, truncated or stale evidence cannot grant permission.
- Use the shared message contract and its real admission owner, never an invented inbox or borrowed task/supervisor identity.
- Preserve immutable evidence ids, capture-before-marker recovery and uncertain-reply refusal; delivery is not acknowledgement or exactly-once execution.
- Keep the approved silhouettes and mostly static motion; render from elapsed time, honor clean/NO_COLOR, and restore terminal state on every exit.
- Run `bin/fm-test-run.sh tests/fm-moiras.test.sh tests/fm-modules.test.sh` from the root; module tests/fakes are colocated here.
- No model call is permitted merely because a persona or provider appears in config; preserve the explicit reasoning gate.
- Keep telemetry secret-free and inside this module's private state; the telemetry sink must not recursively log itself.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
