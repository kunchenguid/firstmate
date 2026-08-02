#!/usr/bin/env python3
"""Private implementation for bin/fm-video-watch.sh.

The public contract lives in fm-video-watch.sh's header and this program's help
text as reached through that wrapper.
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, urlsplit, urlunsplit

SCHEMA = "fm.video-watch.manifest.v1"
OWNED_MARKER = ".fm-video-watch-owned.json"
RECEIPT_PREFIX = "fmvw1."
REQUIRED_COMMON = ("ffmpeg", "ffprobe")
REQUIRED_URL = ("yt-dlp",)
VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}
DEFAULT_MAX_FRAMES = 36
FULL_HARD_MAX_FRAMES = 60
FOCUS_HARD_MAX_FRAMES = 80
DEFAULT_RESOLUTION = 512
MAX_FULL_RESOLUTION = 768
MAX_FOCUS_RESOLUTION = 1280
DEFAULT_MAX_LOCAL_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_MAX_MEDIA_BYTES = 4 * 1024 * 1024 * 1024
HARD_MAX_MEDIA_BYTES = 16 * 1024 * 1024 * 1024
FREE_SPACE_MARGIN_BYTES = 512 * 1024 * 1024
MAX_TRANSCRIPT_CHARS = 16_000
MAX_COMMAND_SECONDS = 180
SCENE_THRESHOLD = 0.28
SCENE_TIMEOUT_FLOOR = 300
SCENE_TIMEOUT_CEILING = 900
SECRET_QUERY_KEYS = {
    "access_token",
    "api_key",
    "apikey",
    "auth",
    "authorization",
    "client_secret",
    "credential",
    "hmac",
    "key-pair-id",
    "password",
    "passwd",
    "policy",
    "pwd",
    "secret",
    "session",
    "session_id",
    "sessionid",
    "sig",
    "sign",
    "signature",
    "token",
}
SECRET_QUERY_PREFIXES = ("x-amz-", "__hdn", "__token")
TRACKING_QUERY_KEYS = {
    "ab_channel",
    "embeds_referring_euri",
    "embeds_referring_origin",
    "fbclid",
    "feature",
    "gclid",
    "msclkid",
    "ncid",
    "pp",
    "ref",
    "ref_src",
    "referrer",
    "si",
    "source_ve_path",
    "spm",
    "utm_campaign",
    "utm_content",
    "utm_id",
    "utm_medium",
    "utm_source",
    "utm_term",
}
IDENTITY_QUERY_KEYS = {
    "clip",
    "clip_id",
    "id",
    "media_id",
    "v",
    "vid",
    "video",
    "video_id",
    "videoid",
}
REDACTED_VALUE = "redacted"


class WatchError(Exception):
    def __init__(self, message: str, code: int = 5, warnings: list[str] | None = None):
        super().__init__(message)
        self.code = code
        self.warnings = warnings or []


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class Range:
    start: float
    end: float
    reason: str


def _json_dumps(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False)


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def run_quiet(cmd: list[str], timeout: int = MAX_COMMAND_SECONDS) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise WatchError(f"command timed out after {timeout}s: {Path(cmd[0]).name}", 5) from exc
    except OSError as exc:
        raise WatchError(f"could not run required command {Path(cmd[0]).name}: {exc}", 5) from exc


def which_missing(names: tuple[str, ...] | list[str]) -> list[str]:
    return [name for name in names if shutil.which(name) is None]


def require_deps(url_mode: bool) -> None:
    missing = which_missing(list(REQUIRED_COMMON) + (list(REQUIRED_URL) if url_mode else []))
    if missing:
        hints = []
        if any(name in missing for name in ("ffmpeg", "ffprobe")):
            hints.append("install ffmpeg, which provides ffmpeg and ffprobe")
        if "yt-dlp" in missing:
            hints.append("install yt-dlp")
        raise WatchError(
            "missing required dependencies: " + ", ".join(missing) + ". " + "; ".join(hints),
            3,
        )


def parse_time(value: str | None) -> float | None:
    if value is None:
        return None
    s = value.strip()
    if not s:
        return None
    if s.startswith("-"):
        raise WatchError("timestamps must be non-negative absolute times", 2)
    parts = s.split(":")
    try:
        if len(parts) == 1:
            seconds = float(parts[0])
        elif len(parts) == 2:
            seconds = int(parts[0]) * 60 + float(parts[1])
        elif len(parts) == 3:
            seconds = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        else:
            raise ValueError
    except ValueError as exc:
        raise WatchError(f"cannot parse timestamp {value!r}; use SS, MM:SS, or HH:MM:SS", 2) from exc
    if seconds < 0:
        raise WatchError("timestamps must be non-negative absolute times", 2)
    return seconds


def fmt_time(seconds: float) -> str:
    total = int(round(max(0.0, seconds)))
    hours, rem = divmod(total, 3600)
    minutes, sec = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{sec:02d}"
    return f"{minutes:02d}:{sec:02d}"


def is_public_url(source: str) -> bool:
    return urlsplit(source).scheme.lower() in {"http", "https"}


def is_secret_query_key(key: str) -> bool:
    lowered = key.lower()
    return lowered in SECRET_QUERY_KEYS or lowered.startswith(SECRET_QUERY_PREFIXES)


def describe_url(raw: str) -> dict[str, Any]:
    """Build the display-only identity for a URL that already passed the source policy.

    The fetch target stays byte-for-byte the supplied URL; only this description is
    reduced, and it never reproduces a query value that is not a known public
    resource identifier.
    """
    split = urlsplit(raw)
    query = parse_qs(split.query, keep_blank_values=True)
    display_pairs: list[tuple[str, str]] = []
    for key, values in query.items():
        lowered = key.lower()
        if lowered in TRACKING_QUERY_KEYS:
            continue
        value = values[0] if values else ""
        display_pairs.append((key, value if lowered in IDENTITY_QUERY_KEYS else REDACTED_VALUE))
    display_query = "&".join(f"{quote(k, safe='')}={quote(v, safe='')}" for k, v in display_pairs)
    host = (split.hostname or "").lower()
    sanitized = urlunsplit((split.scheme.lower(), split.netloc.lower(), split.path, display_query, ""))
    return {
        "kind": "public_url",
        "sanitized": sanitized,
        "host": host,
        "path": split.path or "/",
        "query_keys": sorted({key for key, _ in display_pairs}),
    }


def sanitize_url(raw: str) -> tuple[str, dict[str, Any]]:
    split = urlsplit(raw)
    scheme = split.scheme.lower()
    if scheme not in {"http", "https"}:
        raise WatchError("unsupported URL scheme; only public http and https video URLs are accepted", 4)
    if split.username or split.password:
        raise WatchError("URL userinfo is not accepted", 4)
    if not split.netloc:
        raise WatchError("URL host is required", 4)
    query = parse_qs(split.query, keep_blank_values=True)
    if "list" in query or "playlist" in query:
        raise WatchError("playlist URLs are rejected; provide exactly one public video URL", 4)
    if any(is_secret_query_key(key) for key in query):
        raise WatchError(
            "URL carries credential, signature, session, or token query fields; "
            "supply the plain public video URL instead of a signed or authenticated one",
            4,
        )
    return raw, describe_url(raw)


def reject_unsafe_source(source: str) -> tuple[str, dict[str, Any], bool]:
    split = urlsplit(source)
    if split.scheme and split.scheme.lower() not in {"http", "https"}:
        raise WatchError("unsupported source scheme; use a public http(s) URL or an explicit local file path", 4)
    if is_public_url(source):
        fetch_url, identity = sanitize_url(source)
        return fetch_url, identity, True
    return source, {"kind": "local_file", "sanitized": Path(source).name}, False


def validate_local(source: str, max_local_bytes: int) -> Path:
    path = Path(source).expanduser()
    try:
        st = path.lstat()
    except FileNotFoundError as exc:
        raise WatchError("local video file was not found", 2) from exc
    if path.is_symlink():
        raise WatchError("local video file must be an explicit regular file, not a symlink", 4)
    if not path.is_file():
        raise WatchError("local video source must be an explicit regular file", 4)
    if st.st_size <= 0:
        raise WatchError("local video file is empty", 4)
    if st.st_size > max_local_bytes:
        raise WatchError(
            f"local video file is larger than the configured safety limit ({max_local_bytes} bytes)",
            4,
        )
    if path.suffix.lower() not in VIDEO_EXTS:
        raise WatchError("local file extension is not a supported video type", 4)
    return path.resolve(strict=True)


def make_workdir() -> tuple[Path, str]:
    root = Path(tempfile.mkdtemp(prefix="fm-video-watch-")).resolve(strict=True)
    nonce = uuid.uuid4().hex
    marker = {"schema": "fm.video-watch.owned.v1", "nonce": nonce}
    marker_path = root / OWNED_MARKER
    marker_path.write_text(_json_dumps(marker) + "\n", encoding="utf-8")
    marker_path.chmod(0o600)
    return root, nonce


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)


def make_receipt(root: Path, nonce: str) -> str:
    payload = {"schema": "fm.video-watch.receipt.v1", "root": str(root), "nonce": nonce}
    return RECEIPT_PREFIX + b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))


def decode_receipt(receipt: str) -> tuple[Path, str]:
    if not receipt.startswith(RECEIPT_PREFIX):
        raise WatchError("cleanup receipt is not a Firstmate video-watch receipt", 2)
    try:
        payload = json.loads(b64url_decode(receipt[len(RECEIPT_PREFIX):]).decode("utf-8"))
    except Exception as exc:
        raise WatchError("cleanup receipt is malformed", 2) from exc
    if payload.get("schema") != "fm.video-watch.receipt.v1":
        raise WatchError("cleanup receipt schema is unsupported", 2)
    root = Path(str(payload.get("root") or ""))
    nonce = str(payload.get("nonce") or "")
    if not root.is_absolute() or not nonce:
        raise WatchError("cleanup receipt is incomplete", 2)
    return root, nonce


def verify_owned_root(root: Path, nonce: str) -> None:
    try:
        resolved = root.resolve(strict=True)
    except FileNotFoundError as exc:
        raise WatchError("cleanup target no longer exists", 5) from exc
    if resolved != root:
        raise WatchError("cleanup target must be the exact owned temporary directory", 4)
    temp_root = Path(tempfile.gettempdir()).resolve(strict=True)
    try:
        resolved.relative_to(temp_root)
    except ValueError as exc:
        raise WatchError("cleanup target is outside the system temporary directory", 4) from exc
    if not root.name.startswith("fm-video-watch-"):
        raise WatchError("cleanup target is not a Firstmate video-watch directory", 4)
    if root.is_symlink() or not root.is_dir():
        raise WatchError("cleanup target is not an ordinary owned directory", 4)
    marker = root / OWNED_MARKER
    if marker.is_symlink() or not marker.is_file():
        raise WatchError("cleanup ownership marker is missing or unsafe", 4)
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except Exception as exc:
        raise WatchError("cleanup ownership marker is unreadable", 4) from exc
    if data.get("schema") != "fm.video-watch.owned.v1" or data.get("nonce") != nonce:
        raise WatchError("cleanup receipt does not match the owned evidence directory", 4)


def cmd_cleanup(args: argparse.Namespace) -> int:
    root, nonce = decode_receipt(args.receipt)
    verify_owned_root(root, nonce)
    shutil.rmtree(root)
    if root.exists():
        raise WatchError("cleanup could not prove the evidence directory was removed", 5)
    print(_json_dumps({"schema": "fm.video-watch.cleanup.v1", "removed": True, "receipt": args.receipt}))
    return 0


def cmd_doctor(_args: argparse.Namespace) -> int:
    missing = which_missing(list(REQUIRED_COMMON) + list(REQUIRED_URL))
    status = {
        "schema": "fm.video-watch.doctor.v1",
        "ready": not missing,
        "missing_dependencies": missing,
        "install_hint": "Install ffmpeg (for ffmpeg and ffprobe) and yt-dlp. Firstmate never auto-installs them.",
        "auto_install_attempted": False,
    }
    print(_json_dumps(status))
    return 0 if not missing else 3


def load_ytdlp_metadata(url: str) -> dict[str, Any]:
    cmd = [
        "yt-dlp",
        "--dump-single-json",
        "--skip-download",
        "--no-playlist",
        "--no-warnings",
        url,
    ]
    result = run_quiet(cmd)
    if result.returncode != 0:
        raise WatchError("public video metadata was unavailable without login or was unsupported", 4)
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise WatchError("public video metadata was malformed", 5) from exc
    if not isinstance(data, dict):
        raise WatchError("public video metadata was malformed", 5)
    reject_metadata(data)
    return data


def reject_metadata(data: dict[str, Any]) -> None:
    if data.get("_type") in {"playlist", "multi_video"} or data.get("playlist_count") or data.get("entries"):
        raise WatchError("source expanded to more than one video; playlists are rejected", 4)
    if data.get("is_live") or str(data.get("live_status") or "").lower() in {"is_live", "is_upcoming", "post_live"}:
        raise WatchError("live or upcoming streams are rejected", 4)
    availability = str(data.get("availability") or "").lower()
    if availability and availability not in {"public", "unlisted"}:
        raise WatchError("authenticated, private, subscriber-only, or DRM video sources are rejected", 4)
    if data.get("drm") or data.get("has_drm"):
        raise WatchError("DRM-protected video sources are rejected", 4)


def normalize_chapters(raw: Any, duration: float) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if isinstance(raw, list):
        for chapter in raw[:80]:
            if not isinstance(chapter, dict):
                continue
            start = safe_float(chapter.get("start_time"), 0.0)
            end = safe_float(chapter.get("end_time"), duration)
            title = str(chapter.get("title") or "").strip()[:120]
            if end <= start:
                continue
            out.append({"start_seconds": round(start, 2), "end_seconds": round(end, 2), "title": title})
    return out


def safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        value = float(value)
        if math.isnan(value) or math.isinf(value):
            return default
        return value
    except (TypeError, ValueError):
        return default


def parse_frame_rate(stream: dict[str, Any]) -> float:
    for key in ("avg_frame_rate", "r_frame_rate"):
        raw = str(stream.get(key) or "")
        if "/" not in raw:
            continue
        num, _, den = raw.partition("/")
        numerator = safe_float(num, 0.0)
        denominator = safe_float(den, 0.0)
        if numerator > 0 and denominator > 0:
            return numerator / denominator
    return 0.0


def tail_seek_limit(duration: float, frame_rate: float) -> float:
    """Last timestamp that ffmpeg can still decode a frame at.

    Seeking at or past the final frame's presentation time makes ffmpeg exit
    non-zero without writing a file, so keep one safe frame of slack.
    """
    frame_gap = 1.0 / frame_rate if frame_rate > 0 else 0.5
    return max(0.0, duration - max(2 * frame_gap, 0.5))


def probe_video(path: Path) -> dict[str, Any]:
    result = run_quiet([
        "ffprobe",
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(path),
    ])
    if result.returncode != 0:
        raise WatchError("video probing failed", 5)
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise WatchError("video metadata was malformed", 5) from exc
    streams = data.get("streams") if isinstance(data.get("streams"), list) else []
    fmt = data.get("format") if isinstance(data.get("format"), dict) else {}
    video_stream = next((s for s in streams if isinstance(s, dict) and s.get("codec_type") == "video"), {})
    if not video_stream:
        raise WatchError("video file has no video stream", 4)
    duration = safe_float(fmt.get("duration") or video_stream.get("duration"), 0.0)
    if duration <= 0:
        raise WatchError("video duration could not be determined", 5)
    return {
        "duration_seconds": duration,
        "frame_rate": parse_frame_rate(video_stream),
        "width": video_stream.get("width"),
        "height": video_stream.get("height"),
        "codec": video_stream.get("codec_name"),
        "size_bytes": int(safe_float(fmt.get("size"), 0.0)),
        "has_audio": any(isinstance(s, dict) and s.get("codec_type") == "audio" for s in streams),
    }


def choose_caption(metadata: dict[str, Any], requested: str | None) -> tuple[str | None, str | None, str | None]:
    requested = requested or "en"
    subtitles = metadata.get("subtitles") if isinstance(metadata.get("subtitles"), dict) else {}
    automatic = metadata.get("automatic_captions") if isinstance(metadata.get("automatic_captions"), dict) else {}
    preference = [requested, "en", "en-US", "en-GB", "en-orig"]
    seen: set[str] = set()
    for lang in preference + sorted(subtitles) + sorted(automatic):
        if lang in seen:
            continue
        seen.add(lang)
        if lang in subtitles:
            return lang, "manual", lang
        if lang in automatic:
            return lang, "automatic", lang
    return None, None, None


def retrieve_captions(url: str, work: Path, lang: str) -> Path | None:
    out_dir = work / "captions"
    out_dir.mkdir(parents=True, exist_ok=True)
    template = str(out_dir / "caption.%(ext)s")
    cmd = [
        "yt-dlp",
        "--skip-download",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        lang,
        "--sub-format",
        "vtt",
        "--convert-subs",
        "vtt",
        "--no-playlist",
        "--no-warnings",
        "-o",
        template,
        url,
    ]
    result = run_quiet(cmd)
    candidates = sorted(out_dir.glob("*.vtt"))
    if result.returncode != 0 and not candidates:
        return None
    return candidates[0] if candidates else None


TS_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[.,](\d{3})")
TAG_RE = re.compile(r"<[^>]+>")


def _to_seconds(parts: tuple[str, str, str, str]) -> float:
    h, m, s, ms = parts
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_vtt(path: Path) -> list[Segment]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    segments: list[Segment] = []
    i = 0
    while i < len(lines):
        match = TS_RE.match(lines[i])
        if not match:
            i += 1
            continue
        start = _to_seconds(match.groups()[:4])
        end = _to_seconds(match.groups()[4:])
        i += 1
        cue_lines: list[str] = []
        while i < len(lines) and lines[i].strip():
            cleaned = TAG_RE.sub("", lines[i]).strip()
            if cleaned:
                cue_lines.append(cleaned)
            i += 1
        cue = " ".join(cue_lines).strip()
        if cue:
            segments.append(Segment(round(start, 2), round(end, 2), cue))
        i += 1
    return dedupe_segments(segments)


def dedupe_segments(segments: list[Segment]) -> list[Segment]:
    out: list[Segment] = []
    for seg in segments:
        if out and seg.text == out[-1].text:
            prev = out[-1]
            out[-1] = Segment(prev.start, seg.end, prev.text)
            continue
        if out and seg.text.startswith(out[-1].text + " "):
            prev = out[-1]
            out[-1] = Segment(prev.start, seg.end, seg.text)
            continue
        out.append(seg)
    return out


def query_terms(question: str | None) -> set[str]:
    if not question:
        return set()
    stop = {"about", "what", "when", "where", "which", "there", "their", "this", "that", "does", "with", "from", "the", "how", "why", "who", "can", "summarize", "summary", "video"}
    return {token for token in re.findall(r"[a-z0-9]{3,}", question.lower()) if token not in stop}


def clip_range(start: float, end: float, duration: float) -> Range | None:
    start = max(0.0, min(duration, start))
    end = max(0.0, min(duration, end))
    if end <= start:
        return None
    return Range(round(start, 2), round(end, 2), "transcript_match")


def merge_ranges(ranges: list[Range], duration: float, max_ranges: int = 5) -> list[Range]:
    normalized = sorted([r for r in ranges if r.end > r.start], key=lambda r: r.start)
    merged: list[Range] = []
    for r in normalized:
        if not merged or r.start > merged[-1].end + 5:
            merged.append(r)
        else:
            prev = merged[-1]
            reason = prev.reason if prev.reason == r.reason else f"{prev.reason}+{r.reason}"
            merged[-1] = Range(prev.start, max(prev.end, r.end), reason)
    if not merged:
        return [Range(0.0, duration, "full_video")]
    return merged[:max_ranges]


def select_ranges(
    duration: float,
    segments: list[Segment],
    chapters: list[dict[str, Any]],
    question: str | None,
    start: float | None,
    end: float | None,
) -> list[Range]:
    if start is not None or end is not None:
        lo = start if start is not None else 0.0
        hi = end if end is not None else duration
        if lo >= duration:
            raise WatchError("--start is at or after the end of the video", 2)
        if hi <= lo:
            raise WatchError("--end must be greater than --start", 2)
        return [Range(round(lo, 2), round(min(hi, duration), 2), "focused_range")]
    terms = query_terms(question)
    ranges: list[Range] = []
    if terms and segments:
        for seg in segments:
            lower = seg.text.lower()
            if any(term in lower for term in terms):
                clipped = clip_range(seg.start - 20, seg.end + 20, duration)
                if clipped:
                    ranges.append(clipped)
    if terms and chapters:
        for chapter in chapters:
            title = str(chapter.get("title") or "").lower()
            if any(term in title for term in terms):
                ranges.append(Range(float(chapter["start_seconds"]), float(chapter["end_seconds"]), "chapter_match"))
    if ranges:
        return merge_ranges(ranges, duration)
    return [Range(0.0, duration, "full_video")]


def transcript_excerpt(segments: list[Segment], ranges: list[Range]) -> tuple[list[dict[str, Any]], bool]:
    selected: list[dict[str, Any]] = []
    chars = 0
    truncated = False
    for seg in segments:
        if not any(seg.end >= r.start and seg.start <= r.end for r in ranges):
            continue
        text = seg.text.strip()
        chars += len(text)
        if chars > MAX_TRANSCRIPT_CHARS:
            truncated = True
            break
        selected.append({"start_seconds": seg.start, "end_seconds": seg.end, "text": text})
    return selected, truncated


@dataclass
class Media:
    path: Path | None
    coverage: str
    byte_ceiling: int
    declared_bytes: int | None = None
    downloaded_bytes: int | None = None
    section: tuple[float, float] | None = None
    offset_seconds: float = 0.0
    refusal: str | None = None


def resolve_media_ceiling(requested: int | None, work: Path, warnings: list[str]) -> int:
    ceiling = DEFAULT_MAX_MEDIA_BYTES if requested is None else requested
    if ceiling <= 0:
        raise WatchError("--max-media-bytes must be positive", 2)
    if ceiling > HARD_MAX_MEDIA_BYTES:
        raise WatchError(
            f"--max-media-bytes cannot exceed the {HARD_MAX_MEDIA_BYTES} byte hard cap for transient public media",
            2,
        )
    usable = max(0, shutil.disk_usage(work).free - FREE_SPACE_MARGIN_BYTES)
    if ceiling > DEFAULT_MAX_MEDIA_BYTES and ceiling > usable:
        raise WatchError(
            "a transient media ceiling above the 4 GiB default requires proven local free space; "
            f"only {usable} usable bytes are available",
            2,
        )
    if ceiling > usable:
        warnings.append(
            f"transient media ceiling reduced to {usable} bytes because local free space is the binding limit"
        )
        ceiling = usable
    if ceiling <= 0:
        raise WatchError("no usable local free space remains for transient media", 5)
    return ceiling


def declared_media_bytes(metadata: dict[str, Any]) -> int | None:
    for key in ("filesize", "filesize_approx"):
        value = safe_float(metadata.get(key), 0.0)
        if value > 0:
            return int(value)
    return None


def purge_media(out_dir: Path) -> None:
    if out_dir.exists():
        shutil.rmtree(out_dir, ignore_errors=True)


def run_ytdlp_download(
    url: str, out_dir: Path, max_bytes: int, section: tuple[float, float] | None
) -> tuple[Path | None, bool, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "yt-dlp",
        "-f",
        "bv*[height<=720]+ba/b[height<=720]/bv+ba/b",
        "--merge-output-format",
        "mp4",
        "--no-playlist",
        "--no-warnings",
        "--max-filesize",
        str(max_bytes),
    ]
    if section is not None:
        cmd += [
            "--download-sections",
            f"*{section[0]:.3f}-{section[1]:.3f}",
            "--force-keyframes-at-cuts",
        ]
    cmd += ["-o", str(out_dir / "video.%(ext)s"), url]
    result = run_quiet(cmd, timeout=600)
    videos = sorted([p for p in out_dir.glob("video.*") if p.suffix.lower() in VIDEO_EXTS])
    hit_ceiling = "max-filesize" in (result.stderr or "").lower() or "max-filesize" in (result.stdout or "").lower()
    return (videos[0] if videos else None), hit_ceiling, result.returncode


def acquire_media(
    url: str,
    work: Path,
    ceiling: int,
    declared: int | None,
    section: tuple[float, float] | None,
    warnings: list[str],
) -> Media:
    out_dir = work / "media"
    if section is not None:
        path, hit_ceiling, _ = run_ytdlp_download(url, out_dir, ceiling, section)
        if path is not None:
            return bound_downloaded_media(
                Media(path, "section", ceiling, declared, section=section, offset_seconds=section[0]),
                out_dir,
                warnings,
            )
        purge_media(out_dir)
        if hit_ceiling:
            return Media(
                None,
                "none",
                ceiling,
                declared,
                refusal=(
                    "the provider could not deliver a bounded section and the full media exceeds the "
                    "transient byte ceiling, so no video was downloaded"
                ),
            )
        warnings.append(
            "the provider could not deliver a bounded section download; a full media pass was attempted "
            "within the transient byte ceiling"
        )
    if declared is not None and declared > ceiling:
        purge_media(out_dir)
        return Media(
            None,
            "none",
            ceiling,
            declared,
            refusal="the declared public media size exceeds the transient byte ceiling, so no video was downloaded",
        )
    path, hit_ceiling, returncode = run_ytdlp_download(url, out_dir, ceiling, None)
    if path is None:
        purge_media(out_dir)
        if hit_ceiling:
            return Media(
                None,
                "none",
                ceiling,
                declared,
                refusal="the public media size exceeds the transient byte ceiling, so no video was downloaded",
            )
        if returncode != 0:
            raise WatchError("public video download failed without safe public access", 4)
        raise WatchError("public video download produced no video file", 5)
    return bound_downloaded_media(Media(path, "full", ceiling, declared), out_dir, warnings)


def bound_downloaded_media(media: Media, out_dir: Path, warnings: list[str]) -> Media:
    if media.path is None:
        return media
    downloaded = media.path.stat().st_size
    if downloaded <= 0:
        purge_media(out_dir)
        raise WatchError("public video download produced no usable media", 5)
    if downloaded > media.byte_ceiling:
        purge_media(out_dir)
        warnings.append(
            "the acquired public media exceeded the transient byte ceiling and its partial artifacts were removed"
        )
        return Media(
            None,
            "none",
            media.byte_ceiling,
            media.declared_bytes,
            refusal="the acquired public media exceeded the transient byte ceiling, so no video evidence was kept",
        )
    media.downloaded_bytes = downloaded
    return media


def confirm_section_media(media: Media, probed_duration: float, warnings: list[str]) -> Media:
    if media.coverage != "section" or media.section is None:
        return media
    span = media.section[1] - media.section[0]
    if probed_duration <= span + max(5.0, 0.25 * span):
        return media
    warnings.append(
        "the provider ignored the bounded section request and returned full media; "
        "frame timestamps remain absolute"
    )
    media.coverage = "full"
    media.section = None
    media.offset_seconds = 0.0
    return media


def scene_timestamp_timeout(span: float) -> int:
    return int(min(SCENE_TIMEOUT_CEILING, max(SCENE_TIMEOUT_FLOOR, span + 120)))


def scene_timeout(selected: Range) -> int:
    return scene_timestamp_timeout(max(0.0, selected.end - selected.start))


def scene_timestamps(video: Path, ranges: list[Range], offset: float = 0.0) -> tuple[list[float], list[str]]:
    warnings: list[str] = []
    timestamps: list[float] = []
    for selected in ranges:
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "info",
            "-ss",
            f"{max(0.0, selected.start - offset):.3f}",
            "-to",
            f"{max(0.0, selected.end - offset):.3f}",
            "-i",
            str(video),
            "-vf",
            f"select='gt(scene,{SCENE_THRESHOLD})',showinfo",
            "-an",
            "-f",
            "null",
            "-",
        ]
        try:
            result = run_quiet(cmd, timeout=scene_timeout(selected))
        except WatchError:
            warnings.append("scene-change detection did not finish for at least one selected range; periodic coverage was still used")
            continue
        if result.returncode != 0:
            warnings.append("scene-change detection failed for at least one selected range; periodic coverage was still used")
            continue
        for match in re.finditer(r"pts_time:([0-9]+(?:\.[0-9]+)?)", result.stderr):
            timestamps.append(round(selected.start + float(match.group(1)), 2))
    return sorted(set(timestamps)), warnings


def periodic_timestamps(ranges: list[Range], budget: int) -> list[float]:
    total_duration = sum(max(0.0, r.end - r.start) for r in ranges)
    if total_duration <= 0:
        return []
    points: list[float] = []
    periodic_budget = max(1, budget)
    for r in ranges:
        share = max(1, round(periodic_budget * ((r.end - r.start) / total_duration)))
        if share == 1:
            points.append(round((r.start + r.end) / 2, 2))
            continue
        step = (r.end - r.start) / (share - 1)
        for i in range(share):
            points.append(round(min(r.end, r.start + i * step), 2))
    return sorted(set(points))


def combine_frame_plan(ranges: list[Range], scenes: list[float], max_frames: int) -> list[dict[str, Any]]:
    periodic = periodic_timestamps(ranges, max(1, max_frames // 2))
    candidates: list[dict[str, Any]] = []
    for t in periodic:
        candidates.append({"timestamp_seconds": t, "reason": "periodic_coverage"})
    min_gap = max(1.0, sum(r.end - r.start for r in ranges) / max(max_frames, 1) / 2)
    last_scene = -9999.0
    for t in scenes:
        if not any(r.start <= t <= r.end for r in ranges):
            continue
        if t - last_scene < min_gap:
            continue
        candidates.append({"timestamp_seconds": t, "reason": "scene_or_slide_change"})
        last_scene = t
    focused = ranges and ranges[0].reason == "focused_range"
    if focused:
        for r in ranges:
            candidates.append({"timestamp_seconds": r.start, "reason": "focused_range_start"})
            candidates.append({"timestamp_seconds": max(r.start, r.end - 0.01), "reason": "focused_range_end"})
    by_time: dict[float, str] = {}
    for item in sorted(candidates, key=lambda x: (x["timestamp_seconds"], x["reason"])):
        t = round(float(item["timestamp_seconds"]), 2)
        reason = str(item["reason"])
        if t in by_time:
            if reason not in by_time[t]:
                by_time[t] = by_time[t] + "+" + reason
        else:
            by_time[t] = reason
    items = [{"timestamp_seconds": t, "reason": reason} for t, reason in sorted(by_time.items())]
    if len(items) <= max_frames:
        return items
    # Keep a stable spread across the selected evidence instead of the first N frames.
    chosen: list[dict[str, Any]] = []
    for i in range(max_frames):
        idx = round(i * (len(items) - 1) / max(max_frames - 1, 1))
        chosen.append(items[idx])
    dedup: dict[float, dict[str, Any]] = {item["timestamp_seconds"]: item for item in chosen}
    return [dedup[t] for t in sorted(dedup)]


def extract_frame(video: Path, out_path: Path, timestamp: float, resolution: int) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    result = run_quiet([
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{timestamp:.3f}",
        "-i",
        str(video),
        "-frames:v",
        "1",
        "-vf",
        f"scale={resolution}:-2",
        "-q:v",
        "4",
        str(out_path),
    ])
    if result.returncode != 0 or not out_path.exists() or out_path.stat().st_size <= 0:
        raise WatchError("frame extraction failed", 5)


def extract_frames(
    video: Path,
    work: Path,
    plan: list[dict[str, Any]],
    resolution: int,
    offset: float = 0.0,
    last_decodable: float | None = None,
) -> list[dict[str, Any]]:
    frames: list[dict[str, Any]] = []
    frame_dir = work / "frames"
    frame_dir.mkdir(parents=True, exist_ok=True)
    seen: set[float] = set()
    for item in plan:
        timestamp = float(item["timestamp_seconds"])
        if last_decodable is not None:
            timestamp = min(timestamp, offset + last_decodable)
        timestamp = round(max(offset, timestamp), 2)
        if timestamp in seen:
            continue
        seen.add(timestamp)
        idx = len(frames) + 1
        out_path = frame_dir / f"frame_{idx:04d}.jpg"
        extract_frame(video, out_path, max(0.0, timestamp - offset), resolution)
        frames.append({
            "index": idx,
            "path": str(out_path),
            "timestamp_seconds": timestamp,
            "timestamp": fmt_time(timestamp),
            "reason": item["reason"],
        })
    return frames


def clamp_requested_limits(args: argparse.Namespace, focused: bool, warnings: list[str]) -> tuple[int, int]:
    hard_max = FOCUS_HARD_MAX_FRAMES if focused else FULL_HARD_MAX_FRAMES
    max_frames = args.max_frames if args.max_frames is not None else DEFAULT_MAX_FRAMES
    if max_frames <= 0:
        raise WatchError("--max-frames must be positive", 2)
    if max_frames > hard_max:
        warnings.append(f"requested frame cap exceeded the hard cap; using {hard_max} frames")
        max_frames = hard_max
    res_hard = MAX_FOCUS_RESOLUTION if focused else MAX_FULL_RESOLUTION
    resolution = args.resolution
    if resolution <= 0:
        raise WatchError("--resolution must be positive", 2)
    if resolution > res_hard:
        warnings.append(f"requested resolution exceeded the hard cap; using {res_hard}px wide")
        resolution = res_hard
    return max_frames, resolution


def source_title(metadata: dict[str, Any], local_path: Path | None) -> str | None:
    if local_path is not None:
        return local_path.name
    title = metadata.get("title")
    return str(title)[:200] if title else None


def requested_section(
    start: float | None, end: float | None, duration: float
) -> tuple[float, float] | None:
    if start is None and end is None:
        return None
    lo = start if start is not None else 0.0
    hi = end if end is not None else (duration if duration > 0 else None)
    if hi is None or hi <= lo:
        return None
    return (lo, hi)


def focused_pass_recommendation(ranges: list[Range], duration: float) -> str:
    anchor = ranges[0] if ranges else Range(0.0, duration, "full_video")
    lo = anchor.start
    hi = min(duration, lo + 300.0) if duration > 0 else lo + 300.0
    return (
        "no visual frames were acquired within the transient media ceiling; re-run one focused pass with "
        f"--start {fmt_time(lo)} --end {fmt_time(hi)}, or raise --max-media-bytes if the local disk allows it"
    )


def build_manifest(args: argparse.Namespace, smoke_mode: bool = False) -> dict[str, Any]:
    fetch_source, source_identity, url_mode = reject_unsafe_source(args.source)
    require_deps(url_mode)
    warnings: list[str] = []
    start = parse_time(args.start)
    end = parse_time(args.end)
    if start is not None and end is not None and end <= start:
        raise WatchError("--end must be greater than --start", 2)
    focused = start is not None or end is not None
    max_frames, resolution = clamp_requested_limits(args, focused, warnings)
    work, nonce = make_workdir()
    receipt = make_receipt(work, nonce)
    metadata: dict[str, Any] = {}
    transcript_segments: list[Segment] = []
    transcript_language: str | None = None
    transcript_provenance = "none"
    local_path: Path | None = None
    media = Media(None, "none", 0)
    try:
        if url_mode:
            ceiling = resolve_media_ceiling(args.max_media_bytes, work, warnings)
            metadata = load_ytdlp_metadata(fetch_source)
            transcript_language, caption_kind, caption_lang = choose_caption(metadata, args.caption_lang)
            if caption_lang:
                caption_path = retrieve_captions(fetch_source, work, caption_lang)
                if caption_path:
                    transcript_segments = parse_vtt(caption_path)
                    transcript_provenance = f"captions:{caption_kind}"
                else:
                    warnings.append("caption metadata existed but caption retrieval produced no VTT file")
            else:
                warnings.append("no compatible public captions were advertised; remote transcription is disabled in v1")
            media = acquire_media(
                fetch_source,
                work,
                ceiling,
                declared_media_bytes(metadata),
                requested_section(start, end, safe_float(metadata.get("duration"), 0.0)),
                warnings,
            )
        else:
            local_path = validate_local(fetch_source, args.max_local_bytes)
            media_dir = work / "media"
            media_dir.mkdir(parents=True, exist_ok=True)
            local_copy = media_dir / f"local{local_path.suffix.lower()}"
            shutil.copy2(local_path, local_copy)
            media = Media(
                local_copy,
                "full",
                args.max_local_bytes,
                declared_bytes=local_copy.stat().st_size,
                downloaded_bytes=local_copy.stat().st_size,
            )
            warnings.append("local-file transcription is not enabled in v1 unless captions are separately supported later")
        video_path = media.path
        if video_path is not None:
            probed = probe_video(video_path)
            media = confirm_section_media(media, float(probed["duration_seconds"]), warnings)
        else:
            probed = {}
        duration = safe_float(metadata.get("duration"), 0.0) or float(probed.get("duration_seconds", 0.0))
        if duration <= 0:
            raise WatchError("video duration could not be determined", 5)
        chapters = normalize_chapters(metadata.get("chapters"), duration)
        ranges = select_ranges(duration, transcript_segments, chapters, args.question, start, end)
        max_frames, resolution = clamp_requested_limits(args, ranges[0].reason == "focused_range", warnings)
        selected_transcript, transcript_truncated = transcript_excerpt(transcript_segments, ranges)
        if transcript_truncated:
            warnings.append("transcript evidence was truncated to the bounded manifest budget")
        frames: list[dict[str, Any]] = []
        recommendation: str | None = None
        if video_path is not None:
            scenes, scene_warnings = scene_timestamps(video_path, ranges, media.offset_seconds)
            warnings.extend(scene_warnings)
            plan = combine_frame_plan(ranges, scenes, max_frames)
            if not plan:
                raise WatchError("frame planning produced no evidence frames", 5)
            frames = extract_frames(
                video_path,
                work,
                plan,
                resolution,
                media.offset_seconds,
                tail_seek_limit(float(probed["duration_seconds"]), float(probed.get("frame_rate") or 0.0)),
            )
        else:
            recommendation = focused_pass_recommendation(ranges, duration)
            warnings.append(media.refusal or "no visual evidence was acquired for this source")
            warnings.append(
                "this manifest carries transcript and chapter evidence only; do not claim any visual coverage"
            )
        if media.coverage == "section" and media.section is not None:
            warnings.append(
                "visual evidence covers only the requested section "
                f"{fmt_time(media.section[0])}-{fmt_time(media.section[1])}, not the whole video"
            )
        if duration > 600 and not focused and frames:
            warnings.append("video is over 10 minutes; this is sparse sampled evidence, not every frame")
        frame_token_estimate = int(len(frames) * 1200 * (resolution / 512) ** 2)
        transcript_chars = sum(len(seg["text"]) for seg in selected_transcript)
        manifest = {
            "schema": SCHEMA,
            "mode": "real_public_smoke" if smoke_mode else "prepare",
            "source": source_identity,
            "title": source_title(metadata, local_path),
            "duration_seconds": round(duration, 2),
            "duration": fmt_time(duration),
            "chapters": chapters,
            "selected_ranges": [
                {"start_seconds": r.start, "end_seconds": r.end, "reason": r.reason} for r in ranges
            ],
            "transcript": {
                "available": bool(transcript_segments),
                "provenance": transcript_provenance,
                "language": transcript_language,
                "selected_segment_count": len(selected_transcript),
                "segments": selected_transcript,
                "remote_transcription": "disabled",
            },
            "media": {
                "acquired": video_path is not None,
                "visual_coverage": media.coverage,
                "byte_ceiling": media.byte_ceiling,
                "declared_bytes": media.declared_bytes,
                "downloaded_bytes": media.downloaded_bytes,
                "acquired_range": (
                    {"start_seconds": round(media.section[0], 2), "end_seconds": round(media.section[1], 2)}
                    if media.coverage == "section" and media.section is not None
                    else None
                ),
                "focused_pass_recommendation": recommendation,
            },
            "frames": frames,
            "token_budget": {
                "estimated_frame_tokens": frame_token_estimate,
                "estimated_transcript_tokens": math.ceil(transcript_chars / 4),
                "estimated_total_tokens": frame_token_estimate + math.ceil(transcript_chars / 4),
                "max_frames": max_frames,
                "resolution_px_wide": resolution,
                "batching_guidance": "Read frames in batches of 10-20 and cite timestamps; re-run focused with --start/--end if a sampled range is insufficient.",
            },
            "warnings": sorted(set(warnings)),
            "cleanup_receipt": receipt,
        }
        (work / "manifest.json").write_text(_json_dumps(manifest) + "\n", encoding="utf-8")
        return manifest
    except Exception:
        # Keep the quarantined evidence directory for diagnosis but never print raw source details.
        if work.exists():
            eprint(f"fm-video-watch: evidence retained for cleanup with receipt {receipt}")
        raise


def cmd_prepare(args: argparse.Namespace) -> int:
    manifest = build_manifest(args)
    print(_json_dumps(manifest))
    return 0


def cmd_smoke(args: argparse.Namespace) -> int:
    if os.environ.get("FM_VIDEO_WATCH_REAL_SMOKE") != "1" or not args.i_understand_this_uses_network:
        raise WatchError(
            "real public smoke is opt-in only; set FM_VIDEO_WATCH_REAL_SMOKE=1 and pass --i-understand-this-uses-network",
            2,
        )
    args.source = args.url
    manifest = build_manifest(args, smoke_mode=True)
    print(_json_dumps(manifest))
    return 0


def add_prepare_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("source", nargs="?", help="One public video URL or one explicit local video file path")
    parser.add_argument("--question", default=None, help="Analysis request used to select transcript windows and evidence ranges")
    parser.add_argument("--start", default=None, help="Absolute focus start timestamp: SS, MM:SS, or HH:MM:SS")
    parser.add_argument("--end", default=None, help="Absolute focus end timestamp: SS, MM:SS, or HH:MM:SS")
    parser.add_argument("--max-frames", type=int, default=None, help="Frame cap. Default 36; hard cap 60 full video or 80 focused.")
    parser.add_argument("--resolution", type=int, default=DEFAULT_RESOLUTION, help="Frame width in pixels. Default 512; hard cap 768 full or 1280 focused.")
    parser.add_argument("--caption-lang", default=None, help="Preferred caption language, default en with compatible fallbacks")
    parser.add_argument("--max-local-bytes", type=int, default=DEFAULT_MAX_LOCAL_BYTES, help="Safety limit for explicit local video files")
    parser.add_argument(
        "--max-media-bytes",
        type=int,
        default=None,
        help=(
            "Transient public-media byte ceiling. Default 4 GiB; explicit values up to 16 GiB are honored "
            "only when local free space proves sufficient. Sources declared above the ceiling are refused "
            "before download and return transcript and chapter evidence with a focused-pass recommendation."
        ),
    )


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fm-video-watch.sh",
        description="Prepare safe, bounded video evidence manifests for Firstmate /watch.",
        epilog=(
            "The manifest is sparse evidence: it reports sampled frames and transcript windows, "
            "not a claim that every frame was watched. Public URL mode uses yt-dlp only, with "
            "no browser profiles, cookies, login state, headers, or extensions. The supplied public "
            "URL is fetched exactly as given; only the manifest description redacts query values, and "
            "credential, signature, session, or token query fields are refused outright. Public media "
            "is bounded by a transient byte ceiling both before download and after acquisition, focused "
            "runs request a bounded section when the provider supports one, and media.visual_coverage "
            "reports whether the evidence is full, section-only, or absent. Missing dependencies "
            "are reported; no installer is run. Remote transcription is disabled in v1."
        ),
    )
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="Detect dependencies only; never install anything").set_defaults(func=cmd_doctor)
    prepare = sub.add_parser("prepare", help="Create one value-safe manifest and evidence directory")
    add_prepare_options(prepare)
    prepare.set_defaults(func=cmd_prepare)
    cleanup = sub.add_parser("cleanup", help="Remove exactly one owned evidence directory using its opaque receipt")
    cleanup.add_argument("receipt")
    cleanup.set_defaults(func=cmd_cleanup)
    smoke = sub.add_parser("smoke", help="Opt-in real public smoke; impossible to run accidentally")
    smoke.add_argument("--url", required=True, help="Public URL to test")
    smoke.add_argument("--i-understand-this-uses-network", action="store_true")
    add_prepare_options(smoke)
    smoke.set_defaults(func=cmd_smoke)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if getattr(args, "command", None) == "prepare" and not args.source:
            raise WatchError("prepare requires one source", 2)
        return int(args.func(args))
    except WatchError as exc:
        eprint(f"fm-video-watch: {exc}")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
