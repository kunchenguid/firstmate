# fm-tui-core

This is a dependency-free terminal library, not a service or an application theme.
Follow the [module template](../TEMPLATE.md); current API, limits, and verification belong in [docs/README.md](docs/README.md).

- Keep cell operations pure in `src/core` and display orchestration in `src/usecases`; real stream I/O implements `src/ports/terminal.d.ts` at the adapter edge.
- Preserve last-column reservation, six-color output, external-text sanitization, no whole-screen clears, and idempotent terminal restoration.
- Reused mutable buffers must still produce correct diffs; clean/no-ui displays write once without escapes or hidden timers.
- Keep reusable rendering separate from application sprites, rules, and message formats.
- Put tests and in-memory terminal fakes here; run `bin/fm-test-run.sh tests/fm-modules.test.sh` from the repository root, or `npm test` in this package.
- Do not add a model, persona, state store, logger, or dependency to this library for a future application.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
