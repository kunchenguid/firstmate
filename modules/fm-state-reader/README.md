# fm-state-reader

## Why it exists

Applications need one bounded view of operational state instead of several incompatible parsers.
They also need one shared message port, not a separate inbox format for every service.
This library separates plain snapshot rules from filesystem, message, and registered-event I/O.
It starts no service, invokes no model, and performs no task lifecycle action on import.

## How to run

From a fresh checkout with Node 20+, Bash, jq and Perl installed:

```sh
npm --prefix modules/fm-state-reader run run
bin/fm-message.sh -h
bin/fm-message.sh send --help
bin/fm-message.sh receive --help
```

Import `files`, `snapshot`, `readLedger`, `publishEvent`, `messages`, and `serviceMessages` from `src/index.mjs`.
For example, `snapshot(files(process.env.FM_HOME), Date.now() / 1000)` returns a plain snapshot.
`messages({home, root})` returns the [MessagePort](src/ports/messages.d.ts); its adapter delegates to `bin/fm-message.sh` and never implements a second wire codec or writes task files directly.

Messaging requires an existing operational home and live participants; these commands do not launch them:

```sh
FM_HOME=/path/to/home bin/fm-message.sh send peer-a,peer-b --thread review --kind request -- 'Check the API'
FM_HOME=/path/to/home bin/fm-message.sh receive
FM_HOME=/path/to/home bin/fm-message.sh ack 001.msg
```

