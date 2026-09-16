#!/usr/bin/env python3
"""WhatsApp Agent Platform v1 HTTP and credential-free scripted simulator.

Only fixed HTTPS api.whatsapp.com/agent/v1 endpoints are reachable. Redirects
and environment proxies are disabled, credentials are read privately per call,
and untrusted HTTP error strings are never diagnostics. A simulator script is
an array of {endpoint,http,body,headers} or {endpoint,fault}; its position is
durable. It never instantiates the HTTP client or reads a credential file.
"""

import email.utils
import getpass
import http.client
import json
import os
import random
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

from fm_whatsapp_store import BridgeError, digest, encode


class Reply:
    def __init__(self, http=0, body=None, headers=None, fault=None):
        self.http, self.body, self.headers, self.fault = http, body, headers or {}, fault


def classify(endpoint, reply):
    error = reply.body.get("error", {}) if isinstance(reply.body, dict) else {}
    error = error if isinstance(error, dict) else {}
    code = error.get("code")
    if reply.http == 409 and code == 1752041 and endpoint == "updates":
        return "poll_conflict"
    if reply.http == 429 or (reply.http == 503 and code == 131016):
        return "retry"
    if reply.http == 401 or (reply.http == 400 and code == 100 and endpoint == "updates"):
        return "auth_failed"
    if 400 <= reply.http < 500:
        return "permanent"
    if reply.fault or reply.http >= 500:
        return "delivery_unknown" if endpoint == "messages" else "retry"
    if 200 <= reply.http < 300:
        return "accepted"
    return "permanent"


def delay(attempt, headers, now, rng=random.random):
    result = min(300, 2 ** min(attempt, 8)) * (0.5 + rng())
    retry = next((str(v) for k, v in headers.items() if k.lower() == "retry-after"), "")
    try:
        seconds = float(retry)
    except ValueError:
        try:
            seconds = email.utils.parsedate_to_datetime(retry).timestamp() - now
        except (ValueError, TypeError, OverflowError):
            seconds = 0
    # Retry-After is honored when supplied; it is not an API guarantee.
    return max(result, seconds)


def read_secret(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise BridgeError("token file must be an owner-only regular file")
        raw = os.read(fd, 8193)
    finally:
        os.close(fd)
    value = raw.decode().strip()
    if not value or len(raw) > 8192 or any(c.isspace() for c in value):
        raise BridgeError("invalid local token file; use configure-token")
    return value


def configure_token(config):
    if config.token_file is None:
        raise BridgeError("set token_file locally before configuring the secret")
    if not os.isatty(0):
        raise BridgeError("configure-token requires a local interactive terminal")
    secret = getpass.getpass("API key (hidden; never paste in chat): ")
    if not secret or any(c.isspace() for c in secret) or len(secret) > 8192:
        raise BridgeError("invalid token format")
    # Atomic replacement supports rotation without exposing the old or new value.
    from fm_inbox_key import atomic_write
    config.token_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(config.token_file, secret + "\n")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HTTP:
    def __init__(self, config):
        if config.mode != "live" or not config.enabled:
            raise BridgeError("live HTTP is disabled")
        self.config = config
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, endpoint, payload):
        if endpoint not in ("updates", "messages"):
            raise BridgeError("endpoint is pending a later stage")
        if endpoint == "messages" and not self.config.outbound:
            raise BridgeError("outbound is not locally authorized")
        url = "https://api.whatsapp.com/agent/v1/" + endpoint
        data = None
        timeout = self.config.timeout + 15
        if endpoint == "updates":
            url += "?" + urllib.parse.urlencode(payload)
        else:
            data = encode(payload).encode()
            timeout = self.config.send_timeout
        req = urllib.request.Request(url, data=data, headers={
            "Authorization": "Bearer " + read_secret(self.config.token_file),
            "Content-Type": "application/json"})
        status, headers = 0, {}
        try:
            try:
                response = self.opener.open(req, timeout=timeout)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status, headers = response.code, dict(response.headers)
                if status == 204:
                    return Reply(status, headers=headers)
                raw = response.read(2 * 1024 * 1024 + 1)
                if len(raw) > 2 * 1024 * 1024:
                    return Reply(status, headers=headers, fault="oversized_response")
                try:
                    body = json.loads(raw)
                except (ValueError, UnicodeError):
                    return Reply(status, headers=headers, fault="invalid_json")
                return Reply(status, body, headers)
        except (OSError, urllib.error.URLError, http.client.HTTPException):
            return Reply(status, headers=headers, fault="connection_or_timeout")


class Simulator:
    def __init__(self, store, path):
        self.store = store
        self.script = json.loads(path.read_text())
        if not isinstance(self.script, list):
            raise BridgeError("simulation fixture must be an array")
        identity = digest(self.script)
        with store.tx():
            if store.get("sim_fixture") not in (None, identity):
                raise BridgeError("simulator fixture changed; use a new disposable state")
            store.put("sim_fixture", identity)

    def call(self, endpoint, payload):
        with self.store.tx():
            position = int(self.store.get("sim_position") or 0)
            if position < len(self.script) and self.script[position].get("endpoint") == endpoint:
                value = self.script[position]
                self.store.put("sim_position", position + 1)
                return Reply(value.get("http", 0), value.get("body"),
                             value.get("headers"), value.get("fault"))
            if endpoint == "updates":
                return Reply(204)
            seq = self.store.db.execute("SELECT COALESCE(MAX(seq),0)+1 FROM sim_sends").fetchone()[0]
            self.store.db.execute("INSERT INTO sim_sends VALUES(?,?)", (seq, encode(payload)))
            return Reply(200, {"messaging_product": "whatsapp",
                               "contacts": [{"input": payload["to"], "wa_id": payload["to"]}],
                               "messages": [{"id": f"wamid.simulated.{seq}"}]})
