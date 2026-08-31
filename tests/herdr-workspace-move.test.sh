#!/usr/bin/env bash
# Behavioral tests for the cross-platform Herdr workspace.move transport.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 not found"
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$ROOT/bin/backends/herdr-workspace-move.py" --check-transport \
  || fail "the current platform transport was not reported as usable"

python3 - "$ROOT/bin/backends/herdr-workspace-move.py" <<'PY'
import contextlib
import importlib.util
import io
import socket
import sys


path = sys.argv[1]
spec = importlib.util.spec_from_file_location("herdr_workspace_move", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module._transport_kind("nt", False) == "windows-named-pipe"
assert module._transport_kind("posix", True) == "unix-domain-socket"
assert module._transport_kind("posix", False) is None

assert (
    module._windows_pipe_name("/c/Users/example/AppData/Roaming/herdr/herdr.sock")
    == r"\\.\pipe\C:\Users\example\AppData\Roaming\herdr\herdr.sock"
)
assert (
    module._windows_pipe_name(r"C:\Users\example\AppData\Roaming\herdr\herdr.sock")
    == r"\\.\pipe\C:\Users\example\AppData\Roaming\herdr\herdr.sock"
)

calls = []


def failed_windows_connect(socket_path):
    calls.append(socket_path)
    raise OSError("named pipe unavailable")


stderr = io.StringIO()
with contextlib.redirect_stderr(stderr):
    status = module.main(
        ["herdr-workspace-move.py", r"C:\missing\herdr.sock", "w8", "2"],
        connector=failed_windows_connect,
    )

assert status == 2
assert calls == [r"C:\missing\herdr.sock"]
assert "named pipe unavailable" in stderr.getvalue()
assert "AF_UNIX" not in stderr.getvalue()

if sys.platform == "win32":
    assert not hasattr(socket, "AF_UNIX")
    assert module._transport_kind() == "windows-named-pipe"
else:
    assert module._transport_kind() == "unix-domain-socket"
PY

pass "herdr workspace mover selects the native transport and reports Windows connection failure"
