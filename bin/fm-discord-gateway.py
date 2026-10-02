#!/usr/bin/env python3
"""Firstmate Discord Gateway client (primary event mechanism).

Connects to Discord's Gateway with GUILDS + GUILD_MESSAGES intents (the
latter is the intent that actually delivers MESSAGE_CREATE), dispatches
MESSAGE_CREATE and INTERACTION_CREATE events to ``bin/fm-discord-poll.sh
--event-file`` for idempotent routing into Firstmate's existing message
pipeline, and reconnects with exponential backoff + resume. Slash
interactions arrive over this same outbound connection already
authenticated by the gateway session, so no Ed25519 signature check and
no inbound HTTPS endpoint are involved (Relay-style outbound-only). Message-content intent stays
opt-in (DISCORD_MESSAGE_CONTENT=1); without it only mentions/replies that
Discord delivers without privileged intent are routed.

Secrets resolve like the shell contract (environment wins over the home's
.env); without a token --once reports "not configured" instead of exiting
successfully while inert. Stdlib only (no new dependencies): minimal
RFC6455 client over socket+ssl with masked client frames, continuation
reassembly, scheduled heartbeats with server-request handling, and ACK
liveness. The loop holds state/discord-gateway.lock (pid); --stop ends it.

Usage:
  fm-discord-gateway.py           run the reconnect loop (foreground)
  fm-discord-gateway.py --once    health check: gateway session-limit lookup
  fm-discord-gateway.py --stop     stop a running loop via its lock
  fm-discord-gateway.py --print-intents
                                  print the configured intent bits and exit

Env: FM_HOME (or FM_ROOT_OVERRIDE), DISCORD_BOT_TOKEN, DISCORD_GUILD_ID,
DISCORD_MESSAGE_CONTENT, DISCORD_API_BASE, DISCORD_ENV_FILE.
Secrets are never printed; failures exit non-zero with a redacted diagnostic.
"""
import json
import os
import random
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import hashlib
import base64

API_DEFAULT = "https://discord.com/api/v10"
GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"
INTENTS_GUILDS = 1 << 0
INTENTS_GUILD_MESSAGES = 1 << 9
INTENTS_MESSAGE_CONTENT = 1 << 15
BASE_BACKOFF = 5
MAX_BACKOFF = 300


def redact(text):
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    if token and len(token) >= 8:
        text = text.replace(token, "***")
    return text


def diag(msg):
    print("fm-discord-gateway: " + redact(msg), file=sys.stderr)


def resolve_home():
    root = os.environ.get("FM_ROOT_OVERRIDE") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..")
    return os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or root


def env_file_value(key, path):
    """Mirror fmx_env_get: last assignment wins; tolerate leading export,
    surrounding whitespace, and one layer of matching quotes."""
    found = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("export "):
                    stripped = stripped[len("export "):].lstrip()
                if not stripped.startswith(key + "="):
                    continue
                val = stripped[len(key) + 1:].strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                    val = val[1:-1]
                found = val
    except OSError:
        return None
    return found


def load_config(home):
    """Environment wins over the home's .env, matching the shell contract."""
    path = os.environ.get("DISCORD_ENV_FILE") or os.path.join(home or "", ".env")
    for key in ("DISCORD_BOT_TOKEN", "DISCORD_GUILD_ID", "DISCORD_OWNER_USER_ID",
                "DISCORD_MESSAGE_CONTENT", "DISCORD_API_BASE"):
        if os.environ.get(key):
            continue
        val = env_file_value(key, path)
        if val:
            os.environ[key] = val
    flag = os.environ.get("DISCORD_MESSAGE_CONTENT", "").strip().lower()
    os.environ["DISCORD_MESSAGE_CONTENT"] = "1" if flag in ("1", "true", "yes", "on") else ""
    if not os.environ.get("DISCORD_API_BASE"):
        os.environ["DISCORD_API_BASE"] = API_DEFAULT
    else:
        os.environ["DISCORD_API_BASE"] = os.environ["DISCORD_API_BASE"].rstrip("/")


def intents():
    extra = INTENTS_MESSAGE_CONTENT if os.environ.get("DISCORD_MESSAGE_CONTENT") == "1" else 0
    return INTENTS_GUILDS | INTENTS_GUILD_MESSAGES | extra


