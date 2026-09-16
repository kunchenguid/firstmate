---
name: bearings
description: >-
  Compatibility alias for /report.
  Use when the captain invokes /bearings, including the existing file, live-PR enrichment, or Lavish variants.
user-invocable: true
metadata:
  internal: true
---

# bearings

Load [`../report/SKILL.md`](../report/SKILL.md) and follow its report contract exactly.
Route plain `/bearings` to `bin/fm-report.sh --command bearings` so it produces byte-identical Markdown to plain `/report` in normal conversation history.
Preserve every supplied option when delegating: `file`, `lavish`, and `include PRs` remain explicit modes owned by the report skill.
Do not compose, alter, summarize, or supplement the report in this alias.
