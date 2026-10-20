---
name: reports-page
description: >-
  Build and hand out this home's offline reports page, one searchable file carrying every data/<id>/report.md and this home's recorded captain decisions, with a stable link per entry.
  Use when the captain invokes /reports-page, asks to read, browse, search, or be linked to a scout report or an earlier investigation, or asks what a past report said.
  Also use when the captain asks what was decided about something, what they already answered, or for the link to a recorded decision.
  Also use right after a scout's report lands, when handing the captain the link to it.
user-invocable: true
metadata:
  internal: true
---

# reports-page

A scout's report is written once and then read by path, which makes a month-old finding effectively unreachable.
A captain decision is recorded in the task it gated, which makes it just as unreachable - and leaves a report describing work with no visible trace of the word that allowed it.
This skill turns both piles into one page the captain can search, and gives every entry a link that stays the same.

The page is a plain file.
There is no service, no port, no unit, and no timer behind it: `bin/fm-reports-page.sh build` is the entire mechanism, and the page shows what the reports said at the moment of that build.
Rebuild before handing out a link, so a report written since the last build is actually on the page.

## Invocation

- Rebuild and hand over the page: `bin/fm-reports-page.sh build`, then give the captain the path it printed as a `file://` link.
- Link one entry: `bin/fm-reports-page.sh link <id>`, where `<id>` is the report's directory name under `data/` or the task id of a recorded decision.
- The script's header owns every mechanic, including its output lines and the only-on-change rule; `--help` prints it.
- `bin/fm-reports-decisions.sh` owns which records count as a decision and which report one belongs to; it only ever reads.

Never assemble a link by hand and never hand out a path the build did not just print.
`link` refuses any id the published page has no entry for, which is the whole reason it exists: a hand-built anchor to a deleted report, or to one written since the last build, looks live and silently shows a different entry.
Rebuild and then link; the refusal names that.

## What the captain gets

One page, opened from the local copy, with the list on the left and the open entry on the right.
Searching filters the list over titles, report text, and decision text, the list sorts by time, title, or file, and `j`, `k`, `/`, and `i` move through it without the mouse.
It reads on a phone, and printing prints only the open entry.

An entry's link is the page path plus `#<id>`, so a link stays valid across every later rebuild as long as that entry exists.
Inside an entry, a link to one of its own headings jumps to that heading and stays in the entry.

A report whose task recorded a decision carries that decision under the report, with the captain's own words, the resolution, and the record's checksum, so the work the report describes can be traced back to the word that allowed it.
A decision that gated no report of this home is its own entry in the same list, marked as a decision, with its own anchor.
The count line names both numbers, and a source of decisions that was missing, skipped, or unreadable at build time is named on the page rather than passed off as "there were none".

## For report authors

These are the properties the page relies on; they are what a report should already look like.

- One report per task, at `data/<id>/report.md`; the anchor `<id>` uses only lowercase letters, digits, and hyphens.
- First line `# <title>`, which becomes the list title; without one the list shows the id instead.
- Raw HTML in a report is shown as text, never rendered, so a report can quote markup safely.
- The rendered markdown subset is owned by `bin/fm-reports-render.jq`: headings, paragraphs, hard line breaks, lists, tables, quotes, fenced and inline code, emphasis, links, images, and bare URLs.
- A cross-reference to another report needs that report's own link; a bare `#<other-id>` inside a report is treated as a heading jump and does not change the report.
- Never include credentials, keys, or passwords in a report: the page makes them easier to find, not safer to store.

## What it does not do

The page only shows decisions; nothing about how a decision is recorded changes, and no report author gains a new obligation.
`bin/fm-captain-hold.sh` stays the one place a decision is written.
The page is a local file of this home, like the reports themselves: it is never published, attached to a contribution, or handed outside, because a decision can carry private detail.
