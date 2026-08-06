#!/usr/bin/env python3
"""Inspect and narrowly recover cross-kernel localhost ownership.

The --help text is the authoritative operator contract.  Keep implementation
details out of AGENTS.md and maintained prose so this safety procedure has one
owner.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlsplit


SCHEMA = "fm-localhost.v1"
INSPECT_PS = r"""
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Port = [int]$args[0]
$Rows = @()
$Connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { [int]$_.LocalPort -eq $Port } | Sort-Object LocalAddress, OwningProcess)
foreach ($Connection in $Connections) {
  $Process = $null
  try { $Process = Get-CimInstance Win32_Process -Filter "ProcessId = $($Connection.OwningProcess)" -ErrorAction Stop } catch {}
  $Rows += [pscustomobject]@{
    address = [string]$Connection.LocalAddress
    port = [int]$Connection.LocalPort
    pid = [int]$Connection.OwningProcess
    process = if ($null -ne $Process) { [string]$Process.Name } else { $null }
    executable = if ($null -ne $Process) { [string]$Process.ExecutablePath } else { $null }
    command = if ($null -ne $Process) { [string]$Process.CommandLine } else { $null }
  }
}
ConvertTo-Json -InputObject @($Rows) -Compress -Depth 3
"""

TERMINATE_PS = r"""
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Port = [int]$args[0]
$PidToStop = [int]$args[1]
$ExpectedCommandHash = [string]$args[2]
$ExpectedAstroScript = [string]$args[3]
$Connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { [int]$_.LocalPort -eq $Port })
if ($Connections.Count -lt 1) { throw 'reserved port has no Windows listener' }
foreach ($Connection in $Connections) {
  if ([int]$Connection.OwningProcess -ne $PidToStop) { throw 'reserved port ownership changed' }
}
$Process = Get-CimInstance Win32_Process -Filter "ProcessId = $PidToStop" -ErrorAction Stop
if ($null -eq $Process -or [string]$Process.Name -ieq 'wslrelay.exe') { throw 'wslrelay.exe is never a termination target' }
if ([string]$Process.Name -ine 'node.exe' -or [IO.Path]::GetFileName([string]$Process.ExecutablePath) -ine 'node.exe') { throw 'target is not native Windows node.exe' }
$Command = [string]$Process.CommandLine
if ([string]::IsNullOrWhiteSpace($Command)) { throw 'target command is unavailable' }
$Bytes = [Text.Encoding]::UTF8.GetBytes($Command)
$Hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
if ($Hash -ne $ExpectedCommandHash) { throw 'target command changed' }
$NormalizedCommand = $Command.Replace('\', '/')
$NormalizedScript = $ExpectedAstroScript.Replace('\', '/')
$NodePattern = '(?i)^\s*(?:"[^"]*/node\.exe"|(?:[^"\s]+/)?node\.exe)\s+'
$AstroDevPattern = $NodePattern + '"?' + [regex]::Escape($NormalizedScript) + '"?\s+dev(?:\s|$)'
if ($NormalizedCommand -notmatch $AstroDevPattern) { throw 'target is not the verified Astro development launcher' }
if ($Command -match '(?i)(^|\s)(preview|build)(\s|$)' -or $Command -match '(?i)(node_env\s*=\s*production|--mode(?:=|\s+)production)') { throw 'target looks production-like' }
Stop-Process -Id $PidToStop -ErrorAction Stop
for ($i = 0; $i -lt 100; $i++) {
  if ($null -eq (Get-Process -Id $PidToStop -ErrorAction SilentlyContinue)) { 'terminated'; exit 0 }
  Start-Sleep -Milliseconds 100
}
throw 'exact PID did not exit after termination'
"""

ROUTE_PS = r"""
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Url = [string]$args[0]
Add-Type -AssemblyName System.Net.Http
$Handler = [System.Net.Http.HttpClientHandler]::new()
$Handler.UseProxy = $false
$Client = [System.Net.Http.HttpClient]::new($Handler)
$Client.MaxResponseContentBufferSize = 8388609
$Client.Timeout = [TimeSpan]::FromSeconds(10)
$Client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 FirstmateLocalhost/1') | Out-Null
$Client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'text/html,application/xhtml+xml') | Out-Null
try {
  $Response = $Client.GetAsync($Url).GetAwaiter().GetResult()
  $Body = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  $Hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Body))).Replace('-', '').ToLowerInvariant()
  [pscustomobject]@{status = [int]$Response.StatusCode; sha256 = $Hash; length = [int64]$Body.Length} | ConvertTo-Json -Compress
} finally {
  $Client.Dispose()
  $Handler.Dispose()
}
"""


@dataclasses.dataclass(frozen=True)
class GitInfo:
    checkout: str = "unknown"
    branch: str = "unknown"
    sha: str = "unknown"
    dirty: str = "unknown"
    source: str = "unknown"
    default_branch: str = "unknown"
    error: str = ""


@dataclasses.dataclass(frozen=True)
class Listener:
    kernel: str
    address: str
    pid: int
    process: str
    command: str
    command_raw: str
    executable_raw: str
    git: GitInfo
    tasks: tuple[str, ...]
    classification: str


@dataclasses.dataclass
class Inspection:
    windows: list[Listener]
    wsl: list[Listener]
    task_error: str = ""
    windows_error: str = ""
    wsl_error: str = ""


@dataclasses.dataclass(frozen=True)
class OwnedLaunch:
    process: subprocess.Popen
    pgid: int


class SafeRefusal(RuntimeError):
    pass


def command_output(argv: list[str], *, cwd: Path | None = None, timeout: float = 15) -> str:
    completed = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise SafeRefusal(f"command failed with exit {completed.returncode}")
    return completed.stdout


def git_output(path: Path, *args: str) -> str:
    return command_output(["git", "-C", str(path), *args]).strip()


def normalize_source(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return "unknown"
    if raw.startswith("file://"):
        parsed = urlsplit(raw)
        return f"file:{Path(parsed.path).resolve()}".removesuffix(".git")
    scp = re.fullmatch(r"(?:[^@/]+@)?([^:/]+):(.+)", raw)
    if scp and "://" not in raw:
        host, path = scp.groups()
        return f"{host.lower()}/{path.strip('/')}".removesuffix(".git")
    parsed = urlsplit(raw)
    if parsed.scheme and parsed.hostname:
        path = parsed.path.strip("/")
        return f"{parsed.hostname.lower()}/{path}".removesuffix(".git")
    if Path(raw).is_absolute():
        try:
            return f"file:{Path(raw).resolve()}".removesuffix(".git")
        except OSError:
            pass
    return "unknown"


def git_info(path: Path) -> GitInfo:
    try:
        top = Path(git_output(path, "rev-parse", "--show-toplevel")).resolve()
        sha = git_output(top, "rev-parse", "HEAD")
        branch = git_output(top, "branch", "--show-current") or "detached"
        status = command_output(["git", "-C", str(top), "status", "--porcelain=v1", "--untracked-files=all"])
        source = normalize_source(git_output(top, "remote", "get-url", "origin"))
        default_branch = "unknown"
        try:
            remote_head = git_output(top, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
            if remote_head.startswith("origin/"):
                default_branch = remote_head.removeprefix("origin/")
        except (SafeRefusal, subprocess.TimeoutExpired):
            for candidate in ("main", "master"):
                try:
                    git_output(top, "show-ref", "--verify", f"refs/heads/{candidate}")
                    default_branch = candidate
                    break
                except (SafeRefusal, subprocess.TimeoutExpired):
                    continue
        return GitInfo(
            checkout=str(top),
            branch=branch,
            sha=sha,
            dirty="dirty" if status else "clean",
            source=source,
            default_branch=default_branch,
        )
    except (OSError, SafeRefusal, subprocess.TimeoutExpired) as exc:
        return GitInfo(error=type(exc).__name__)


def windows_mount_root() -> Path:
    override = os.environ.get("FM_LOCALHOST_WINDOWS_MOUNT_ROOT")
    if override and os.environ.get("FM_LOCALHOST_TESTING") == "1":
        return Path(override).resolve()
    return Path("/mnt")


def windows_to_wsl(raw: str) -> Path | None:
    value = raw.strip().strip('"\'')
    drive = re.match(r"^([A-Za-z]):[\\/](.*)$", value)
    if drive:
        tail = [piece for piece in re.split(r"[\\/]+", drive.group(2)) if piece]
        return windows_mount_root() / drive.group(1).lower() / Path(*tail)
    unc = value.replace("\\", "/")
    match = re.match(r"^//(?:wsl\.localhost|wsl\$)/([^/]+)(/.*)?$", unc, re.IGNORECASE)
    if match:
        distro = os.environ.get("WSL_DISTRO_NAME")
        if not distro or match.group(1).lower() != distro.lower():
            return None
        return Path(match.group(2) or "/")
    if value.startswith("/"):
        return Path(value)
    return None


def wsl_to_windows(path: Path) -> str:
    resolved = path.resolve()
    mount = windows_mount_root()
    try:
        relative = resolved.relative_to(mount)
        parts = relative.parts
        if len(parts) >= 2 and len(parts[0]) == 1 and parts[0].isalpha():
            suffix = "\\".join(parts[1:])
            return f"{parts[0].upper()}:\\{suffix}"
    except ValueError:
        pass
    distro = os.environ.get("WSL_DISTRO_NAME")
    if not distro:
        return "unknown"
    return f"\\\\wsl.localhost\\{distro}\\{str(resolved).lstrip('/').replace('/', '\\')}"


def redact_command(raw: str) -> str:
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", raw or "").strip()
    if not value:
        return "unknown"
    value = re.sub(r"(?i)(https?://)[^/@\s]+@", r"\1<redacted>@", value)
    sensitive = r"(?:token|secret|password|passwd|api[-_]?key|authorization|credential|cookie|session)"
    value = re.sub(rf"(?i)({sensitive}\s*=\s*)(?:\"[^\"]*\"|'[^']*'|[^\s]+)", r"\1<redacted>", value)
    value = re.sub(rf"(?i)(--?{sensitive}(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|[^\s]+)", r"\1<redacted>", value)
    value = re.sub(
        rf'''(?i)(["']?{sensitive}["']?\s*:\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,\s}}]+)''',
        r"\1<redacted>",
        value,
    )
    value = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1<redacted>", value)
    value = re.sub(r"(?i)\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?", "<redacted-id>", value)
    value = re.sub(r"\b[A-Za-z0-9_-]{48,}\b", "<redacted>", value)
    if len(value) > 512:
        value = value[:500] + " <truncated>"
    return value


def command_tokens(raw: str) -> list[str]:
    if not raw or raw.count('"') % 2:
        return []
    return [
        match.group(1) if match.group(1) is not None else match.group(2)
        for match in re.finditer(r'"([^"]*)"|([^\s]+)', raw)
    ]


def astro_dev_script(command: str, executable: str, checkout: str) -> Path | None:
    tokens = command_tokens(command)
    executable_name = re.split(r"[\\/]", executable)[-1].lower() if executable else ""
    first_name = re.split(r"[\\/]", tokens[0])[-1].lower() if tokens else ""
    if len(tokens) < 3 or first_name not in {"node", "node.exe"} or (executable and executable_name != "node.exe"):
        return None
    script = windows_to_wsl(tokens[1])
    if script is None or checkout == "unknown":
        return None
    try:
        script = script.resolve(strict=True)
        relative = script.relative_to(Path(checkout).resolve())
    except (OSError, ValueError):
        return None
    parts = tuple(part.casefold() for part in relative.parts)
    if parts[:2] != ("node_modules", "astro") or parts[2:] not in (("astro.js",), ("astro.mjs",)):
        return None
    if tokens[2].casefold() != "dev":
        return None
    return script


def command_paths(command: str, executable: str) -> list[Path]:
    values: list[str] = []
    combined = f"{command} {executable}"
    values.extend(re.findall(r'["\']((?:[A-Za-z]:[\\/]|\\\\(?:wsl\.localhost|wsl\$)\\)[^"\']+)["\']', combined, re.IGNORECASE))
    values.extend(re.findall(r"(?<![A-Za-z0-9_])([A-Za-z]:[\\/][^\s\"]+)", combined))
    values.extend(re.findall(r"(\\\\(?:wsl\.localhost|wsl\$)\\[^\s\"]+)", combined, re.IGNORECASE))
    result: list[Path] = []
    for value in values:
        converted = windows_to_wsl(value.rstrip(",;"))
        if converted and converted not in result:
            result.append(converted)
    return result


def checkout_from_windows_command(command: str, executable: str) -> Path | None:
    found: set[Path] = set()
    for candidate in command_paths(command, executable):
        parts = list(candidate.parts)
        if "node_modules" in parts:
            candidate = Path(*parts[: parts.index("node_modules")])
        probe = candidate if candidate.is_dir() else candidate.parent
        while probe != probe.parent:
            if (probe / ".git").exists():
                info = git_info(probe)
                if info.checkout != "unknown":
                    found.add(Path(info.checkout))
                    break
            probe = probe.parent
    return next(iter(found)) if len(found) == 1 else None


def classify_windows(process: str, command: str, executable: str, checkout: str = "unknown") -> str:
    lower_name = Path(process).name.lower()
    lower_executable = re.split(r"[\\/]", executable)[-1].lower() if executable else ""
    lower_command = command.lower()
    if lower_name == "wslrelay.exe":
        return "wslrelay"
    if not command.strip():
        return "unknown-command"
    if lower_name != "node.exe" or lower_executable != "node.exe":
        return "unrelated-process"
    if re.search(r"(?:^|\s)(?:preview|build)(?:\s|$)", lower_command) or re.search(
        r"node_env\s*=\s*production|--mode(?:=|\s+)production", lower_command
    ):
        return "production-like"
    if astro_dev_script(command, executable, checkout):
        return "native-windows-node-astro-dev"
    return "unknown-node"


def classify_wsl(process: str, command: str, checkout: str = "unknown") -> str:
    if Path(process).name.lower() in {"node", "nodejs"} and astro_dev_script(command, "", checkout):
        return "wsl-node-astro-dev"
    return "unknown-wsl-process"


def task_state_files(state: Path) -> list[Path]:
    try:
        if not state.is_dir():
            raise SafeRefusal("Firstmate task-state inspection unavailable")
        files = sorted(state.glob("*.meta"))
        for meta in files:
            with meta.open("rb"):
                pass
        return files
    except OSError as exc:
        raise SafeRefusal("Firstmate task-state inspection unavailable") from exc


def task_associations(state: Path, checkout: str, pid: int) -> tuple[str, ...]:
    if checkout == "unknown":
        checkout_path = None
    else:
        checkout_path = Path(checkout).resolve()
    matches: list[str] = []
    for meta in task_state_files(state):
        try:
            fields: dict[str, list[str]] = {}
            for line in meta.read_text(encoding="utf-8", errors="replace").splitlines():
                key, separator, value = line.partition("=")
                if separator:
                    fields.setdefault(key, []).append(value)
            associated = False
            if checkout_path:
                for key in ("worktree", "project"):
                    for raw_path in fields.get(key, []):
                        converted = windows_to_wsl(raw_path)
                        if converted is None:
                            converted = Path(raw_path)
                        try:
                            if converted.resolve() == checkout_path:
                                associated = True
                        except OSError:
                            continue
            for key in ("pid", "process_pid", "windows_pid"):
                if str(pid) in fields.get(key, []):
                    associated = True
            if associated:
                matches.append(meta.stem)
        except OSError:
            matches.append(f"{meta.stem}:unreadable")
    return tuple(matches)


def powershell() -> str:
    if os.environ.get("FM_LOCALHOST_TESTING") == "1":
        found = shutil.which("powershell.exe")
        if found:
            return found
    standard = Path("/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
    if standard.is_file():
        return str(standard)
    raise SafeRefusal("Windows inspection unavailable")


def run_powershell(script: str, *args: str, timeout: float = 20) -> str:
    literals = ", ".join("'" + value.replace("'", "''") + "'" for value in args)
    command = f"$FmArgs = @({literals})\n" + script.replace("$args[", "$FmArgs[")
    try:
        return command_output(
            [powershell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise SafeRefusal("Windows inspection timed out") from exc
    except OSError as exc:
        raise SafeRefusal("Windows inspection unavailable") from exc
    except SafeRefusal as exc:
        if str(exc) == "Windows inspection unavailable":
            raise
        raise SafeRefusal("Windows inspection failed") from exc


def windows_listeners(port: int, state: Path) -> list[Listener]:
    raw = run_powershell(INSPECT_PS, str(port))
    try:
        payload = json.loads(raw.lstrip("\ufeff").strip() or "[]")
    except json.JSONDecodeError as exc:
        raise SafeRefusal("Windows listener output was invalid") from exc
    if isinstance(payload, dict):
        payload = [payload]
    if not isinstance(payload, list):
        raise SafeRefusal("Windows listener output was invalid")
    listeners: list[Listener] = []
    for row in payload:
        if not isinstance(row, dict):
            raise SafeRefusal("Windows listener row was invalid")
        try:
            row_port = int(row.get("port"))
            pid = int(row.get("pid"))
        except (TypeError, ValueError) as exc:
            raise SafeRefusal("Windows listener identity was incomplete") from exc
        if row_port != port or pid <= 0:
            raise SafeRefusal("Windows listener identity was inconsistent")
        process = str(row.get("process") or "unknown")
        command = str(row.get("command") or "")
        executable = str(row.get("executable") or "")
        checkout = checkout_from_windows_command(command, executable)
        info = git_info(checkout) if checkout else GitInfo()
        listeners.append(
            Listener(
                kernel="windows",
                address=f"{row.get('address') or 'unknown'}:{port}",
                pid=pid,
                process=process,
                command=redact_command(command),
                command_raw=command,
                executable_raw=executable,
                git=info,
                tasks=task_associations(state, info.checkout, pid),
                classification=classify_windows(process, command, executable, info.checkout),
            )
        )
    return listeners


def proc_root() -> Path:
    override = os.environ.get("FM_LOCALHOST_PROC_ROOT")
    if override and os.environ.get("FM_LOCALHOST_TESTING") == "1":
        return Path(override)
    return Path("/proc")


def wsl_listeners(port: int, state: Path) -> list[Listener]:
    try:
        output = command_output(["ss", "-H", "-ltnp", f"sport = :{port}"])
    except (OSError, SafeRefusal, subprocess.TimeoutExpired) as exc:
        raise SafeRefusal("WSL listener inspection unavailable") from exc
    found: dict[tuple[int, str], tuple[str, str]] = {}
    for line in output.splitlines():
        address_match = re.search(r"\s([^\s]+:%s)\s" % port, line)
        process_matches = re.findall(r'\("([^"\n]+)",pid=(\d+),fd=\d+\)', line)
        if not address_match or not process_matches:
            if line.strip():
                raise SafeRefusal("WSL listener output was incomplete")
            continue
        for process, pid_text in process_matches:
            found[(int(pid_text), address_match.group(1))] = (process, line)
    listeners: list[Listener] = []
    root = proc_root()
    for (pid, address), (ss_process, _line) in sorted(found.items()):
        pid_root = root / str(pid)
        try:
            command_raw = (pid_root / "cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            process = (pid_root / "comm").read_text(encoding="utf-8", errors="replace").strip() or ss_process
            cwd = (pid_root / "cwd").resolve(strict=True)
            info = git_info(cwd)
        except OSError:
            command_raw = ""
            process = ss_process or "unknown"
            info = GitInfo()
        listeners.append(
            Listener(
                kernel="wsl",
                address=address,
                pid=pid,
                process=process,
                command=redact_command(command_raw),
                command_raw=command_raw,
                executable_raw="",
                git=info,
                tasks=task_associations(state, info.checkout, pid),
                classification=classify_wsl(process, command_raw, info.checkout),
            )
        )
    return listeners


def inspect_system(port: int, state: Path) -> Inspection:
    result = Inspection(windows=[], wsl=[])
    try:
        task_state_files(state)
    except SafeRefusal as exc:
        result.task_error = str(exc)
        return result
    try:
        result.windows = windows_listeners(port, state)
    except SafeRefusal as exc:
        result.windows_error = str(exc)
    except OSError:
        result.windows_error = "Windows inspection unavailable"
    try:
        result.wsl = wsl_listeners(port, state)
    except SafeRefusal as exc:
        result.wsl_error = str(exc)
    except OSError:
        result.wsl_error = "WSL listener inspection unavailable"
    return result


def source_state(info: GitInfo, expected: GitInfo, expected_sha: str) -> str:
    if info.checkout == "unknown" or info.source == "unknown":
        return "unknown"
    if info.source != expected.source:
        return "unrelated"
    if info.dirty == "dirty":
        return "dirty"
    if info.sha != expected_sha or info.branch != expected.default_branch:
        return "divergent"
    if info.dirty == "clean":
        return "canonical"
    return "noncanonical"


def expected_checkout_verdict(expected: GitInfo, expected_sha: str) -> str:
    if expected.checkout == "unknown" or expected.source == "unknown":
        return "refuse:expected-checkout-identity-unavailable"
    if expected.dirty != "clean":
        return "refuse:expected-checkout-dirty"
    if expected.default_branch == "unknown" or expected.branch != expected.default_branch:
        return "refuse:expected-checkout-not-current-main"
    if expected.sha != expected_sha:
        return "refuse:expected-checkout-sha-mismatch"
    return "ready"


def same_listener_identity(before: list[Listener], after: list[Listener]) -> bool:
    def identity(items: list[Listener]) -> list[tuple[object, ...]]:
        return sorted(
            (
                item.address,
                item.pid,
                item.process.lower(),
                hashlib.sha256(item.command_raw.encode("utf-8")).hexdigest(),
                item.executable_raw.lower(),
                item.git.checkout,
                item.git.sha,
                item.git.dirty,
                item.tasks,
                item.classification,
            )
            for item in items
        )

    return identity(before) == identity(after)


def recovery_verdict(inspection: Inspection, expected: GitInfo, expected_sha: str) -> str:
    expected_verdict = expected_checkout_verdict(expected, expected_sha)
    if expected_verdict != "ready":
        return expected_verdict
    if inspection.task_error:
        return "refuse:firstmate-task-state-inspection-unavailable"
    if inspection.windows_error:
        return "refuse:windows-inspection-unavailable"
    if inspection.wsl_error:
        return "refuse:wsl-inspection-unavailable"
    if not inspection.windows:
        return "refuse:no-windows-listener"
    pids = {listener.pid for listener in inspection.windows}
    if len(pids) != 1:
        return "refuse:ambiguous-windows-ownership"
    if any(listener.classification == "wslrelay" for listener in inspection.windows):
        return "refuse:wslrelay-is-never-terminated"
    if any(listener.classification != "native-windows-node-astro-dev" for listener in inspection.windows):
        return "refuse:windows-process-is-not-proven-node-astro-dev"
    checkouts = {listener.git.checkout for listener in inspection.windows}
    if len(checkouts) != 1 or "unknown" in checkouts:
        return "refuse:windows-checkout-identity-unavailable"
    states = {source_state(listener.git, expected, expected_sha) for listener in inspection.windows}
    if "unrelated" in states:
        return "refuse:windows-process-is-unrelated"
    if "unknown" in states or "canonical" in states:
        return "refuse:windows-source-is-not-proven-stale"
    tasks = sorted({task for listener in inspection.windows for task in listener.tasks})
    if tasks:
        return "refuse:active-firstmate-task-associated"
    for listener in inspection.wsl:
        if (
            listener.classification != "wsl-node-astro-dev"
            or listener.git.checkout != expected.checkout
            or listener.git.sha != expected_sha
            or listener.git.dirty != "clean"
            or listener.git.source != expected.source
        ):
            return "refuse:wsl-port-owned-by-unexpected-process"
    return "eligible"


def sanitize(value: object) -> str:
    return re.sub(r"[\t\r\n\x00-\x1f\x7f]+", " ", str(value)).strip() or "unknown"


def emit(kind: str, **fields: object) -> str:
    line = "\t".join([kind, *(f"{key}={sanitize(value)}" for key, value in fields.items())])
    print(line)
    return line


def render_inspection(mode: str, project: Path, port: int, expected_sha: str, expected: GitInfo, inspection: Inspection) -> list[str]:
    lines = [
        emit("schema", value=SCHEMA),
        emit("request", mode=mode, project=project, port=port, expected_sha=expected_sha),
        emit(
            "expected",
            owner_kernel="wsl",
            address=f"localhost:{port}",
            pid="not-running",
            process="project-launcher",
            command="npm run dev -- --host 0.0.0.0 --port <port>",
            checkout=expected.checkout,
            checkout_windows=wsl_to_windows(project),
            branch=expected.branch,
            sha=expected.sha,
            dirty=expected.dirty,
            git_source=expected.source,
            task_association="none",
            recovery_verdict=expected_checkout_verdict(expected, expected_sha),
        ),
    ]
    if inspection.task_error:
        lines.append(emit("inspection", owner_kernel="firstmate", status="unavailable", error=inspection.task_error))
    if inspection.windows_error:
        lines.append(emit("inspection", owner_kernel="windows", status="unavailable", error=inspection.windows_error))
    if inspection.wsl_error:
        lines.append(emit("inspection", owner_kernel="wsl", status="unavailable", error=inspection.wsl_error))
    for listener in [*inspection.windows, *inspection.wsl]:
        lines.append(
            emit(
                "listener",
                owner_kernel=listener.kernel,
                address=listener.address,
                pid=listener.pid,
                process=listener.process,
                command=listener.command,
                checkout=listener.git.checkout,
                branch=listener.git.branch,
                sha=listener.git.sha,
                dirty=listener.git.dirty,
                git_source=listener.git.source,
                task_association=",".join(listener.tasks) or "none",
                classification=listener.classification,
                recovery_verdict=(
                    "never-terminate"
                    if listener.classification == "wslrelay"
                    else source_state(listener.git, expected, expected_sha)
                ),
            )
        )
    lines.append(emit("recovery", verdict=recovery_verdict(inspection, expected, expected_sha)))
    return lines


def evidence_root(state: Path) -> Path:
    root = state / "localhost-evidence"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    return root


def write_evidence(state: Path, project: Path, port: int, pid: int, lines: list[str]) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", project.name)[:64] or "project"
    path = evidence_root(state) / f"{stamp}-{slug}-{port}-{pid}.evidence"
    content = "\n".join(["private=true", f"created_utc={stamp}", *lines, "action=terminate-exact-windows-pid"]) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    return path


def launcher_command(project: Path, port: int) -> list[str]:
    package = project / "package.json"
    try:
        payload = json.loads(package.read_text(encoding="utf-8"))
        script = payload["scripts"]["dev"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise SafeRefusal("verified Astro dev launcher is unavailable") from exc
    try:
        tokens = shlex.split(script) if isinstance(script, str) else []
    except ValueError as exc:
        raise SafeRefusal("project dev launcher is not proven to be Astro dev") from exc
    if not isinstance(script, str) or re.search(r"[\x00-\x1f\x7f;&|<>$`\\]", script):
        raise SafeRefusal("project dev launcher is not proven to be Astro dev")
    command_tokens = tokens[1:] if tokens[:1] == ["npx"] else tokens
    is_astro_dev = (
        len(command_tokens) >= 2
        and Path(command_tokens[0]).name in {"astro", "astro.js", "astro.mjs"}
        and command_tokens[1] == "dev"
    )
    if not is_astro_dev:
        raise SafeRefusal("project dev launcher is not proven to be Astro dev")
    npm = shutil.which("npm")
    if not npm:
        raise SafeRefusal("npm is unavailable for the verified project launcher")
    return [npm, "run", "dev", "--", "--host", "0.0.0.0", "--port", str(port)]


def revalidated_expected_checkout(project: Path, expected: GitInfo, expected_sha: str) -> str:
    current = git_info(project)
    verdict = expected_checkout_verdict(current, expected_sha)
    if verdict != "ready":
        return verdict
    if current.checkout != expected.checkout or current.source != expected.source:
        return "refuse:expected-checkout-identity-changed"
    return "ready"


def launch_expected(project: Path, port: int, expected: GitInfo, expected_sha: str, evidence: Path) -> OwnedLaunch:
    verdict = revalidated_expected_checkout(project, expected, expected_sha)
    if verdict != "ready":
        raise SafeRefusal(verdict.removeprefix("refuse:"))
    argv = launcher_command(project, port)
    verdict = revalidated_expected_checkout(project, expected, expected_sha)
    if verdict != "ready":
        raise SafeRefusal(verdict.removeprefix("refuse:"))
    log_path = evidence.with_suffix(".launcher.log")
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    log = os.fdopen(descriptor, "wb", buffering=0)
    try:
        process = subprocess.Popen(
            argv,
            cwd=project,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        log.close()
    try:
        pgid = os.getpgid(process.pid)
    except OSError:
        process.kill()
        process.wait()
        raise
    if pgid != process.pid:
        process.kill()
        process.wait()
        raise SafeRefusal("owned launcher process group was not isolated")
    return OwnedLaunch(process=process, pgid=pgid)


def cleanup_owned_launch(launch: OwnedLaunch) -> None:
    try:
        os.killpg(launch.pgid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        return
    try:
        launch.process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(launch.pgid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass


def wsl_route_fingerprint(url: str) -> dict[str, object]:
    test_fixture = os.environ.get("FM_LOCALHOST_TEST_WSL_ROUTE_JSON")
    if test_fixture and os.environ.get("FM_LOCALHOST_TESTING") == "1":
        try:
            return json.loads(Path(test_fixture).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SafeRefusal("WSL route fingerprint fixture failed") from exc
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 FirstmateLocalhost/1",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    try:
        with opener.open(request, timeout=10) as response:
            body = response.read(8 * 1024 * 1024 + 1)
            if len(body) > 8 * 1024 * 1024:
                raise SafeRefusal("WSL route response exceeds 8 MiB fingerprint bound")
            return {"status": int(response.status), "sha256": hashlib.sha256(body).hexdigest(), "length": len(body)}
    except SafeRefusal:
        raise
    except Exception as exc:  # urllib has several transport-specific exception types.
        raise SafeRefusal("WSL route fingerprint failed") from exc


def windows_route_fingerprint(url: str) -> dict[str, object]:
    raw = run_powershell(ROUTE_PS, url)
    try:
        payload = json.loads(raw.lstrip("\ufeff").strip())
        status = int(payload["status"])
        sha = str(payload["sha256"])
        length = int(payload["length"])
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise SafeRefusal("Windows route fingerprint was invalid") from exc
    if status < 100 or not re.fullmatch(r"[0-9a-fA-F]{64}", sha) or length < 0:
        raise SafeRefusal("Windows route fingerprint was invalid")
    return {"status": status, "sha256": sha.lower(), "length": length}


def verified_pair(inspection: Inspection, expected: GitInfo, expected_sha: str) -> tuple[bool, str]:
    if inspection.task_error:
        return False, "firstmate-task-state-inspection-unavailable"
    if inspection.windows_error:
        return False, "windows-inspection-unavailable"
    if inspection.wsl_error:
        return False, "wsl-inspection-unavailable"
    if len(inspection.windows) != 1 or inspection.windows[0].classification != "wslrelay":
        return False, "windows-owner-is-not-wslrelay"
    if len(inspection.wsl) != 1:
        return False, "expected-wsl-listener-missing"
    item = inspection.wsl[0]
    if (
        item.classification != "wsl-node-astro-dev"
        or item.git.checkout != expected.checkout
        or item.git.sha != expected_sha
        or item.git.dirty != "clean"
        or item.git.source != expected.source
    ):
        return False, "wsl-listener-identity-mismatch"
    return True, "pair-proven"


def post_stop_restart_verdict(inspection: Inspection, expected: GitInfo, expected_sha: str) -> str:
    if inspection.task_error:
        return "refuse:firstmate-task-state-inspection-unavailable"
    if inspection.windows_error:
        return "refuse:windows-inspection-unavailable"
    if inspection.wsl_error:
        return "refuse:wsl-inspection-unavailable"
    if inspection.wsl:
        pair_ok, reason = verified_pair(inspection, expected, expected_sha)
        return "already-verified" if pair_ok else f"refuse:post-stop-reserved-port-not-safe:{reason}"
    if len(inspection.windows) > 1 or any(item.classification != "wslrelay" for item in inspection.windows):
        return "refuse:post-stop-reserved-port-not-safe:windows-owner-is-not-wslrelay"
    return "restart-safe"


def verify(project: Path, port: int, expected_sha: str, expected: GitInfo, state: Path, *, render: bool = True) -> bool:
    if expected_checkout_verdict(expected, expected_sha) != "ready":
        inspection = inspect_system(port, state)
        if render:
            render_inspection("verify", project, port, expected_sha, expected, inspection)
            emit("verification", verdict="refuse", reason=expected_checkout_verdict(expected, expected_sha))
        return False
    inspection = inspect_system(port, state)
    pair_ok, reason = verified_pair(inspection, expected, expected_sha)
    if not pair_ok:
        if render:
            render_inspection("verify", project, port, expected_sha, expected, inspection)
            emit("verification", verdict="refuse", reason=reason)
        return False
    url = f"http://localhost:{port}/"
    try:
        wsl_fingerprint = wsl_route_fingerprint(url)
        windows_fingerprint = windows_route_fingerprint(url)
    except SafeRefusal as exc:
        if render:
            render_inspection("verify", project, port, expected_sha, expected, inspection)
            emit("verification", verdict="refuse", reason=str(exc))
        return False
    fingerprints_match = (
        wsl_fingerprint == windows_fingerprint
        and 200 <= int(wsl_fingerprint["status"]) < 400
    )
    final = inspect_system(port, state)
    final_pair_ok, final_reason = verified_pair(final, expected, expected_sha)
    verification_ok = pair_ok and final_pair_ok and fingerprints_match
    if render:
        render_inspection("verify", project, port, expected_sha, expected, final)
        emit("route", origin_kernel="wsl", **wsl_fingerprint)
        emit("route", origin_kernel="windows", **windows_fingerprint)
        emit(
            "verification",
            verdict="pass" if verification_ok else "refuse",
            reason="pair-and-route-fingerprints-match" if verification_ok else (final_reason if not final_pair_ok else (reason if not pair_ok else "route-fingerprint-mismatch")),
        )
    return verification_ok


def termination_boundary_listener(
    listener: Listener,
    port: int,
    expected: GitInfo,
    expected_sha: str,
    state: Path,
) -> Listener:
    boundary = inspect_system(port, state)
    if recovery_verdict(boundary, expected, expected_sha) != "eligible":
        raise SafeRefusal("pid-or-command-reresolution-changed")
    if len(boundary.windows) != 1 or not same_listener_identity([listener], boundary.windows):
        raise SafeRefusal("pid-or-command-reresolution-changed")
    return boundary.windows[0]


def terminate_exact(listener: Listener, port: int, expected: GitInfo, expected_sha: str, state: Path) -> None:
    listener = termination_boundary_listener(listener, port, expected, expected_sha, state)
    if listener.classification != "native-windows-node-astro-dev" or Path(listener.process).name.lower() != "node.exe":
        raise SafeRefusal("exact PID target is no longer a proven native Windows Astro dev server")
    if Path(listener.process).name.lower() == "wslrelay.exe":
        raise SafeRefusal("wslrelay.exe is never a termination target")
    if listener.git.checkout == "unknown":
        raise SafeRefusal("exact PID target checkout is unavailable")
    astro_script = astro_dev_script(listener.command_raw, listener.executable_raw, listener.git.checkout)
    if astro_script is None:
        raise SafeRefusal("exact PID target Astro script path is unavailable")
    expected_script = wsl_to_windows(astro_script)
    if expected_script == "unknown":
        raise SafeRefusal("exact PID target Astro script path is unavailable")
    command_hash = hashlib.sha256(listener.command_raw.encode("utf-8")).hexdigest()
    output = run_powershell(TERMINATE_PS, str(port), str(listener.pid), command_hash, expected_script, timeout=20).strip()
    if output != "terminated":
        raise SafeRefusal("exact PID termination was not confirmed")


def recover(project: Path, port: int, expected_sha: str, expected: GitInfo, state: Path) -> bool:
    before = inspect_system(port, state)
    before_lines = render_inspection("recover", project, port, expected_sha, expected, before)
    verdict = recovery_verdict(before, expected, expected_sha)
    if verdict != "eligible":
        emit("recovery-result", verdict=verdict, mutated="no")
        return False
    target = before.windows[0]
    try:
        launcher_command(project, port)
    except SafeRefusal as exc:
        emit("recovery-result", verdict=f"refuse:{str(exc)}", mutated="no")
        return False
    immediate = inspect_system(port, state)
    immediate_verdict = recovery_verdict(immediate, expected, expected_sha)
    if immediate_verdict != "eligible" or not same_listener_identity(before.windows, immediate.windows):
        emit("recovery-result", verdict="refuse:pid-or-command-reresolution-changed", mutated="no")
        return False
    mutation = inspect_system(port, state)
    mutation_verdict = recovery_verdict(mutation, expected, expected_sha)
    if mutation_verdict != "eligible" or not same_listener_identity(immediate.windows, mutation.windows):
        emit("recovery-result", verdict="refuse:pid-or-command-reresolution-changed", mutated="no")
        return False
    evidence_lines = [
        *before_lines,
        emit("immediate-recheck", verdict=immediate_verdict, pid=target.pid, identity="unchanged"),
        emit("mutation-recheck", verdict=mutation_verdict, pid=target.pid, identity="unchanged"),
    ]
    try:
        evidence = write_evidence(state, project, port, target.pid, evidence_lines)
    except OSError:
        emit("recovery-result", verdict="refuse:private-evidence-write-failed", mutated="no")
        return False
    try:
        terminate_exact(mutation.windows[0], port, expected, expected_sha, state)
    except SafeRefusal as exc:
        emit(
            "recovery-result",
            verdict=f"refuse:{str(exc)}",
            mutated="unknown-after-exact-pid-termination-attempt",
            evidence=evidence,
        )
        return False
    post_stop = inspect_system(port, state)
    post_stop_verdict = post_stop_restart_verdict(post_stop, expected, expected_sha)
    render_inspection("recover-post-stop", project, port, expected_sha, expected, post_stop)
    if post_stop_verdict not in {"restart-safe", "already-verified"}:
        emit("recovery-result", verdict=f"failed:{post_stop_verdict.removeprefix('refuse:')}", mutated="windows-pid-terminated", evidence=evidence)
        return False
    launcher_pid: int | str = "already-running"
    launcher_process = None
    if post_stop_verdict == "restart-safe":
        try:
            launcher_process = launch_expected(project, port, expected, expected_sha, evidence)
            launcher_pid = launcher_process.process.pid
        except (OSError, SafeRefusal) as exc:
            emit("recovery-result", verdict=f"failed:{str(exc)}", mutated="windows-pid-terminated", evidence=evidence)
            return False
    timeout = os.environ.get("FM_LOCALHOST_START_TIMEOUT", "20")
    try:
        timeout_seconds = max(1, min(120, int(timeout)))
    except ValueError:
        timeout_seconds = 20
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if verify(project, port, expected_sha, expected, state, render=False):
            final = inspect_system(port, state)
            final_pair_ok, _ = verified_pair(final, expected, expected_sha)
            render_inspection("recover-post-verify", project, port, expected_sha, expected, final)
            if not final_pair_ok:
                time.sleep(0.2)
                continue
            emit(
                "recovery-result",
                verdict="recovered-and-verified",
                mutated=f"terminated-exact-pid:{target.pid}",
                launcher_pid=launcher_pid,
                evidence=evidence,
            )
            return True
        time.sleep(0.2)
    verify(project, port, expected_sha, expected, state, render=True)
    if launcher_process is not None:
        cleanup_owned_launch(launcher_process)
    emit(
        "recovery-result",
        verdict="failed:post-recovery-verification",
        mutated=f"terminated-exact-pid:{target.pid}",
        launcher_pid=launcher_pid,
        evidence=evidence,
    )
    return False


def parser() -> argparse.ArgumentParser:
    description = "Inspect or narrowly recover localhost ownership across native Windows and WSL."
    epilog = """mechanics (authoritative):
  The tuple is <project> <port> <expected-sha>. <project> must be the intended
  clean WSL default-branch checkout, and <expected-sha> must be its full 40-hex
  canonical commit. inspect reports every Windows and WSL listener with owner
  kernel, address, PID, process, redacted command, checkout, branch, SHA, dirty
  state, normalized Git source, task association, classification, and recovery
  verdict. It reads Windows listeners and process identity through fixed
  non-interactive PowerShell, WSL listeners through ss and /proc, and task
  associations from this Firstmate home's state/*.meta. It never reads a
  process environment, credentials, production data, or hosted data.

  recover is deliberately narrower than inspect. It may stop exactly one PID
  only after complete observations, including a fresh mutation-boundary
  recheck, independently prove that the same PID still owns every
  native-Windows binding of the reserved port; the unchanged
  process is node.exe whose first script argument resolves to that checkout's
  node_modules/astro/astro.js or astro.mjs and is followed immediately by `dev`;
  that checkout is dirty,
  divergent, or otherwise noncanonical; no task record names that checkout or
  PID; WSL has no unrelated port owner; and the requested replacement is clean,
  on the repository default branch, at expected-sha. Unknown commands, changed
  PIDs or commands, multiple Windows owners, unrelated sources, task records,
  missing identity, Windows inspection failure, canonical Windows source,
  production-like commands, and every wslrelay.exe owner refuse recovery.
  Recovery never kills by process name or port and never targets wslrelay.exe.

  Immediately before mutation, recover re-resolves listener, PID, command,
  checkout, Git, and task evidence. The termination boundary repeats that
  complete proof after the evidence is fsynced. It writes a mode-0600 record beneath
  $FM_HOME/state/localhost-evidence before invoking fixed PowerShell that again
  requires the exact PID, port, node.exe identity, unchanged command hash, and
  exact Astro script path followed by `dev`. After the exact PID exits, it
  re-resolves the clean expected checkout and runs only that project's package.json
  `scripts.dev` when that script is proven to be Astro, using `npm run dev --
  --host 0.0.0.0 --port <port>`; an already-running expected WSL server is reused
  rather than duplicated.

  verify sends the same bounded browser-like request to http://localhost:<port>/
  from WSL and native Windows, compares status/body-length/SHA-256 fingerprints,
  then repeats the listener-pair inspection. It passes only when Windows reports
  wslrelay.exe, WSL reports the clean expected Astro server, and both route
  fingerprints match the post-route pair. A nonzero exit means
  inspection, recovery, or verification did not prove the requested safe state.
