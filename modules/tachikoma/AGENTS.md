# Tachikoma

Follow the [module template](../TEMPLATE.md); current commands, configuration, ports, and evidence limits belong in [README.md](README.md).

- Keep domain decisions pure in `src/core`, orchestrations in `src/usecases`, and real I/O in `src/adapters`.
- Import shared functionality only through the `fm-state-reader` and `fm-tui-core` package entries; never import another application.
- Reuse catalog, dispatch, cooldown, telemetry, and locking owners; do not infer subscription/credential relations from model names or clear gates from a timer.
- Routing requires reviewed source hashes and explicit bindings; learning changes derived evidence, never approved policy or activation.
- Preserve append-before-return, the transaction around unmeasured-pool caps, exact decision joins, and null for unobserved measurements.
- Keep prompt text, account descriptions, raw provider errors, and credentials out of records; do not weaken bounded reads or unsafe-file refusals.
- The shared message contract owns service envelopes; no private inbox protocol or automatic service/model startup.
- Test core functions with plain data, use cases with the declared in-memory fakes, and adapters through their executable boundary.
- Run `bin/fm-test-run.sh tests/fm-tachikoma.test.sh` from the repository root; the package test command also requires the existing Firstmate owner scripts.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
