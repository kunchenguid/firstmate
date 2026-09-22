#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT/bin/jev-typesafe-run.py" <<'PY'
import importlib.util
import sys
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("wrapper", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
consumer = SimpleNamespace(pw_name="consumer", pw_gid=456, pw_uid=123)
calls = Mock()
with (
    patch.object(mod.os, "geteuid", return_value=0),
    patch.object(mod, "TOKEN_FILE") as token,
    patch.object(mod.tempfile, "mkdtemp", return_value="unused-fixture"),
    patch.object(mod.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="fixture-key")),
    patch.object(mod.pwd, "getpwnam", return_value=consumer),
    patch.object(mod.sys, "argv", ["wrapper", "--", "true"]),
    patch.object(mod.os, "initgroups", calls.initgroups),
    patch.object(mod.os, "setgid", calls.setgid),
    patch.object(mod.os, "setuid", calls.setuid),
    patch.object(mod.os, "execvpe", calls.execvpe),
):
    token.read_text.return_value = "fixture-token"
    mod.main()
    assert [call[0] for call in calls.mock_calls] == ["initgroups", "setgid", "setuid", "execvpe"]
    calls.initgroups.assert_called_once_with("consumer", 456)
    calls.setgid.assert_called_once_with(456)
    calls.setuid.assert_called_once_with(123)
    calls.reset_mock()
    calls.initgroups.side_effect = PermissionError("fixture refusal")
    try:
        mod.main()
    except PermissionError:
        pass
    else:
        raise AssertionError("group initialization failure was ignored")
    calls.setgid.assert_not_called()
    calls.setuid.assert_not_called()
    calls.execvpe.assert_not_called()
print("PASS: complete privilege drop precedes command execution")
PY
