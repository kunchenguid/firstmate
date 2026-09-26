---
name: osmo
description: >-
  Catalog, transcribe, and classify video clips from a connected DJI Osmo Pocket drive.
  Use when the captain invokes /osmo or asks to catalog, transcribe, pair, or classify Osmo Pocket footage.
  Discovers /Volumes/Osmo strictly read-only, pairs master MP4 and low-resolution proxy LRF files, transcribes audio via local headless CLI or Superwhisper, samples visuals locally with ffmpeg and Apple Vision, classifies clips into A-roll, B-roll, or mixed, caches results deterministically outside the device, and generates a local Markdown report.
user-invocable: true
metadata:
  internal: true
---

# osmo

Catalog, transcribe, and classify video footage from a connected DJI Osmo Pocket drive strictly read-only.
The skill pairs high-resolution master MP4 files with low-resolution proxy LRF files, samples frames locally using ffmpeg and macOS Apple Vision, analyzes speech and silence activity, interfaces with Superwhisper, classifies each clip into A-roll, B-roll, or mixed, caches derived artifacts incrementally outside the device, and compiles a comprehensive local Markdown report.
The entire workflow is free, private, and 100% local: no paid APIs are used, and no footage, audio, transcripts, or sampled frames are uploaded to cloud services.

## Invocation and commands

The primary driver is `bin/fm-osmo.sh` (backed by `bin/fm-osmo.py`).
When the captain invokes `/osmo`, run `bin/fm-osmo.sh catalog` by default.

Supported subcommands:

- `bin/fm-osmo.sh discover [--drive <path>] [--json]` - Check whether the Osmo drive is mounted at `/Volumes/Osmo` (or a custom path) and verify read-only access.
- `bin/fm-osmo.sh scan [--drive <path>] [--json]` - Scan the DCIM directory and report master MP4 and proxy LRF clip pairs without extracting media.
- `bin/fm-osmo.sh catalog [--drive <path>] [--cache-dir <dir>] [--output <file>] [--transcriber <cmd>] [--sample-count <N>] [--force] [--json]` - Run end-to-end sampling, audio analysis, transcription, classification, caching, and report compilation.
- `bin/fm-osmo.sh report [--cache-dir <dir>] [--json]` - Render the latest generated catalog report.

## Safety and read-only boundaries

The Osmo drive (`/Volumes/Osmo`) is strictly read-only.
Never write, modify, rename, delete, or generate sidecars on the physical Osmo storage drive.
All derived assets - sampled video frames, extracted audio tracks, cache manifests, and Markdown reports - are stored in a local destination outside the device (by default `~/.firstmate/osmo-catalog-cache/` or `--cache-dir`).

## File pairing (MP4 and LRF)

DJI Osmo cameras record each take as a pair of files with matching base names:

- `<STEM>.MP4` - the high-resolution master recording used for final video edits.
- `<STEM>.LRF` - the low-resolution proxy file used for fast mobile preview.

The cataloger groups files by stem and pairs the master MP4 with its LRF proxy.
Sampling and frame extraction prefer the LRF proxy when present because it decodes significantly faster and uses less CPU and battery while preserving the exact frame composition of the master clip.
Clips without an LRF proxy fall back automatically to the master MP4.
Each clip record stores full provenance and file paths back to the source recordings.

## Headless CLI transcription, Superwhisper, and speech analysis

Transcription and speech analysis run 100% locally with zero cloud processing, no paid APIs, and no GUI automation:

1. **Free Local Headless CLI Transcriber**: The cataloger supports executing a fully local headless CLI transcriber (configurable via `--transcriber <cmd>` or `FM_OSMO_TRANSCRIBER`, or autodetected local `whisper` CLI).
2. **Prior Approval Invariant**: The workflow strictly forbids downloading models or installing packages without prior user approval.
   If an audio clip requires transcription but no local model is downloaded, the clip record reports `approval_required` alongside the exact tool name, model identifier, download source, disk footprint, and execution command.
3. **Superwhisper Integration**: Superwhisper on macOS is an interactive menu bar dictation tool without a headless batch CLI.
   The skill interfaces with Superwhisper by pairing existing transcripts from Superwhisper's SQLite database (`superwhisper.sqlite`) when available, and extracting 16 kHz mono audio tracks to the local cache directory outside the device.
4. **Local Speech Metrics**: Vocal activity is measured locally using ffmpeg silence detection (`silencedetect`) and volume detection (`volumedetect`), calculating exact speech ratios and silence durations for each clip.
5. **Transcripts and Provenance**: When transcripts are generated or paired, the text is cached and factored into clip classification alongside visual and acoustic features.

## Visual sampling and classification

Clips are categorized into three standard video production roles:

- **A-roll**: Primary narrative footage, such as host presentations, dialogue, or interviews, characterized by high speech ratio (>35%) and prominent host face presence across sampled frames.
- **B-roll**: Supplemental cutaways and atmospheric footage, such as scenery, architecture, street action, or objects, characterized by low or zero vocal activity (<10%) and absence of a focal talking head.
- **Mixed**: Hybrid footage combining spoken commentary with cutaways, movement, or walk-and-talk shots, or dialogue clips containing significant scene variance.

Visual sampling extracts representative frames evenly across each clip.
On macOS, facial detection runs through Apple's built-in Vision framework (`VNDetectFaceRectanglesRequest`) via swift with zero extra dependencies and hardware acceleration.
If Apple Vision is unavailable, the classifier falls back to visual complexity, brightness, and scene variance metrics.

## Incremental caching

Processed clips are cached deterministically in `catalog-cache.json` under the cache directory.
Clips are fingerprinted by file size and modification timestamp.
Subsequent catalog runs check the cache and immediately reuse existing frame extractions, audio measurements, and classifications for unchanged files.
When clips have incomplete transcription status, providing a transcriber command or local model re-evaluates transcription while reusing already extracted frames and audio.
Passing `--force` forces re-sampling and re-classification of all clips.
The latest report is always linked at `<cache_dir>/latest-report.md` for immediate review.
