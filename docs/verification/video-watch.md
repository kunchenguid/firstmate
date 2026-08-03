# Video watch verification

Audience: maintainer verification.

This record holds reusable evidence for Firstmate's `/watch` safety and manifest guarantees.
The user-facing workflow is owned by `.agents/skills/watch/SKILL.md`, and the exact mechanics, flags, limits, manifest schema, cleanup receipt, and exit codes are owned by `bin/fm-video-watch.sh --help`.

## Upstream provenance

Firstmate's implementation preserves and adapts useful mechanics from the MIT-licensed upstream skill `bradautomates/claude-video`.
The audited local installation was:

```text
repository: https://github.com/bradautomates/claude-video.git
installed revision: 755c157466738dda102c939158a0116b972925a3
commit author: bradautomates <bradley_bonanno@outlook.com>
commit date: 2026-04-24T17:22:51+10:00
commit subject: Fix Windows compatibility: encoding, installer hints, interpreter name
license: MIT, Copyright (c) 2026 Bradley Bonanno
```

Firstmate does not depend on that installed path or a floating branch at runtime.
It also does not copy the Claude plugin, Codex plugin, hook, release, installer, or Whisper-key management surfaces.

## Offline contract coverage

`tests/fm-video-watch.test.sh` exercises the public wrapper with fake `yt-dlp`, `ffprobe`, and `ffmpeg` commands.
The suite does not use network access and does not assert implementation-source bytes.

Covered guarantees include:

| Guarantee | Coverage |
| --- | --- |
| dependency checks are detect-only | `doctor` reports missing tools and the fake command log proves no installer command ran |
| URL value safety | signed query strings, cookies, and redaction canaries are absent from manifests and diagnostics |
| public-source rejection | unsafe schemes, playlist URLs, credential- or signature-bearing query fields, metadata-expanded playlists, live streams, authenticated/private videos, and DRM metadata are refused |
| fetch-target fidelity | the exact supplied public URL reaches `yt-dlp`, including identity-bearing query parameters, while the manifest description drops tracking fields and redacts every value that is not a known public identifier |
| transient media bounds | a declared size above the byte ceiling is refused before any download command runs, the default ceiling clamps to free space instead of failing, raising it above the default requires proven free space, and values above 16 GiB are refused |
| honest visual coverage | `media.visual_coverage` reports full, section, or none; a section that the provider ignores is downgraded to full with a warning, and a refused acquisition still returns transcript, chapters, and a focused-pass recommendation |
| cheaper bounded acquisition route | a focus range spanning most of the source takes the full download and says so in `media.acquisition_reason` and a warning, a small focus range still takes the bounded provider section, a declared size above the ceiling still forces the section as the only route, and the selected evidence range is identical either way |
| trustworthy size estimates | the metadata call is scoped to the same format selector the download uses, so `media.declared_bytes` describes the bytes actually fetched; measured 0.34% and 0.17% off on the two acceptance sources |
| section timestamp fidelity | frames extracted from a bounded section are seeked relative to the acquired media while manifest timestamps stay absolute |
| local-file boundary | local mode accepts only an explicit ordinary video file and refuses symlinks, non-video extensions, empty files, and oversized files |
| transcript-first planning | caption metadata causes caption retrieval before media download, and matching transcript terms narrow selected ranges before frame extraction |
| caption choice | requested language, manual captions, automatic captions, and English fallback are selected deterministically |
| frame and token budgets | default caps prefer a compact frame set, hard caps clamp excessive requests, and manifest token estimates expose the resulting cost |
| scene-plus-periodic evidence | fake scene-change output is combined with bounded periodic coverage and every selected frame records a timestamp and reason |
| whole-video extraction | the stub `ffmpeg` refuses a seek at or past the last frame, so the mocked suite can no longer hide this class; additionally, when real `ffmpeg` and `ffprobe` are present the default no-focus-range path runs end to end over a synthesized clip, every planned frame lands on disk, the final frame stays inside the last decodable frame, and cleanup proves absence, and that one case is skipped when those tools are absent |
| optional enrichment stays optional | scene-change detection that fails or does not finish degrades to periodic coverage with a warning, and caption retrieval that fails or does not finish degrades to a warning, instead of aborting the manifest |
| source-timeline range fidelity | a source that advertises no duration still honors `--start`/`--end` after a bounded section download: the focus range, the acquisition reason, and a duration disclosed as a lower bound all stay in source coordinates |
| documented exit classes | a local copy that would exhaust usable free space is refused before it starts, and any unexpected failure is reported as exit 5 by exception class alone rather than escaping as a traceback that names local paths |
| focused ranges | `--start` and `--end` produce absolute focused ranges, denser allowed caps, and focused start/end frame reasons |
| manifest schema | schema, sanitized source identity, duration, chapters, transcript provenance, frames, warnings, token budget, and cleanup receipt are present |
| malformed metadata | invalid JSON from `yt-dlp` or `ffprobe` is refused without leaking raw command output |
| failure cleanup contract | extraction failures retain a quarantined owned directory only behind an opaque receipt, and that receipt is proven to remove it; every refusal path in the suite hands its receipt back so a run leaves no owned directory in the system temp directory |
| exact cleanup | cleanup requires the matching receipt, rejects receipt mismatch, refuses unsafe targets, removes only an owned temp directory, and proves absence |
| symlink/race resistance | symlinked cleanup roots and replaced ownership markers are refused |

