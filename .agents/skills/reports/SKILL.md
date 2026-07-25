---
name: reports
description: Browse, search, open, or summarize Firstmate's durable completion report stack. Use when the captain asks what Firstmate or its crewmates finished, wants a completion report or visual evidence, asks to review recent work, or invokes /reports.
user-invocable: true
metadata:
  internal: true
---

# Completion reports

Use `bin/fm-report-stack.mjs` from the Firstmate installation that loaded this skill.

Run `bin/fm-report-stack.mjs open` to regenerate and open the searchable offline stack.
Run `bin/fm-report-stack.mjs list` for a concise inventory, or add `--json` when structured filtering or summarization is needed.
Run `bin/fm-report-stack.mjs path <task-id>` to locate one report without opening it.
Run `bin/fm-report-stack.mjs open <task-id>` to open one report directly.

When the captain asks for a summary in chat, read the selected entry's `manifest.json` and `report.md`, then summarize the outcome, verification, visual evidence, and follow-ups.
Do not inspect provider account homes or raw session state for report browsing.
Treat the report stack as the durable completion ledger and the source task state as volatile.

Read `docs/report-stack.md` only when diagnosing publication, explaining the storage contract, or intentionally publishing a pre-cutover task.
