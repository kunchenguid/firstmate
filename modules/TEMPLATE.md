# Copyable module pattern

Build the first useful command before adding another layer.
The two inner layers are plain functions: `core` transforms data; `usecases` receives the I/O ports it needs and returns plain results.
A port is a small TypeScript interface, one real adapter and one in-memory fake; add one only for I/O that needs substitution or testing.
No service classes, repositories, dependency-injection containers, event buses, or empty pattern-only files.

## Layout to copy

```text
modules/<name>/
  package.json
  AGENTS.md         # one-page module contract, ports, contributor conventions
  CLAUDE.md         # canonical @AGENTS.md pointer, managed by the repo helper
  src/core/          # pure rules over plain records
  src/usecases/      # functions receiving only their required ports
  src/ports/         # interfaces in .d.ts; no runtime framework
  src/adapters/      # files, forge, harness, procevent, terminal/CLI as needed
  src/index.mjs      # public exports; no startup side effects
  tests/            # core.test.mjs, usecases.test.mjs, adapters.test.mjs, fakes
  README.md         # Why it exists, How to run, How to configure, Telemetry, Development
  config.json       # application defaults, only when configurable
  config.schema.json
  personas/         # only when the application actually invokes a model
```

Libraries retain only implemented capabilities: no pretend daemon, empty config, or unused persona.
The two shared libraries are `fm-tui-core` and `fm-state-reader`; applications may import both and the existing process-event contract, never one another.
Use relative package entry imports in this repository; package-manager workspace wiring can replace those at extraction time.

## Package and configuration shapes

```json
{"name":"@firstmate/<name>","version":"0.1.0","private":true,"type":"module","exports":"./src/index.mjs","engines":{"node":">=20"},"scripts":{"run":"node src/adapters/cli.mjs","test":"node --test tests/*.test.mjs"}}
```

A pure library's `run` invokes its executable checks instead of inventing an application CLI.
An application's optional model configuration has shape `{"roles":{"role":{"harness":"pi","model":"default","effort":"low","persona":"personas/role.md"}}}`.
Its own `config.schema.json` uses JSON Schema 2020-12 with explicit types, required keys and rejected unknown fields; validate at the CLI edge before side effects, using existing dependencies or a small direct validator.
Load edited personas per invocation; each English Markdown persona states purpose, forbidden actions and the exact bounded output format.

## Application contract

`run -- start` starts manually in the foreground; `status` prints once; `--frames N --out DIR` exports bounded frames; `--clean` prints a static all-row view; `--no-ui` runs without animation; honor `NO_COLOR`.
Every command and subcommand supports `-h` and `--help`, listing every verb and flag with a one-line description and one example each, without starting the application or requiring credentials.
Each module's root `README.md` has these sections in order: `Why it exists` (3-5 lines), `How to run` (fresh-checkout commands), `How to configure` (every key, default, and file location), `Telemetry` (paths and reading commands), and `Development` (tests and fakes).
Desktop applications use a mostly static lo-fi/synthwave idle scene, with a small blink, flicker, drifting cloud, breathing glow, or thread twitch every few seconds at 1-4 fps, never constant fast motion; preserve `--clean` and `NO_COLOR` output.
Libraries and one-shot commands do not invent an idle animation or timer.
The application owns signals, frame timing and file-change debounce; `fm-tui-core` never starts a timer.
Keep runtime writes under `FM_HOME/state/<name>/`, including any database, plus registered process-event records; never auto-start or perform actions from untrusted evidence.
Only a thin `bin/fm-<name>.sh` wrapper lives outside the module; event adapters live in `src/adapters/procevent.sh` and use the existing process-event owner, never direct wake-queue append.
The [shared reader](fm-state-reader/README.md) owns that executable delivery seam and its durability limits.
Service requests and replies consume the shared [MessagePort](fm-state-reader/src/ports/messages.d.ts), [adapter](fm-state-reader/src/adapters/messages.mjs), and [fake](fm-state-reader/tests/fake-messages.mjs), never an application-private inbox wire format.
The adapter delegates to existing guarded message owners; services without supported lifecycle admission remain on the fake rather than claiming a task identity.
A service appends daily JSONL under `state/<name>/telemetry/YYYY-MM-DD.jsonl` with this record shape: `{"ts":"UTC ISO-8601","module":"name","event":"port.exit","requestId":null,"threadId":null,"actor":"name","inputs":{"ids":[],"bytes":0},"decision":null,"reasons":[],"stepsMs":{},"model":null,"harness":null,"effort":null,"tokens":null,"cost":null,"outcome":"accepted","evidencePath":null,"counters":{}}`.
Outcome is `accepted`, `rejected`, or `error` after a step and null at entry; unknown measurements remain null, never invented zeros.
Log adapter entry/exit and errors with refusal reasons; pure core functions return decision evidence for the use case to log rather than doing I/O themselves.
Include per-request counters and a `stats` verb summarizing the last day; redact secrets and record unavailable costs explicitly, without adding a database or logging framework.

## First runnable slice

Copy the [StateFiles interface](fm-state-reader/src/ports/files.d.ts), [file adapter](fm-state-reader/src/adapters/files.mjs), [fake](fm-state-reader/tests/fake-files.mjs), and [use-case test](fm-state-reader/tests/usecases.test.mjs) as the worked example, not as four new abstractions to duplicate.
Register one thin `tests/fm-<name>.test.sh` bridge in the repository's existing test runner and a PR CI command; keep test implementations inside the module.
Run that bridge through `bin/fm-test-run.sh`, then the exact relevant CI checks, with real adapter composition evidence separate from fake-backed use-case tests.
