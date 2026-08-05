# Daily upstream maintainer verification

This record supports the active guarantees in [`../daily-upstream.md`](../daily-upstream.md).
It records repeatable deterministic evidence rather than a deployment approval or proof that a live LaunchAgent was installed.

## Environment

Verification was first run on 2026-08-02 and re-run on 2026-08-05 after review fixes with this local toolchain:

```text
ProductName:            macOS
ProductVersion:         26.5.2
BuildVersion:           25F84
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
git version 2.42.0
gh-axi 0.1.28
ShellCheck - shell script analysis tool
version: 0.11.0
```

The 2026-08-05 re-run matched this toolchain except for `gh-axi`, which had advanced to 0.1.29, and the deterministic suite uses a local `gh-axi` fixture rather than the installed client.

The source commands were:

```sh
sw_vers
/bin/bash --version | head -1
git --version
gh-axi --version
shellcheck --version | head -2
```

## Deterministic behavior

The focused daily-owner suite uses local bare Git repositories, canonical-looking GitHub origins routed through test-only local URL rewrites, a value-safe `gh-axi` fixture, static public-feed fixtures, an absent-notifier fixture, and a LaunchAgent directory outside the live user library.
It never invokes live `launchctl`, never loads a job, and never contacts GitHub, YouTube, Homebrew, npm, or Apple update services.

```sh
tests/fm-daily-upstream.test.sh
```

```text
ok - green update matrix applies only pinned eligible copies and redacts canaries
ok - channel identities dedupe and report survives an absent notifier/session until exact acknowledgement
ok - a channel history gap preserves state without resurfacing uncounted uploads
ok - duplicate collection is excluded by one home-local lock
ok - a scheduled report contending with a live collection defers explicitly
ok - a report rendered from an earlier receipt names that receipt's date and mode
ok - LaunchAgent definitions are 04:00/08:00 exact, idempotent, static, and transactional on refusal
# all fm-daily-upstream tests passed
```

The matrix covers green, red, and missing checks; clean, dirty, diverged, off-default, local-only, production-bearing, ambiguous-origin, absent, and unregistered project outcomes; private output canaries; report preservation; authenticated report offers; channel initialization, new upload, dedupe, and history-gap preservation; duplicate locking; scheduled report lock contention; earlier-receipt attribution; bounded report re-offer cadence; notification absence; exact calendar hours; no `RunAtLoad`; install idempotence; unsafe-file refusal; transactional uninstall refusal; and preservation of unrelated LaunchAgent files.
The 04:00 and 08:00 definitions use local `StartCalendarInterval` triggers, while the absence of `RunAtLoad` and the report grace plus bounded lock wait cover sleep-delayed launch without an unscheduled login update or a partial receipt read.
The contention test fabricates a live collection lock and requires the scheduled report to return the explicit `report=deferred; reason=run-lock-busy` outcome rather than ending silently under `set -e`.
The re-offer test runs the exact generated check three times and requires the pending report to be offered, then suppressed within the cadence, then offered again once the interval has elapsed.

The authoritative self-update expected-SHA race test was run with:

```sh
tests/fm-update.test.sh
```

Its relevant exact line was:

```text
ok - expected SHA refuses an origin movement without broadening the update
```

The authoritative project-sync expected-target race test was run with:

```sh
tests/fm-fleet-sync.test.sh
```

Its relevant exact line was:

```text
ok - expected target refuses origin movement and leaves the clone untouched
```

## Supported primary and runtime consequence review

The new report is offered through the existing authenticated custom-check path in `bin/fm-watch.sh` before any primary-harness delivery mechanism is selected.
Claude, Codex, OpenCode, Pi and `pi-signed`, Grok, and Kimi therefore consume the same typed `daily-upstream-report <report-id>` check result, while the agent-only handling skill is loaded from the shared `AGENTS.md` trigger.
No backend adapter under `bin/backends/`, no harness-specific supervision protocol, and no runtime session-provider contract changed.
The deterministic suite executes the exact generated check, validates its private offer file, verifies the typed result, and proves exact acknowledgement removes the executable check only after the report is readable.

## Static deployment boundary

The focused suite runs plist syntax validation through the installed `/usr/bin/plutil` but directs every generated definition to a temporary directory.
A fake `launchctl` records any invocation, and the suite requires that record to remain empty.
This proves generation, exact verification, refusal, and rollback mechanics without installing, loading, unloading, or executing a live LaunchAgent.
A live deployment remains a separate captain-authorized operation after landing.

## Repository checks

The maintained documentation inventory and shell lint entry points are:

```sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

Their required successful output is recorded at final branch verification together with the focused and complete relevant test runner results.
