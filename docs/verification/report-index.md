# Scout report index verification

Audience: maintainer verification.

This record supports the privacy-safe scout report catalog owned by [`bin/fm-report-index.sh`](../../bin/fm-report-index.sh) and the bounded session-start tail that surfaces it.
It records only facts that must be re-established when a producer script or its inputs change.
Task chronology, incident transcripts, and the contents of any private report stay in private task reports or PR evidence; no report body is reproduced here.

## Subject

`bin/fm-report-index.sh` builds `data/report-index.md` (one line per report: `id | date | project | title | summary | path`) and `data/report-index.skipped` (one line per skipped report: `id | reason`) from `data/<id>/report.md`, with the project slug parsed from the surviving `data/<id>/brief.md` worktree line.
`bin/fm-teardown.sh` rebuilds the index after a scout's report is finalized, and `bin/fm-session-start.sh` prints a bounded tail of the prebuilt file in the fleet-state digest without ever rebuilding on the startup blocking path.
The requirement forbids a second LLM at runtime: extraction is deterministic `grep` and `awk` over each report's bounded head.

## Extraction and privacy, verified against a real fleet home

Verified 2026-09-07 against a real primary home holding 25 scout reports totaling 621,724 bytes across `data/*/report.md`.
The reports were copied into a throwaway `FM_HOME` (shown as `<home>` below) so the primary home's `data/` was never mutated; real report ids, titles, and summaries are redacted here because they are private fleet content that must never enter a tracked file.

```text
$ FM_HOME=<home> bin/fm-report-index.sh rebuild
indexed 25 report(s), skipped 0; index: <home>/data/report-index.md

$ FM_HOME=<home> bin/fm-report-index.sh show --tail 3
<report-id> | 2026-09-07 | <project> | <title, capped at 120 chars> | <summary: the report's own first TL;DR line, capped at 140 chars> [truncated] | data/<report-id>/report.md
<report-id> | 2026-09-07 | <project> | <title> | <summary, or "-" when no TL;DR heading exists> | data/<report-id>/report.md
<report-id> | 2026-08-11 | <project> | <title> | <summary> | data/<report-id>/report.md
```

Each summary is the report's own first TL;DR/summary line (or, when no summary heading exists, the first content line after the H1), with list markers and markdown bold stripped and capped at 140 characters; a line over the shared 220-character digest cap ends with the ` [truncated]` marker from `bin/fm-line-cap-lib.sh`.
Three independent `rebuild` runs on identical input produced byte-identical output, which verifies observable determinism only.
The no-second-LLM guarantee is a source and runtime contract fact, not a conclusion drawn from repeated output.

The privacy boundary was pinned by placing a distinctive marker string only in a report body (well past the bounded head) and asserting it appears in neither the index nor the skipped file.
The body marker never reached either file across the rebuild, which verifies only that those marker bytes were not emitted.
The bounded-head read remains a documented source contract and is not inferred from this runtime assertion.

## Skip and safety cases

Synthetic fixtures under a throwaway `FM_HOME` confirmed each skip path records a reason and no body:

```text
$ FM_REPORT_INDEX_MAX_BYTES=1024 FM_HOME=<home> bin/fm-report-index.sh rebuild
indexed 1 report(s), skipped 3; index: <home>/data/report-index.md
$ cat <home>/data/report-index.skipped
<report-id> | oversized
<report-id> | no-title
<report-id> | unreadable       # chmod 000; the size check uses stat (no file open) so no permission text leaks
```

A directory with a `brief.md` but no `report.md` is not scanned, so it appears in neither file.
The `stat`-based size read avoids opening the file, so an unreadable report's permission error never leaks to the rebuild's output.
Portable interface fixtures also confirmed that invalid size caps, failed candidate enumeration or sorting, and directory-shaped publication destinations stop the rebuild with a diagnostic instead of publishing success.

## Teardown hook and digest

A scout teardown (`kind=scout`) with a finalized report, run through the `tests/fm-teardown.test.sh` machinery, rebuilt the index and cataloged the report while preserving `data/<id>/report.md` (the report survives teardown).
The session-start digest's new "Scout report index (data/report-index.md)" subsection printed the bounded tail from the prebuilt file, and printed `report index: ABSENT` without creating the index file when no index existed (no rebuild on the blocking path).

## Missing enumeration, recency ordering, and digest hardening

Three contract decisions (raised as ask-user review findings and approved A/A/A) were implemented on top of the publication/concurrency hardening:

- **Missing reports (r1).** `rebuild` enumerates authoritative completed-scout records from `data/done-archive.md` and `data/backlog.md` Done rows (lines marked `(kind: scout)` with a `data/<id>/report.md` pointer) and flags any completed scout whose `data/<id>/report.md` is absent as `<id> | missing` in the skipped file. The main scan only indexes existing `report.md` files, so a deleted completed-scout report is surfaced rather than silently invisible. The backlog parse is best-effort: a format change yields no missing entries rather than failing the rebuild, so the coupling stays loose.
- **Recency ordering (r2).** The published index is ordered by date then id (a stable sort key staged per entry, with `unknown` dates mapped oldest), so the bounded digest tail surfaces the most recent reports. This replaces the earlier lexical-by-id order, which could let an old `z-*` report displace a newly finalized `a-*` report. Determinism is preserved: same dates reproduce the same bytes, ties broken by id.
- **Digest hardening (r12).** `print_report_index_tail` rejects a symlinked or non-regular `data/report-index.md` and one missing the schema-owner header as ABSENT, never streaming its target. A path pointing at a report body therefore cannot inject report content into the digest.

Fixtures in `tests/fm-report-index.test.sh` pin each: a completed scout in `done-archive.md` whose report is absent is flagged `missing`; a newer-by-date `a-*` report is the tail entry over an older `z-*` report; and a symlinked or non-schema-header index is rejected without streaming a body marker.

## Portability and harness surface

Verified 2026-09-07 with the repo-pinned ShellCheck 0.11.0, GNU bash 3.2.57 (Apple Git, macOS stock `/bin/bash`), tasks-axi 0.2.5, and git 2.50.1.
`bash -n bin/fm-report-index.sh` parses cleanly under `/bin/bash` 3.2, so the macos-stock-bash CI lane is satisfied, and ShellCheck 0.11.0 reports the script, `bin/fm-session-start.sh`, `bin/fm-teardown.sh`, and `tests/fm-report-index.test.sh` clean.

The report index is harness-agnostic: it reads markdown files and prints text, and its verdicts never depend on a vendor-emitted signal (process name, rendered glyph, banner, or bound key).
Under the harness-dependent-checks rule in [`firstmate-coding-guidelines`](../../.agents/skills/firstmate-coding-guidelines/SKILL.md) that marks an axis not applicable only after inspecting its integration surface, no per-harness live guard applies.
The portable regression in `tests/fm-report-index.test.sh` pins the behavior with no harness and runs in CI everywhere; the teardown hook is exercised end to end by `tests/fm-teardown.test.sh`.

## Reproduction

```text
bin/fm-test-run.sh tests/fm-report-index.test.sh        # 21 portable assertions (extraction, privacy, skips, publication, missing, ordering, digest hardening)
bin/fm-test-run.sh tests/fm-teardown.test.sh            # scout teardown rebuilds the index (case: test_scout_teardown_rebuilds_report_index)
bin/fm-test-run.sh --check-coverage                     # coverage guard: the new test is accounted for
```
