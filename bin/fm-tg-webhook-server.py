#!/usr/bin/env python3
"""Telegram webhook server. Receives updates, acknowledges instantly, queues for firstmate."""
from __future__ import annotations

import json
import os
import urllib.request
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

FM_ROOT = Path(os.environ.get("FM_ROOT", "/home/m_gogate/hermes/firstmate"))
INBOX = FM_ROOT / "state" / "tg-inbox"
CHAT_ID_FILE = FM_ROOT / "state" / ".tg-chat-id"
BOT_TOKEN = "8743350050:AAFHOKSS5KgYAvmY_j1MV3m3blcy7KXNBlU"

INBOX.mkdir(parents=True, exist_ok=True)


def send_telegram(method: str, data: dict) -> dict:
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception:
        return {"ok": False}


def handle_simple(text: str) -> str | None:
    """Handle trivial questions locally. Returns answer or None if complex."""
    lower = text.lower().strip()
    
    # Common patterns
    if "squared" in lower or "^2" in lower:
        try:
            num = int("".join(c for c in lower.replace("squared", "").replace("^2", "").strip() if c.isdigit() or c == "-"))
            return str(num * num)
        except: pass
    
    if "cubed" in lower or "^3" in lower:
        try:
            num = int("".join(c for c in lower.replace("cubed", "").replace("^3", "").strip() if c.isdigit() or c == "-"))
            return str(num * num * num)
        except: pass
    
    if "square root" in lower or "sqrt" in lower:
        import math
        try:
            num = int("".join(c for c in lower.replace("square root", "").replace("sqrt", "").strip() if c.isdigit() or c == "-"))
            return str(int(math.sqrt(num)))
        except: pass
    
    # General math
    if all(c in "0123456789+-*/.= x()?" for c in lower.replace(" ", "")) and any(c in lower for c in "+-*/"):
        expr = lower.rstrip("?").replace("x", "*").replace("=", "").strip()
        try:
            if "=" in expr:
                parts = expr.split(",")[0].split("=")
                if len(parts) == 2:
                    left = parts[0].strip()
                    right = parts[1].strip()
                    if "+" in left:
                        const = int(left.split("+")[-1].strip())
                        return str(int(right) - const)
                    if "-" in left:
                        const = int(left.split("-")[-1].strip())
                        return str(int(right) + const)
                    if "*" in left:
                        const = int(left.split("*")[-1].strip())
                        return str(int(right) // const)
            result = eval(expr.replace(" ", ""))
            return str(int(result))
        except Exception:
            return None

    return None


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

    # Try simple auto-reply first
    answer = handle_simple(text)
    if answer:
        send_telegram("sendMessage", {"chat_id": chat_id, "text": answer})
    else:
        # Complex question: acknowledge and queue for firstmate
        send_telegram("sendChatAction", {"chat_id": chat_id, "action": "typing"})
        send_telegram("sendMessage", {"chat_id": chat_id, "text": "Got it. Answering shortly..."})

    # Always write to inbox for firstmate review
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
