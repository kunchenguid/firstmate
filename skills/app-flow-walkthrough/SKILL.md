---
name: app-flow-walkthrough
description: 'Build a single self-contained HTML walkthrough that explains an application to a non-user - a partner, a client, a reviewer, an exec - by driving one simulated app window through its screens with an explanation beside it. Screens are hand-built HTML/CSS mockups drawn from the application''s own source, never real captures, so no client data can leak and nothing needs redacting. Use when asked for an app walkthrough, application flow, click-through, product tour, screen-by-screen explainer, demo document, or a "show them how it works" document, and when redoing one that has drifted into a long scrolling page.'
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. -->

# App-flow walkthrough document

One HTML file. One simulated application window. A reader who has never opened the app clicks through it and understands what the app does, what it decides, and what it cannot do.

## The shape (this is the part that gets lost)

**One fixed frame whose contents change.** Not a long page with mockups down it, and not a page that steps between long sections. A single application window sits in one place; clicking Next swaps what is inside it - the active tab and the body - while the window itself does not move, resize, or scroll away. Beside it, one explanation panel changes with it.

```
┌─ pills: 1 Setup · 2 Import · 3 Processing · … ───────────────┐
│                                                              │
│  ┌────────────────────────┐   STEP 3 OF 7 · PROCESSING       │
│  │ ▢ AppName        — □ ✕ │   Processing — a run in flight   │
│  │ File Edit View  Window │                                  │
│  │ [Setup][Import][Run]   │   Prose explaining what this      │
│  │ ┌────────────────────┐ │   screen is for and why it        │
│  │ │  screen body,      │ │   matters to the reader.          │
│  │ │  swaps per step    │ │                                  │
│  │ └────────────────────┘ │   ① Numbered note keyed to a      │
│  └────────────────────────┘      marker on the mockup         │
│   ‹ Back   Step 3 of 7    Next ›                             │
└──────────────────────────────────────────────────────────────┘
```

Rules that make it work:

- **Fix the frame height** so stepping never moves the page. Size it to the common case, not the tallest screen - the tallest ones scroll inside the frame. Sizing to the tallest leaves short screens sitting in a void of empty white, and the first step is usually a short one.
- **Vertically centre** a screen shorter than the frame.
- **Keep window chrome stable** across steps - title bar, menu row, tab strip. Only the body and the active tab change.
- **Controls belong with the frame**: Back, a live "Step N of M · <screen name>" counter, Next, and jump pills adjacent to it, so it reads as one interactive unit.
- **Do not `scrollIntoView` on step change.** With a fixed frame it is unnecessary and feels like a page jump.

## Simulated screens, never captures

Hand-build each screen as HTML/CSS from the application's own source - view templates, component markup, design mockups, whatever the app actually has - matching real layout, labels and wording. Do not screenshot the running app.

This is a confidentiality decision, not an aesthetic one. A capture taken over real data has to be cropped or painted over afterwards, and a document meant to leave the building should contain nothing that needs catching. Simulations have nothing to redact.

- **Invent the example data** - names, dates, figures, file names - and say so plainly in an opening panel.
- **State up front that nothing is a screenshot** and that clicking changes only this page.
- Read the actual source files for each screen rather than copying an older version of the document; a document one release behind is worse than none.

## Progressive enhancement, or the fallback dies

Build every step into the markup. Let the script *take over* on load: it adds a class (`js-active`) and only then does CSS hide the non-current step.

```css
.walk.js-active .screen:not(.current)      { display: none; }
.walk.js-active #screens { height: 560px; overflow-y: auto; }
```

With scripting off, the document degrades into a long-form page containing every screen and every explanation. The reader loses the interaction, never the content. Never invert this - hiding by default and revealing with script means scripting off shows a blank frame.

## Earn trust in the content

The reason a document like this gets read is that someone is deciding whether to rely on the tool. Do not sell.

