#!/usr/bin/env python3
"""fm-mcp-session-proxy.py - transparent reverse proxy that logs MCP session detail.

WHY: an MCP gateway's own access log records only timestamp, status, latency and
method plus path.
It never records the Mcp-Session-Id the client presented, so a client reporting
"Session terminated" cannot be diagnosed from it.
Mark3labs/mcp-go answers that exact symptom with
"session terminated (404). need to re-initialize" whenever the gateway replies
404 to a request, so a bare 404 does not say whether the client presented no
session, an unparseable one, or a well-formed one the gateway no longer knows.
This proxy sits in front of the gateway and records that missing evidence.

WHAT IT LOGS, one JSON object per line, in chronological order:
  request    HTTP method, path, tool group, the presented Mcp-Session-Id (or
             "absent"), the real client address taken from the X-Forwarded-For
             chain plus Tailscale identity headers, and the JSON-RPC method when
             the body carries one.
  response   HTTP status, the Mcp-Session-Id the gateway issued, the MCP
             JSON-RPC error code and message when the gateway returns one,
             session_state, and a verdict naming the failure shape the
             exchange matches.
             session_state is always present and answers "does this front know
             this id": absent (none presented), untracked (an id this front
             never issued), or tracked (an id it did issue).
             A gateway that answers 200 to an untracked id is not enforcing
             session ownership, which the log then shows on successful calls
             too, not only on rejected ones.
             verdict is ok unless the exchange failed, in which case it names
             the shape:
               ok                  gateway answered normally
               missing-session-id  client presented no session header at all
               unparseable-id      client presented a session id the gateway
                                  cannot parse (gateway answers 404 "Invalid
                                  session ID"); the shape it does accept is the
                                  --session-id-pattern value, reported in the
                                  startup line
               unknown-session-id  a well-formed id this front never issued
               session-lost        an id this front did issue that the gateway
                                  then rejected, so the gateway lost the session
               client-closed       the client hung up before the gateway
                                  finished the response body
  session_created / session_deleted / session_expired
             lifecycle transitions observed at the gateway boundary.
  startup / shutdown / upstream_error
             process and transport events.

SECRETS: no header value is ever logged except Mcp-Session-Id.
Authorization, Proxy-Authorization, Cookie and api-key headers are recorded as a
presence boolean only.
Session ids and client addresses are the only identifiers in the log.

WHERE THE FAILURE COMES FROM: a client reports "session terminated" when the
gateway answers 404 to a request, so the failing call is the one whose log line
carries verdict=missing-session-id, unparseable-id, unknown-session-id or
session-lost; the session id beside it and the preceding session_created /
session_deleted / session_expired lines then say which of the three shapes it is.
STREAMING: response bytes reach the client unchanged, including chunked framing,
so an SSE stream is forwarded unbuffered exactly as the gateway sent it.
Only a bounded copy is decoded for inspection.

USAGE (fronting an MCP gateway on 127.0.0.1:8338 and listening on 8337):
  fm-mcp-session-proxy.py --listen-port 8337 --upstream-port 8338 \\
      --log ~/.local/share/mcpjungle/session-proxy.jsonl
Point the fronting proxy (Caddy) at 127.0.0.1:8337 instead of at the gateway.

DEPLOYED HERE AS: launchd label com.mcpjungle.session-proxy, running the installed
copy at ~/.local/share/mcpjungle/fm-mcp-session-proxy.py under /usr/bin/python3,
listening on 8337 and logging to
~/.local/share/mcpjungle/session-proxy.jsonl.
Caddy's ~/.config/mcpjungle-proxy/Caddyfile proxies its :8339 site to 8337, so the
chain is tailnet :8338 -> Caddy :8339 -> this proxy :8337 -> MCPJungle :8338.
Pointing Caddy's upstream back at 8338 bypasses the logger without removing it.

SERVES ONE REQUEST PER CONNECTION: the response advertises
`Connection: close` deliberately.
Noticing an abandoned stream needs a watcher on the client socket, and such a
watcher would swallow the bytes of a pipelined next request, so keep-alive is not
offered.

Run with --help for the full flag list.
Stdlib only, no third-party dependency.
"""

import argparse
import asyncio
import contextlib
import json
import os
import re
import signal
import sys
import time

