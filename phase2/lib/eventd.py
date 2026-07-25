#!/usr/bin/env python3
"""Minimal Phase 2 event listener: Unix socket + filesystem poll fallback."""
from __future__ import annotations

import argparse
import json
import os
import select
import socket
import sys
import time
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=os.environ.get("FM_HOME", "."))
    ap.add_argument("--poll", type=float, default=2.0)
    args = ap.parse_args()
    home = Path(args.home).resolve()
    evdir = home / "state" / "events"
    procd = home / "state" / "events-processed"
    sock_path = home / "state" / "phase2.sock"
    evdir.mkdir(parents=True, exist_ok=True)
    procd.mkdir(parents=True, exist_ok=True)
    if sock_path.exists():
        sock_path.unlink()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    srv.listen(16)
    srv.setblocking(False)
    sock_path.chmod(0o600)
    print(f"eventd: listening on {sock_path}", flush=True)

    def process_file(path: Path) -> None:
        if not path.is_file():
            return
        dest = procd / path.name
        if dest.exists():
            path.unlink(missing_ok=True)
            return
        try:
            data = json.loads(path.read_text())
        except Exception as exc:
            print(f"eventd: bad event {path}: {exc}", flush=True)
            return
        # Idempotent: move after accept
        path.replace(dest)
        print(f"eventd: processed {data.get('kind')} task={data.get('task_id')}", flush=True)

    last_poll = 0.0
    while True:
        now = time.time()
        if now - last_poll >= args.poll:
            for p in sorted(evdir.glob("*.json")):
                process_file(p)
            last_poll = now
        r, _, _ = select.select([srv], [], [], args.poll)
        if not r:
            continue
        try:
            conn, _ = srv.accept()
        except BlockingIOError:
            continue
        with conn:
            raw = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                raw += chunk
                if b"\n" in raw:
                    break
        line = raw.decode(errors="replace").strip()
        if line:
            process_file(Path(line))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        sys.exit(0)