- **A figures table where every number cites the source file it came from** - version, counts, limits. Re-derive each one from source; never carry a figure across from a previous draft on trust.
- **Say so when a figure cannot be pinned down.** "Two measured runs widened into a range, not a quote" beats an invented average.
- **A "what is honestly true today" section** and a **"what is not true yet"** section.
- **Name what the tool cannot check.** If checks are unimplemented and a human has to confirm them, list them and say which carry the real risk. This is usually the most valuable paragraph in the document.
- **No internal vocabulary.** No project roles, no team shorthand, no build-system nouns the reader will not know. Grep for them before shipping.

## Mechanics

- **One file, self-contained.** No external `src`/`href`; it must open from `file://` with no network. Embed a banner as a data URI if you want one.
- **Size discipline.** Under ~300KB. A banner is worth ~120KB of that; screenshots are not, which is another reason simulations win.
- **Numbered markers in a gutter, never over text.** Absolutely-positioned markers land on column headings and section labels. Put them in a panel's right gutter and keep the placement consistent across every screen rather than nudging each one by eye.
- Keep reference sections (read-first, honesty, figures, caveats) around the walkthrough, not inside it.

## Verify it by looking at it

Static checks miss what the eye catches immediately - a marker sitting over a heading is invisible to DOM integrity checks and obvious in a render.

The underlying task is always the same regardless of platform: render the finished HTML file in a real browser and photograph it, because only a render shows layout defects a DOM check cannot see.
Drive that with whatever headless-browser tooling is already available in the environment - a browser automation tool, or the browser's own headless CLI flags (most Chromium- and Firefox-based browsers accept a screenshot flag plus a `--window-size`-style option) - pointed at the file's own `file://` URL or a local static-file server.

Traps worth knowing before you start, stated as traps rather than as one setup's commands:

- **A headless screenshot only ever captures the viewport from the top of the document.** An injected `scrollIntoView` does not move it in most headless screenshot modes. To photograph a section further down, inject an on-load script that reparents that section as the sole child of `<body>`, then screenshot.
- **Reparent a whole element that still carries its own state classes.** The step-hiding and frame-height rules above are scoped to the `.walk.js-active` ancestor, so lifting the frame - or anything else nested inside the walkthrough - out on its own silently drops both rules and photographs every screen stacked at full height: the no-script long-form layout instead of the step you wanted. Move the `.walk` container itself, with its `js-active` class intact, and reparent standalone sections only when they sit outside the walkthrough.
- **To photograph step N**, inject a script that clicks Next N times (with a short delay so the page's own script has initialised) before reparenting the `.walk` container or screenshotting.
- **To check the no-script fallback**, strip `<script>` blocks from a copy and render that copy; disabling scripting through a browser flag can silently produce no output when combined with headless screenshotting, so prefer the stripped-copy approach and confirm a file was actually written.
- **If the browser and the file are not on the same machine or filesystem**, the file has to be somewhere that browser can actually reach - copied across, served over a local file server, or opened by a path meaningful to that browser's own OS - before any of the above works; a path meaningful only to the machine that built the file is silently unreachable to a browser running elsewhere.

A builder working in a container or a minimal Linux environment often cannot start a browser there at all - headless browser engines commonly need system libraries and permissions that a stripped-down environment lacks. Plan for the rendering-and-photographing pass to happen wherever a real browser can actually launch, and brief whoever does the rendering to reason about the page's own coordinates and step transitions rather than assuming a specific host setup.

## Checklist before it goes out

- [ ] Opening the file, clicking Next changes one stationary window; the frame does not move
- [ ] Counter and active pill track the step; Back disabled on the first, Next on the last
- [ ] Every screen reached, every explanation paired with the right screen
- [ ] Scripting off: all content still present and readable
- [ ] Opens offline; no external references; no `data:` payload you did not intend
- [ ] No real names, addresses, account numbers, or file paths from a live system
- [ ] No internal vocabulary
- [ ] Every figure traceable to source, or explicitly marked as not pinned down
- [ ] Markers clear of all text on every screen
