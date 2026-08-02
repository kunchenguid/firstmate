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
| public-source rejection | unsafe schemes, playlist URLs, metadata-expanded playlists, live streams, authenticated/private videos, and DRM metadata are refused |
| local-file boundary | local mode accepts only an explicit ordinary video file and refuses symlinks, non-video extensions, empty files, and oversized files |
| transcript-first planning | caption metadata causes caption retrieval before media download, and matching transcript terms narrow selected ranges before frame extraction |
| caption choice | requested language, manual captions, automatic captions, and English fallback are selected deterministically |
| frame and token budgets | default caps prefer a compact frame set, hard caps clamp excessive requests, and manifest token estimates expose the resulting cost |
| scene-plus-periodic evidence | fake scene-change output is combined with bounded periodic coverage and every selected frame records a timestamp and reason |
| focused ranges | `--start` and `--end` produce absolute focused ranges, denser allowed caps, and focused start/end frame reasons |
| manifest schema | schema, sanitized source identity, duration, chapters, transcript provenance, frames, warnings, token budget, and cleanup receipt are present |
| malformed metadata | invalid JSON from `yt-dlp` or `ffprobe` is refused without leaking raw command output |
| failure cleanup contract | extraction failures retain a quarantined owned directory only behind an opaque receipt |
| exact cleanup | cleanup requires the matching receipt, rejects receipt mismatch, refuses unsafe targets, removes only an owned temp directory, and proves absence |
| symlink/race resistance | symlinked cleanup roots and replaced ownership markers are refused |

## Real public smoke

The opt-in real smoke is intentionally impossible to trigger accidentally.
It requires both `FM_VIDEO_WATCH_REAL_SMOKE=1` and `--i-understand-this-uses-network`:

```sh
FM_VIDEO_WATCH_REAL_SMOKE=1 bin/fm-video-watch.sh smoke \
  --url 'https://www.youtube.com/watch?v=8ZgpAXe5V5w' \
  --question 'Summarize the public acceptance case with compact evidence.' \
  --max-frames 24 \
  --i-understand-this-uses-network
```

The acceptance record must retain only sanitized facts: schema, sanitized source identity, transcript provenance and language, selected range count, frame count, timestamp-alignment spot checks, warnings, and successful cleanup proof.
Downloaded media, captions, frames, signed URLs, raw command output, and local temp paths must not be committed.

Verified on 2026-08-02 on macOS with `yt-dlp` 2026.06.09 and FFmpeg/ffprobe 8.0.1:

```text
schema: fm.video-watch.manifest.v1
source: https://www.youtube.com/watch?v=8ZgpAXe5V5w
duration_seconds: 3709.0
transcript: captions:automatic, language en, selected_segment_count 116
selected_ranges: 5
frames: 24
first frame timestamp: 05:25, reason periodic_coverage
second frame timestamp: 05:27, reason scene_or_slide_change
last frame timestamp: 25:58, reason periodic_coverage
token estimate: frame 28800, transcript 2155, total 30955
warnings: video is over 10 minutes; this is sparse sampled evidence, not every frame
cleanup proof: owned evidence directory existed before cleanup, cleanup reported removed=true, and the owned directory was absent afterward
```
