#!/usr/bin/env python3
"""Render and open one fail-closed local Markdown preview.

This helper is the single executable owner of Firstmate's Markdown preview
lifecycle.
It reads one current regular file, renders a conservative Markdown subset with
raw HTML escaped and image targets omitted, adds a restrictive Content Security
Policy, serves only that in-memory result on an ephemeral 127.0.0.1 port, and
opens the tokenized URL through a local desktop opener.
The source digest is checked during the browser request so a changed file is
never answered with the older rendering.
A verified browser fetch is success independently of the opener process
lifetime.
The server exists only for a bounded wait and is shut down on success, failure,
timeout, or interruption.

Usage:
  fm-markdown-preview.py [--timeout SECONDS] [--opener PATH] FILE

Options:
  --timeout SECONDS  Maximum wait for the browser to fetch the page (default 12,
                     accepted range 0.1 through 30).
  --opener PATH      Desktop URL opener executable.
                     Intended for deterministic tests; normal use auto-detects
                     open, xdg-open, or gio.

Exit status:
  0  The browser fetched the verified current rendering.
  1  Rendering, verification, opening, serving, or cleanup failed.
  2  Arguments were invalid.
"""

import argparse
import hashlib
import html
import http.client
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


MAX_SOURCE_BYTES = 8 * 1024 * 1024
MAX_RENDERED_BYTES = 64 * 1024 * 1024
INLINE_SCAN_FACTOR = 4
MAX_BLOCKQUOTE_DEPTH = 64
MAX_SOURCE_LINES = 100000
MAX_RENDER_PARTS = 150000
MAX_RETAINED_QUOTE_CHARS = MAX_SOURCE_BYTES
MAX_TABLE_COLUMNS = 1024
MAX_TABLE_CELLS = 100000
DEFAULT_TIMEOUT = 12.0
MIN_TIMEOUT = 0.1
MAX_TIMEOUT = 30.0
VERIFY_HEADER = "X-Firstmate-Preview-Check"
CSP = (
    "default-src 'none'; "
    "base-uri 'none'; "
    "connect-src 'none'; "
    "font-src 'none'; "
    "form-action 'none'; "
    "frame-src 'none'; "
    "img-src data:; "
    "media-src 'none'; "
    "object-src 'none'; "
    "script-src 'none'; "
    "style-src 'unsafe-inline'"
)

FENCE_PREFIX_RE = re.compile(r"^[ \t]{0,3}(`{3,}|~{3,})(.*)$")
HEADING_PREFIX_RE = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t](.*)$")
UNORDERED_RE = re.compile(r"^\s{0,3}[-+*]\s+(.+)$")
ORDERED_RE = re.compile(r"^\s{0,3}\d+[.)]\s+(.+)$")
QUOTE_RE = re.compile(r"^\s{0,3}>\s?(.*)$")
THEMATIC_RE = re.compile(r"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$")
TABLE_DIVIDER_RE = re.compile(r"^:?-{3,}:?$")


class PreviewError(Exception):
    pass


class RenderBuffer:
    def __init__(self):
        self.parts = []
        self.size = 0
        self.retained_quote_chars = 0
        self.table_cells = 0

    def append(self, value):
        if len(self.parts) >= MAX_RENDER_PARTS:
            raise PreviewError(
                f"rendered preview exceeds {MAX_RENDER_PARTS} parts"
            )
        size = len(value.encode("utf-8"))
        if self.size + size > MAX_RENDERED_BYTES:
            raise PreviewError(
                f"rendered preview exceeds {MAX_RENDERED_BYTES} bytes"
            )
        self.parts.append(value)
        self.size += size

    def add_quote_copy(self, count):
        if self.retained_quote_chars + count > MAX_RETAINED_QUOTE_CHARS:
            raise PreviewError(
                "blockquote input exceeds "
                f"{MAX_RETAINED_QUOTE_CHARS} retained characters"
            )
        self.retained_quote_chars += count

    def add_table_cells(self, count):
        if self.table_cells + count > MAX_TABLE_CELLS:
            raise PreviewError(
                f"Markdown table exceeds {MAX_TABLE_CELLS} rendered cells"
            )
        self.table_cells += count

    def finish(self):
        return "".join(self.parts)


