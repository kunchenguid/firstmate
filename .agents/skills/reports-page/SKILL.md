---
name: reports-page
description: >-
  Build and hand out this home's offline reports page, one searchable file carrying every data/<id>/report.md with a stable link per report.
  Use when the captain invokes /reports-page, asks to read, browse, search, or be linked to a scout report or an earlier investigation, or asks what a past report said.
  Also use right after a scout's report lands, when handing the captain the link to it.
user-invocable: true
metadata:
  internal: true
---

# reports-page

A scout's report is written once and then read by path, which makes a month-old finding effectively unreachable.
This skill turns the whole pile into one page the captain can search, and gives every report a link that stays the same.

The page is a plain file.
There is no service, no port, no unit, and no timer behind it: `bin/fm-reports-page.sh build` is the entire mechanism, and the page shows what the reports said at the moment of that build.
Rebuild before handing out a link, so a report written since the last build is actually on the page.

## Invocation

- Rebuild and hand over the page: `bin/fm-reports-page.sh build`, then give the captain the path it printed as a `file://` link.
- Link one report: `bin/fm-reports-page.sh link <id>`, where `<id>` is the report's directory name under `data/`.
- The script's header owns every mechanic, including its output lines and the only-on-change rule; `--help` prints it.

Never assemble a report link by hand and never hand out a path the build did not just print.
`link` refuses an id that has no report, which is the whole reason it exists: a hand-built anchor to a deleted report looks live and silently shows the wrong report.

## What the captain gets

One page, opened from the local copy, with the report list on the left and the open report on the right.
Searching filters the list over titles and report text, the list sorts by time, title, or file, and `j`, `k`, `/`, and `i` move through it without the mouse.
It reads on a phone, and printing prints only the open report.

A report's link is the page path plus `#<id>`, so a link stays valid across every later rebuild as long as that report exists.
Inside a report, a link to one of its own headings jumps to that heading and stays in the report.

## For report authors

These are the properties the page relies on; they are what a report should already look like.

- One report per task, at `data/<id>/report.md`, and that `<id>` is the anchor.
- First line `# <title>`, which becomes the list title; without one the list shows the id instead.
- Raw HTML in a report is shown as text, never rendered, so a report can quote markup safely.
- The rendered markdown subset is owned by `bin/fm-reports-render.jq`: headings, paragraphs, hard line breaks, lists, tables, quotes, fenced and inline code, emphasis, links, images, and bare URLs.
- A cross-reference to another report needs that report's own link; a bare `#<other-id>` inside a report is treated as a heading jump and does not change the report.
- Reports stay free of credentials and keys, exactly as before: the page makes them easier to find, not safer to store.