SESSION_HEADER = "Mcp-Session-Id"
# Hop-by-hop headers are connection-scoped and must not be forwarded.
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)
# Never log these values; record presence only.
SECRET_HEADERS = frozenset({"authorization", "proxy-authorization", "cookie", "x-api-key"})
# Largest request body decoded while looking for the JSON-RPC method.
MAX_REQUEST_BODY_SCAN = 65536
# Largest response-body slice kept per event, so a long stream cannot grow the log.
MAX_RESPONSE_SNIPPET = 4096
# The id shape this gateway parses, measured against MCPJungle v0.4.6: the literal
# prefix "mcp-session-" (case-sensitive) then a hex UUID, and nothing else. An id
# outside this shape draws 404 "Invalid session ID", which is what a client
# reports as "session terminated". Override with --session-id-pattern for another
# gateway's shape.
DEFAULT_SESSION_ID_PATTERN = (
    r"\Amcp-session-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)
GROUP_RE = re.compile(r"/v0/groups/([^/]+)/mcp")
# SSE field lines carry stream metadata, not payload, so they are skipped while scanning.
SSE_FIELD_RE = re.compile(rb"\A(event|id|retry):", re.IGNORECASE)


def utc_now():
    """Return an ISO-8601 UTC timestamp with millisecond resolution."""
    now = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + ".%03dZ" % int(now * 1000 % 1000)


class HeaderMap:
    """Ordered, case-insensitive view of one HTTP head's headers.

    A hand-rolled parse keeps duplicate headers and wire casing intact, which
    both the forwarded head and the log depend on.
    """

    def __init__(self, pairs=()):
        self._pairs = [(str(name), str(value).strip()) for name, value in pairs]

    @classmethod
    def parse(cls, head_bytes):
        """Parse a head, skipping any status/request line before the header block."""
        pairs = []
        for raw_line in head_bytes.decode("latin-1").split("\r\n"):
            if not raw_line:
                continue
            name, sep, value = raw_line.partition(":")
            if not sep:
                continue
            pairs.append((name.strip(), value))
        return cls(pairs)

    def items(self):
        return list(self._pairs)

    def get_all(self, name):
        lowered = name.lower()
        return [value for key, value in self._pairs if key.lower() == lowered]

    def get(self, name):
        values = self.get_all(name)
        return values[0] if values else None


def first_header(headers, name):
    """Return the first non-empty value for a header name, case-insensitively."""
    for value in headers.get_all(name):
        if value:
            return value
    return None


def real_client(headers, peer):
    """Resolve the caller's address from the X-Forwarded-For chain.

    Every proxy in the chain appends its own view, so the leftmost entry is the
    closest thing to the original client and the rightmost is the hop that spoke
    to us. Prefer the leftmost non-loopback entry, else the entry our own hop
    recorded, else the transport peer.

    Behind Tailscale serve the whole chain is usually 127.0.0.1, because serve
    proxies from a local listener and does not forward the tailnet peer address.
    That is why the Tailscale identity headers are logged beside this: their
    presence is what separates a tailnet caller from a public one.
    """
    chain = first_header(headers, "X-Forwarded-For") or ""
    entries = [part.strip() for part in chain.split(",") if part.strip()]
    for entry in entries:
        if not entry.startswith("127.") and entry != "::1":
            return entry
    if entries:
        return entries[-1]
    return peer[0] if peer else "?"


def group_of(path):
    """Return the tool group named by a gateway path, or "" when not one."""
    match = GROUP_RE.search(path)
    return match.group(1) if match else ""


def parse_jsonrpc_method(body):
    """Return the JSON-RPC method named by a request body, or "" when absent.

    Batches and notifications both occur; the first named method is reported,
    which is what a reader needs to follow one call.
    """
    if not body:
        return ""
    try:
        payload = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return ""
    if isinstance(payload, list):
        payload = payload[0] if payload else None
    if isinstance(payload, dict) and isinstance(payload.get("method"), str):
        return payload["method"]
    return ""


class ChunkedInspector:
    """Decode chunked transfer framing on a copy of the bytes being forwarded.

    Raw bytes go to the client untouched; only this side view is decoded, so an
    SSE stream's JSON-RPC errors can be read without buffering the stream.
    """

    def __init__(self):
        self._buf = b""
        self._remaining = None
        self._done = False

    @property
    def done(self):
        """True once the terminating zero-length chunk has been seen."""
        return self._done

    def feed(self, raw):
        """Return the payload bytes carried by one raw upstream read."""
        if self._done:
            return b""
        self._buf += raw
        out = bytearray()
        while not self._done:
            if self._remaining is None:
                index = self._buf.find(b"\r\n")
                if index < 0:
                    break
                line = self._buf[:index]
                self._buf = self._buf[index + 2 :]
                try:
                    size = int(line.split(b";", 1)[0].strip(), 16)
                except ValueError:
                    self._done = True
                    break
                if size == 0:
                    self._done = True
                    break
                self._remaining = size
            if len(self._buf) < self._remaining:
                break
            out += self._buf[: self._remaining]
            self._buf = self._buf[self._remaining :]
            self._remaining = None
            if self._buf[:2] == b"\r\n":
                self._buf = self._buf[2:]
        return bytes(out)


class ResponseSniffer:
    """Bounded scan of response bytes for the first JSON-RPC result or error.

    Reads SSE `data:` lines and plain JSON bodies alike, and stops after the
    first meaningful message so a long tool result cannot dominate the log.
    """

    def __init__(self, limit=MAX_RESPONSE_SNIPPET):
        self._limit = limit
        self._buf = b""
        self.text = None
        self.code = None
        self.message = None
        self.saw_result = False
        self.saw_data = False

    def feed(self, payload):
        self._ingest(payload, final=False)

    def flush(self):
        """Scan whatever remains once the body ends, for a body with no trailing newline."""
        self._ingest(b"", final=True)

    def _ingest(self, payload, final):
        if self.text is not None or self.code is not None or self.saw_result:
            return
        self._buf += payload
        if len(self._buf) > self._limit:
            self._buf = self._buf[: self._limit]
        while True:
            newline = self._buf.find(b"\n")
            if newline < 0:
                if not final:
                    return
                line, self._buf = self._buf, b""
                if not line:
                    return
            else:
                line = self._buf[:newline]
                self._buf = self._buf[newline + 1 :]
            line = line.strip()
            if line.startswith(b"data:"):
                line = line[5:].strip()
                self.saw_data = True
            elif not line.startswith(b":") and not SSE_FIELD_RE.match(line):
                pass
            else:
                continue
            if not line:
                continue
            if line[:1] not in (b"{", b"["):
                if self.saw_data:
                    continue
                # Plain-text gateway rejection, e.g. "Invalid session ID".
                self.text = line.decode("utf-8", "replace")[: self._limit]
                return
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, list):
                obj = obj[0] if obj else None
            if not isinstance(obj, dict):
                continue
            if "error" in obj and isinstance(obj["error"], dict):
                self.code = obj["error"].get("code")
                self.message = str(obj["error"].get("message", ""))[: self._limit]
                return
            if "result" in obj:
                self.saw_result = True
                return


