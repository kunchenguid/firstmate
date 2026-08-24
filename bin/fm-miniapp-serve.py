#!/usr/bin/env python3
"""Serve the Telegram Mini App decision page and take its answers.

The page asks the captain one question; the answer travels straight back over
HTTPS from the page itself. That is the whole point of the Mini App route: it
needs no second getUpdates reader, so it cannot collide with the poller that
already owns those bots, and the captain sees his answer land immediately
instead of after the next polling sweep.

Everything that identifies this installation comes from the environment. There
is no default bot, no default chat and no default address, and a missing value
refuses to start rather than pointing at a stranger's bot:

    FM_MINIAPP_BOT_TOKEN   the bot whose initData is accepted    (required)
    FM_MINIAPP_OWNER_ID    the only user id allowed to answer    (required)
    FM_MINIAPP_CHANNEL     the <channel> part of the answer file (required)
    FM_MINIAPP_QUESTIONS   directory holding the question files  (required)
    FM_MINIAPP_ANSWERS     directory the answers are written to  (required)
    FM_MINIAPP_LISTEN      host:port to bind      (default 127.0.0.1:8779)
    FM_MINIAPP_WEB         directory of the page  (default fm-miniapp/ beside
                           this script)
    FM_MINIAPP_MAX_AGE     initData age limit in seconds        (default 900)

Bind address is a safety decision, not a detail. On a machine without a running
firewall, binding 0.0.0.0 is reachable from the internet the second the process
starts. Bind the Docker bridge gateway instead, so only the reverse proxy in
front of it can reach the service.

Routes:

    GET  /            the page
    GET  /app.js      its script - a separate file on purpose, see below
    GET  /style.css   its styling, same reason
    GET  /question    the question named by ?f=<id>, initData required
    POST /answer      the choice, initData required

The page's script must live in its own file. This service sends a
content-security-policy without 'unsafe-inline', so a <script> block inside the
page is blocked and the captain sees a page that renders its heading and then
stops - the exact "Mini App does not load" the prototype produced. Relaxing the
policy to fix that would throw away the reason the policy is here, which is that
the page cannot be made to load foreign script.

Answers are written as <query-id>.<channel>.msg with mode 0600 through a temp
file and os.replace, byte-for-byte the same contract as the existing poller's
inbox files, so every reader of that inbox understands them unchanged.
"""

import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The import lives beside this script; that is why the path insert above comes
# first. Deploying means copying both files into the same directory.
import importlib.util

_VERIFY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-telegram-verify.py")
_spec = importlib.util.spec_from_file_location("fm_telegram_verify", _VERIFY_PATH)
_verify_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_verify_mod)
InvalidInitData = _verify_mod.InvalidInitData
verify_init_data = _verify_mod.verify_init_data
field_names = _verify_mod.field_names

# The page is loaded inside Telegram's own web view, which is an iframe on
# Telegram Web. default-src 'none' means every source has to be named; nothing
# is inherited by accident. telegram.org is here because the web-app bridge
# script is served from there and there is no offline copy of it.
CSP = (
    "default-src 'none'; "
    "script-src 'self' https://telegram.org; "
    "style-src 'self'; "
    "connect-src 'self'; "
    "img-src 'self' data:; "
    "base-uri 'none'; "
    "form-action 'none'; "
    "frame-ancestors https://telegram.org https://web.telegram.org"
)

STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}

# An id that becomes part of a filename. Anything outside this set could walk
# out of the inbox directory, so it is replaced rather than trusted.
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

MAX_BODY = 8192


class Config:
    def __init__(self, env):
        missing = []

        def need(name):
            value = env.get(name, "").strip()
            if not value:
                missing.append(name)
            return value

        self.bot_token = need("FM_MINIAPP_BOT_TOKEN")
        owner_raw = need("FM_MINIAPP_OWNER_ID")
        self.channel = need("FM_MINIAPP_CHANNEL")
        self.questions = need("FM_MINIAPP_QUESTIONS")
        self.answers = need("FM_MINIAPP_ANSWERS")
        if missing:
            raise SystemExit(
                "fm-miniapp-serve: refusing to start, unset: " + ", ".join(missing)
            )
        try:
            self.owner_id = int(owner_raw)
        except ValueError:
            raise SystemExit("fm-miniapp-serve: FM_MINIAPP_OWNER_ID must be a number")
        if not SAFE_ID.match(self.channel):
            raise SystemExit(
                "fm-miniapp-serve: FM_MINIAPP_CHANNEL must match [A-Za-z0-9_-]"
            )

        listen = env.get("FM_MINIAPP_LISTEN", "127.0.0.1:8779")
        host, _, port = listen.rpartition(":")
        if not host or not port.isdigit():
            raise SystemExit("fm-miniapp-serve: FM_MINIAPP_LISTEN must be host:port")
        self.host, self.port = host, int(port)

        self.web = env.get("FM_MINIAPP_WEB") or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "fm-miniapp"
        )
        try:
            self.max_age_s = int(env.get("FM_MINIAPP_MAX_AGE", "900"))
        except ValueError:
            raise SystemExit("fm-miniapp-serve: FM_MINIAPP_MAX_AGE must be a number")