## Real public smoke

The opt-in real smoke is intentionally impossible to trigger accidentally.
It requires both `FM_VIDEO_WATCH_REAL_SMOKE=1` and `--i-understand-this-uses-network`:

```sh
FM_VIDEO_WATCH_REAL_SMOKE=1 bin/fm-video-watch.sh smoke \
  --url 'https://www.youtube.com/watch?v=8ZgpAXe5V5w' \
  --question 'Summarize the video' \
  --i-understand-this-uses-network
```

The acceptance record must retain only sanitized facts: schema, sanitized source identity, transcript provenance and language, selected range count, frame count, timestamp-alignment spot checks, warnings, and successful cleanup proof.
Downloaded media, captions, frames, signed URLs, raw command output, and local temp paths must not be committed.

Re-verified on 2026-08-02 on macOS with `yt-dlp` 2026.06.09 and FFmpeg/ffprobe 8.0.1, after the URL-identity, transient-media-ceiling, whole-video extraction, and acquisition-route changes.
This record was produced by the exact `smoke` invocation above, so it reports `mode: real_public_smoke` and carries the `media:` block.

```text
schema: fm.video-watch.manifest.v1
mode: real_public_smoke
source: https://www.youtube.com/watch?v=8ZgpAXe5V5w
source identity: host www.youtube.com, path /watch, query_keys [v]
title: L8 Principal's Agentic Engineering Setup (just copy him)
duration_seconds: 3709.0 (1:01:49)
transcript: captions:automatic, language en, selected_segment_count 214
selected_ranges: 1, reason full_video, 0.0-3709.0
media: acquired true, visual_coverage full, acquisition_reason no_focus_range_requested,
       byte_ceiling 4294967296, declared_bytes 164619367, downloaded_bytes 164332937, acquired_range none
declared-size accuracy: 164619367 estimated against 164332937 actual, 0.17% high
frames: 36, reasons periodic_coverage and scene_or_slide_change
first frame timestamp: 00:00
last frame timestamp: 1:01:49 (3708.94s, inside the last decodable frame)
token estimate: frame 43200, transcript 3996, total 47196
warnings: transcript evidence was truncated to the bounded manifest budget; video is over 10 minutes, this is sparse sampled evidence, not every frame
wall clock: 70s including download, caption retrieval, scene detection, and 36 extractions
cleanup proof: cleanup by exact receipt reported removed=true and the owned directory was absent afterward
```

## Whole-video versus focused acceptance

These three runs are ordinary `prepare` evidence, not the opt-in smoke path.
All used `bin/fm-video-watch.sh prepare '<url>' --question 'Summarize the video'`, the second and third adding a focus range.