class SessionRegistry:
    """This proxy's view of which session ids the gateway front has handled.

    The distinction it exists for: an id the client presents that this front
    never issued points at the client reaching the wrong gateway or reusing a
    stale id, while an id this front did issue that the gateway then rejects
    points at the gateway itself losing the session.
    """

    def __init__(self, ttl_seconds):
        self._ttl = ttl_seconds
        self._sessions = {}

    def note_created(self, session_id, group):
        if session_id in self._sessions:
            return False
        self._sessions[session_id] = {
            "group": group,
            "created_at": time.time(),
            "last_seen": time.time(),
            "state": "created",
        }
        return True

    def note_seen(self, session_id):
        record = self._sessions.get(session_id)
        if record is not None:
            record["last_seen"] = time.time()

    def note_deleted(self, session_id):
        record = self._sessions.get(session_id)
        if record is not None:
            record["state"] = "deleted"
            record["last_seen"] = time.time()
            return True
        return False

    def known(self, session_id):
        return session_id in self._sessions

    def sweep_idle(self):
        """Return sessions idle beyond the TTL that are still marked live."""
        cutoff = time.time() - self._ttl
        stale = [
            (sid, rec)
            for sid, rec in self._sessions.items()
            if rec["state"] == "created" and rec["last_seen"] < cutoff
        ]
        for sid, rec in stale:
            rec["state"] = "expired"
        return stale


