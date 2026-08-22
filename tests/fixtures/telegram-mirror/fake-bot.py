#!/usr/bin/env python3
"""Stand-in for bin/fm-telegram.py's socket side in the real-Pi guard.

Records every frame the Pi extension writes, with timestamps, and delivers the
lines of $FM_TELEGRAM_DIR/inject.txt back-to-back the way the real bot drains
its in-memory queue.
"""
import asyncio
import base64
import json
import os
import time
from pathlib import Path

HOME = Path(os.environ["FM_TELEGRAM_DIR"])
LOG = HOME / "frames.log"
SOCK = HOME / "bot.sock"
INJECT = HOME / "inject.txt"
INJECT_IMAGE = HOME / "inject-image.txt"


def note(line: str) -> None:
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(f"{time.time():.3f} {line}\n")


async def deliver_injected(writer: asyncio.StreamWriter) -> None:
    while True:
        await asyncio.sleep(0.1)
        if INJECT_IMAGE.exists():
            caption = INJECT_IMAGE.read_text(encoding="utf-8").strip()
            INJECT_IMAGE.unlink()
            # A 1x1 PNG is enough to prove the image survives the whole path.
            pixel = base64.b64encode(bytes.fromhex(
                "89504e470d0a1a0a0000000d4948445200000001000000010103000000"
                "25db56ca00000003504c5445000000a77a3dda0000000174524e530040"
                "e6d8660000000a4944415408d76360000000020001e221bc3300000000"
                "49454e44ae426082")).decode()
            writer.write((json.dumps({"t": "deliver", "id": "img1", "text": caption,
                                      "image": {"data": pixel, "mime": "image/png"}}) + "\n").encode())
            await writer.drain()
            continue
        if not INJECT.exists():
            continue
        lines = [line for line in INJECT.read_text(encoding="utf-8").splitlines() if line.strip()]
        INJECT.unlink()
        for index, text in enumerate(lines, start=1):
            writer.write((json.dumps({"t": "deliver", "id": f"m{index}", "text": text}) + "\n").encode())
        await writer.drain()


async def serve_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    note("CONNECT")
    pump = asyncio.create_task(deliver_injected(writer))
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            payload = line.decode("utf-8").strip()
            note(f"FRAME {payload}")
            frame = json.loads(payload)
            if frame.get("t") == "command":
                writer.write((json.dumps({"t": "command_result", "id": frame["id"],
                                          "text": "Mirror is on. Firstmate is connected."}) + "\n").encode())
                await writer.drain()
    finally:
        pump.cancel()
        note("DISCONNECT")


async def main() -> None:
    HOME.mkdir(parents=True, exist_ok=True)
    LOG.touch()
    if SOCK.exists():
        SOCK.unlink()
    server = await asyncio.start_unix_server(serve_client, path=str(SOCK))
    async with server:
        await asyncio.Future()


asyncio.run(main())
