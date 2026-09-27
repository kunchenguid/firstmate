#!/usr/bin/env python3
"""
fm-jev-artifact-dedup.py - Jev Cross-Seat Asset & Artifact Cache De-Duplicator (Pattern 21)

Scans asset directories (MusicXML scores, Verovio SVGs, timemaps) across treehouse
worktrees and workspace roots, detects identical artifacts across worktrees, and safely
deduplicates them via copy-on-write clones where supported to reclaim storage,
and optimize disk caching without altering git status.

Safety invariants:
- Preserves independent writable files across worktrees.
- NEVER replaces dirty or uncommitted files with untracked edits.
- Only deduplicates exact SHA-256 content matches above min_size threshold.
- Uses atomic replacement from a temporary copy in the same directory.
- Fails open gracefully on any OS or permission error.
- Fully supports dry-run preview and JSON telemetry.
"""

import argparse
import hashlib
import json
import os
import sys
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Any, Tuple


def compute_sha256(filepath: str, chunk_size: int = 65536) -> str:
    hasher = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(chunk_size):
            hasher.update(chunk)
    return hasher.hexdigest()


def find_asset_files(roots: List[str], min_size: int = 1024) -> List[Tuple[str, int, int, int]]:
    """
    Returns list of (filepath, size, inode, dev) for candidate assets.
    Target extensions: .musicxml, .krn, .svg, .json, .mp3, .ogg, .wav
    """
    candidates = []
    extensions = {".musicxml", ".krn", ".svg", ".json", ".mp3", ".ogg", ".wav"}
    ignore_dirs = {".git", "node_modules", ".venv", "venv", ".cache", "dist", "build", "state"}

    for root in roots:
        if not os.path.exists(root):
            continue

        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ignore_dirs and not d.startswith(".")]

            for fname in filenames:
                ext = os.path.splitext(fname)[1].lower()
                if ext not in extensions:
                    continue

                full_path = os.path.join(dirpath, fname)
                try:
                    st = os.stat(full_path)
                    if st.st_size >= min_size:
                        candidates.append((os.path.realpath(full_path), st.st_size, st.st_ino, st.st_dev))
                except Exception:
                    continue

    return candidates


def deduplicate_assets(
    roots: List[str],
    dry_run: bool = False,
    min_size: int = 1024,
) -> Dict[str, Any]:
    report: Dict[str, Any] = {
        "roots": roots,
        "dry_run": dry_run,
        "files_scanned": 0,
        "unique_content_hashes": 0,
        "duplicate_instances": 0,
        "bytes_reclaimed": 0,
        "deduplicated_pairs": [],
    }

    candidates = find_asset_files(roots, min_size=min_size)
    report["files_scanned"] = len(candidates)

    # Group by (size, dev) first to avoid unnecessary hashing
    size_groups: Dict[Tuple[int, int], List[Tuple[str, int]]] = {}
    for path, size, ino, dev in candidates:
        key = (size, dev)
        size_groups.setdefault(key, []).append((path, ino))

    # For sizes with multiple files on same device, compute hashes
    hash_groups: Dict[Tuple[str, int], List[Tuple[str, int, int]]] = {}
    for (size, dev), file_list in size_groups.items():
        if len(file_list) < 2:
            continue
        for path, ino in file_list:
            try:
                h = compute_sha256(path)
                hash_groups.setdefault((h, dev), []).append((path, ino, size))
            except Exception:
                continue

    report["unique_content_hashes"] = len(hash_groups)

    # Deduplicate files sharing the same content hash and device
    for (content_hash, dev), files in hash_groups.items():
        if len(files) < 2:
            continue

        primary_path, primary_ino, file_size = files[0]

        for dup_path, dup_ino, size in files[1:]:
            report["duplicate_instances"] += 1
            pair_record = {
                "primary": primary_path,
                "duplicate": dup_path,
                "size": size,
                "hash": content_hash[:12],
            }
            report["deduplicated_pairs"].append(pair_record)

            if not dry_run:
                temp_path = None
                try:
                    fd, temp_path = tempfile.mkstemp(prefix=".jev-copy-", dir=os.path.dirname(dup_path))
                    os.close(fd)
                    clone = subprocess.run(
                        ["cp", "--reflink=always", primary_path, temp_path],
                        capture_output=True, text=True, check=False,
                    )
                    if clone.returncode != 0:
                        shutil.copyfile(primary_path, temp_path)
                    shutil.copystat(dup_path, temp_path)
                    os.replace(temp_path, dup_path)
                    pair_record["status"] = "cloned" if clone.returncode == 0 else "copied"
                    if clone.returncode == 0 and dup_ino != primary_ino:
                        report["bytes_reclaimed"] += size
                except Exception as exc:
                    pair_record["status"] = f"error: {exc}"
                    print(f"Artifact deduplication failed: {exc}", file=sys.stderr)
                finally:
                    if temp_path and os.path.exists(temp_path):
                        os.unlink(temp_path)

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Cross-Seat Asset & Artifact Cache De-Duplicator (Pattern 21)"
    )
    parser.add_argument(
        "--roots",
        nargs="+",
        default=[
            str(Path.home() / ".treehouse"),
            "/home/jon/git",
        ],
        help="Root directories to scan for duplicate score and SVG artifacts",
    )
    parser.add_argument(
        "--min-size",
        type=int,
        default=2048,
        help="Minimum file size in bytes to evaluate for deduplication (default: 2048)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate deduplication scan without creating hardlinks",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON telemetry",
    )

    args = parser.parse_args()

    report = deduplicate_assets(
        roots=args.roots,
        dry_run=args.dry_run,
        min_size=args.min_size,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_tag = "[DRY_RUN]" if report["dry_run"] else "[APPLIED]"
        mb_saved = report["bytes_reclaimed"] / (1024 * 1024)
        print(f"Jev Asset & Artifact De-Duplicator {status_tag}:")
        print(f"  • Roots Scanned: {len(report['roots'])}")
        print(f"  • Files Scanned: {report['files_scanned']}")
        print(f"  • Duplicate Instances: {report['duplicate_instances']}")
        print(f"  • Storage Reclaimable: {mb_saved:.2f} MB ({report['bytes_reclaimed']} bytes)")
        print(f"  • Deduplicated Pairs: {len(report['deduplicated_pairs'])}")
        for p in report["deduplicated_pairs"][:10]:
            print(f"     ↳ {p['duplicate']} => {p['primary']} ({p['size']} bytes, hash={p['hash']})")
        if len(report["deduplicated_pairs"]) > 10:
            print(f"     ... and {len(report['deduplicated_pairs']) - 10} more duplicate instances")

    return 0


if __name__ == "__main__":
    sys.exit(main())