```text
schema: fm.video-watch.manifest.v1
mode: prepare
source: https://www.youtube.com/watch?v=9WOpQqSO5aA
title: Real AI Agent Stack: Harness -> Loop -> Graph
duration_seconds: 559.0 (09:19), chapters 8
transcript: captions:automatic, language en, selected_segment_count 218
declared-size accuracy: 19939872 estimated against 20008710 actual, 0.34% low

default whole-video run, no focus range:
  selected_ranges: 1, reason full_video, 0.0-559.0
  media: visual_coverage full, acquisition_reason no_focus_range_requested, downloaded_bytes 20008710
  frames: 20, first 00:00, last 09:18
  warnings: transcript evidence was truncated to the bounded manifest budget
  wall clock: 18s
  result: completed, this is the path that previously failed

wide focus range, --start 00:00 --end 09:19, the whole source:
  selected_ranges: 1, reason focused_range, 0.0-559.0
  media: visual_coverage full, acquisition_reason the_full_media_is_projected_cheaper_than_a_re_encoded_section,
         downloaded_bytes 20008710, acquired_range none
  frames: 20, first 00:00, last 09:18
  warnings: the requested focus range covers enough of the source that downloading the whole media is
            cheaper than a re-encoded provider section, the selected evidence range is unchanged
  wall clock: 18s
  result: completed; the same request cost 5m22s and 32510301 bytes before the route choice landed

narrow focus range, --start 02:00 --end 03:00, 11% of the source:
  selected_ranges: 1, reason focused_range, 120.0-180.0
  media: visual_coverage section, acquisition_reason a_bounded_section_is_projected_cheaper_than_the_full_media,
         downloaded_bytes 3603554, acquired_range 120.0-180.0
  frames: 18, first 02:00, last 03:00
  warnings: visual evidence covers only the requested section 02:00-03:00, not the whole video
  wall clock: 16s
  result: completed; the bounded section still runs where it actually saves, 18% of the full download

cleanup proof: every run was removed by its exact receipt, each reporting removed=true
```

## Whole-video extraction defect and correction

The captain reported that the default no-focus-range preparation failed during frame extraction on `https://www.youtube.com/watch?v=9WOpQqSO5aA` while twelve explicit focused ranges over the same timeline succeeded.

- Trigger: `periodic_timestamps` emits a sample at exactly the range end, and on the default `full_video` path that end is the video duration.
- Masking condition: a focused range usually ends before the media does, so its samples stay inside the last decodable frame; only a range that reaches the end of the media hits the failure.
- Symptom: `ffmpeg -ss <duration>` exits non-zero and writes no file, and `extract_frame` treated that as fatal, so `prepare` exited 5 after the download had already completed.

Counterfactuals, run through the local-file path on synthesized clips so no network is involved:

```text
12s at 25fps, default frame budget
  implementation at ad44376 (before the correction): exit 5, "frame extraction failed"
  implementation at b52f31c (with tail_seek_limit): exit 0, 18 frames, last frame 11.5s of 12.0s

6s at 10fps with --max-frames 8 --resolution 128, the shape the regression test ships
  implementation at ad44376: exit 5, "frame extraction failed"
  current implementation: exit 0, every planned frame on disk, final frame inside the media

mocked suite with the strengthened stub ffmpeg, 120s fixture
  implementation at ad44376: exit 5
  current implementation: exit 0, 21 frames, last frame 119.0
```

The correction is `tail_seek_limit`, which derives the last safely seekable timestamp from the probed duration and `avg_frame_rate` rather than from a fixed margin, so a low-frame-rate source is handled too. Whole-video coverage, the duration-aware frame budget, and truthful sampling language are unchanged. `tests/fm-video-watch.test.sh` now covers this two ways: the stub `ffmpeg` refuses a seek at or past the last frame, and a real-`ffmpeg` regression test runs the default whole-video path end to end over a synthesized clip.

## Acquisition route choice

A bounded provider section is re-encoded rather than stream-copied, because `--force-keyframes-at-cuts` is required for the cut to land where the caller asked.
The earlier acceptance record measured that cost on a 559-second source: a section spanning the whole video cost 32510301 bytes and 5m22s against 20008710 bytes and 26s for the same video downloaded whole, so the mechanism meant to bound resources was inflating them.

The route is now chosen from the projected byte cost rather than taken unconditionally:

- the projected section cost is `span / duration * 1.7` of the full download, where `1.7` is the measured re-encode overhead above;
- a section is requested when that projection lands at or under 75% of the full download, which works out to spans below roughly 44% of the source;
- a declared size above the transient byte ceiling still forces the section, because it is then the only route to any visual evidence;
- an unknown duration still honors the focus range, because nothing can be projected.

The estimate is trustworthy because the metadata call now uses the same format selector as the download, so `declared_bytes` describes the bytes actually fetched instead of the best-quality formats.
The focus range itself is never altered by this choice: `selected_ranges` is identical on both routes, and taking the full media only ever widens what was acquired, which `media.visual_coverage` and `media.acquisition_reason` both state.

resolved: [key=01KZ1NPWRMTEZXYFDDXT1XT9N4] captain approved refreshed public proof and whole-video extraction correction
