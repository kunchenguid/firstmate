# fm-state-reader

## Usage

`npm --prefix modules/fm-state-reader run run` runs the executable checks on Node 20 or newer with this repository's process-event tools available.
Import `files`, `snapshot`, `readLedger`, and `publishEvent` from `src/index.mjs`.
For example: `const data = snapshot(files(process.env.FM_HOME), Date.now() / 1000);`.

## Layout

Follow the [shared template](../../TEMPLATE.md): record parsing in `src/core`, snapshot/ledger orchestration in `src/usecases`, `StateFiles` in `src/ports`, and filesystem/process-event edges in `src/adapters`.
Tests keep plain-input core assertions, fake-backed orchestration, and real filesystem/process-event composition separate.
This package imports no application or TUI code and starts nothing on import.

## Ports

`StateFiles` exposes `taskIds()`, explicit pool keys, bounded `read(key)` records, and `watch(changed)` returning a close function.
The filesystem adapter reads only public task metadata/status/busy-generation records, beacon, wake count, routing/review ledgers, and explicitly configured pool files; it never opens agent-private sessions.
Missing files return null; malformed pool data stays unknown; ledger parsing reports malformed rows and truncation rather than manufacturing complete evidence.
`snapshot(source, now)` returns worker records, observation time, beacon age, pool measurements, and a bounded wake count; age means time since the latest status, not task lifetime.
`publishEvent({home, root, module, id})` publishes an already-written immutable `state/<module>/events/<24-hex-id>.json` through `bin/fm-procevent.sh register` and `start` with the shared `fm-state-reader` adapter.
The event must contain its matching `id`; module names are bounded lowercase identifiers, and symlinked or oversized event paths are rejected.

## Configuration

There is no model, persona, persistent configuration, or private database in this library.
The file adapter accepts `poolFiles` explicitly and `maxBytes` from 1 to 1048576, defaulting to 65536; pools are not guessed from task metadata.
`root` identifies the installed Firstmate tools and `home` the observed operational home, so a copied state tree need not contain executables.

## Limits

File reads are bounded tail reads; incomplete ledgers report truncation, and metadata or state records must not be treated as authoritative when incomplete.
File and state-directory symlinks are refused; these are local read safeguards, not a sandbox against concurrent filesystem replacement by the same user.
`watch` subscribes only to existing state/data/pool parent directories and reports watcher errors; close and recreate it after adding a new parent directory.
Read an initial snapshot after subscribing; native filesystem notifications can coalesce or be dropped and are not a complete event history.
A missing generation match stays `unknown`; neither old status nor missing data proves a worker idle.
The renderer must sanitize external text; this library's ledger rows are data, not trusted instructions or safe-to-log secrets.
The process-event owner captures output before announcing a wake, but interruption before capture can lose destructive source output and effects can repeat before acknowledgement.
This publisher uses a non-destructive immutable file, performs no task lifecycle action, and does not promise exactly-once delivery; the application owns event immutability and duplicate policy, and the consumer still acknowledges through `fm-procevent.sh handled`.
Legacy `bin/fm-procevent-<adapter>.sh` adapters retain precedence; module adapters resolve from `modules/<adapter>/src/adapters/procevent.sh`.

## Verification

`bin/fm-test-run.sh tests/fm-modules.test.sh` verifies the fake-backed snapshot plus real bounded file reads, symlink/allow-list refusals, file-change notification, durable event capture, wake publication, and unchanged source task bytes.
The process-event composition check needs Bash, Node, jq and Perl; it runs in a temporary home and launches no model or task worker.
