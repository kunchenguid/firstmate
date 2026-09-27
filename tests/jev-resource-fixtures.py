import contextlib
import importlib.util
import io
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

kind = sys.argv[1]
path = Path(__file__).resolve().parent.parent / "bin" / f"fm-jev-{kind}-guard.py"
spec = importlib.util.spec_from_file_location("guard", path)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

def cli(args):
    output = io.StringIO()
    with patch.object(sys, "argv", [str(path), "--json", "--check", *args]), contextlib.redirect_stdout(output):
        try:
            result = guard.main()
            return result or 0
        except SystemExit as exc:
            return exc.code or 0

if kind == "shm":
    with tempfile.TemporaryDirectory() as tmp, patch.object(guard, "SHM_PATH", tmp), patch.object(guard, "get_sysv_ipc_counts", return_value=(0, 0)):
        with patch.object(guard.shutil, "disk_usage", return_value=SimpleNamespace(total=1000, used=0)):
            assert cli(["--warning-pct", "0.001"]) == 0
        with patch.object(guard.shutil, "disk_usage", return_value=SimpleNamespace(total=1000, used=800)):
            assert cli([]) == 1
        target = Path(tmp) / "playwright-fixture"
        target.write_bytes(b"preserve")
        os.utime(target, (1, 1))
        with patch.object(guard.subprocess, "run", side_effect=FileNotFoundError("fixture missing fuser")):
            report = guard.audit_shm(sweep=True)
        assert target.read_bytes() == b"preserve"
        assert report["candidates_sample"][0]["is_open"] is None
        assert report["candidates_sample"][0]["safe_to_reclaim"] is False
elif kind == "inotify":
    paths = ["/proc/123/fdinfo/7"]
    def opened(path, *args, **kwargs):
        if path.endswith("max_user_watches"):
            return io.StringIO("100")
        if path.endswith("max_user_instances"):
            return io.StringIO("100")
        if path.endswith("cmdline"):
            return io.StringIO("fixture-watcher")
        return io.StringIO("inotify wd:1\n" * 2)
    with patch.object(guard.glob, "glob", return_value=paths), patch("builtins.open", side_effect=opened):
        report = guard.audit_inotify_usage()
        assert report["summary"]["total_watches"] == 2
        assert len(report["top_consumers"]) == 1
        assert cli([]) == 0
        assert cli(["--warning-pct", "1"]) == 1
    with patch.object(guard.glob, "glob", return_value=[]):
        assert cli(["--warning-pct", "0.001"]) == 0
elif kind == "port":
    def opened(path, *args, **kwargs):
        if path.endswith("ip_local_port_range"):
            return io.StringIO("10000 10999")
        return io.StringIO("header\n0: local remote 06\n")
    with patch("builtins.open", side_effect=opened), patch.object(guard.subprocess, "run", return_value=SimpleNamespace(stdout="Total: 2\nTCP: 2 (estab 0, closed 2, orphaned 0, timewait 2)\n")):
        report = guard.audit_port_exhaustion()
        assert report["state_distribution"]["TIME_WAIT"] == 2
        assert cli([]) == 0
        assert cli(["--warning-timewait", "1"]) == 1
    with patch("builtins.open", return_value=io.StringIO("")), patch.object(guard.subprocess, "run", return_value=SimpleNamespace(stdout="")):
        assert cli(["--warning-timewait", "1"]) == 0
elif kind == "fd":
    def listed(path):
        return ["123"] if path == "/proc" else [str(n) for n in range(12)]
    with (
        patch.object(guard.os, "listdir", side_effect=listed),
        patch.object(guard.os.path, "isdir", return_value=True),
        patch.object(guard.os, "access", return_value=True),
        patch.object(guard.os, "stat", return_value=SimpleNamespace(st_uid=os.getuid())),
        patch.object(guard, "get_process_limits", return_value=(100, 100)),
        patch.object(guard, "get_process_comm", return_value="fixture-worker"),
        patch.object(guard, "get_system_file_nr", return_value={"allocated": 12, "unused": 0, "maximum": 100}),
    ):
        report = guard.audit_process_fds()
        assert report["total_user_open_fds"] == 12
        assert report["audited_processes_count"] == 1
        assert cli([]) == 0
        assert cli(["--warn-count", "5"]) == 1
    with patch.object(guard.os, "listdir", return_value=[]):
        assert cli(["--warn-count", "5"]) == 0
else:
    raise ValueError(kind)
print(f"PASS: {kind} empty and populated resource fixtures")
