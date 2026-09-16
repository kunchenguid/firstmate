---
name: image-review
description: >-
  Agent-only procedure for Lavish image-review sessions driven by bin/fm-image-review.sh.
  Use when the captain asks to review, annotate, or select among a directory of images with Lavish,
  before building or opening an image-review page, and when reading returned image feedback back
  into image paths.
user-invocable: false
metadata:
  internal: true
---

# image-review

Run a Lavish image-review session for a directory of images.
`bin/fm-image-review.sh` owns the page mechanics: it walks an images tree in deterministic
sorted order and writes one self-contained review page (default `<images-root>/.image-review.html`)
that groups images by the file structure - top-level directory segments become tabs, deeper
segments become nested collapsible sections - with medium lazy-loaded thumbnails, a full-size
lightbox, and per-image comment plus select/clear controls wired through `window.lavish.queuePrompt`.

## Build and open

1. Inspect the directory first: confirm it holds reviewable images (jpg/jpeg/png/webp/gif;
   hidden entries and non-images are skipped) and that writing the page inside it is acceptable.
2. Generate and open in one pass:

   ```sh
   bin/fm-image-review.sh <images-root> [--out <path>] [--title <text>]
   lavish-axi <page>
   ```

   The generator's header owns every flag and refusal. The page's relative image refs are
   computed from the page's own directory, so any `--out` destination works, but the default
   page inside the tree keeps refs short and is skipped on the next walk.
3. Never run `lavish-axi stop` and never restart the shared Lavish server while any review
   page the captain has open must stay reachable; opening a new session with
   `lavish-axi <page>` is additive and touches no other session.
   Follow the current `lavish-axi --help` for session mechanics instead of copying detail here.

## Verify before handing the page over

The Lavish session wraps the page in a sandboxed iframe and injects `window.lavish` only after
load, so prove both halves before telling the captain the page is ready:

- Integration (session URL through `lavish-axi`): with a live `lavish-axi poll` running, the
  not-connected banner disappears and Send-all enables - the generator re-checks availability on
  an interval, so give it a beat after the page loads. Queue one test comment and confirm the
  queued prompt in the Conversation panel carries the image's `data-image-id`.
- Rendering (artifact URL `http://127.0.0.1:<port>/artifact/<session>/index.html`, no wrapper):
  a frame-piercing browser tool (Playwright, or `chrome-devtools-axi run` page.eval) can drive
  the artifact directly. Verify tabs switch panes, nested sections collapse and expand,
  thumbnails render at ~350px, and clicking one opens the full-size lightbox that closes on Esc
  and backdrop click. Resize to a phone-width window and repeat: tabs scroll, the grid stacks to
  one column, and the comment and select controls stay usable. `chrome-devtools-axi`'s
  accessibility snapshot only reaches the wrapper and the artifact's tabs, not the cards inside
  the sandboxed frame, so use it for the session surface and a frame-piercing tool for the rest.

## Read feedback back

Poll in the foreground per current `lavish-axi poll` help until the captain sends feedback.
Every queued prompt carries the image's `data-image-id` - its path relative to the images root -
in its text, selector, and `data` payload, so map each returned comment back to that exact image
path when reporting findings, and never paraphrase an id into a bare file name.
Selections arrive as `selected: true/false` in the same payload.
