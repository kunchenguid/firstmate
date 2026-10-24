# Herdr checklist — format contract + invariants

This is the format your checklist file follows, rewrite after rewrite.
Keeping the shape fixed is what lets it survive terminal restarts, and lets an AI agent maintaining the file rebuild it the same way every time after its context is compacted.

The checklist is a single markdown file (default `CHECKLIST.md`, configurable) rendered in a dedicated Herdr pane.
It is meant to be your one at-a-glance reading surface for everything in flight: what only you can unblock, what is running, what is parked, and what just landed.

`{{OWNER}}` below is you, the operator — the plugin's `new` action substitutes `$HERDR_CHECKLIST_OWNER` (default `you`) when it creates the file.

## Sections, in this order, always all four

```
# CHECKLIST — {{OWNER}}                                <YYYY-MM-DD HH:MM local>
# ═══════ (full-width bar)

## 🔴 ACT NOW — only you can do these
## 🔵 IN FLIGHT — agents working right now
## 🟡 WAITING — parked on a word or an external event
## 🟢 RECENTLY DONE
```

Blank line after the header bar and between every section.
One blank line between numbered ACT NOW items.

## Placement rules (what goes where)

- 🔴 ACT NOW: only items where YOU are the blocker (a paste, a click, a settings change, a decision word).
  Each item: numbered, 1-3 lines, the reply-word in quotes when one exists, and what it unblocks.
- 🔵 IN FLIGHT: an agent is actively executing.
  Include the Herdr pane or tab id so you can jump to it, and what "done" will produce.
- 🟡 WAITING: nothing is executing; name exactly WHAT unblocks each item (whose court, which event, which reply-word).
  Watches and time-gates that will resurface themselves get a mention so you know they are covered.
- 🟢 RECENTLY DONE: compressed, up to about 6 lines total, newest first; drop entries after about 2 days.

## Invariants that survive every rewrite

1. Every live thread appears EXACTLY ONCE, in the section matching its true current state.
2. Nothing leaves the checklist while still live.
   A thread exits only when genuinely closed (merged, answered, abandoned on your word).
   At every rewrite, diff against the previous version and re-justify each removal so nothing is dropped silently.
3. Every PR or link mention is a full `https://` markdown link copied from a real record — never assembled from memory.
4. Reply-words are load-bearing: quoted, unique, and each maps to one action an agent executes without follow-up questions.
5. Plain language only: no internal tool jargon, ticket ids, or process vocabulary.
   Herdr pane and tab ids are allowed — you navigate by them.
6. ADHD shape: lead with the action, one thought per line, cap about 5 items per section (split or compress past that), concrete time estimates when known.
7. The timestamp in the header updates on every edit.

## Update discipline

- Small state changes are a surgical edit of the affected item, not a full rewrite.
- Full rewrites only for structure drift; when doing one, run invariant 2's removal audit.
- After a context compaction: re-read this contract and the current checklist before the first edit.
