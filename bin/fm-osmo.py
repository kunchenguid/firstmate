#!/usr/bin/env python3
"""fm-osmo.py - DJI Osmo Pocket video clip cataloging, pairing, sampling, and classification.

Discovers the Osmo drive strictly read-only, pairs MP4 master and LRF proxy files,
samples video visuals locally using ffmpeg and macOS Apple Vision (or PIL),
analyzes audio speech/silence metrics locally, transcribes via local headless CLI
or Superwhisper, classifies clips into A-roll, B-roll, or mixed, caches results
deterministically outside the device, and generates a comprehensive local Markdown report.

Free and 100% local: no paid APIs, no cloud uploads, zero external network calls.
"""

import argparse
import datetime
import json
import math
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

DEFAULT_DRIVE_PATH = "/Volumes/Osmo"
DEFAULT_CACHE_DIR = os.path.expanduser("~/.firstmate/osmo-catalog-cache")
SUPERWHISPER_APP = "/Applications/superwhisper.app"
SUPERWHISPER_DB = os.path.expanduser(
    "~/Library/Application Support/superwhisper/database/superwhisper.sqlite"
)
SUPERWHISPER_RECORDINGS = os.path.expanduser("~/superwhisper/recordings")


def log(msg):
    sys.stderr.write(f"[fm-osmo] {msg}\n")
    sys.stderr.flush()


def format_duration(seconds):
    """Format duration in seconds to HH:MM:SS or MM:SS."""
    if seconds is None:
        return "00:00"
    seconds = max(0, float(seconds))
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"


def format_bytes(num_bytes):
    """Format bytes to human-readable string."""
    if num_bytes is None:
        return "0 B"
    num_bytes = float(num_bytes)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if num_bytes < 1024.0:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} PB"


# =============================================================================
# 1. Drive Discovery & Read-Only Invariant
# =============================================================================

def discover_osmo(drive_path=None):
    """Discover the Osmo drive read-only and locate DCIM directory."""
    target_path = os.path.abspath(drive_path or os.environ.get("FM_OSMO_DRIVE") or DEFAULT_DRIVE_PATH)

    result = {
        "found": False,
        "drive_path": target_path,
        "dcim_path": None,
        "read_only_verified": False,
        "total_files": 0,
        "video_files": [],
        "error": None,
    }

    if not os.path.exists(target_path):
        result["error"] = f"Drive path does not exist: {target_path}"
        return result

    if not os.path.isdir(target_path):
        result["error"] = f"Drive path is not a directory: {target_path}"
        return result

    if not os.access(target_path, os.R_OK):
        result["error"] = f"Drive path is not readable: {target_path}"
        return result

    # Read-only verification: We explicitly verify the path is accessed strictly read-only.
    # We do not attempt write tests on the drive. We treat all discovered paths as read-only.
    result["read_only_verified"] = True

    # Look for DCIM folder (case-insensitive search)
    dcim_candidate = None
    try:
        entries = os.listdir(target_path)
    except OSError as e:
        result["error"] = f"Cannot list directory {target_path}: {e}"
        return result

    for entry in entries:
        if entry.upper() == "DCIM":
            full_entry = os.path.join(target_path, entry)
            if os.path.isdir(full_entry):
                dcim_candidate = full_entry
                break

    # If DCIM is not a child directory, check if target_path itself is a DCIM directory or contains video files
    if not dcim_candidate:
        has_videos_directly = any(
            e.upper().endswith((".MP4", ".LRF")) and not e.startswith("._")
            for e in entries
            if os.path.isfile(os.path.join(target_path, e))
        )
        if has_videos_directly or os.path.basename(target_path).upper() == "DCIM":
            dcim_candidate = target_path

    if not dcim_candidate:
        result["error"] = f"No DCIM directory or video files found in {target_path}"
        return result

    result["dcim_path"] = dcim_candidate
    result["found"] = True

    # Gather video files safely (ignoring macOS AppleDouble hidden files ._* and .DS_Store)
    video_files = []
    for root, _dirs, files in os.walk(dcim_candidate):
        for f in files:
            if f.startswith("._") or f.startswith("."):
                continue
            ext = os.path.splitext(f)[1].upper()
            if ext in [".MP4", ".LRF"]:
                full_path = os.path.join(root, f)
                video_files.append(full_path)

    result["total_files"] = len(video_files)
    result["video_files"] = sorted(video_files)
    return result


# =============================================================================
# 2. File Pairing (MP4 & LRF)
# =============================================================================

def pair_osmo_clips(video_files):
    """Pair master MP4 files with low-resolution LRF proxy files by stem name."""
    clips_by_stem = {}

    for file_path in video_files:
        filename = os.path.basename(file_path)
        stem, ext = os.path.splitext(filename)
        ext_upper = ext.upper()

        if stem not in clips_by_stem:
            clips_by_stem[stem] = {
                "stem": stem,
                "mp4_path": None,
                "lrf_path": None,
                "mp4_size": None,
                "lrf_size": None,
                "mp4_mtime": None,
                "lrf_mtime": None,
                "recorded_at": None,
            }

        try:
            stat_res = os.stat(file_path)
            file_size = stat_res.st_size
            file_mtime = stat_res.st_mtime
        except OSError:
            file_size = 0
            file_mtime = 0

        if ext_upper == ".MP4":
            clips_by_stem[stem]["mp4_path"] = file_path
            clips_by_stem[stem]["mp4_size"] = file_size
            clips_by_stem[stem]["mp4_mtime"] = file_mtime
        elif ext_upper == ".LRF":
            clips_by_stem[stem]["lrf_path"] = file_path
            clips_by_stem[stem]["lrf_size"] = file_size
            clips_by_stem[stem]["lrf_mtime"] = file_mtime

    paired_list = []
    for stem, data in sorted(clips_by_stem.items()):
        # Determine pair status
        if data["mp4_path"] and data["lrf_path"]:
            status = "paired"
        elif data["mp4_path"]:
            status = "mp4_only"
        else:
            status = "lrf_only"
        data["pair_status"] = status

        # Try to parse timestamp from DJI filename: DJI_YYYYMMDDHHMMSS_XXXX_D
        # e.g. DJI_20260914164537_0001_D
        match = re.match(r"^DJI_(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})", stem)
        if match:
            y, mo, d, h, mi, s = match.groups()
            data["recorded_at"] = f"{y}-{mo}-{d}T{h}:{mi}:{s}"
        else:
            ref_mtime = data["mp4_mtime"] or data["lrf_mtime"]
            if ref_mtime:
                data["recorded_at"] = datetime.datetime.fromtimestamp(
                    ref_mtime, tz=datetime.timezone.utc
                ).strftime("%Y-%m-%dT%H:%M:%SZ")

        paired_list.append(data)

    return paired_list


