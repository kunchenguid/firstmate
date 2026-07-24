# Compact internal-report format

The normative contract is owned by `.agents/skills/compact-report-format/SKILL.md` and is not restated here.
This document records the schema by worked example, the byte-reduction measurement methodology, and verification evidence.

## Worked example

Two synthetic fixtures cover the same fictional finding set - a narrative-style report in the shape a scout wrote before this contract existed, and the same content in the compact form - with no captain-private data:

- `docs/examples/compact-report-narrative.md`
- `docs/examples/compact-report-compact.md`

Read them side by side.
Every outcome, finding, piece of evidence, verification step, recommendation, and decision key present in the narrative fixture also appears in the compact fixture; the checklist below maps each one explicitly so the reduction can be checked against fidelity, not size alone.

### Semantic checklist

| Category | Narrative fixture | Compact fixture |
|---|---|---|
| Outcome | opening paragraphs (background + "Overall, the investigation found...") | `## Outcome` |
| Finding 1 (perf, evictor.py:142) | paragraph starting "The first thing we found..." | `## Findings` record 1 |
| Finding 2 (bug, evictor.py:89) | paragraph starting "Second, we found..." | `## Findings` record 2 |
| Finding 3 (security, config_loader.py:34) | paragraph starting "Third, and most seriously..." | `## Findings` record 3 + `### Full detail` block |
| Evidence (commands, output, paths) | inline across the finding paragraphs | `## Evidence` + inline on Findings records |
| Verification performed | paragraph starting "Verification performed for the two eviction defects..." | `## Verification performed` |
| Recommendation + next action | paragraph starting "Our recommendation is to ship..." | `## Recommendation` |
| Unresolved captain decision + key | closing paragraphs (credential rotation timing / blast radius) | `## Unresolved captain decisions` (`[key=widget-cache-credential-rotation]`) |
| Closing recap | final "To summarize" paragraph restates the whole report | not present - the compact form states each fact once, so no recap section is needed |

No category was dropped going from the narrative fixture to the compact fixture; the only content the compact form removes is the closing recap, which restates facts already stated once.

## Measurement methodology

Byte count is the reproducible approximation for this comparison: a fixed-ratio approximation of tokens (roughly 4 bytes/token, the same approximation used elsewhere in this repo, for example `data/caveman-token-reduction-scout-v7/report.md`), so the ratio between the two fixture forms is the meaningful number, not either fixture's absolute byte count.
`tests/fm-compact-report-format.test.sh` re-runs this measurement as a regression assertion (`wc -c` on both fixtures, reduction `>= 40%`), so the number below is checked on every test run rather than only recorded once.

```text
$ wc -c docs/examples/compact-report-narrative.md docs/examples/compact-report-compact.md
    4618 docs/examples/compact-report-narrative.md
    2702 docs/examples/compact-report-compact.md
    7320 total
```

Reduction: `(4618 - 2702) / 4618` = 41.5%.

## Verification record

Verification date: 2026-07-24.

```text
$ bash tests/fm-compact-report-format.test.sh
ok - compact-report-format skill declares itself the single owner with the required trigger metadata
ok - compact-report-format skill owns every required fixed section in order
ok - compact-report-format skill owns the full-detail escape hatch and its named risk categories
ok - compact-report-format skill preserves the keyed status-line protocol byte-for-byte
ok - compact-report-format skill preserves the decision-hold-lifecycle and self-contained-report requirements
ok - AGENTS.md has exactly one precise trigger for compact-report-format
ok - scout brief points crewmates at the compact report contract without restating it
ok - compact-report-format doc points to the skill and owns the worked example and verification record
ok - compact fixture reduces the narrative fixture by at least 40 percent
ok - compact fixture preserves every semantic category the narrative fixture has

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse
ok - fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting
ok - fm-brief.sh: custom pause verb renders in every scaffold
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
(plus every other case in the file; full run exit 0)

$ bash tests/fm-instruction-owners.test.sh
ok - secondmate registry guidance keeps concise routes and points to the charter
ok - state, startup, and ordinary recovery have focused owners and triggers
ok - compressed AGENTS.md records the approved one-owner map
ok - intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work
ok - compressed AGENTS.md retains authority, supervision, AFK, and X safety

$ bash tests/fm-captain-translation-contract.test.sh
ok - ahoy is internal, user-invocable, and absent from public skills
ok - README lists ahoy under the shared cross-harness invocation convention
ok - ahoy delegates first-message fallback and keeps later recaps visible-session-only
ok - ahoy adds visibly open decisions without changing the ordinary recap boundary
ok - ahoy: one canonical owner constructs typed operational input for every Firstmate-controlled user-role producer

$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=97 parallel=30 serial=58 herdr=9
```