Run from the launched task's working directory with its inherited `FM_TASK_ID`, or from the supervisor's own home without that task marker.
No caller-supplied `from` label is supported.
The [message owner](../../bin/fm-task-inbox-lib.sh) defines `fm-message.v1`; [current message behavior](../../docs/agent-control.md#shared-messages-and-threads) covers thread membership, authority, and retry guarantees.
The library and one-shot commands have no idle scene or timer; animation belongs to applications following [the module template](../TEMPLATE.md).

### Standalone service admission

A foreground service uses `await serviceMessages({home, root, name})` at startup, rather than borrowing `FM_TASK_ID` or the supervisor identity.
It returns the same MessagePort plus `close()`; no process, poller, timer, or alternate wire format is created.

```js
const port = await serviceMessages({ home, root, name: 'fm-moiras' });
try {
  const [entry] = await port.receive();
  if (entry?.message.kind === 'request') {
    const receipt = await port.send([entry.message.from], 'received', {
      kind: 'reply', ref: entry.message.id,
    });
    if (!receipt.partial) await port.acknowledge(entry.name);
  }
} finally {
  await port.close();
}
```

The [service owner](../../bin/fm-service-message-lib.sh) defines the process-bound registration in `state/services/<name>.json`; `bin/fm-message.sh service --help` documents the equivalent shell lifecycle.
Names share the participant namespace: `supervisor`, task collisions, duplicate live owners, malformed records, and symlinked registry paths refuse.
A service hint is verified against its recorded live PID fingerprint and calling-process ancestry on every message operation; omitting the hint from a registered process cannot fall back to another identity.
The factory replaces inherited task identity only in its captured CLI environment, leaving the application's environment unchanged.
Service traffic uses `state/<name>.inbox/`, the same threads, request references, retries, rate limits, and telemetry as other messages, never the supervisor inbox unless explicitly addressed there.
Structured sends also pin supervisor wakes to that home's state directory rather than inheriting an unrelated queue override.
Applications own receive scheduling and graceful signal handling; call `close()` after in-flight operations and before shutdown.
Normal Node process exit also attempts deregistration synchronously; failures warn, while abrupt termination can leave a stale registration.
Dead processes refuse delivery; after the recorded PID is gone, restarting the same named service can replace its stale registration without deleting pending or handled messages.
A still-live PID with a changed fingerprint remains a refusal, not permission to replace its owner.
PID validation is a preflight, not an atomic guarantee against a process dying immediately afterwards; queued messages remain durable for the next instance.

## How to configure

There is no configuration file, model, persona, database, or background service in this library.
All available options are function arguments or the existing operational environment:

| API / setting | Default | Meaning |
| --- | --- | --- |
| `files(home, options)` | `home` required | Physical operational home to read. |
| `options.poolFiles` | `[]` | Explicit pool file paths; never guessed from task metadata. |
| `options.maxBytes` | `65536` | Tail-read limit, from 1 to 1048576 bytes. |
| `snapshot(source, now)` | Both required | StateFiles port and observation time in epoch seconds. |
| `readLedger(source, key)` | Both required | Read a permitted ledger with malformed/truncated evidence retained. |
| `publishEvent({home, root, module, id})` | All required | Publish an already-written immutable event through the registered process-event owner. |
| `messages({home, root, service})` | `service` absent | Physical home and tool checkout; optional service name binds an already-registered calling process. |
| `serviceMessages({home, root, name})` | All required | Register this process and return a ServiceMessagePort; does not start a server. |
| `ServiceMessagePort.close()` | Explicit shutdown | Deregister this process without deleting its inbox or history. |
| `FM_SERVICE_ID` | Absent outside services | Registered service lookup hint, checked against live native process ancestry. |
| `FM_TASK_ID` | Absent for the supervisor | Inherited task identity; checked against live metadata and the working directory. |
| `MessagePort.send(to, text, options)` | `options={}`, kind `note` | Recipient id array, text, and optional `kind`, `thread`, `ref`; unspecified thread is created by the transport. |
| `MessagePort.reply(ref, text)` | Thread members | Reply using the received request's id. |
| `MessagePort.retry(id, thread)` | No replacement data | Resume the original partial fan-out using the returned receipt. |
| `MessagePort.receive()` | Own inbox | Ordered entries; reading never acknowledges processing. |
| `MessagePort.acknowledge(name)` | No implicit acknowledgement | Move one received numeric record to `handled/`, idempotently. |

The message adapter captures the current working directory and environment when constructed, pins `FM_HOME`, `FM_ROOT_OVERRIDE`, and `FM_STATE_OVERRIDE` to its explicit home/root, and runs each CLI call with a 30-second timeout and a 1 MiB output bound.
Those bounds are fixed, not hidden configuration knobs.
A partial fan-out returns `partial: true` with its original id and thread; a timeout or other uncertain error must not be retried by sending replacement text.
Inspect the retained thread ledger before recovery when no receipt was returned.

`StateFiles` exposes `taskIds()`, explicit pool keys, bounded `read(key)`, and `watch(changed)` returning a close function.
Its file adapter reads only the public task metadata/status/busy-generation records, beacon, wake count, routing/review ledgers, and explicitly supplied pools; it never opens agent-private sessions.
Missing files are null, malformed pools remain unknown, and snapshot age measures time since the latest status rather than task lifetime.

An immutable event is `state/<module>/events/<24-hex-id>.json`, containing the matching `id`; module names are bounded lowercase identifiers.
The publisher rejects symlinked or oversized events, then uses the existing `register` and `start` commands with the shared event adapter.

## Telemetry

The message transport owns append-only daily JSONL in `FM_HOME/state/fm-message/telemetry/YYYY-MM-DD.jsonl`.
Its [telemetry owner](../../bin/fm-message-telemetry-lib.sh) defines the schema and counters; logs include ids, input byte counts, static refusal reasons, step timings, and available model/harness/effort, never message text or captured stderr.
Unknown tokens and cost stay null because the transport calls no model.

```sh
FM_HOME=/path/to/home bin/fm-message.sh stats
jq . /path/to/home/state/fm-message/telemetry/2026-09-11.jsonl
```

`stats` summarizes the rolling last 24 hours, including service registration/deregistration outcomes; delivery counters count accepted delivery calls, including idempotent retry confirmations, not unique new inbox files.
Thread ledgers contain private conversation text and must not be copied into telemetry.
Consuming services own their own decision and model telemetry; this shared reader adds no autonomous logging process.
For Tachikoma and Backpass integration, consume these JSONL files by `requestId` and `threadId`; this change provides the feed, not an automatic ingestion process.

## Development

```sh
bin/fm-test-run.sh tests/fm-modules.test.sh tests/fm-peer-message.test.sh
npm --prefix modules/fm-state-reader test
```

Follow the [module template](../TEMPLATE.md): pure record parsing in `src/core`, snapshot orchestration in `src/usecases`, TypeScript contracts in `src/ports`, and concrete edges in `src/adapters`.
Tests distinguish plain core assertions, use cases using [fake files](tests/fake-files.mjs) and [fake messages](tests/fake-messages.mjs), and real filesystem/CLI/process-event composition.
The message fake includes `close()` for service use cases; real service acceptance tests exercise separate Node processes, registration, both reply directions, guarded refusal, normal shutdown and abrupt-death recovery.
Ordinary task records retain verified tmux or Herdr liveness; standalone service admission uses native process identity independently of those backends.

### Supported limits

File reads are bounded tails, and incomplete records are not authoritative.
A missing generation match stays unknown; neither old status nor missing data proves a worker idle.
File and state-directory symlinks are refused, but these are same-user operational safeguards, not a sandbox against concurrent filesystem replacement.
`watch` subscribes only to existing parent directories; close and recreate it after adding a new parent.
Read an initial snapshot after subscribing: native notifications can coalesce or be dropped and are not complete history.
Renderers must sanitize external text; ledger rows are data, never trusted instructions or safe-to-log secrets.

The event publisher uses a non-destructive immutable file and performs no lifecycle action, but interruption before capture can lose destructive source output and effects can repeat before acknowledgement.
Applications own event immutability and deduplication; consumers still acknowledge through `fm-procevent.sh handled`.
Legacy `bin/fm-procevent-<adapter>.sh` adapters retain precedence over `modules/<adapter>/src/adapters/procevent.sh`.