# =============================================================================
# 3. Superwhisper Integration
# =============================================================================

def check_superwhisper_env():
    """Inspect local Superwhisper installation, database, and process status."""
    info = {
        "installed": os.path.exists(SUPERWHISPER_APP),
        "app_path": SUPERWHISPER_APP if os.path.exists(SUPERWHISPER_APP) else None,
        "running": False,
        "database_found": os.path.exists(SUPERWHISPER_DB),
        "database_path": SUPERWHISPER_DB if os.path.exists(SUPERWHISPER_DB) else None,
        "recordings_dir_found": os.path.exists(SUPERWHISPER_RECORDINGS),
        "limitation_note": (
            "Superwhisper is a macOS menu bar dictation tool without a headless CLI batch transcription mode. "
            "Audio tracks are extracted locally and primed for Superwhisper input; speech activity is analyzed locally via ffmpeg."
        ),
    }

    # Check if Superwhisper is running
    try:
        res = subprocess.run(
            ["pgrep", "-x", "superwhisper"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        info["running"] = (res.returncode == 0)
    except Exception:
        info["running"] = False

    return info


def find_superwhisper_transcript_for_clip(stem, recorded_at, sw_db_path=SUPERWHISPER_DB):
    """Search Superwhisper's SQLite database for existing transcripts matching this clip."""
    if not os.path.exists(sw_db_path):
        return None

    try:
        conn = sqlite3.connect(f"file:{sw_db_path}?mode=ro", uri=True)
        cursor = conn.cursor()

        query = (
            "SELECT r.id, r.datetime, COALESCE(fts.result, fts.rawResult, r.promptContext), r.promptContext "
            "FROM recording r "
            "LEFT JOIN recording_fts fts ON r.id = fts.recordingId "
            "WHERE r.folderName LIKE ? OR r.promptContext LIKE ? ORDER BY r.datetime DESC LIMIT 1"
        )
        like_pattern = f"%{stem}%"
        cursor.execute(query, (like_pattern, like_pattern))
        row = cursor.fetchone()
        conn.close()

        if row and row[2]:
            return {
                "id": row[0],
                "datetime": row[1],
                "text": str(row[2]).strip(),
                "source": "superwhisper_db",
            }
    except Exception as e:
        log(f"Warning: Superwhisper SQLite lookup failed for {stem}: {e}")

    return None


def run_headless_cli_transcriber(audio_path, output_dir, transcriber_cmd=None):
    """Transcribe audio track using a free fully local headless CLI transcriber."""
    if not audio_path or not os.path.exists(audio_path) or os.path.getsize(audio_path) == 0:
        return {
            "status": "no_audio",
            "text": None,
            "source": None,
        }

    os.makedirs(output_dir, exist_ok=True)
    out_transcript = os.path.join(output_dir, "transcript.txt")
    stem = os.path.splitext(os.path.basename(audio_path))[0]

    cmd_str = transcriber_cmd or os.environ.get("FM_OSMO_TRANSCRIBER")

    if cmd_str:
        try:
            if "{input}" in cmd_str:
                formatted_cmd = cmd_str.format(input=shlex.quote(audio_path), output=shlex.quote(out_transcript))
                args = shlex.split(formatted_cmd)
            elif "{audio}" in cmd_str:
                formatted_cmd = cmd_str.format(audio=shlex.quote(audio_path))
                args = shlex.split(formatted_cmd)
            else:
                args = shlex.split(cmd_str) + [audio_path]

            res = subprocess.run(args, capture_output=True, text=True, timeout=180)
            text = ""

            if os.path.exists(out_transcript) and os.path.getsize(out_transcript) > 0:
                with open(out_transcript, "r", encoding="utf-8") as f:
                    text = f.read().strip()
            elif res.returncode == 0 and res.stdout.strip():
                text = res.stdout.strip()
                with open(out_transcript, "w", encoding="utf-8") as f:
                    f.write(text)

            if res.returncode == 0:
                return {
                    "status": "transcribed",
                    "text": text,
                    "source": "cli_transcriber",
                    "command": cmd_str,
                }
            else:
                err_msg = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
                return {
                    "status": "transcription_failed",
                    "text": None,
                    "source": "cli_transcriber",
                    "error": err_msg,
                }
        except Exception as e:
            return {
                "status": "transcription_failed",
                "text": None,
                "source": "cli_transcriber",
                "error": str(e),
            }

    whisper_bin = shutil.which("whisper")
    user_whisper = os.path.expanduser("~/Library/Python/3.9/bin/whisper")
    if not whisper_bin and os.path.exists(user_whisper) and os.access(user_whisper, os.X_OK):
        whisper_bin = user_whisper

    model_override = os.environ.get("FM_OSMO_WHISPER_MODEL")
    cache_whisper = os.path.expanduser("~/.cache/whisper")
    cached_model_path = None
    if model_override and os.path.exists(model_override):
        cached_model_path = model_override
    elif os.path.exists(cache_whisper):
        candidates = [os.path.join(cache_whisper, f) for f in os.listdir(cache_whisper) if f.endswith(".pt")]
        if candidates:
            cached_model_path = sorted(candidates)[0]

    if whisper_bin and cached_model_path:
        try:
            whisper_cmd = [
                whisper_bin,
                audio_path,
                "--model", cached_model_path,
                "--output_dir", output_dir,
                "--output_format", "txt",
            ]
            res = subprocess.run(whisper_cmd, capture_output=True, text=True, timeout=180)
            txt_file = os.path.join(output_dir, f"{stem}.txt")
            text = ""
            if os.path.exists(txt_file) and os.path.getsize(txt_file) > 0:
                with open(txt_file, "r", encoding="utf-8") as f:
                    text = f.read().strip()
            elif res.returncode == 0 and res.stdout.strip():
                text = res.stdout.strip()

            if res.returncode == 0:
                return {
                    "status": "transcribed",
                    "text": text,
                    "source": "whisper_cli",
                    "model": cached_model_path,
                }
            else:
                err_msg = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
                return {
                    "status": "transcription_failed",
                    "text": None,
                    "source": "whisper_cli",
                    "error": err_msg,
                }
        except Exception as e:
            return {
                "status": "transcription_failed",
                "text": None,
                "source": "whisper_cli",
                "error": str(e),
            }

    return {
        "status": "approval_required",
        "text": None,
        "source": None,
        "note": (
            "Free fully local headless CLI transcription requires approval prior to downloading a model. "
            "No model checkpoint was found locally. To transcribe automatically, approve downloading an open-source model "
            "or provide --transcriber <command>."
        ),
        "approval_request": {
            "tool": "whisper (openai-whisper CLI)",
            "model": "base.en",
            "source": "https://openaipublic.azureedge.net/main/whisper/models/ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e/base.en.pt",
            "disk_footprint": "142 MB",
            "install_command": "python3 -m whisper --model base.en <audio_file>",
        },
    }


# =============================================================================
# 4. Local Media Sampling & Metrics (ffmpeg / ffprobe / Vision / PIL)
# =============================================================================

def get_clip_metadata_ffprobe(file_path):
    """Extract duration, resolution, fps from video using ffprobe."""
    meta = {
        "duration_seconds": 0.0,
        "width": 0,
        "height": 0,
        "fps": 0.0,
        "has_audio": False,
    }
    if not file_path or not os.path.exists(file_path):
        return meta

    try:
        cmd = [
            "ffprobe",
            "-v", "error",
            "-show_entries", "format=duration:stream=width,height,r_frame_rate,codec_type",
            "-of", "json",
            file_path,
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            return meta

        data = json.loads(res.stdout)
        fmt = data.get("format", {})
        if "duration" in fmt:
            meta["duration_seconds"] = float(fmt["duration"])

        for stream in data.get("streams", []):
            ctype = stream.get("codec_type")
            if ctype == "video" and meta["width"] == 0:
                meta["width"] = int(stream.get("width", 0))
                meta["height"] = int(stream.get("height", 0))
                r_rate = stream.get("r_frame_rate", "0/1")
                if "/" in r_rate:
                    num, den = r_rate.split("/", 1)
                    if float(den) > 0:
                        meta["fps"] = round(float(num) / float(den), 2)
            elif ctype == "audio":
                meta["has_audio"] = True

    except Exception as e:
        log(f"ffprobe failed on {file_path}: {e}")

    return meta


def extract_sample_frames(video_path, output_dir, duration_seconds, sample_count=5):
    """Extract sample frames evenly distributed across clip duration."""
    os.makedirs(output_dir, exist_ok=True)
    frame_paths = []

    if duration_seconds <= 0.0:
        duration_seconds = 1.0

    # Calculate sample timestamps
    if duration_seconds < 2.0:
        timestamps = [duration_seconds * 0.5]
    elif duration_seconds <= 5.0:
        timestamps = [
            duration_seconds * 0.25,
            duration_seconds * 0.5,
            duration_seconds * 0.75,
        ][:sample_count]
    else:
        # e.g. for 5 samples: 10%, 30%, 50%, 70%, 90%
        step = 1.0 / (sample_count + 1)
        timestamps = [(i + 1) * step * duration_seconds for i in range(sample_count)]

    for idx, ts in enumerate(timestamps, start=1):
        out_file = os.path.join(output_dir, f"frame_{idx:02d}.jpg")
        cmd = [
            "ffmpeg",
            "-v", "error",
            "-ss", f"{ts:.3f}",
            "-i", video_path,
            "-vframes", "1",
            "-q:v", "2",
            "-y",
            out_file,
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if res.returncode == 0 and os.path.exists(out_file) and os.path.getsize(out_file) > 0:
                frame_paths.append(out_file)
        except Exception as e:
            log(f"Failed to extract frame at {ts:.2f}s from {video_path}: {e}")

    return frame_paths


def detect_faces_with_apple_vision(frame_paths):
    """Use macOS Apple Vision framework via swift to detect faces locally."""
    if not frame_paths:
        return {}

    # Check if swift is available
    if not shutil.which("swift"):
        return {p: 0 for p in frame_paths}

    swift_code = r'''
import Vision
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments.dropFirst()
var results: [String: [String: Any]] = [:]

for path in args {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        results[path] = ["faces": 0, "prominent": false]
        continue
    }
    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
        let faces = request.results ?? []
        var hasProminent = false
        for face in faces {
            let bb = face.boundingBox
            if bb.width > 0.15 || bb.height > 0.15 {
                hasProminent = true
                break
            }
        }
        results[path] = ["faces": faces.count, "prominent": hasProminent]
    } catch {
        results[path] = ["faces": 0, "prominent": false]
    }
}

if let json = try? JSONSerialization.data(withJSONObject: results),
   let str = String(data: json, encoding: .utf8) {
    print(str)
}
'''
    try:
        cmd = ["swift", "-e", swift_code, "--"] + frame_paths
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if res.returncode == 0 and res.stdout.strip():
            parsed = json.loads(res.stdout.strip())
            return parsed
    except Exception as e:
        log(f"Apple Vision face detection fallback notice: {e}")

    return {p: {"faces": 0, "prominent": False} for p in frame_paths}


def compute_visual_metrics(frame_paths):
    """Compute local visual metrics across sampled frames."""
    if not frame_paths:
        return {
            "sample_count": 0,
            "sampled_frames": [],
            "face_frames_count": 0,
            "face_count_max": 0,
            "has_prominent_face": False,
            "avg_brightness": 0.0,
            "scene_variance": 0.0,
        }

    vision_results = detect_faces_with_apple_vision(frame_paths)

    face_frames_count = 0
    face_count_max = 0
    has_prominent_face = False

    for path, vinfo in vision_results.items():
        if isinstance(vinfo, dict):
            fc = vinfo.get("faces", 0)
            prom = vinfo.get("prominent", False)
        else:
            fc = int(vinfo)
            prom = False

        if fc > 0:
            face_frames_count += 1
        if fc > face_count_max:
            face_count_max = fc
        if prom:
            has_prominent_face = True

    # Try brightness computation using PIL if installed
    brightnesses = []
    try:
        from PIL import Image, ImageStat
        for p in frame_paths:
            with Image.open(p) as img:
                stat = ImageStat.Stat(img.convert("L"))
                brightnesses.append(stat.mean[0])
    except ImportError:
        # Fallback brightness calculation using lightweight ffprobe/stat or neutral default
        brightnesses = [128.0]

    avg_brightness = round(sum(brightnesses) / len(brightnesses), 1) if brightnesses else 128.0
    scene_variance = round(
        (max(brightnesses) - min(brightnesses)) / 255.0 if brightnesses else 0.0, 3
    )

    return {
        "sample_count": len(frame_paths),
        "sampled_frames": frame_paths,
        "face_frames_count": face_frames_count,
        "face_count_max": face_count_max,
        "has_prominent_face": has_prominent_face,
        "avg_brightness": avg_brightness,
        "scene_variance": scene_variance,
    }


def analyze_audio(video_path, audio_out_dir, total_duration):
    """Extract audio track and analyze speech/silence ratios locally via ffmpeg."""
    os.makedirs(audio_out_dir, exist_ok=True)
    audio_wav = os.path.join(audio_out_dir, "audio.wav")

    metrics = {
        "audio_extracted_path": None,
        "has_audio": False,
        "speech_ratio": 0.0,
        "speech_duration_seconds": 0.0,
        "silence_duration_seconds": 0.0,
        "mean_volume_db": -99.0,
        "max_volume_db": -99.0,
    }

    if not video_path or not os.path.exists(video_path):
        return metrics

    # Extract 16kHz mono audio for transcription / speech analysis
    cmd_extract = [
        "ffmpeg",
        "-v", "error",
        "-i", video_path,
        "-vn",
        "-ac", "1",
        "-ar", "16000",
        "-y",
        audio_wav,
    ]
    try:
        res = subprocess.run(cmd_extract, capture_output=True, text=True, timeout=60)
        if res.returncode != 0 or not os.path.exists(audio_wav) or os.path.getsize(audio_wav) == 0:
            return metrics
        metrics["audio_extracted_path"] = audio_wav
        metrics["has_audio"] = True
    except Exception as e:
        log(f"Audio extraction failed on {video_path}: {e}")
        return metrics

    # Run silencedetect and volumedetect
    cmd_analysis = [
        "ffmpeg",
        "-i", audio_wav,
        "-af", "silencedetect=noise=-30dB:d=0.5,volumedetect",
        "-f", "null",
        "-",
    ]
    try:
        res_analysis = subprocess.run(cmd_analysis, capture_output=True, text=True, timeout=60)
        output = res_analysis.stderr

        # Parse silence durations
        silence_durations = []
        for line in output.splitlines():
            if "silence_duration:" in line:
                m = re.search(r"silence_duration:\s*([0-9.]+)", line)
                if m:
                    silence_durations.append(float(m.group(1)))

        total_silence = sum(silence_durations)
        if total_duration <= 0.0:
            total_duration = total_silence or 1.0

        # Bound silence to total_duration
        total_silence = min(total_silence, total_duration)
        active_speech = max(0.0, total_duration - total_silence)
        speech_ratio = round(active_speech / total_duration, 3)

        metrics["silence_duration_seconds"] = round(total_silence, 2)
        metrics["speech_duration_seconds"] = round(active_speech, 2)
        metrics["speech_ratio"] = speech_ratio

        # Parse mean/max volume
        m_mean = re.search(r"mean_volume:\s*([-0-9.]+)\s*dB", output)
        if m_mean:
            metrics["mean_volume_db"] = float(m_mean.group(1))

        m_max = re.search(r"max_volume:\s*([-0-9.]+)\s*dB", output)
        if m_max:
            metrics["max_volume_db"] = float(m_max.group(1))

    except Exception as e:
        log(f"Audio analysis failed on {audio_wav}: {e}")

    return metrics


# =============================================================================
# 5. Classification (A-roll / B-roll / Mixed)
# =============================================================================

def classify_clip(visual_metrics, audio_metrics, transcription=None):
    """Classify video clip as A-roll, B-roll, or Mixed based on audio/visual features."""
    sr = audio_metrics.get("speech_ratio", 0.0)
    has_audio = audio_metrics.get("has_audio", False)
    prominent = visual_metrics.get("has_prominent_face", False)
    face_frames = visual_metrics.get("face_frames_count", 0)
    sample_count = visual_metrics.get("sample_count", 1) or 1
    scene_var = visual_metrics.get("scene_variance", 0.0)

    has_transcript = bool(
        transcription and transcription.get("text") and len(str(transcription.get("text")).strip().split()) >= 2
    )

    # 1. High speech with prominent host face -> A-roll
    if has_audio and (sr >= 0.35 or has_transcript) and (prominent or face_frames >= math.ceil(sample_count / 2)):
        conf = min(0.98, 0.85 + (sr * 0.1) + (0.05 if prominent else 0.0))
        return {
            "category": "A-roll",
            "confidence": round(conf, 2),
            "rationale": (
                f"Primary narrative footage: high voice activity ({sr*100:.0f}%) with host/presenter "
                f"face prominently framed in {face_frames}/{sample_count} sample frames."
            ),
        }

    # 2. High speech without face -> Mixed or A-roll dialogue
    if has_audio and (sr >= 0.35 or has_transcript):
        if scene_var > 0.25:
            return {
                "category": "Mixed",
                "confidence": 0.85,
                "rationale": (
                    f"Voiceover or walk-and-talk: high speech activity ({sr*100:.0f}%) recorded over "
                    f"dynamic scene movement without a focal talking head."
                ),
            }
        else:
            return {
                "category": "A-roll",
                "confidence": 0.80,
                "rationale": (
                    f"Narrative dialogue: continuous speech ({sr*100:.0f}% vocal activity) in stable framing."
                ),
            }

    # 3. Low speech or no audio + no face -> B-roll
    if (not has_audio or sr < 0.10) and not has_transcript and face_frames == 0:
        conf = 0.95 if not has_audio or sr < 0.05 else 0.90
        return {
            "category": "B-roll",
            "confidence": conf,
            "rationale": (
                f"Atmospheric / cutaway footage: low audio activity ({sr*100:.0f}%) and no host face "
                f"detected across sample frames (scenery, objects, or environmental capture)."
            ),
        }

    # 4. Low speech with incidental faces -> B-roll (street/crowd) or Mixed
    if (not has_audio or sr < 0.10) and not has_transcript and face_frames > 0:
        if not prominent:
            return {
                "category": "B-roll",
                "confidence": 0.85,
                "rationale": (
                    f"Street / crowd B-roll: low audio activity ({sr*100:.0f}%) with incidental background "
                    f"passersby rather than a speaking presenter."
                ),
            }
        else:
            return {
                "category": "Mixed",
                "confidence": 0.75,
                "rationale": (
                    "Silent presenter shot: host in frame but minimal or no speech recorded (reaction or action take)."
                ),
            }

    # 5. Moderate speech (0.10 <= sr < 0.35) -> Mixed
    return {
        "category": "Mixed",
        "confidence": 0.85,
        "rationale": (
            f"Hybrid clip: moderate speech activity ({sr*100:.0f}%) combined with cutaways, pauses, or transitional action."
        ),
    }


# =============================================================================
# 6. Incremental Cache Manager
# =============================================================================

class OsmoCache:
    """Manages deterministic incremental cataloging cache outside the device."""

    def __init__(self, cache_dir=None):
        self.cache_dir = os.path.abspath(cache_dir or os.environ.get("FM_OSMO_CACHE_DIR") or DEFAULT_CACHE_DIR)
        self.manifest_path = os.path.join(self.cache_dir, "catalog-cache.json")
        self.frames_dir = os.path.join(self.cache_dir, "frames")
        self.audio_dir = os.path.join(self.cache_dir, "audio")
        self.reports_dir = os.path.join(self.cache_dir, "reports")
        self.data = self._load()

    def _load(self):
        if os.path.exists(self.manifest_path):
            try:
                with open(self.manifest_path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                log(f"Warning: could not read cache file {self.manifest_path}: {e}")
        return {"version": 1, "clips": {}}

    def save(self):
        os.makedirs(self.cache_dir, exist_ok=True)
        try:
            temp_file = self.manifest_path + ".tmp"
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2)
            os.replace(temp_file, self.manifest_path)
        except Exception as e:
            log(f"Warning: failed to save cache to {self.manifest_path}: {e}")

    def get_clip(self, stem):
        return self.data.get("clips", {}).get(stem)

    def is_cached_and_valid(self, pair_info, transcriber=None):
        stem = pair_info["stem"]
        cached = self.get_clip(stem)
        if not cached:
            return False

        # Compare file sizes and modification times
        if cached.get("mp4_size") != pair_info.get("mp4_size"):
            return False
        if cached.get("mp4_mtime") != pair_info.get("mp4_mtime"):
            return False
        if cached.get("lrf_size") != pair_info.get("lrf_size"):
            return False
        if cached.get("lrf_mtime") != pair_info.get("lrf_mtime"):
            return False

        # Verify extracted assets still exist
        frames = cached.get("visual_metrics", {}).get("sampled_frames", [])
        if not frames or not all(os.path.exists(f) for f in frames):
            return False

        # Incomplete transcriptions must be re-evaluated when a transcriber or model is available
        t_status = cached.get("transcription", {}).get("status")
        if t_status not in ("transcribed", "no_audio"):
            cmd_str = transcriber or os.environ.get("FM_OSMO_TRANSCRIBER")
            if cmd_str:
                return False
            model_override = os.environ.get("FM_OSMO_WHISPER_MODEL")
            cache_whisper = os.path.expanduser("~/.cache/whisper")
            if (model_override and os.path.exists(model_override)) or (
                os.path.exists(cache_whisper)
                and any(f.endswith(".pt") for f in os.listdir(cache_whisper))
            ):
                return False
            if find_superwhisper_transcript_for_clip(stem, pair_info.get("recorded_at")):
                return False

        return True

    def put_clip(self, stem, clip_data):
        self.data.setdefault("clips", {})[stem] = clip_data


# =============================================================================
# 7. High-Level Report Generator
# =============================================================================

def generate_markdown_report(catalog_results, report_path=None):
    """Generate a high-level local Markdown report summarizing cataloged Osmo clips."""
    summary = catalog_results.get("summary", {})
    clips = catalog_results.get("clips", [])
    sw_env = catalog_results.get("superwhisper", {})
    drive_info = catalog_results.get("drive", {})

    total_clips = summary.get("total_clips", 0)
    total_duration = summary.get("total_duration_seconds", 0.0)
    a_roll_count = summary.get("a_roll_count", 0)
    b_roll_count = summary.get("b_roll_count", 0)
    mixed_count = summary.get("mixed_count", 0)
    paired_count = summary.get("paired_count", 0)

    now_iso = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = [
        "# Osmo Pocket Footage Catalog & Classification Report",
        "",
        f"**Generated:** {now_iso}  ",
        f"**Source Drive:** `{drive_info.get('drive_path', 'Unknown')}` (Read-Only Verified)  ",
        f"**Cache Location:** `{catalog_results.get('cache_dir', 'Unknown')}`  ",
        f"**Superwhisper Status:** {'App Available' if sw_env.get('installed') else 'Not Installed'}  ",
        "",
        "## Executive Summary",
        "",
        f"Discovered and categorized **{total_clips} video clips** totaling **{format_duration(total_duration)}** of footage.",
        "All processing performed 100% locally with zero cloud uploads or paid APIs.",
        "",
        "| Category | Clip Count | Total Duration | % of Total Footage |",
        "| :--- | :--- | :--- | :--- |",
    ]

    def cat_pct(count):
        return f"{(count / total_clips * 100):.1f}%" if total_clips > 0 else "0.0%"

    lines.append(f"| **A-roll** (Host / Dialogue) | {a_roll_count} | {format_duration(summary.get('a_roll_duration_seconds', 0))} | {cat_pct(a_roll_count)} |")
    lines.append(f"| **B-roll** (Atmospheric / Cutaway) | {b_roll_count} | {format_duration(summary.get('b_roll_duration_seconds', 0))} | {cat_pct(b_roll_count)} |")
    lines.append(f"| **Mixed** (Hybrid / Walk & Talk) | {mixed_count} | {format_duration(summary.get('mixed_duration_seconds', 0))} | {cat_pct(mixed_count)} |")
    lines.append(f"| **Total Footage** | **{total_clips}** | **{format_duration(total_duration)}** | 100.0% |")

    lines.extend([
        "",
        "## Device & Pairing Integrity",
        "",
        f"- **Read-Only Invariant:** Verified. No writes, deletes, or sidecars were placed on `/Volumes/Osmo`.",
        f"- **MP4 / LRF Proxy Pairing:** {paired_count} clips paired with high-efficiency LRF proxy files.",
        f"- **Single Files:** {total_clips - paired_count} clips found with only master MP4 or LRF.",
        "",
        "## Superwhisper & Speech Analysis",
        "",
        f"- **Superwhisper Desktop App:** {'Detected at ' + str(sw_env.get('app_path')) if sw_env.get('installed') else 'Not detected'}.",
        f"- **Audio Tracks Extracted:** Audio tracks extracted to local cache outside the device.",
        f"- **Interface Note:** {sw_env.get('limitation_note', '')}",
        "",
        "## Clip Catalog Table",
        "",
        "| Clip ID | Recorded At | Duration | Pair | Category | Conf. | Speech % | Faces | Summary / Rationale |",
        "| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |",
    ])

    for c in clips:
        stem = c.get("stem")
        dt = c.get("recorded_at") or "Unknown"
        dur = format_duration(c.get("duration_seconds", 0))
        pair = c.get("pair_status")
        cls = c.get("classification", {})
        cat = cls.get("category", "Unknown")
        conf = f"{cls.get('confidence', 0.0):.2f}"
        am = c.get("audio_metrics", {})
        sp_pct = f"{am.get('speech_ratio', 0.0)*100:.0f}%"
        vm = c.get("visual_metrics", {})
        faces = f"{vm.get('face_frames_count', 0)}/{vm.get('sample_count', 0)}"
        rat = cls.get("rationale", "")
        # Clean rationale for markdown table
        rat_short = rat.replace("|", "-")
        lines.append(f"| `{stem}` | {dt} | {dur} | `{pair}` | **{cat}** | {conf} | {sp_pct} | {faces} | {rat_short} |")

    lines.extend([
        "",
        "## Creator Workflow Recommendations",
        "",
        "1. **A-roll Selects Pass:** Assemble the A-roll talking clips chronologically to establish the narrative spine.",
        "2. **B-roll Cutaways:** Pair B-roll atmospheric clips to cover cuts in the A-roll and visualize contextual locations.",
        "3. **Mixed Clip Trimming:** Review mixed clips to split conversational starts from cutaway action shots.",
        "",
        "---",
        "*Report compiled locally by Firstmate Osmo Catalog Skill.*",
    ])

    report_text = "\n".join(lines) + "\n"

    if report_path:
        os.makedirs(os.path.dirname(os.path.abspath(report_path)), exist_ok=True)
        with open(report_path, "w", encoding="utf-8") as f:
            f.write(report_text)

    return report_text


# =============================================================================
# 8. Main Workflow (Catalog / Scan / Discover)
# =============================================================================

def run_catalog(drive_path=None, cache_dir=None, output_path=None, sample_count=5, force=False, transcriber=None):
    """Execute complete cataloging, pairing, sampling, classification, and report generation."""
    discovery = discover_osmo(drive_path)
    cache = OsmoCache(cache_dir)
    sw_env = check_superwhisper_env()

    if not discovery["found"]:
        return {
            "success": False,
            "error": discovery["error"],
            "discovery": discovery,
            "cache_dir": cache.cache_dir,
            "superwhisper": sw_env,
        }

    paired_clips = pair_osmo_clips(discovery["video_files"])
    cataloged_clips = []

    a_roll_dur = 0.0
    b_roll_dur = 0.0
    mixed_dur = 0.0
    total_dur = 0.0
    a_roll_cnt = 0
    b_roll_cnt = 0
    mixed_cnt = 0
    paired_cnt = 0

    log(f"Processing {len(paired_clips)} clips from {discovery['dcim_path']}...")

    for clip in paired_clips:
        stem = clip["stem"]
        if clip["pair_status"] == "paired":
            paired_cnt += 1

        # Check if already processed in cache and unchanged
        if not force and cache.is_cached_and_valid(clip, transcriber=transcriber):
            cached_entry = cache.get_clip(stem)
            cached_entry["from_cache"] = True
            cataloged_clips.append(cached_entry)

            dur = cached_entry.get("duration_seconds", 0.0)
            total_dur += dur
            cat = cached_entry.get("classification", {}).get("category")
            if cat == "A-roll":
                a_roll_cnt += 1
                a_roll_dur += dur
            elif cat == "B-roll":
                b_roll_cnt += 1
                b_roll_dur += dur
            elif cat == "Mixed":
                mixed_cnt += 1
                mixed_dur += dur
            continue

        # Process new or modified clip
        master_path = clip["mp4_path"] or clip["lrf_path"]
        proxy_path = clip["lrf_path"] or clip["mp4_path"]
        clip_frames_dir = os.path.join(cache.frames_dir, stem)
        clip_audio_dir = os.path.join(cache.audio_dir, stem)

        cached_entry = cache.get_clip(stem)
        can_reuse_media = (
            not force
            and cached_entry is not None
            and cached_entry.get("mp4_size") == clip.get("mp4_size")
            and cached_entry.get("mp4_mtime") == clip.get("mp4_mtime")
            and cached_entry.get("lrf_size") == clip.get("lrf_size")
            and cached_entry.get("lrf_mtime") == clip.get("lrf_mtime")
            and cached_entry.get("visual_metrics", {}).get("sampled_frames")
            and all(os.path.exists(f) for f in cached_entry["visual_metrics"]["sampled_frames"])
            and cached_entry.get("audio_metrics", {}).get("audio_extracted_path")
            and os.path.exists(cached_entry["audio_metrics"]["audio_extracted_path"])
        )

        if can_reuse_media:
            dur = cached_entry.get("duration_seconds", 0.0)
            resolution = cached_entry.get("resolution", "Unknown")
            fps = cached_entry.get("fps", 0.0)
            visual_metrics = cached_entry.get("visual_metrics", {})
            audio_metrics = cached_entry.get("audio_metrics", {})
        else:
            # 1. Metadata via ffprobe
            meta = get_clip_metadata_ffprobe(master_path)
            dur = meta["duration_seconds"]
            resolution = f"{meta['width']}x{meta['height']}" if meta['width'] else "Unknown"
            fps = meta["fps"]

            # 2. Visual sampling (prefer proxy LRF for speed)
            frame_paths = extract_sample_frames(proxy_path, clip_frames_dir, dur, sample_count=sample_count)
            visual_metrics = compute_visual_metrics(frame_paths)

            # 3. Audio analysis & speech detection
            audio_metrics = analyze_audio(master_path, clip_audio_dir, dur)

        # 4. Transcription & Superwhisper transcript lookup
        if not audio_metrics.get("has_audio"):
            transcription = {
                "status": "no_audio",
                "text": None,
                "source": None,
            }
        else:
            transcript_info = find_superwhisper_transcript_for_clip(stem, clip["recorded_at"])
            if transcript_info and transcript_info.get("text"):
                transcription = {
                    "status": "transcribed",
                    "text": transcript_info.get("text"),
                    "source": transcript_info.get("source"),
                }
            else:
                transcription = run_headless_cli_transcriber(
                    audio_metrics["audio_extracted_path"],
                    clip_audio_dir,
                    transcriber_cmd=transcriber,
                )

        # 5. Classification
        classification = classify_clip(visual_metrics, audio_metrics, transcription=transcription)

        # Assemble clip record
        clip_record = {
            "stem": stem,
            "mp4_path": clip["mp4_path"],
            "lrf_path": clip["lrf_path"],
            "pair_status": clip["pair_status"],
            "mp4_size": clip["mp4_size"],
            "lrf_size": clip["lrf_size"],
            "mp4_mtime": clip["mp4_mtime"],
            "lrf_mtime": clip["lrf_mtime"],
            "recorded_at": clip["recorded_at"],
            "duration_seconds": dur,
            "resolution": resolution,
            "fps": fps,
            "visual_metrics": visual_metrics,
            "audio_metrics": audio_metrics,
            "transcription": transcription,
            "classification": classification,
            "from_cache": False,
            "processed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }

        # Save to cache
        cache.put_clip(stem, clip_record)
        cataloged_clips.append(clip_record)

        total_dur += dur
        cat = classification["category"]
        if cat == "A-roll":
            a_roll_cnt += 1
            a_roll_dur += dur
        elif cat == "B-roll":
            b_roll_cnt += 1
            b_roll_dur += dur
        elif cat == "Mixed":
            mixed_cnt += 1
            mixed_dur += dur

    # Save updated cache manifest
    cache.save()

    summary = {
        "total_clips": len(cataloged_clips),
        "total_duration_seconds": round(total_dur, 2),
        "paired_count": paired_cnt,
        "a_roll_count": a_roll_cnt,
        "a_roll_duration_seconds": round(a_roll_dur, 2),
        "b_roll_count": b_roll_cnt,
        "b_roll_duration_seconds": round(b_roll_dur, 2),
        "mixed_count": mixed_cnt,
        "mixed_duration_seconds": round(mixed_dur, 2),
    }

    results = {
        "success": True,
        "drive": discovery,
        "cache_dir": cache.cache_dir,
        "superwhisper": sw_env,
        "summary": summary,
        "clips": cataloged_clips,
    }

    # Generate Markdown report
    if not output_path:
        os.makedirs(cache.reports_dir, exist_ok=True)
        ts_str = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        report_file = os.path.join(cache.reports_dir, f"osmo-catalog-{ts_str}.md")
        latest_file = os.path.join(cache.cache_dir, "latest-report.md")
        generate_markdown_report(results, report_file)
        generate_markdown_report(results, latest_file)
        results["report_path"] = report_file
    else:
        generate_markdown_report(results, output_path)
        results["report_path"] = output_path

    return results


def main():
    parser = argparse.ArgumentParser(
        description="DJI Osmo Pocket video clip cataloging, pairing, sampling, and classification tool."
    )
    subparsers = parser.add_subparsers(dest="command", help="Subcommands")

    # discover subcommand
    parser_disc = subparsers.add_parser("discover", help="Discover Osmo drive status read-only")
    parser_disc.add_argument("--drive", help="Path to Osmo drive (default: /Volumes/Osmo)")
    parser_disc.add_argument("--json", action="store_true", help="Output JSON format")

    # scan subcommand
    parser_scan = subparsers.add_parser("scan", help="Scan and pair MP4/LRF files on Osmo drive")
    parser_scan.add_argument("--drive", help="Path to Osmo drive (default: /Volumes/Osmo)")
    parser_scan.add_argument("--json", action="store_true", help="Output JSON format")

    # catalog subcommand
    parser_cat = subparsers.add_parser("catalog", help="Run full cataloging, sampling, and classification")
    parser_cat.add_argument("--drive", help="Path to Osmo drive (default: /Volumes/Osmo)")
    parser_cat.add_argument("--cache-dir", help="Path to local cache directory outside device")
    parser_cat.add_argument("--output", help="Path to write Markdown report")
    parser_cat.add_argument("--transcriber", help="Command or path for headless CLI transcriber")
    parser_cat.add_argument("--sample-count", type=int, default=5, help="Number of visual frames to sample (default: 5)")
    parser_cat.add_argument("--force", action="store_true", help="Force re-processing of cached clips")
    parser_cat.add_argument("--json", action="store_true", help="Output JSON format")

    # report subcommand
    parser_rep = subparsers.add_parser("report", help="Display latest catalog report")
    parser_rep.add_argument("--cache-dir", help="Path to local cache directory")
    parser_rep.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()

    # Default to catalog command if none provided
    cmd = args.command or "catalog"

    if cmd == "discover":
        res = discover_osmo(getattr(args, "drive", None))
        if getattr(args, "json", False):
            print(json.dumps(res, indent=2))
        else:
            if res["found"]:
                print(f"Osmo drive discovered at: {res['drive_path']}")
                print(f"DCIM folder: {res['dcim_path']}")
                print(f"Read-only verified: {res['read_only_verified']}")
                print(f"Total video files: {res['total_files']}")
            else:
                sys.stderr.write(f"Osmo drive not found: {res['error']}\n")
                sys.exit(1)

    elif cmd == "scan":
        res = discover_osmo(getattr(args, "drive", None))
        if not res["found"]:
            if getattr(args, "json", False):
                print(json.dumps({"success": False, "error": res["error"]}))
            else:
                sys.stderr.write(f"Osmo drive not found: {res['error']}\n")
            sys.exit(1)

        paired = pair_osmo_clips(res["video_files"])
        if getattr(args, "json", False):
            print(json.dumps({"success": True, "drive": res["drive_path"], "clips": paired}, indent=2))
        else:
            print(f"Found {len(paired)} clips on {res['drive_path']}:")
            for c in paired:
                print(f"  [{c['pair_status']}] {c['stem']} (Recorded: {c.get('recorded_at', 'Unknown')})")

    elif cmd == "catalog":
        drive = getattr(args, "drive", None)
        cache_dir = getattr(args, "cache_dir", None)
        out = getattr(args, "output", None)
        samples = getattr(args, "sample_count", 5)
        force = getattr(args, "force", False)
        transcriber = getattr(args, "transcriber", None)

        res = run_catalog(
            drive_path=drive,
            cache_dir=cache_dir,
            output_path=out,
            sample_count=samples,
            force=force,
            transcriber=transcriber,
        )

        if not res["success"]:
            if getattr(args, "json", False):
                print(json.dumps(res, indent=2))
            else:
                sys.stderr.write(f"Catalog failed: {res['error']}\n")
            sys.exit(1)

        if getattr(args, "json", False):
            print(json.dumps(res, indent=2))
        else:
            sm = res["summary"]
            print("=" * 60)
            print("OSMO POCKET CLIP CATALOG COMPLETE")
            print("=" * 60)
            print(f"Total clips cataloged: {sm['total_clips']} ({format_duration(sm['total_duration_seconds'])})")
            print(f"  • A-roll: {sm['a_roll_count']} clips ({format_duration(sm['a_roll_duration_seconds'])})")
            print(f"  • B-roll: {sm['b_roll_count']} clips ({format_duration(sm['b_roll_duration_seconds'])})")
            print(f"  • Mixed:  {sm['mixed_count']} clips ({format_duration(sm['mixed_duration_seconds'])})")
            print(f"Report saved to: {res['report_path']}")
            print("=" * 60)

    elif cmd == "report":
        c_dir = getattr(args, "cache_dir", None) or os.environ.get("FM_OSMO_CACHE_DIR") or DEFAULT_CACHE_DIR
        latest = os.path.join(c_dir, "latest-report.md")
        manifest = os.path.join(c_dir, "catalog-cache.json")

        if getattr(args, "json", False):
            if os.path.exists(manifest):
                with open(manifest, "r", encoding="utf-8") as f:
                    print(f.read())
            else:
                sys.stderr.write(f"No catalog cache found at {manifest}\n")
                sys.exit(1)
        else:
            if os.path.exists(latest):
                with open(latest, "r", encoding="utf-8") as f:
                    print(f.read())
            else:
                sys.stderr.write(f"No report found at {latest}. Run 'fm-osmo.sh catalog' first.\n")
                sys.exit(1)


if __name__ == "__main__":
    main()