def read_source(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as error:
        raise PreviewError(f"cannot read Markdown source: {error}") from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise PreviewError("Markdown source is not a regular file")
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, min(65536, MAX_SOURCE_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_SOURCE_BYTES:
                raise PreviewError(
                    f"Markdown source exceeds {MAX_SOURCE_BYTES} bytes"
                )
        after = os.fstat(fd)
    finally:
        os.close(fd)
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    )
    if identity_before != identity_after:
        raise PreviewError("Markdown source changed while it was being read")
    data = b"".join(chunks)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PreviewError("Markdown source is not valid UTF-8") from error
    return data, text


def safe_href(target):
    value = target.strip()
    if not value or any(ord(char) < 32 for char in value):
        return None
    if value.startswith("#"):
        return value
    try:
        parsed = urlsplit(value)
    except ValueError:
        return None
    if parsed.scheme.lower() not in {"http", "https", "mailto"}:
        return None
    return value


def render_inline(source, depth=0):
    if depth > 4:
        return html.escape(source, quote=True)
    rendered = []
    plain = []
    length = len(source)
    index = 0
    remaining_scan = length * INLINE_SCAN_FACTOR

    def flush_plain():
        if plain:
            rendered.append(html.escape("".join(plain), quote=True))
            plain.clear()

    def find_delimiter(marker, start):
        nonlocal remaining_scan
        if start >= length or remaining_scan <= 0:
            return -1
        stop = min(length, start + remaining_scan)
        found = source.find(marker, start, stop)
        if found == -1:
            remaining_scan -= stop - start
        else:
            remaining_scan -= found + len(marker) - start
        return found

    while index < length:
        if source[index] == "\\" and index + 1 < length:
            plain.append(source[index + 1])
            index += 2
            continue

        if source[index] == "`":
            marker_end = index
            while marker_end < length and source[marker_end] == "`":
                marker_end += 1
            marker = source[index:marker_end]
            close = find_delimiter(marker, marker_end)
            if close != -1:
                flush_plain()
                code = source[marker_end:close].strip(" ")
                rendered.append(f"<code>{html.escape(code, quote=True)}</code>")
                index = close + len(marker)
                continue
            plain.append(marker)
            index = marker_end
            continue

        image_start = source.startswith("![", index)
        link_start = source[index] == "["
        label_start = index + 2 if image_start else index + 1
        if image_start or link_start:
            label_end = find_delimiter("](", label_start)
            target_end = (
                find_delimiter(")", label_end + 2) if label_end != -1 else -1
            )
            if label_end != -1 and target_end != -1:
                flush_plain()
                label = source[label_start:label_end]
                target = source[label_end + 2 : target_end]
                if image_start:
                    rendered.append(
                        '<span class="image-alt">Image: '
                        f"{html.escape(label, quote=True)}</span>"
                    )
                else:
                    href = safe_href(target)
                    label_html = render_inline(label, depth + 1)
                    if href is None:
                        rendered.append(label_html)
                    else:
                        rendered.append(
                            '<a rel="noreferrer noopener" target="_blank" '
                            f'href="{html.escape(href, quote=True)}">'
                            f"{label_html}</a>"
                        )
                index = target_end + 1
                continue

        matched_delimiter = False
        for marker, tag in (("**", "strong"), ("__", "strong"), ("~~", "del")):
            if source.startswith(marker, index):
                close = find_delimiter(marker, index + len(marker))
                if close > index + len(marker):
                    flush_plain()
                    inner = source[index + len(marker) : close]
                    rendered.append(
                        f"<{tag}>{render_inline(inner, depth + 1)}</{tag}>"
                    )
                    index = close + len(marker)
                    matched_delimiter = True
                    break
        if matched_delimiter:
            continue

        if source[index] in "*_":
            marker = source[index]
            close = find_delimiter(marker, index + 1)
            if close > index + 1:
                flush_plain()
                rendered.append(
                    f"<em>{render_inline(source[index + 1:close], depth + 1)}</em>"
                )
                index = close + 1
                continue

        plain.append(source[index])
        index += 1

    flush_plain()
    return "".join(rendered)


def parse_fence(line):
    match = FENCE_PREFIX_RE.match(line)
    if not match:
        return None
    marker, tail = match.groups()
    if "`" in tail:
        return None
    return marker, tail.strip()


def parse_heading(line):
    match = HEADING_PREFIX_RE.match(line)
    if not match:
        return None
    marker, raw_body = match.groups()
    if not raw_body:
        return None
    body = raw_body.rstrip()
    without_hashes = body.rstrip("#")
    if without_hashes:
        body = without_hashes.rstrip()
    elif body:
        body = "#"
    else:
        body = " "
    return marker, body


def iter_table_cells(line):
    stripped = line.strip().strip("|")
    if not stripped:
        return
    start = 0
    while True:
        end = stripped.find("|", start)
        if end == -1:
            yield stripped[start:].strip()
            return
        yield stripped[start:end].strip()
        start = end + 1


def split_table_row(line):
    cells = []
    for cell in iter_table_cells(line):
        cells.append(cell)
        if len(cells) > MAX_TABLE_COLUMNS:
            raise PreviewError(
                f"Markdown table exceeds {MAX_TABLE_COLUMNS} columns"
            )
    return cells


def table_column_count(lines, index):
    if index + 1 >= len(lines) or "|" not in lines[index]:
        return None
    count = 0
    for cell in iter_table_cells(lines[index + 1]):
        if not TABLE_DIVIDER_RE.fullmatch(cell):
            return None
        count += 1
    if count == 0:
        return None
    if count > MAX_TABLE_COLUMNS:
        raise PreviewError(
            f"Markdown table exceeds {MAX_TABLE_COLUMNS} columns"
        )
    return count


def starts_block(lines, index):
    line = lines[index]
    return (
        parse_fence(line) is not None
        or parse_heading(line) is not None
        or UNORDERED_RE.match(line)
        or ORDERED_RE.match(line)
        or QUOTE_RE.match(line)
        or THEMATIC_RE.match(line)
        or line.startswith("    ")
        or table_column_count(lines, index) is not None
    )


def render_blocks(lines, quote_depth=0, output=None):
    root = output is None
    if root:
        output = RenderBuffer()
    index = 0
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue

        fence = parse_fence(line)
        if fence:
            marker, tail = fence
            info = tail.split(None, 1)
            language = info[0] if info else ""
            index += 1
            code_lines = []
            while index < len(lines):
                candidate = lines[index].lstrip()
                if candidate.startswith(marker):
                    index += 1
                    break
                code_lines.append(lines[index])
                index += 1
            language_attr = (
                f' class="language-{html.escape(language, quote=True)}"'
                if language
                else ""
            )
            code = html.escape("\n".join(code_lines), quote=True)
            output.append(f"<pre><code{language_attr}>{code}</code></pre>")
            continue

        heading = parse_heading(line)
        if heading:
            marker, body = heading
            level = len(marker)
            output.append(
                f"<h{level}>{render_inline(body)}</h{level}>"
            )
            index += 1
            continue

        if THEMATIC_RE.match(line):
            output.append("<hr>")
            index += 1
            continue

        divider_count = table_column_count(lines, index)
        if divider_count is not None:
            headings = split_table_row(line)
            output.add_table_cells(divider_count)
            index += 2
            headings = (headings + [""] * divider_count)[:divider_count]
            output.append("<table><thead><tr>")
            for cell in headings:
                output.append(f"<th>{render_inline(cell)}</th>")
            output.append("</tr></thead><tbody>")
            while index < len(lines) and lines[index].strip() and "|" in lines[index]:
                row = split_table_row(lines[index])
                output.add_table_cells(divider_count)
                row = (row + [""] * divider_count)[:divider_count]
                output.append("<tr>")
                for cell in row:
                    output.append(f"<td>{render_inline(cell)}</td>")
                output.append("</tr>")
                index += 1
            output.append("</tbody></table>")
            continue

        quote = QUOTE_RE.match(line)
        if quote:
            if quote_depth >= MAX_BLOCKQUOTE_DEPTH:
                raise PreviewError(
                    f"blockquote nesting exceeds {MAX_BLOCKQUOTE_DEPTH} levels"
                )
            quoted = []
            while index < len(lines):
                match = QUOTE_RE.match(lines[index])
                if not match:
                    break
                start, end = match.span(1)
                output.add_quote_copy(end - start)
                quoted.append(lines[index][start:end])
                index += 1
            output.append("<blockquote>")
            render_blocks(quoted, quote_depth + 1, output)
            output.append("</blockquote>")
            continue

        unordered = UNORDERED_RE.match(line)
        if unordered:
            output.append("<ul>")
            while index < len(lines):
                match = UNORDERED_RE.match(lines[index])
                if not match:
                    break
                output.append(f"<li>{render_inline(match.group(1))}</li>")
                index += 1
            output.append("</ul>")
            continue

        ordered = ORDERED_RE.match(line)
        if ordered:
            output.append("<ol>")
            while index < len(lines):
                match = ORDERED_RE.match(lines[index])
                if not match:
                    break
                output.append(f"<li>{render_inline(match.group(1))}</li>")
                index += 1
            output.append("</ol>")
            continue

        if line.startswith("    "):
            code_lines = []
            while index < len(lines) and (
                lines[index].startswith("    ") or not lines[index].strip()
            ):
                code_lines.append(lines[index][4:] if lines[index] else "")
                index += 1
            code = html.escape("\n".join(code_lines), quote=True)
            output.append(f"<pre><code>{code}</code></pre>")
            continue

        paragraph = [line.strip()]
        index += 1
        while (
            index < len(lines)
            and lines[index].strip()
            and not starts_block(lines, index)
        ):
            paragraph.append(lines[index].strip())
            index += 1
        output.append(f"<p>{render_inline(' '.join(paragraph))}</p>")

    if root:
        return output.finish()
    return None


def render_document(source, title):
    normalized = source.replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n", MAX_SOURCE_LINES)
    if len(lines) > MAX_SOURCE_LINES:
        raise PreviewError(
            f"Markdown source exceeds {MAX_SOURCE_LINES} lines"
        )
    body = render_blocks(lines)
    safe_title = html.escape(title, quote=True)
    rendered = (
        "<!doctype html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
        f"<title>{safe_title}</title>"
        "<style>"
        ":root{color-scheme:light dark}"
        "body{font:16px/1.6 system-ui,sans-serif;max-width:900px;margin:3rem auto;"
        "padding:0 1.5rem;overflow-wrap:anywhere}"
        "pre{padding:1rem;overflow:auto;background:color-mix(in srgb,currentColor 8%,transparent)}"
        "code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}"
        "blockquote{border-left:.25rem solid currentColor;margin-left:0;padding-left:1rem;opacity:.85}"
        "table{border-collapse:collapse;width:100%}"
        "th,td{border:1px solid;padding:.4rem .6rem;text-align:left}"
        "a{color:LinkText}.image-alt{font-style:italic;opacity:.75}"
        "</style></head><body>"
        f"{body}</body></html>\n"
    ).encode("utf-8")
    if len(rendered) > MAX_RENDERED_BYTES:
        raise PreviewError(
            f"rendered preview exceeds {MAX_RENDERED_BYTES} bytes"
        )
    return rendered


class PreviewState:
    def __init__(self, source_path, digest, body, token):
        self.source_path = source_path
        self.digest = digest
        self.body = body
        self.token = token
        self.path = f"/{token}/"
        self.delivered = threading.Event()
        self.stale = threading.Event()

    def is_current(self):
        try:
            data, _text = read_source(self.source_path)
        except PreviewError:
            self.stale.set()
            return False
        current = hashlib.sha256(data).hexdigest()
        if not secrets.compare_digest(current, self.digest):
            self.stale.set()
            return False
        return True


class PreviewServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, state):
        self.state = state
        super().__init__(("127.0.0.1", 0), PreviewHandler)


class PreviewHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def send_fixed(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Firstmate-Source-SHA256", self.server.state.digest)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return False
        return True

    def do_GET(self):
        state = self.server.state
        if self.path != state.path:
            self.send_fixed(404, b"preview unavailable\n", "text/plain; charset=utf-8")
            return
        if not state.is_current():
            self.send_fixed(409, b"preview source changed\n", "text/plain; charset=utf-8")
            return
        if self.send_fixed(200, state.body, "text/html; charset=utf-8"):
            if self.headers.get(VERIFY_HEADER) != state.token:
                state.delivered.set()


def resolve_opener(explicit):
    if explicit:
        resolved = shutil.which(explicit)
        if resolved is None:
            candidate = Path(explicit)
            if candidate.is_file() and os.access(candidate, os.X_OK):
                resolved = str(candidate)
        if resolved is None:
            raise PreviewError(f"opener is not executable: {explicit}")
        return [resolved]
    if sys.platform == "darwin":
        opener = shutil.which("open")
        if opener:
            return [opener]
    opener = shutil.which("xdg-open")
    if opener:
        return [opener]
    opener = shutil.which("gio")
    if opener:
        return [opener, "open"]
    raise PreviewError("no supported local desktop opener was found")


def verify_server(port, state):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(
            "GET",
            state.path,
            headers={
                VERIFY_HEADER: state.token,
                "User-Agent": "firstmate-markdown-preview-verifier",
            },
        )
        response = connection.getresponse()
        status = response.status
        body = response.read(len(state.body) + 1)
        digest = response.getheader("X-Firstmate-Source-SHA256")
    except (OSError, http.client.HTTPException) as error:
        raise PreviewError(f"local preview verification failed: {error}") from error
    finally:
        connection.close()
    if status == 409:
        raise PreviewError("source changed before preview verification")
    if status != 200:
        raise PreviewError(f"local preview verification returned HTTP {status}")
    if body != state.body or digest != state.digest:
        raise PreviewError("local preview verification did not match the current rendering")


def stop_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=0.5)


