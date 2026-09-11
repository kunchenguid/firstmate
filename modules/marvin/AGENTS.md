# Marvin module

The [README](README.md) owns current behavior, configuration, and commands.
The [module template](../TEMPLATE.md) owns shared layout conventions.
Keep pace and classification pure in `src/core/quota.mjs`; `src/usecases/observe.mjs` receives the source, clock, renderer, and telemetry ports declared in `src/ports/io.d.ts`.
Adapters own bounded quota-axi invocation, terminal rendering, configuration validation, and daily JSONL I/O.
Never read provider credentials directly or copy raw provider snapshots into telemetry.
Keep unknown identity and cycle evidence unknown rather than inventing values.
Use `bin/fm-test-run.sh tests/fm-marvin.test.sh` from the repository root for core, fake-port, and executable composition checks.

## Maintaining this file

Keep this file limited to stable module knowledge and point to authoritative code or documentation rather than duplicating contracts.
Update this file when those owners or verification entry points change.
