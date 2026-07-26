---
name: report-presentation
description: Use when the captain explicitly invokes /bearings, explicitly asks to show or open a completed report, or asks for browser presentation or annotation of an existing canonical Markdown report.
user-invocable: false
metadata:
  internal: true
---

# Report presentation

Keep the canonical Markdown report authoritative and treat static HTML as a disposable reading projection.
This owner changes presentation only.

## Procedure

1. Confirm the canonical Markdown report is complete before presentation work starts.
2. For an explicit show/open request for an individual report, run `bin/fm-present-report.sh markdown --source <report.md> --open`.
3. For an explicit `/bearings` or explicit show/open request for the Bearings overview, pass the exact JSON snapshot used to compose the Markdown report to `bin/fm-present-report.sh bearings --source <report.md> --snapshot <snapshot.json> --open`.
4. Read the command's single stdout result.
   An `html:<path>` result is the opened local reading page.
   A `markdown:<path>` result means rendering or browser opening failed and the canonical Markdown path is the fallback.
5. Keep the captain-facing response concise and preserve the owning report skill's response format.
   State the Markdown path when fallback occurred, but do not turn presentation failure into task failure.

## Boundaries

- Invoke this owner only from an explicit `/bearings` request or an explicit show/open request.
  A background completion, notification, implicit handoff, or another skill's fallback to Bearings never opens a tab.
- Use the native static page for reading.
  Use `lavish-axi` only when the captain explicitly requests annotation or structured review of that generated HTML.
- Never publish, share, start a report server, poll, auto-refresh, or infer report truth from a browser, terminal, WezTerm, Hermes, or Herdr.
- Do not hand-build a second HTML template.
  `bin/fm-present-report.sh` owns output paths, escaping, accessibility, timestamps, local opening, and Markdown fallback mechanics.