"""
    result = argparse.ArgumentParser(
        prog="fm-localhost.py",
        description=description,
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    result.add_argument("mode", choices=("inspect", "recover", "verify"))
    result.add_argument("project")
    result.add_argument("port", type=int)
    result.add_argument("expected_sha")
    return result


def main() -> int:
    args = parser().parse_args()
    project = Path(args.project).resolve()
    if not project.is_dir():
        print("fm-localhost: project must be an existing directory", file=sys.stderr)
        return 2
    if not 1 <= args.port <= 65535:
        print("fm-localhost: port must be between 1 and 65535", file=sys.stderr)
        return 2
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.expected_sha):
        print("fm-localhost: expected-sha must be a full 40-hex commit", file=sys.stderr)
        return 2
    expected_sha = args.expected_sha.lower()
    expected = git_info(project)
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", str(root)))).resolve()
    state = Path(os.environ.get("FM_STATE_OVERRIDE", str(home / "state"))).resolve()
    if args.mode == "inspect":
        inspection = inspect_system(args.port, state)
        render_inspection("inspect", project, args.port, expected_sha, expected, inspection)
        return 1 if inspection.windows_error or inspection.wsl_error else 0
    if args.mode == "verify":
        return 0 if verify(project, args.port, expected_sha, expected, state) else 1
    return 0 if recover(project, args.port, expected_sha, expected, state) else 1


if __name__ == "__main__":
    raise SystemExit(main())