def log(message):
    print(f"{time.strftime('%H:%M:%S')}  {message}", flush=True)


def answer_id(fields):
    """A filename-safe id for one answer.

    Telegram supplies query_id for a Mini App opened from a message button. A
    Mini App opened another way carries none, so fall back to the payload's own
    hash-free identity rather than inventing a counter that two processes could
    hand out twice.
    """
    candidate = fields.get("query_id", "")
    if SAFE_ID.match(candidate):
        return candidate
    import hashlib

    seed = f"{fields.get('auth_date', '')}:{fields.get('user', '')}"
    return "anon-" + hashlib.sha256(seed.encode()).hexdigest()[:24]


def write_atomic(path, text, mode=0o600):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-miniapp"
    sys_version = ""
    config = None

    # BaseHTTPRequestHandler logs to stderr in its own format; route it through
    # the same one-line shape as everything else and drop the noise.
    def log_message(self, fmt, *args):
        log(f'"{fmt % args}"')

    def _send(self, status, body, content_type, extra=None):
        payload = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj), "application/json; charset=utf-8")

    def _reject(self, reason, init_data):
        """One rejection shape for every route.

        The field NAMES go to the log, never the values: without them a rejected
        real payload cannot be told apart from a forgery, and with them the
        captain's identity and a valid hash would sit in the journal.
        """
        log(f"REJECTED: {reason} [fields: {','.join(field_names(init_data))}]")
        self._json(403, {"ok": False, "error": reason})

    def _checked(self):
        """Return the verified fields, or None after answering with a rejection."""
        init_data = self.headers.get("X-Telegram-Init-Data", "")
        try:
            return verify_init_data(
                init_data,
                self.config.bot_token,
                owner_id=self.config.owner_id,
                max_age_s=self.config.max_age_s,
            )
        except InvalidInitData as exc:
            self._reject(str(exc), init_data)
            return None

    def _question_path(self, question_id):
        if not SAFE_ID.match(question_id or ""):
            return None
        return os.path.join(self.config.questions, f"{question_id}.json")

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path in STATIC:
            name, content_type = STATIC[path]
            try:
                with open(os.path.join(self.config.web, name), "rb") as handle:
                    self._send(200, handle.read(), content_type)
            except OSError:
                self._json(500, {"ok": False, "error": "page not installed"})
            return
        if path == "/question":
            fields = self._checked()
            if fields is None:
                return
            params = dict(
                pair.split("=", 1) for pair in query.split("&") if "=" in pair
            )
            import urllib.parse

            question_id = urllib.parse.unquote(params.get("f", ""))
            question_path = self._question_path(question_id)
            if not question_path or not os.path.exists(question_path):
                self._json(404, {"ok": False, "error": "question not found"})
                return
            with open(question_path) as handle:
                question = json.load(handle)
            self._json(200, {"ok": True, "question": question})
            return
        self._json(404, {"ok": False, "error": "no such route"})

    def do_POST(self):
        if self.path.partition("?")[0] != "/answer":
            self._json(404, {"ok": False, "error": "no such route"})
            return
        fields = self._checked()
        if fields is None:
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._json(400, {"ok": False, "error": "body missing or too large"})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._json(400, {"ok": False, "error": "body is not JSON"})
            return

        question_id = str(body.get("f", ""))
        question_path = self._question_path(question_id)
        if not question_path or not os.path.exists(question_path):
            self._json(404, {"ok": False, "error": "question not found"})
            return
        with open(question_path) as handle:
            question = json.load(handle)
        options = question.get("options") or []

        # The choice is an INDEX into the question this service already holds,
        # never a label the page sends. A label from the page would put text the
        # service never authored into the captain's inbox.
        try:
            index = int(body.get("choice"))
            label = options[index]
        except (TypeError, ValueError, IndexError):
            self._json(400, {"ok": False, "error": "choice is not one of the options"})
            return

        name = f"{answer_id(fields)}.{self.config.channel}.msg"
        path = os.path.join(self.config.answers, name)
        write_atomic(path, f"[MiniApp {question_id}] {label}")
        log(
            f"ACCEPTED question={question_id} choice={index} -> {name} "
            f"(initData {fields['_age_s']} s old, reading {fields['_reading']})"
        )
        self._json(200, {"ok": True, "choice": label})


def main():
    config = Config(os.environ)
    os.makedirs(config.questions, mode=0o700, exist_ok=True)
    os.makedirs(config.answers, mode=0o700, exist_ok=True)
    Handler.config = config
    server = ThreadingHTTPServer((config.host, config.port), Handler)
    log(f"listening on {config.host}:{config.port}, channel {config.channel}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
