# Context Atlas verification

This is the active empirical record for the [optional prototype](../context-atlas.md), not a claim of production token savings.
The [design owner](../context-atlas-design.md) owns implementation boundaries.

## Real Pi proof

Verified on 2026-09-11 with Pi 0.85.1 on Linux using its real CLI, explicit extension loading, and a local scripted provider.
No credential, network call, installation, global configuration write, or model token was needed.
The provider fixture registers no tool and supplies deterministic calls; Pi itself validates, dispatches, executes, and delivers the results.
The command refreshes the exact candidate under test, rather than a copied or installed extension:

```sh
FM_CONTEXT_ATLAS_LIVE=1 bin/fm-test-run.sh tests/fm-context-atlas-live-e2e.test.sh
```

Exact terminal success line:

```text
ok - Pi 0.85.1: exact Atlas candidate loaded, real tool calls correct, original read policy preserved, active tools restored, clean exit (offline scripted provider; no model tokens)
```

The guard asserts that Atlas is the only added tool, deferral leaves all other original tools active, activation exposes the unchanged original read schema on the next request, a read-specific policy still blocks a subsequent original read call, an allowed original read succeeds, and shutdown restores the original set without changing definitions.
The non-deferred case verifies preservation without activating the optimization.
All eleven flows read the independently known declaration `export const refundLimit = 42;` from the selected line in a fixture with 60 unrelated source files.
The three two-file flows also read `export const chargeLimit = 7;` and compare native discovery, separate Atlas resolution, and snapshot query/read.
The guard rejects default-tool schema overhead and requires the snapshot flow to finish correctly with one discovery-only call and three total calls.
The test's header owns exact CLI flags and evidence-retention mechanics, including the option terminator before a command-line prompt.

## Measurement

Baseline capture preceded implementation using Pi's public tool factories and a native bounded read.
The repeatable paired measurements below use real Pi requests and tool results; all bytes are UTF-8, not estimated tokens.
Schema bytes are JSON of active tool name, description, and parameters at the provider boundary; prompt bytes are the separate system prompt.
Result bytes include every returned content block, including Atlas's identity/freshness envelope.
Discovery counts are standalone model-facing tool calls, not internal searches; duplicate reads count repeated identical read arguments.
Latency spans the fixture provider's startup through shutdown, excluding CLI module loading and any network/model reasoning; it is a single local observation, not a benchmark distribution.

Observed paired run:

| Flow | Initial/final schema bytes | Prompt bytes | Discovery-only calls | Result bytes | Duplicate reads | Tool calls | Latency ms | Correct |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Native broad find + focused read | 4754 / 4754 | 2724 | 1 | 5989 | 0 | 2 | 40.693 | yes |
| Native focused find + focused read | 4754 / 4754 | 2724 | 1 | 159 | 0 | 2 | 45.686 | yes |
| Native already-known read tool | 4754 / 4754 | 2724 | 0 | 110 | 0 | 1 | 26.183 | yes |
| Atlas file resolve + focused read, deferral enabled | 2672 / 2672 | 2544 | 1 | 729 | 0 | 2 | 54.149 | yes |
| Atlas tool resolve + activation + original read policy probe + allowed read | 2672 / 3326 | 2544 | 1 | 754 | 0 | 4 | 52.371 | yes |
| Atlas file flow, no deferral | 5363 / 5363 | 2724 | 1 | 729 | 0 | 2 | 45.683 | yes |
| Pi default four tools, already-known read | 2717 / 2717 | 2622 | 0 | 110 | 0 | 1 | 24.713 | yes |
| Atlas with Pi default four tools, deferral enabled | 2672 / 2672 | 2544 | 1 | 729 | 0 | 2 | 44.235 | yes |
| Native focused discovery + reads, two files | 4754 / 4754 | 2724 | 2 | 317 | 0 | 4 | 55.941 | yes |
| Atlas separate resolve + reads, two files | 2672 / 2672 | 2544 | 2 | 1458 | 0 | 4 | 48.368 | yes |
| Atlas snapshot query/read for second file | 2672 / 2672 | 2544 | 1 | 1130 | 0 | 3 | 50.248 | yes |