def lock_path(home):
    return os.path.join(home, "state", "discord-gateway.lock")


def lock_alive(home):
    try:
        with open(lock_path(home), "r", encoding="utf-8") as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def send_frame(sock, opcode, payload=b""):
    frame = bytearray([0x80 | (opcode & 0x0F)])
    n = len(payload)
    if n < 126:
        frame.append(0x80 | n)
    elif n < 65536:
        frame.append(0x80 | 126)
        frame += struct.pack("!H", n)
    else:
        frame.append(0x80 | 127)
        frame += struct.pack("!Q", n)
    mask = os.urandom(4)
    frame += mask
    frame += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(frame))


def ws_send(sock, payload):
    send_frame(sock, 0x1, json.dumps(payload).encode())


class WsConn:
    """Buffered frame reader. Bytes already read past the HTTP handshake
    headers stay in the buffer instead of being dropped, and fragmented
    data frames are reassembled before delivery."""

    def __init__(self, sock, pending=b""):
        self.sock = sock
        self.buf = bytearray(pending)
        self.frag_opcode = None
        self.frag_data = bytearray()

    def _take(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(n - len(self.buf), 4096))
            if not chunk:
                raise ConnectionError("gateway closed")
            self.buf += chunk
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def recv_message(self, timeout):
        """Return the next complete text message as a decoded string.
        PINGs are answered with a masked PONG inline; server PONGs and
        stray control frames are absorbed. socket.timeout propagates."""
        while True:
            self.sock.settimeout(timeout)
            hdr = self._take(2)
            b1, b2 = hdr[0], hdr[1]
            fin = bool(b1 & 0x80)
            opcode = b1 & 0x0F
            masked = bool(b2 & 0x80)
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._take(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._take(8))[0]
            mask = self._take(4) if masked else None
            data = self._take(length) if length else b""
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise ConnectionError("gateway close frame")
            if opcode == 0x9:  # ping -> masked pong, per RFC 6455
                send_frame(self.sock, 0xA, data)
                continue
            if opcode == 0xA:  # server pong
                continue
            if opcode == 0x0:  # continuation
                if self.frag_opcode is None:
                    continue
                self.frag_data += data
                if fin:
                    text = bytes(self.frag_data).decode("utf8")
                    self.frag_opcode = None
                    self.frag_data = bytearray()
                    return text
                continue
            if opcode in (0x1, 0x2):
                if fin:
                    return data.decode("utf8")
                self.frag_opcode = opcode
                self.frag_data = bytearray(data)
                continue
            # Unknown frame: ignore and keep reading.