def open_and_wait(command, url, state, timeout):
    try:
        process = subprocess.Popen(
            [*command, url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        raise PreviewError(f"could not start local desktop opener: {error}") from error

    deadline = time.monotonic() + timeout
    delivered = False
    try:
        while True:
            if state.stale.is_set():
                raise PreviewError("source changed before preview delivery")
            if state.delivered.is_set():
                delivered = True
                return
            return_code = process.poll()
            if return_code not in (None, 0):
                raise PreviewError(f"local desktop opener exited {return_code}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise PreviewError("timed out waiting for the browser to fetch the preview")
            state.delivered.wait(min(0.05, remaining))
    finally:
        if not delivered:
            stop_process(process)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Render and open one fail-closed local Markdown preview."
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help="maximum browser-fetch wait in seconds (0.1 through 30)",
    )
    parser.add_argument(
        "--opener",
        help="local desktop URL opener executable (primarily for tests)",
    )
    parser.add_argument("file", help="Markdown file to preview")
    args = parser.parse_args(argv)
    if not MIN_TIMEOUT <= args.timeout <= MAX_TIMEOUT:
        parser.error(
            f"--timeout must be between {MIN_TIMEOUT:g} and {MAX_TIMEOUT:g} seconds"
        )
    return args


def run(args):
    source_path = Path(args.file).expanduser().absolute()
    data, source = read_source(source_path)
    digest = hashlib.sha256(data).hexdigest()
    body = render_document(source, source_path.name)
    state = PreviewState(source_path, digest, body, secrets.token_urlsafe(24))
    opener = resolve_opener(args.opener)
    server = None
    thread = None
    thread_started = False
    try:
        server = PreviewServer(state)
        thread = threading.Thread(
            target=server.serve_forever,
            name="fm-markdown-preview",
            daemon=True,
        )
        try:
            thread.start()
        except RuntimeError as error:
            raise PreviewError(
                "local preview server thread could not start"
            ) from error
        thread_started = True
        port = server.server_address[1]
        url = f"http://127.0.0.1:{port}{state.path}"
        verify_server(port, state)
        if not state.is_current():
            raise PreviewError("source changed before preview opening")
        open_and_wait(opener, url, state, args.timeout)
    finally:
        if server is not None:
            if thread_started:
                server.shutdown()
            server.server_close()
        if thread_started and thread is not None:
            thread.join(timeout=2)
            if thread.is_alive():
                raise PreviewError("local preview server did not stop")
    print(f"ok - previewed {source_path.name}")


def main(argv=None):
    args = parse_args(argv)
    try:
        run(args)
    except PreviewError as error:
        print(f"fm-markdown-preview: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("fm-markdown-preview: interrupted", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
