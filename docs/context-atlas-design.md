# Context Atlas design

[Operator guidance](context-atlas.md) owns adoption and supported limits; the header and help in [`bin/context-atlas.ts`](../bin/context-atlas.ts) own exact invocation mechanics.
The Pi entry point owns registration and active-tool restoration, while [`bin/context-atlas/catalog.mjs`](../bin/context-atlas/catalog.mjs) owns the deterministic dispatcher contract.
Neither is in an auto-discovered extension directory or referenced by a production launcher.
There is no daemon, persistence format, remote service, dependency installation, or general workflow engine.

## Public Pi boundary

The installed extension documentation, SDK documentation, public declarations, and dynamic-tools, kimi-deferred-tools, and tools examples establish the boundary:

| API | Sufficient for | Not sufficient for |
| --- | --- | --- |
| `registerTool` | One compact typed Atlas entry point | Automatically inheriting another tool's policy |
| `getAllTools` | Name, description, parameter schema, guidelines, source provenance | Executable definitions or a generic invocation API |
| `getActiveTools` / `setActiveTools` | Deferring selected tools and additively restoring the original definition | Arbitrary execution or authority to activate an operator-disabled tool |
| SDK tool factories | Constructing a new known built-in implementation | Recovering another extension's registered implementation or preserving its invocation hooks through a direct call |
| Public custom provider API | Observing tools, prompt text, and real tool results in an offline Pi smoke | Proving remote provider serialization, token billing, or model selection quality |

Atlas therefore implements deterministic resolution plus activation for original, originally active, built-in read-only tools.
All configured tools can be cataloged, but only the explicit built-in allowlist can be activated, and only if Atlas itself deferred the same metadata identity.
A custom tool named `read` is not treated as the built-in implementation.
Existing tools retain their original typed entry point and execute normally on the next Pi call.
There is no private Pi API, executable definition extraction, or arbitrary shell/argv path.

The optional file reader is a separate, explicitly authorized read-only adapter, not a proxy call to Pi's `read` tool.
Atlas tool calls go through normal Pi tool events; policies matching only another tool name do not apply automatically.
This distinction is intentional and is reinforced at the read authorization flag and operator guidance.

## Identity and freshness

A file reference combines a hash of its canonical repository-root/relative-path identity with a hash of its filesystem freshness evidence.
Freshness evidence includes device, inode, mode, link count, size, and nanosecond modification/change timestamps, so indexing never opens file contents.
Every reference operation also requires the returned random snapshot generation; refresh, reload, and a replacement session invalidate earlier generations.
There are no positional aliases and no fallback from an unknown reference to a path.
A tool reference hashes the public name, schema, description, guidelines, and source metadata; a metadata change or disappearance refuses the old reference.
This cannot attest hidden changes to a tool's implementation that Pi does not expose.

Discovery uses bounded, fixed-argument Git inventory and ignore queries, including ignore rules for already tracked files.
Paths must pass the default exclusions and operator-added relative prefixes, remain canonical within the selected root, and be regular single-link files without symlink components.
Non-Git directories are refused rather than silently falling back to an unrestricted filesystem walk.
Lookup yields metadata only; focused line reads require the separate read grant, supported UTF-8 text, and the file-size bound.
Before a read, the dispatcher rechecks inventory membership and freshness, opens without following a final symlink, and compares descriptor/path metadata before returning any bytes.
These checks protect ordinary stale references and path mistakes, not an adversarial same-user filesystem race or deliberately disguised secrets.

Responses carry concrete identity or bounded candidates, generation, selection reason, freshness verdict, action outcome, truncation state, and exact UTF-8 JSON output bytes.
Discovery explicitly reports freshness as not checked; inspection and action recheck the selected identity.
Literal queries prefer an exact identity, otherwise use case-insensitive substring matching; ambiguity returns candidates rather than a guessed winner.
A file query can combine resolution and reading only within an explicitly named existing snapshot and with exactly one match.
It uses the stored identity and ordinary selected-file freshness checks, never retargets to a newly indexed path, and still requires the separate read grant.
This avoids an extra lookup for a subsequent file without changing tool execution or introducing another cache.
Oversized structured responses are replaced with a bounded refusal, never invalid JSON, a hidden full-output file, or silent truncation.
Ordinary Pi schema-validation and extension-initialization errors remain Pi errors, outside the dispatcher response envelope.

## Verification

The public dispatcher regression is [`tests/fm-context-atlas.test.sh`](../tests/fm-context-atlas.test.sh).
The real explicitly loaded Pi guard and measurement command are owned by [`tests/fm-context-atlas-live-e2e.test.sh`](../tests/fm-context-atlas-live-e2e.test.sh).
That guard substitutes only the model provider, not the extension host, tool registration, execution loop, active-tool updates, original read policy, or shutdown.
It runs without model tokens and records absent Pi explicitly through the shared live-test gate.
The existing [`Pi type check`](../tests/fm-pi-primary-types.test.sh) includes the optional entry point.
Current measurements and inspected compatibility axes belong in the [maintainer verification record](verification/context-atlas.md).