def ws_connect(host, port, path):
    sock = socket.create_connection((host, port), timeout=15)
    ctx = ssl.create_default_context()
    sock = ctx.wrap_socket(sock, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("gateway handshake failed")
        head += chunk
    header_block, _, trailing = head.partition(b"\r\n\r\n")
    if b" 101 " not in header_block.split(b"\r\n", 1)[0]:
        raise ConnectionError("gateway handshake rejected: " + redact(header_block[:200].decode("utf8", "replace")))
    return WsConn(sock, pending=trailing)


def _route_poll(poll, path):
    try:
        subprocess.run([poll, "--event-file", path], check=False)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def route_event(evt):
    home = resolve_home()
    root = os.environ.get("FM_ROOT_OVERRIDE") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..")
    if not home:
        return
    poll = os.path.join(root, "bin", "fm-discord-poll.sh")
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(evt, f)
        path = f.name
    threading.Thread(target=_route_poll, args=(poll, path), daemon=True).start()


def run_once(token):
    import urllib.request
    api = os.environ.get("DISCORD_API_BASE") or API_DEFAULT
    req = urllib.request.Request(
        api.rstrip("/") + "/gateway/bot",
        headers={"Authorization": "Bot " + token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = json.load(r)
    except Exception as e:  # noqa: BLE001 - diagnostic only
        diag("gateway lookup failed: " + str(e))
        return 1
    print("discord: gateway ok session_start_limit_remaining=%s" % redact(str(body.get("session_start_limit", {}).get("remaining", "?"))))
    return 0


def heartbeat(sock, seq):
    ws_send(sock, {"op": 1, "d": seq})


def run_loop(token):
    home = resolve_home()
    backoff = BASE_BACKOFF
    seq = None
    session_id = None
    resume_url = None
    while True:
        conn = None
        try:
            url = resume_url or GATEWAY_URL
            hostpath = url.split("wss://", 1)[1]
            host, _, path = hostpath.partition("/")
            path = "/" + path
            conn = ws_connect(host, 443, path)
            hello = json.loads(conn.recv_message(30))
            interval = hello.get("d", {}).get("heartbeat_interval", 41250) / 1000.0
            if session_id:
                ws_send(conn.sock, {"op": 6, "d": {"token": token, "session_id": session_id, "seq": seq}})
            else:
                ws_send(
                    conn.sock,
                    {"op": 2, "d": {"token": token, "intents": intents(),
                                     "properties": {"os": sys.platform, "browser": "firstmate", "device": "firstmate"}}},
                )
            now = time.time()
            next_beat = now + interval * random.uniform(0, 1)
            last_beat = None
            awaiting_ack = False
            while True:
                wait = max(0.5, next_beat - time.time())
                try:
                    raw = conn.recv_message(wait)
                except socket.timeout:
                    raw = None
                now = time.time()
                if raw is not None:
                    evt = json.loads(raw)
                else:
                    evt = None
                if evt is not None:
                    op = evt.get("op")
                    if op == 10:  # hello on resume path
                        continue
                    if op == 11:  # heartbeat ACK
                        awaiting_ack = False
                        continue
                    if op == 1:  # server asks for a heartbeat now
                        heartbeat(conn.sock, seq)
                        last_beat = now
                        awaiting_ack = True
                        next_beat = now + interval
                        continue
                    if op == 7:  # reconnect
                        raise ConnectionError("gateway asked to reconnect")
                    if op == 9:  # invalid session: fresh identify on the
                        session_id = None  # main URL after a short delay
                        seq = None
                        resume_url = None
                        time.sleep(1 + random.uniform(0, 4))
                        raise ConnectionError("invalid session")
                    if evt.get("s") is not None:
                        seq = evt["s"]
                    t = evt.get("t")
                    d = evt.get("d", {})
                    if t == "READY":
                        session_id = d.get("session_id")
                        resume_url = d.get("resume_gateway_url")
                        backoff = BASE_BACKOFF
                    elif t in ("MESSAGE_CREATE", "INTERACTION_CREATE"):
                        route_event({"t": t, "d": d})
                if now >= next_beat:
                    if awaiting_ack and last_beat is not None and now - last_beat > interval:
                        raise ConnectionError("heartbeat unacknowledged")
                    heartbeat(conn.sock, seq)
                    last_beat = now
                    awaiting_ack = True
                    next_beat = now + interval
        except Exception as e:  # noqa: BLE001 - reconnect loop by design
            diag("disconnected (%s); retrying in %ss" % (str(e), backoff))
            try:
                if conn is not None:
                    conn.sock.close()
            except OSError:
                pass
            time.sleep(backoff + random.uniform(0, 2))
            backoff = min(backoff * 2, MAX_BACKOFF)


def main():
    home = resolve_home()
    load_config(home)
    if "--print-intents" in sys.argv:
        print(intents())
        return 0
    if "--stop" in sys.argv:
        pid = lock_alive(home)
        if pid is None:
            print("discord: gateway not running")
            return 0
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as e:
            diag("stop failed: " + str(e))
            return 1
        print("discord: gateway stop signalled (pid %d)" % pid)
        return 0
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    if not token:
        diag("not configured (DISCORD_BOT_TOKEN absent from environment and %s/.env); refusing to run inert" % (home or "?"))
        return 1
    if "--once" in sys.argv:
        return run_once(token)
    pid = lock_alive(home)
    if pid is not None:
        diag("already running (pid %d); refusing a second loop" % pid)
        return 1
    state_dir = os.path.join(home, "state")
    try:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
    except OSError:
        pass
    try:
        with open(lock_path(home), "w", encoding="utf-8") as f:
            f.write(str(os.getpid()))
    except OSError as e:
        diag("cannot write lock: " + str(e))
        return 1
    try:
        run_loop(token)
    finally:
        try:
            os.unlink(lock_path(home))
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