def render_request_head(method, path, headers, body_length):
    """Serialize the head sent upstream, dropping only hop-by-hop headers.

    Secret headers are forwarded untouched. SECRET_HEADERS governs logging only:
    this proxy observes credentials without ever writing them down, and certainly
    without consuming them, because an authenticated MCP caller would break the
    moment Authorization stopped reaching the gateway.
    """
    lines = ["%s %s HTTP/1.1" % (method, path)]
    for name, value in headers.items():
        if name.lower() in HOP_BY_HOP:
            continue
        lines.append("%s: %s" % (name, value))
    lines.append("Content-Length: %d" % body_length)
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


async def read_chunked(reader):
    """Read a chunked request body, returning (raw_bytes, decoded_bytes)."""
    raw = b""
    decoded = b""
    while True:
        size_line = await reader.readline()
        raw += size_line
        try:
            size = int(size_line.split(b";", 1)[0].strip(), 16)
        except ValueError:
            break
        if size == 0:
            raw += await reader.readline()
            break
        payload = await reader.readexactly(size)
        raw += payload + await reader.readexactly(2)
        decoded += payload
    return raw, decoded


class Proxy:
    """The reverse proxy itself."""

    def __init__(self, args, log_writer):
        self.args = args
        self.log_writer = log_writer
        self.registry = SessionRegistry(args.session_idle_ttl)
        self.session_id_re = re.compile(args.session_id_pattern)
        self.counter = 0

    def emit(self, event, **fields):
        record = {"ts": utc_now(), "event": event}
        record.update(fields)
        self.log_writer.write(json.dumps(record) + "\n")
        self.log_writer.flush()

    def next_rid(self):
        self.counter += 1
        return "r%d" % self.counter

    async def handle(self, reader, writer):
        rid = self.next_rid()
        peer = writer.get_extra_info("peername")
        try:
            request_line = await reader.readline()
            if not request_line:
                return
            method, path, _proto = request_line.decode("latin-1").split(" ", 2)
            headers = HeaderMap.parse(await reader.readuntil(b"\r\n\r\n"))
            body, raw_body = await self._read_request_body(reader, headers)
            await self._serve(rid, reader, writer, peer, method, path, headers, body, raw_body)
        except (ConnectionResetError, BrokenPipeError):
            self.emit("client_closed", rid=rid, phase="request-read")
        except asyncio.IncompleteReadError:
            self.emit("client_closed", rid=rid, phase="request-head")
        finally:
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()

    async def _read_request_body(self, reader, headers):
        """Read the request body, returning (bytes_to_scan, bytes_to_forward).

        Returns (None, None) for a body the proxy cannot safely relay.
        """
        if (first_header(headers, "Transfer-Encoding") or "").lower().find("chunked") >= 0:
            raw, decoded = await read_chunked(reader)
            return decoded[:MAX_REQUEST_BODY_SCAN], raw
        length_text = first_header(headers, "Content-Length")
        length = int(length_text) if length_text and length_text.isdigit() else 0
        if length <= 0:
            return b"", b""
        raw = await reader.readexactly(length)
        return raw[:MAX_REQUEST_BODY_SCAN], raw

    @staticmethod
    def _is_chunked(headers):
        return (first_header(headers, "Transfer-Encoding") or "").lower().find("chunked") >= 0

    async def _serve(self, rid, reader, writer, peer, method, path, headers, body, raw_body):
        presented = first_header(headers, SESSION_HEADER)
        group = group_of(path)
        client = real_client(headers, peer)
        started = time.time()
        self.emit(
            "request",
            rid=rid,
            method=method,
            path=path,
            group=group,
            session=presented or "absent",
            rpc=parse_jsonrpc_method(body),
            client=client,
            forwarded_for=first_header(headers, "X-Forwarded-For") or "",
            tailscale_login=first_header(headers, "Tailscale-User-Login"),
            tailscale_name=first_header(headers, "Tailscale-User-Name"),
            user_agent=first_header(headers, "User-Agent"),
            auth_present=first_header(headers, "Authorization") is not None,
        )
        if presented:
            self.registry.note_seen(presented)
        try:
            up_reader, up_writer = await asyncio.wait_for(
                asyncio.open_connection(self.args.upstream_host, self.args.upstream_port),
                timeout=self.args.upstream_timeout,
            )
        except (OSError, asyncio.TimeoutError) as exc:
            self.emit(
                "upstream_error",
                rid=rid,
                group=group,
                session=presented or "absent",
                stage="connect",
                error="%s: %s" % (type(exc).__name__, exc),
            )
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            with contextlib.suppress(Exception):
                await writer.drain()
            return
        try:
            up_writer.write(render_request_head(method, path, headers, len(raw_body)) + raw_body)
            await up_writer.drain()
            status, reason, resp_headers, head_raw = await asyncio.wait_for(
                self._read_response_head(up_reader), timeout=self.args.upstream_timeout
            )
            issued = first_header(resp_headers, SESSION_HEADER)
            chunked = self._is_chunked(resp_headers)
            self._forward_head(writer, status, reason, resp_headers, chunked)
            await writer.drain()
            sniffer = ResponseSniffer()
            inspector = ChunkedInspector() if chunked else None
            length_text = first_header(resp_headers, "Content-Length")
            expected = int(length_text) if length_text and length_text.isdigit() else None
            sent, client_error = await self._pump(
                up_reader, writer, sniffer, inspector, reader, expected
            )
        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError) as exc:
            self.emit(
                "upstream_error",
                rid=rid,
                group=group,
                session=presented or "absent",
                stage="response",
                error="%s: %s" % (type(exc).__name__, exc),
            )
            return
        finally:
            with contextlib.suppress(Exception):
                up_writer.close()

        verdict = "ok"
        if client_error:
            verdict = "client-closed"
        elif status >= 400:
            if not presented:
                verdict = "missing-session-id"
            elif not self.session_id_re.match(presented):
                verdict = "unparseable-id"
            elif self.registry.known(presented):
                verdict = "session-lost"
            else:
                verdict = "unknown-session-id"
        if issued and self.registry.note_created(issued, group):
            self.emit("session_created", rid=rid, session=issued, group=group)
        if method == "DELETE" and presented:
            self.emit("session_deleted", rid=rid, session=presented, status=status, tracked=self.registry.note_deleted(presented))
        self.emit(
            "response",
            rid=rid,
            status=status,
            session=presented or "absent",
            session_issued=issued or "none",
            group=group,
            error_code=sniffer.code,
            error_message=sniffer.message or sniffer.text,
            session_state=self.session_state(presented),
            verdict=verdict,
            bytes_to_client=sent,
            duration_ms=round((time.time() - started) * 1000, 3),
        )

    def session_state(self, presented):
        """Classify the presented session id against this front's own record of it.

        A gateway that answers 200 to an id it never issued is not enforcing
        session ownership, which is worth seeing on successful calls too, not
        only on the rejected ones.
        """
        if not presented:
            return "absent"
        return "tracked" if self.registry.known(presented) else "untracked"

    async def _read_response_head(self, up_reader):
        """Return (status, reason, headers, raw_head_bytes)."""
        raw = await up_reader.readuntil(b"\r\n\r\n")
        parts = raw.decode("latin-1").split("\r\n", 1)[0].split(" ", 2)
        status = int(parts[1])
        reason = parts[2] if len(parts) > 2 else ""
        return status, reason, HeaderMap.parse(raw), raw

    def _forward_head(self, writer, status, reason, resp_headers, chunked):
        """Relay the response head, keeping the body's framing valid for the client.

        The body that follows is the upstream body byte-for-byte, so a chunked
        body must keep its Transfer-Encoding header.
        """
        lines = ["HTTP/1.1 %d %s" % (status, reason or "")]
        for name, value in resp_headers.items():
            lowered = name.lower()
            if lowered == "transfer-encoding":
                if chunked:
                    lines.append("%s: %s" % (name, value))
                continue
            if lowered in HOP_BY_HOP:
                continue
            lines.append("%s: %s" % (name, value))
        # Always advertise a single-request connection. This proxy serves one
        # request per connection because it watches the client socket itself to
        # notice an abandoned stream, and such a watcher would swallow the bytes of
        # a pipelined next request. Without this header a fronting proxy reuses the
        # connection, prefetches its next request onto it, and reports 502 when this
        # side closes; one connection per request on loopback is the cheap end of
        # that trade.
        lines.append("Connection: close")
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))

    async def _watch_client(self, reader, gone):
        """Flag the moment a client goes away, without waiting for the next write.

        An abandoned long-lived SSE stream may never produce another upstream
        byte, so a write-side error alone would never fire and the connection
        closure - the premature-termination evidence this proxy exists to keep -
        would go unrecorded.
        """
        try:
            while True:
                chunk = await reader.read(1)
                if not chunk:
                    gone.set()
                    return
                # Unexpected extra bytes (pipelining); not a close, so keep waiting.
        except (ConnectionResetError, OSError, asyncio.IncompleteReadError):
            gone.set()

    async def _pump(self, up_reader, writer, sniffer, inspector, client_reader, expected):
        """Stream the response body to the client.

        Returns (bytes_written, client_error).
        A client that hangs up mid-stream is the premature-termination evidence,
        so it is reported apart from any upstream fault, and only when the body
        was genuinely unfinished: a client that closes just after receiving a
        complete body is not a premature termination, and the declared length or
        terminating chunk is what settles that.
        """
        sent = 0
        gone = asyncio.Event()
        watch = asyncio.ensure_future(self._watch_client(client_reader, gone))
        try:
            while True:
                read_task = asyncio.ensure_future(up_reader.read(65536))
                gone_task = asyncio.ensure_future(gone.wait())
                done, _ = await asyncio.wait({read_task, gone_task}, return_when=asyncio.FIRST_COMPLETED)
                if gone_task in done and read_task not in done:
                    read_task.cancel()
                    with contextlib.suppress(BaseException):
                        await read_task
                    return sent, "client closed the connection"
                gone_task.cancel()
                raw = read_task.result()
                if not raw:
                    break
                writer.write(raw)
                await writer.drain()
                sent += len(raw)
                payload = inspector.feed(raw) if inspector is not None else raw
                sniffer.feed(payload)
                if expected is not None and sent >= expected:
                    break
                if inspector is not None and inspector.done:
                    break
        except (ConnectionResetError, BrokenPipeError) as exc:
            return sent, "%s: %s" % (type(exc).__name__, exc)
        finally:
            watch.cancel()
            with contextlib.suppress(BaseException):
                await watch
        sniffer.flush()
        return sent, None


