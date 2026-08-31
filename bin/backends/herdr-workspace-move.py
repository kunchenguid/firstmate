#!/usr/bin/env python3
"""Send one narrowly scoped workspace.move request to a Herdr local endpoint.

This helper is the wire transport for Firstmate's optional presentation-only
workspace ordering. It accepts only an exact workspace id and a non-negative
insert index, sends only the non-destructive ``workspace.move`` method, and
prints the verified JSON response. Unix uses the Herdr AF_UNIX endpoint.
Native Windows uses the raw byte stream behind Herdr's GenericNamespaced named
pipe; the small ``herdr.sock`` file is only Herdr's ownership marker.

Wire protocol verified against Herdr 0.7.4, protocol 16:

  request:  {"id":"fm-workspace-move","method":"workspace.move",
             "params":{"workspace_id":W,"insert_index":N}}\n
  response: {"id":"fm-workspace-move","result":
             {"type":"workspace_list","workspaces":[...]}}\n
Usage:
  herdr-workspace-move.py --check-transport [<socket_path>]
  herdr-workspace-move.py <socket_path> <workspace_id> <insert_index>

Exit status:
  0  the server returned the matching workspace_list response;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import ctypes
from ctypes import wintypes
import json
import os
import re
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-workspace-move"
ERROR_PIPE_BUSY = 231
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
FILE_ATTRIBUTE_NORMAL = 0x80
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


def _error(message):
    sys.stderr.write(f"error: {message}\n")


def _transport_kind(os_name=None, has_af_unix=None):
    os_name = os.name if os_name is None else os_name
    has_af_unix = hasattr(socket, "AF_UNIX") if has_af_unix is None else has_af_unix
    if os_name == "nt":
        return "windows-named-pipe"
    if has_af_unix:
        return "unix-domain-socket"
    return None


def _windows_native_path(socket_path):
    if re.match(r"^[A-Za-z]:[\\/]", socket_path):
        return socket_path.replace("/", "\\")
    match = re.match(r"^/([A-Za-z])(?:/(.*))?$", socket_path)
    if match:
        suffix = (match.group(2) or "").replace("/", "\\")
        return f"{match.group(1).upper()}:\\{suffix}"
    raise OSError("Windows Herdr endpoint is not a native or Git Bash drive path")


def _windows_pipe_name(socket_path):
    return "\\\\.\\pipe\\" + _windows_native_path(socket_path)


class _UnixTransport:
    def __init__(self, socket_path):
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.settimeout(CONNECT_TIMEOUT)
        self._socket.connect(socket_path)

    def sendall(self, data):
        self._socket.sendall(data)

    def read_line(self, deadline):
        return _read_socket_line(self._socket, deadline)

    def close(self):
        self._socket.close()


class _WindowsNamedPipeTransport:
    def __init__(self, socket_path):
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = (
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        )
        kernel32.CreateFileW.restype = wintypes.HANDLE
        kernel32.WaitNamedPipeW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD)
        kernel32.WaitNamedPipeW.restype = wintypes.BOOL
        kernel32.PeekNamedPipe.argtypes = (
            wintypes.HANDLE,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.LPVOID,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.LPVOID,
        )
        kernel32.PeekNamedPipe.restype = wintypes.BOOL
        kernel32.ReadFile.argtypes = (
            wintypes.HANDLE,
            wintypes.LPVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.LPVOID,
        )
        kernel32.ReadFile.restype = wintypes.BOOL
        kernel32.WriteFile.argtypes = (
            wintypes.HANDLE,
            wintypes.LPCVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.LPVOID,
        )
        kernel32.WriteFile.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL
        self._kernel32 = kernel32
        self._pipe_name = _windows_pipe_name(socket_path)
        self._handle = self._open()

    def _last_error(self, context):
        code = ctypes.get_last_error()
        detail = ctypes.FormatError(code).strip()
        return OSError(code, f"{context}: {detail}")

    def _open(self):
        deadline = time.monotonic() + CONNECT_TIMEOUT
        while True:
            handle = self._kernel32.CreateFileW(
                self._pipe_name,
                GENERIC_READ | GENERIC_WRITE,
                0,
                None,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            if handle != INVALID_HANDLE_VALUE:
                return handle
            code = ctypes.get_last_error()
            if code != ERROR_PIPE_BUSY:
                raise self._last_error("could not open Herdr named pipe")
            remaining_ms = int(max(0.0, deadline - time.monotonic()) * 1000)
            if remaining_ms <= 0:
                raise TimeoutError("timed out waiting for Herdr named pipe")
            if not self._kernel32.WaitNamedPipeW(self._pipe_name, remaining_ms):
                raise self._last_error("could not wait for Herdr named pipe")

    def sendall(self, data):
        offset = 0
        while offset < len(data):
            chunk = ctypes.create_string_buffer(data[offset:])
            written = wintypes.DWORD()
            if not self._kernel32.WriteFile(
                self._handle,
                chunk,
                len(data) - offset,
                ctypes.byref(written),
                None,
            ):
                raise self._last_error("could not write Herdr named pipe")
            if written.value == 0:
                raise OSError("Herdr named pipe accepted zero bytes")
            offset += written.value

    def read_line(self, deadline):
        buffer = b""
        while b"\n" not in buffer:
            if time.monotonic() >= deadline:
                return None
            available = wintypes.DWORD()
            if not self._kernel32.PeekNamedPipe(
                self._handle,
                None,
                0,
                None,
                ctypes.byref(available),
                None,
            ):
                return None
            if available.value == 0:
                time.sleep(0.01)
                continue
            size = min(available.value, RECV_CHUNK)
            chunk = ctypes.create_string_buffer(size)
            read = wintypes.DWORD()
            if not self._kernel32.ReadFile(
                self._handle,
                chunk,
                size,
                ctypes.byref(read),
                None,
            ):
                return None
            if read.value == 0:
                return None
            buffer += chunk.raw[: read.value]
            if len(buffer) > MAX_RESPONSE_BYTES:
                return None
        return buffer.split(b"\n", 1)[0]

    def close(self):
        if self._handle != INVALID_HANDLE_VALUE:
            self._kernel32.CloseHandle(self._handle)
            self._handle = INVALID_HANDLE_VALUE


def _connect_transport(socket_path):
    kind = _transport_kind()
    if kind == "windows-named-pipe":
        return _WindowsNamedPipeTransport(socket_path)
    if kind == "unix-domain-socket":
        return _UnixTransport(socket_path)
    raise OSError("Python exposes no supported Herdr local transport")


def _check_transport(socket_path=None):
    kind = _transport_kind()
    if kind == "windows-named-pipe":
        if not hasattr(ctypes, "WinDLL"):
            return False
        if socket_path is not None:
            _windows_pipe_name(socket_path)
        return True
    if kind == "unix-domain-socket":
        return socket_path is None or socket_path.startswith("/")
    return False


def _read_socket_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv, connector=None):
    if len(argv) in (2, 3) and argv[1] == "--check-transport":
        try:
            socket_path = argv[2] if len(argv) == 3 else None
            return 0 if _check_transport(socket_path) else 2
        except OSError as error:
            _error(str(error))
            return 2
    if len(argv) != 4:
        return 2
    socket_path, workspace_id, raw_index = argv[1:]
    if not socket_path or not workspace_id:
        return 2
    if any(char in workspace_id for char in "\t\r\n"):
        return 2
    try:
        insert_index = int(raw_index)
    except ValueError:
        return 2
    if insert_index < 0 or str(insert_index) != raw_index:
        return 2

    connector = _connect_transport if connector is None else connector
    try:
        transport = connector(socket_path)
    except OSError as error:
        _error(f"could not connect to Herdr local endpoint: {error}")
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "workspace.move",
        "params": {"workspace_id": workspace_id, "insert_index": insert_index},
    }
    try:
        transport.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError as error:
        _error(f"could not send workspace.move: {error}")
        transport.close()
        return 3

    line = transport.read_line(time.monotonic() + RESPONSE_TIMEOUT)
    transport.close()
    if line is None:
        _error("workspace.move returned no complete response")
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    result = response.get("result") if isinstance(response, dict) else None
    if (
        response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(result, dict)
        or result.get("type") != "workspace_list"
        or not isinstance(result.get("workspaces"), list)
    ):
        return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
