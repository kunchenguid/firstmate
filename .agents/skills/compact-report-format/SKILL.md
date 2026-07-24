---
name: compact-report-format
description: >-
  Agent-only structured format for an internal report artifact (a scout's report.md and any
  other investigation or audit deliverable that follows the same scout Definition of done).
  Load before writing a report's Definition-of-done content, before reading or relaying a
  report's findings, and before deciding whether a finding needs the full-detail escape hatch
  instead of the compact form.
user-invocable: false
metadata:
  internal: true
---

# Compact internal-report contract

This skill is the single owner of the structured format for a crewmate's internal report artifact.
It exists to cut the volume of report prose firstmate must ingest to relay and act on a scout's findings, without losing any evidence, verification, recommendation, or captain decision the findings depend on.

## Scope and non-goals

- This format governs report **content**, not the keyed status-line protocol: `working:`, `done:`, `blocked:`, `needs-decision:`, `resolved:`, `paused:`, and `failed:` status-file lines stay exactly as `bin/fm-classify-lib.sh` and the brief scaffold define them, unchanged.
- This format governs internal artifacts read by firstmate and, privately, other crewmates.
  It is not the captain-facing chat message; `AGENTS.md` section 9's translation rules remain the sole authority for anything sent to the captain.
- This is plain markdown text with fixed section headers, so it reads identically across every verified harness (`claude`, `codex`, `opencode`, `pi`, `grok`).
  Nothing here depends on a harness-specific feature, an extra model call, or an external service.

## Required sections

Write every internal report in this fixed order.
Omit a section's content only when it is genuinely empty, and say so (`None.`) rather than dropping the header.

1. `## Outcome` - one line: the terminal result or headline recommendation.
2. `## Findings` - one compact record per finding, each its own line:
   `- [<tag>] <path>:<line[-line]> - <finding> - <impact>`.
   `<tag>` is a short severity or category token, for example `bug`, `risk`, `perf`, `info`, or `security`.
   One finding per compact record, eliminating narrative repetition: do not repeat a finding's substance in prose elsewhere in the report.
3. `## Evidence` - commands run, their output, URLs, and identifiers that do not fit inline on a Findings line above.
   Inline evidence directly on the Findings line when it fits there instead.
4. `## Verification performed` - one line per check: what was run or confirmed and its result.
5. `## Recommendation` - the recommended action and the concrete next step if it is accepted or declined.
6. `## Unresolved captain decisions` - one line per open decision:
   `- [key=<slug>] <question> - options: <a> | <b>`.
   Use the same stable key that `decision-hold-lifecycle` registers with `bin/fm-decision-hold.sh hold`; this section is that policy's semantic inventory in written form, not a second decision mechanism.
   Write `None.` when the inventory is empty.

## Full-detail escape hatch

Compression must never create ambiguity in a place where ambiguity is dangerous.
Write full, unabridged prose for any finding that is a security finding, an irreversible or destructive action, a credential or secret exposure, a legal or compliance concern, or a captain decision whose nuance a one-line record would misrepresent.
Place that prose in a `### Full detail: <finding-id>` block directly under the relevant Findings record, and mark the compacted Findings line with a trailing `(see Full detail)` pointer so a reader knows to keep reading.

When most of a report's findings qualify for full detail, skip the compact schema for the whole report and write ordinary prose instead.
Note `Compact form: not used - <reason>` at the top of that report so the omission reads as a deliberate decision, not an oversight.

## Preserved contracts

- The self-contained-report requirement is unchanged: a compact report must still stand alone, needing no chat history to relay or act on it.
- The decision-hold-lifecycle completion gate is unchanged: inventory and register every unresolved captain decision found in the report exactly as `.agents/skills/decision-hold-lifecycle/SKILL.md` requires before the report can be treated as complete.
  The Unresolved captain decisions section above is that inventory's written form, not a substitute for running the script.

`docs/compact-report-format.md` records the full schema by worked example, the byte-reduction measurement methodology, and verification evidence; it is not restated here.
