#!/usr/bin/env bash
# fm-video-fetch.sh - fetch an allowlisted video through the installed watch pipeline.
#
# Usage:
#   fm-video-fetch.sh -h <https-url> [--max-frames N]
#   fm-video-fetch.sh --validate-only <https-url>
#   fm-video-fetch.sh --validate-redirect <initial-url> <redirect-url>
#
# The fetch writes only FM_HOME/data/video/<sha8>/ (or ./data/video/<sha8>/ when
# FM_HOME is unset). It uses the installed watch.py pipeline, with yt-dlp's
# configuration ignored, a 200 MB video limit, and a 10 minute total deadline.
set -eu

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ALLOWED_HOSTS = (
    "tiktok.com", "www.tiktok.com", "vt.tiktok.com",
    "youtube.com", "www.youtube.com", "youtu.be",
    "vimeo.com", "www.vimeo.com", "x.com", "www.x.com",
)
MAX_BYTES = 200 * 1024 * 1024
MAX_SECONDS = 600
MAX_PROCESS_OUTPUT = 8 * 1024 * 1024
WATCH_SCRIPT = Path.home() / ".agents/skills/watch/scripts/watch.py"


class FetchError(Exception):
    pass


def checked_url(value: str) -> str:
    if any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value):
        raise FetchError("refusing URL containing whitespace or control characters")
    parsed = urlsplit(value)
    if parsed.scheme.lower() != "https":
        raise FetchError("refusing non-HTTPS URL")
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise FetchError("refusing URL with missing host, credentials, or fragment")
    try:
        parsed.port
    except ValueError as exc:
        raise FetchError("refusing URL with invalid port") from exc
    if parsed.port is not None:
        raise FetchError("refusing URL with an explicit port")
    host = parsed.hostname.lower().rstrip(".")
    if host not in ALLOWED_HOSTS:
        raise FetchError(f"refusing host not in allowlist: {host}")
    return parsed._replace(fragment="").geturl()


