#!/usr/bin/env python3
"""Telegram webhook — receives updates, writes to inbox, wakes firstmate via wake queue."""
from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

FM_ROOT = Path(os.environ.get("FM_ROOT", "/home/m_gogate/hermes/firstmate"))
INBOX = FM_ROOT / "state" / "tg-inbox"
WAKE_QUEUE = FM_ROOT / "state" / ".wake-queue"
CHAT_ID_FILE = FM_ROOT / "state" / ".tg-chat-id"
BOT_TOKEN = "8743350050:AAFHOKSS5KgYAvmY_j1MV3m3blcy7KXNBlU"

INBOX.mkdir(parents=True, exist_ok=True)


def send_typing(chat_id: int) -> None:
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendChatAction"
    body = urllib.parse.urlencode({"chat_id": chat_id, "action": "typing"}).encode()
    req = urllib.request.Request(url, data=body)
    try:
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass


app = FastAPI()


@app.post("/telegram-webhook")
async def telegram_webhook(request: Request):
    body = await request.json()
    msg = body.get("message", {})
    text = msg.get("text", "")
    chat_id = msg.get("chat", {}).get("id", "")
    update_id = body.get("update_id", 0)

    if not text or not chat_id:
        return JSONResponse({"ok": True})

    CHAT_ID_FILE.write_text(str(chat_id))
    send_typing(chat_id)

    # Write to inbox
    inbox_file = INBOX / f"{update_id}.json"
    inbox_file.write_text(json.dumps(body))

    # Wake firstmate immediately via wake queue
    epoch = int(time.time())
    wake_line = f"{epoch}\t0\tcheck\t{update_id}\t{text[:80]}\n"
    with open(WAKE_QUEUE, "a") as f:
        f.write(wake_line)

    return JSONResponse({"ok": True})


@app.get("/health")
async def health():
    return {"ok": True}


def main():
    import uvicorn
    port = int(os.environ.get("FM_TG_WEBHOOK_PORT", "8089"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
