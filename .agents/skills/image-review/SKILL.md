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

Use `chrome-devtools-axi` to prove the page renders before telling the captain it is ready:

- Desktop viewport: tabs switch panes, nested sections collapse and expand, thumbnails render,
  and clicking one opens the full-size lightbox that closes on Esc and backdrop click.
- Mobile viewport (resize to a phone-width window): tabs scroll, the grid stacks to one column,
  and the comment and select controls stay usable.
- In the Lavish session (not the raw file), the select and Queue feedback controls work and the
  not-connected banner stays hidden; outside Lavish the banner appears instead.

## Read feedback back

Poll in the foreground per current `lavish-axi poll` help until the captain sends feedback.
Every queued prompt carries the image's `data-image-id` - its path relative to the images root -
in its text and `data` payload, so map each returned comment back to that exact image path when
reporting findings, and never paraphrase an id into a bare file name.
Selections arrive as `selected: true/false` in the same payload.
