# fm-state-reader

This library reads public operational records and bridges immutable events to the existing process-event owner.
Follow the [module template](../TEMPLATE.md); current allow-list, API, limits, and verification belong in [docs/README.md](docs/README.md).

- Keep record parsing pure in `src/core`; `src/usecases` receives `StateFiles` plus an explicit observation time, and returns plain data.
- File adapters may not read agent-private sessions or write task state; preserve bounded reads, symlink refusals, explicit unknown/truncated evidence, and generation matching.
- Pool paths are explicitly supplied, never inferred as permission from arbitrary task metadata.
- Publish through the registered process-event contract, never by appending to the wake queue; delivery is not acknowledgement or permission for lifecycle actions.
- The shared crew-talk feature owns message wire formats; this library must not invent a module-private inbox schema.
- Keep tests/fakes colocated; run `bin/fm-test-run.sh tests/fm-modules.test.sh` from the repository root, or `npm test` in this package with the Firstmate tool root available.
- Service telemetry, personas, and decision policy belong to consuming applications, not this reader.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
