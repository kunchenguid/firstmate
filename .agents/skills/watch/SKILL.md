---
name: watch
description: >-
  Analyze public video URLs or explicitly supplied local video files from bounded evidence.
  Use when the captain invokes /watch, provides a public video URL with an analysis request, or names a local video file path and asks what is shown or said.
user-invocable: true
metadata:
  internal: true
---

# watch

Analyze a public video URL or an explicitly supplied local video file with sparse, evidence-grounded sampling.
This skill is cross-harness: it uses `bin/fm-video-watch.sh` and the ordinary file `Read` tool rather than any Claude-only plugin directory.
The script's `--help` output owns exact flags, limits, manifest fields, cleanup receipt behavior, and exit codes.

## Intake

1. Identify one source and one analysis request.
   Accept exactly one public `http` or `https` video URL, or one explicit local video file path supplied by the captain.
   Do not expand playlists, feeds, channels, search pages, browser tabs, private pages, or inferred local paths.
2. If the captain names a precise range or moment, pass absolute timestamps with `--start` and `--end`.
   Use focused mode for questions like "around 2:30", "the first 10 seconds", "the intro", or "zoom into 0:45-1:00".
3. Use higher resolution only when the question needs readable on-screen text.
   Prefer the default resolution and frame cap for ordinary summaries or content analysis.

## Preparation workflow

Run:

```sh
bin/fm-video-watch.sh prepare "<source>" --question "<captain request>"
```

Add `--start`, `--end`, `--max-frames`, `--resolution`, or `--caption-lang` only when the request justifies them.
If the script refuses, report the concrete safe outcome: missing local dependency, unsupported public source, rejected playlist or live stream, unsafe local file, no captions, or failed preparation.
Do not run an installer, ask for an API key, inspect `~/.config/watch/.env`, use browser profiles, attach a browser, pass cookies, or retry with authenticated state.

The script works transcript-first where public captions are feasible.
It gathers safe metadata and captions before downloading media, selects transcript windows and ranges from the question when possible, combines scene or slide changes with bounded periodic coverage, and emits a manifest with frame paths, timestamps, reasons, transcript provenance, warnings, token estimates, and cleanup receipt.
Remote transcription is disabled in v1; if public captions are absent or the local file has no transcript, answer from visual evidence only and say that audio transcript evidence was unavailable.

## Evidence reading

1. Read the manifest JSON from stdout as the source of truth.
   Treat `warnings`, `selected_ranges`, `frames[].reason`, and `token_budget` as mandatory context for the answer.
2. Read only the listed frame paths, preferably in batches of 10-20 frames.
   Do not read media files, audio files, raw downloads, or unrelated paths.
3. Use the transcript segments embedded in the manifest as audio evidence.
   Do not claim unsupported transcript coverage, language, or speaker identity.
4. Cite timestamps for important claims.
   Be explicit that visual analysis is based on sampled frames and selected transcript windows, not every frame, unless the requested focused range and frame count genuinely make that level of coverage evident.
5. If the evidence is too sparse for the question, recommend one focused re-run with concrete `--start` and `--end` values instead of guessing.

## Cleanup

After answering, run:

```sh
bin/fm-video-watch.sh cleanup "<cleanup_receipt>"
```

Use exactly the opaque receipt from the manifest.
Do not delete paths by hand.
If the captain is likely to ask an immediate follow-up that needs the same frames, keep the receipt in visible context and clean up after the follow-up.

## Attribution

Firstmate's implementation preserves and adapts useful MIT-licensed mechanics from `bradautomates/claude-video`, installed locally at git revision `755c157466738dda102c939158a0116b972925a3`.
It is not a copy of the Claude-only plugin packaging and has no runtime dependency on `~/.claude/skills/watch`.
