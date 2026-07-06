#!/usr/bin/env python3
"""Telegram webhook server. Receives updates, writes to inbox, replies async."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

FM_ROOT = Path(os.environ.get("FM_ROOT", "/home/m_gogate/hermes/firstmate"))
INBOX = FM_ROOT / "state" / "tg-inbox"
CHAT_ID_FILE = FM_ROOT / "state" / ".tg-chat-id"

INBOX.mkdir(parents=True, exist_ok=True)

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

    # Persist chat_id
    CHAT_ID_FILE.write_text(str(chat_id))

    # Write to inbox for firstmate
    inbox_file = INBOX / f"{update_id}.json"
    inbox_file.write_text(json.dumps(body))

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