class RedirectGuard(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        checked_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_redirect_fixture(initial: str, redirected: str) -> None:
    checked_url(initial)
    checked_url(redirected)


def preflight_redirects(url: str, deadline: float) -> str:
    opener = build_opener(RedirectGuard)
    request = Request(url, headers={"Range": "bytes=0-0", "User-Agent": "fm-video-fetch/1"}, method="GET")
    try:
        with opener.open(request, timeout=max(1, min(20, int(deadline - time.monotonic())))) as response:
            return checked_url(response.geturl())
    except HTTPError as exc:
        # A final 4xx/5xx is for yt-dlp to diagnose; redirect_request already
        # checked every redirect that preceded this response.
        return checked_url(exc.geturl())
    except URLError:
        # DNS, TLS, and origin errors are retried by yt-dlp; there was no
        # response redirect to accept here.
        return url


def ensure_output(home: Path, digest: str) -> Path:
    home = home.resolve()
    data = home / "data"
    base = data / "video"
    for path in (data, base):
        if path.is_symlink():
            raise FetchError(f"refusing symlinked output directory: {path}")
    base.mkdir(parents=True, exist_ok=True)
    base = base.resolve()
    try:
        base.relative_to(home)
    except ValueError as exc:
        raise FetchError(f"output path escapes calling home: {base}") from exc
    destination = (base / digest).resolve()
    try:
        destination.relative_to(base)
    except ValueError as exc:
        raise FetchError(f"output path escapes video root: {destination}") from exc
    if destination.exists():
        raise FetchError(f"refusing to overwrite existing output: {destination}")
    destination.mkdir()
    return destination


def kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_limited(command: list[str], env: dict[str, str], deadline: float, output: Path) -> tuple[int, bool, bool]:
    err = output.with_suffix(output.suffix + ".stderr")
    with output.open("wb") as stdout, err.open("wb") as stderr:
        process = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        timed_out = False
        output_limited = False
        while process.poll() is None:
            if time.monotonic() >= deadline:
                timed_out = True
                kill_process_group(process)
                break
            if output.stat().st_size > MAX_PROCESS_OUTPUT or err.stat().st_size > MAX_PROCESS_OUTPUT:
                output_limited = True
                kill_process_group(process)
                break
            time.sleep(0.1)
        process.wait()
    return process.returncode, timed_out, output_limited


def read_bounded(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")[:MAX_PROCESS_OUTPUT]


def yt_version(yt_dlp: Path) -> str:
    try:
        result = subprocess.run(
            [str(yt_dlp), "--ignore-config", "--version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return result.stdout.strip() or "unknown"


def fallback_metadata(yt_dlp: Path, url: str, env: dict[str, str], deadline: float, work: Path) -> tuple[dict, str, str]:
    fields = ("title", "uploader", "duration", "description", "webpage_url")
    command = [str(yt_dlp), "--ignore-config", "--no-playlist", "--skip-download"]
    for field in fields:
        command += ["--print", f"__FM_{field.upper()}__%({field})j"]
    command += ["--", url]
    output = work / "fallback.txt"
    code, timed_out, limited = run_limited(command, env, deadline, output)
    if timed_out:
        raise FetchError("TikTok metadata fallback exceeded the 10 minute wall bound")
    if limited:
        raise FetchError("TikTok metadata fallback exceeded its output limit")
    raw = read_bounded(output)
    values: dict[str, str] = {}
    for line in raw.splitlines():
        for field in fields:
            prefix = f"__FM_{field.upper()}__"
            if line.startswith(prefix):
                value = line[len(prefix):]
                try:
                    values[field] = str(json.loads(value))
                except json.JSONDecodeError:
                    values[field] = value
                break
    if not any(values.get(field) for field in ("title", "uploader", "description", "webpage_url")):
        detail = read_bounded(output.with_suffix(output.suffix + ".stderr")).strip().splitlines()
        reason = detail[-1] if detail else f"yt-dlp exited {code}"
        raise FetchError(f"TikTok metadata fallback failed: {reason[:300]}")
    return values, raw, read_bounded(output.with_suffix(output.suffix + ".stderr"))


def clean_text(value: object) -> str:
    return " ".join(str(value or "").replace("`", "'").splitlines()).strip()


def load_info(download_dir: Path, url: str) -> dict:
    info_path = download_dir / "video.info.json"
    if not info_path.is_file() or info_path.stat().st_size > MAX_PROCESS_OUTPUT:
        return {"url": url}
    try:
        raw = json.loads(info_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"url": url}
    return {
        "url": raw.get("webpage_url") or url,
        "title": raw.get("title") or "",
        "uploader": raw.get("uploader") or raw.get("channel") or "",
        "duration": raw.get("duration") or 0,
    }


def extract_transcript(report: str) -> str:
    marker = "## Transcript\n"
    start = report.find(marker)
    if start < 0:
        return ""
    section = report[start + len(marker):]
    opening = section.find("```\n")
    if opening < 0:
        return ""
    text = section[opening + 4:]
    closing = text.find("\n```")
    return text if closing < 0 else text[:closing]


def copy_frames(source: Path, destination: Path) -> None:
    destination.mkdir()
    total = 0
    for frame in sorted(source.glob("frame_*.jpg")):
        if frame.is_symlink() or not frame.is_file():
            raise FetchError("refusing an unexpected frame entry")
        total += frame.stat().st_size
        if total > MAX_BYTES:
            raise FetchError("extracted frames exceed the 200 MB size cap")
        shutil.copy2(frame, destination / frame.name)


def write_result(destination: Path, url: str, info: dict, transcript: str, frames: Path, fetched_at: str, version: str, status: str, note: str = "") -> None:
    metadata = {
        "url": url,
        "uploader": clean_text(info.get("uploader")),
        "title": clean_text(info.get("title")),
        "duration": info.get("duration") or 0,
        "fetched_at": fetched_at,
        "yt_dlp_version": version,
        "status": status,
    }
    (destination / "metadata.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (destination / "transcript.txt").write_text(transcript, encoding="utf-8")
    copy_frames(frames, destination / "frames")
    lines = [
        "# Video source",
        "",
        f"- URL: {clean_text(url)}",
        f"- Uploader: {clean_text(info.get('uploader')) or 'unknown'}",
        f"- Title: {clean_text(info.get('title')) or 'unknown'}",
        f"- Duration: {clean_text(info.get('duration')) or 'unknown'}",
        f"- Fetched-at: {fetched_at}",
        f"- yt-dlp: {version}",
        f"- Result: {status}",
    ]
    if note:
        lines.append(f"- Note: {clean_text(note)}")
    (destination / "source.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def make_yt_wrapper(directory: Path, yt_dlp: Path) -> Path:
    wrapper = directory / "yt-dlp"
    wrapper.write_text(
        "#!/bin/sh\nexec " + shlex.quote(str(yt_dlp)) + " --ignore-config --max-filesize 200M \"$@\"\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    return wrapper


def fetch(url: str, max_frames: int) -> Path:
    url = checked_url(url)
    home = Path(os.environ.get("FM_HOME", Path.cwd())).expanduser()
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:8]
    destination = ensure_output(home, digest)
    deadline = time.monotonic() + MAX_SECONDS
    yt_dlp = Path(shutil.which("yt-dlp") or "")
    if not yt_dlp.is_file():
        raise FetchError("yt-dlp is not installed")
    if not WATCH_SCRIPT.is_file():
        raise FetchError(f"installed watch pipeline not found: {WATCH_SCRIPT}")

    work = Path(tempfile.mkdtemp(prefix="fm-video-fetch-"))
    try:
        resolved_url = preflight_redirects(url, deadline)
        version = yt_version(yt_dlp)
        env = os.environ.copy()
        env["PATH"] = str(make_yt_wrapper(work, yt_dlp).parent) + os.pathsep + env.get("PATH", "")
        report = work / "watch-report.md"
        command = [sys.executable, str(WATCH_SCRIPT), resolved_url, "--max-frames", str(max_frames), "--out-dir", str(work / "watch")]
        code, timed_out, limited = run_limited(command, env, deadline, report)
        download_dir = work / "watch" / "download"
        video_files = [p for p in download_dir.iterdir() if p.is_file() and p.suffix.lower() in {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}] if download_dir.is_dir() else []
        oversized = any(p.stat().st_size > MAX_BYTES for p in video_files)
        if code == 0 and not timed_out and not limited and video_files and not oversized:
            info = load_info(download_dir, url)
            write_result(destination, url, info, extract_transcript(read_bounded(report)), work / "watch" / "frames", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), version, "downloaded")
            return destination
        if timed_out:
            raise FetchError("video fetch exceeded the 10 minute wall bound")
        if limited:
            raise FetchError("video fetch exceeded its diagnostic output limit")
        if oversized:
            raise FetchError("video exceeds the 200 MB size cap")
        if urlsplit(url).hostname.lower().endswith("tiktok.com"):
            info, _, fallback_stderr = fallback_metadata(yt_dlp, url, env, deadline, work)
            description = info.get("description", "")
            write_result(destination, url, info, description, work / "watch" / "frames" if (work / "watch" / "frames").is_dir() else work / "empty-frames", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), version, "metadata-only fallback", "TikTok extractor failed; metadata and description fallback used")
            return destination
        detail = read_bounded(report.with_suffix(report.suffix + ".stderr")).strip().splitlines()
        reason = detail[-1] if detail else f"yt-dlp exited {code}"
        raise FetchError(f"video fetch failed: {reason[:300]}")
    except Exception:
        if destination.exists():
            shutil.rmtree(destination, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("-h", dest="url")
    parser.add_argument("--max-frames", type=int, default=80)
    parser.add_argument("--validate-only")
    parser.add_argument("--validate-redirect", nargs=2, metavar=("INITIAL", "TARGET"))
    parser.add_argument("--help", action="store_true")
    args = parser.parse_args()
    if args.help or (not args.url and not args.validate_only and not args.validate_redirect):
        print("usage: fm-video-fetch.sh -h <https-url> [--max-frames N]")
        print("       fm-video-fetch.sh --validate-only <https-url>")
        print("       fm-video-fetch.sh --validate-redirect <initial-url> <redirect-url>")
        return 0 if args.help else 2
    try:
        if args.validate_only:
            print(f"allowed: {checked_url(args.validate_only)}")
            return 0
        if args.validate_redirect:
            check_redirect_fixture(*args.validate_redirect)
            print("redirect allowed")
            return 0
        if args.max_frames < 1 or args.max_frames > 100:
            raise FetchError("--max-frames must be between 1 and 100")
        destination = fetch(args.url, args.max_frames)
        print(destination)
        return 0
    except (FetchError, OSError, ValueError) as exc:
        print(f"fm-video-fetch.sh: {exc}", file=sys.stderr)
        return 1


raise SystemExit(main())
PY