async def amain(args):
    log_file = open(args.log, "a", buffering=1, encoding="utf-8")
    proxy = Proxy(args, log_file)
    proxy.emit(
        "startup",
        pid=os.getpid(),
        listen="%s:%d" % (args.listen_host, args.listen_port),
        upstream="%s:%d" % (args.upstream_host, args.upstream_port),
        session_id_pattern=args.session_id_pattern,
        session_idle_ttl_s=args.session_idle_ttl,
        secrets="no token or secret value is logged; Mcp-Session-Id, client address and Tailscale identity are",
    )
    proxy.emit("warning", what="existing sessions are unknown to this fresh process", effect="their next use logs verdict=unknown-session-id until each client re-initializes")

    async def sweeper():
        while True:
            await asyncio.sleep(args.sweep_interval)
            for sid, record in proxy.registry.sweep_idle():
                proxy.emit("session_expired", session=sid, group=record["group"], idle_ttl_s=args.session_idle_ttl)

    sweeper_task = asyncio.ensure_future(sweeper())
    server = await asyncio.start_server(proxy.handle, args.listen_host, args.listen_port)
    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()
    sweeper_task.cancel()
    proxy.emit("shutdown", pid=os.getpid())
    log_file.close()


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="fm-mcp-session-proxy.py",
        description="Transparent reverse proxy that logs the MCP session detail an MCP gateway omits.",
    )
    parser.add_argument("--listen-host", default="127.0.0.1", help="address to bind (default 127.0.0.1)")
    parser.add_argument("--listen-port", type=int, required=True, help="port to listen on")
    parser.add_argument("--upstream-host", default="127.0.0.1", help="gateway address (default 127.0.0.1)")
    parser.add_argument("--upstream-port", type=int, required=True, help="gateway port to front")
    parser.add_argument("--log", required=True, help="JSONL log path, appended")
    parser.add_argument(
        "--session-id-pattern",
        default=DEFAULT_SESSION_ID_PATTERN,
        help="regex naming the session-id shape this gateway parses; anything else draws 404 (default: the MCPJungle shape)",
    )
    parser.add_argument(
        "--session-idle-ttl",
        type=int,
        default=3600,
        help="seconds after which an untouched session is marked expired in this proxy's view (default 3600)",
    )
    parser.add_argument(
        "--sweep-interval",
        type=int,
        default=60,
        help="seconds between idle-session sweeps (default 60)",
    )
    parser.add_argument(
        "--upstream-timeout",
        type=float,
        default=30.0,
        help="seconds allowed for connecting upstream and reading its response head (default 30)",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())