The seven-tool setup reduces initial active schema bytes by 43.8%, from 4754 to 2672, while original-read activation grows that set again to 3326.
Against the four-tool default, Atlas saves 45 schema bytes (1.7%); without deferral it still adds 609 bytes to the seven-tool set.
This reduction comes from compact description wording, not removing typed fields or safety validation.
Broad discovery output falls from 5989 to 729 bytes, but focused native discovery is substantially smaller at 159 bytes.
For two files, reusing the first lookup's snapshot generation combines the second file's resolution and read: discovery-only calls fall from two to one, total calls from four to three, and Atlas result bytes from 1458 to 1130.
The combined call still performs an internal lookup and freshness checks; it does not avoid that work, and native focused results remain smaller at 317 bytes.
The safety-probe row deliberately includes one blocked read call and its error result; it is not a matched latency comparison against the single-call native row.
There is no measured duplicate-read improvement, and resolving/activating an already-known tool still adds calls.
The result supports a removable, opt-in exploration for larger tool sets, not default activation or a universal token-saving claim.
Remote provider serialization, caching, billed tokens, natural-language selection accuracy, TUI pixel layout, and non-Linux filesystem behavior were not measured.

## Portable failure coverage

```sh
bin/fm-test-run.sh tests/fm-context-atlas.test.sh
```

Exact output:

```text
ok - Atlas public dispatcher: identity, freshness, exclusions, authority, bounds and refusal cases
```

Coverage includes stale generation and file metadata, same-size rewrites, newly ignored tracked paths, replaced directory symlinks, out-of-root/ignored/private paths, hardlinks, unknown handles, ambiguity and bounded pagination, invalid line ranges, UTF-8, oversized/binary output, absent or changed tools, read authorization, custom read overrides, and disallowed execution.
Query reads additionally cover missing/stale generations, conflicting selectors, ambiguity without contents, file-only selection, and refusal to retarget after the original file disappears even when a new matching file exists.
The existing Pi type-check entry point includes Atlas and passed with TypeScript 5.9.3 against Pi 0.85.1:

```sh
bin/fm-test-run.sh tests/fm-pi-primary-types.test.sh
```

```text
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.85.1
```

## Compatibility inspection

No startup, supervisor instruction, hook, shared runtime adapter, package manifest, or existing extension changes to load Atlas.
The affected shared runner only classifies/selects its new tests; existing primary/runtime integration behavior is not modified.

| Axis inspected | Integration surface | Applicability |
| --- | --- | --- |
| Pi and pi-signed primary/secondmate | `.pi/extensions/`, `bin/fm-spawn.sh` Pi launch branches | Ordinary startup unaffected; optional explicit Pi path verified above; signed wrapper not installed or claimed tested |
| Pi workers | Generated per-task extension and explicit `-e` launch in `bin/fm-spawn.sh` | Unaffected; Atlas is not added to generated extensions or launch arguments |
| Claude | `.claude/settings.json` | Not applicable; hooks do not discover TypeScript under `bin/` |
| Codex | `.codex/hooks.json` | Not applicable; startup and pre-tool/stop hooks unchanged |
| OpenCode | `.opencode/plugins/` | Not applicable; plugin discovery and shell checks unchanged |
| Grok | `.grok/hooks/` | Not applicable; configured command hooks unchanged |
| Kimi | Harness reference and global-hook launch integration | Not applicable; no primary guard or worker-hook changes |
| Cursor | `.cursor/hooks.json` | Not applicable; explicit shell/session hooks unchanged |
| OMP | `.omp/extensions/` and launch branches | Not applicable; its separate discovery path does not import Atlas |
| Gemini, Muse, Rovo workers | Harness detection and launch branches | Not applicable; no entry point for this Pi-only extension added |
| tmux, Herdr, zellij, Orca, cmux | `bin/backends/` adapter headers and launch boundary | Not applicable; Atlas neither controls endpoints nor changes session-provider operations |

No runtime backend was started, stopped, restarted, or otherwise exercised for this experiment.
