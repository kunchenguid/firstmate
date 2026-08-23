#!/usr/bin/env python3
"""Renew Pi provider credentials before they expire, and republish them.

This module is the single owner of firstmate's provider-credential *renewal*.
`bin/fm-credential-expiry.py` owns the question "can this credential still
authenticate", and `bin/fm-pi-account-home.py` owns "how does one pooled Pi
profile become the single-profile account home its consumers read". This owns
the third question those two deliberately leave open: what turns a credential
that is about to die back into a live one, with no human at the keyboard.

Why this exists: every Pi profile in the fleet expires on the same day, and
nothing on the host renewed one. A reviewer compartment cannot renew its own,
because its egress allowlist carries the provider's API host and deliberately
not the provider's auth host, so renewal has to happen here and be staged
outward. Until it did, the whole fleet stopped on a date rather than on a
decision.

What it does, in order:

  select     read the pool, name the slots whose access token dies inside the
             horizon, and refuse the ones whose shape cannot be renewed at all
  back up    copy the pool first. Pi rewrites the credential file in place with
             a plain truncating write, so an interrupted write loses every slot
             at once, not just the one being renewed
  rotate     hand the due slots to `bin/fm-pi-refresh.mjs`, which drives Pi's
             own OAuth refresh inside Pi's own credential lock
  republish  re-project each renewed slot into the account home its consumers
             read, because a renewal that stays in the pool leaves every
             reviewer holding the credential that is about to expire
  verify     re-read each republished home through the expiry owner and require
             it to be usable, so the run's exit code means the fleet is live
             rather than that an HTTP call returned 200

It also owns the schedule that makes the above unattended: one machine-global
macOS LaunchAgent running `run-once --all --scheduled` on an interval. Machine
global because the credential pool is: one `auth.json` serves every Firstmate
home on the machine, and this machine has nine of them, so a per-home job would
install redundant refreshers racing for one lock.

A heartbeat counts only when it carries the activation nonce baked into the
installed plist, which exists only in launchd's copy of the job environment.
A hand-run `--scheduled` therefore writes nothing at all rather than making an
absent or dead schedule look alive.

What it never does: log in. A profile whose refresh material is gone needs a
human and a browser, and this says so by name instead of pretending otherwise.
It also never installs the schedule on its own: a background owner that writes
credentials is installed deliberately, so `ensure` reports and waits.

Token material is never printed, returned, or logged. Accounts and tokens
appear only as truncated digests, and a provider error is redacted before it is
reported, because Pi's own refresh error text interpolates the provider's JSON
response and one failure shape of that response carries a token.

Usage:
  fm-pi-refresh.py report [--source PATH] [--horizon-seconds N] [--json]
  fm-pi-refresh.py run-once [--source PATH] [--destination-root DIR]
                            [--horizon-seconds N] [--slot NAME]... [--all]
                            [--backup-root DIR] [--timeout-ms N] [--json]
                            [--scheduled]
  fm-pi-refresh.py install-scheduler [--interval-seconds N]
  fm-pi-refresh.py uninstall-scheduler
  fm-pi-refresh.py scheduler-status [--json]
  fm-pi-refresh.py ensure
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time
from typing import Any

BIN_DIR = Path(__file__).resolve().parent
ACCOUNT_HOME_TOOL = BIN_DIR / "fm-pi-account-home.py"
CREDENTIAL_EXPIRY_TOOL = BIN_DIR / "fm-credential-expiry.py"
REFRESH_ADAPTER = BIN_DIR / "fm-pi-refresh.mjs"

DEFAULT_SOURCE = "~/.pi/agent/auth.json"

# The observed credential life is ten days. Renewing at half life means the
# machine has to be off for five consecutive days before a token is lost, while
# still asking the provider for a rotation only about twice a fortnight.
DEFAULT_HORIZON_SECONDS = 5 * 24 * 60 * 60

# One rotation is one HTTPS round trip per slot. The adapter enforces this per
# slot; the whole invocation gets the same number times the slot count plus a
# process-start allowance, so one wedged slot cannot hold a scheduled run open.
DEFAULT_TIMEOUT_MS = 20_000
ADAPTER_START_ALLOWANCE_SECONDS = 30

# Pi gives up acquiring its credential lock after 30 seconds, so a slot can
# spend that long waiting before its own refresh timeout even starts. Budgeting
# only the round trip made the whole invocation killable mid-write, which is
# exactly the interrupted write the pre-rotation copy exists to survive, self
# inflicted.
ADAPTER_LOCK_WAIT_SECONDS = 30

# The adapter emits one small JSON object per slot. Anything larger is not
# output we know how to read, and is refused rather than parsed.
MAX_ADAPTER_OUTPUT_BYTES = 256 * 1024

# Used only when a Pi install declares no readable Node floor of its own. Both
# installs on this machine declare >= 22.19.0.
FALLBACK_NODE_MAJOR = 22
NODE_PROBE_TIMEOUT_SECONDS = 10

PI_PACKAGE_NAME = "@earendil-works/pi-coding-agent"

# Backups exist for one failure: an interrupted in-place write of the pool.
# Once a run has proved the pool still parses and still carries every slot, the
# older copies protect nothing and are only credential material at rest.
BACKUP_KEEP = 3
DEFAULT_BACKUP_ROOT = "~/.local/state/firstmate/pi-credential-backups"

# A second-resolution stamp collides when two runs land inside one second. More
# than this many in the same second is a loop, not a schedule.
MAX_BACKUPS_PER_SECOND = 100

# The account homes the reviewer roster names live beside the Agent Fleet
# account pool, under the `pi` vendor directory.
DEFAULT_DESTINATION_ROOT = "~/.local/share/agent-fleet/accounts/pi"

# Republished homes are verified with headroom, not merely "not yet expired": a
# credential that dies an hour from now is not a successful renewal.
VERIFY_MARGIN_SECONDS = 24 * 60 * 60

# One label for the machine, because one credential pool serves every Firstmate
# home on it and this machine has nine.
SCHEDULER_LABEL = "com.firstmate.pi-auth-refresh"

# Six hours against a five-day horizon. The interval only has to be short
# enough that a machine which wakes at all inside the horizon renews; a fire
# outside the horizon is a no-op, so a shorter interval buys nothing.
DEFAULT_INTERVAL_SECONDS = 6 * 60 * 60
MIN_INTERVAL_SECONDS = 300
MAX_INTERVAL_SECONDS = 24 * 60 * 60

# A heartbeat is stale after this many intervals. Two would call a job late by
# one skipped fire dead; three tolerates a missed wake without hiding a job
# that has actually stopped.
HEARTBEAT_STALE_INTERVALS = 3

LAUNCH_AGENTS_DIR = "~/Library/LaunchAgents"

# The installed job is identified by what it runs, not by which checkout is
# asking. Nine Firstmate homes share one credential pool and one label.
REFRESH_ENTRYPOINT_NAME = "fm-pi-refresh.py"

# launchctl answers locally or not at all; a hang here would wedge a session
# start rather than report a broken schedule.
LAUNCHCTL_TIMEOUT_SECONDS = 20


# Any run of this length in the base64url alphabet is treated as token material.
# The adapter redacts its own writes, but stderr is a channel this side does not
# control: Node warnings, import-time output and internal traces land there too,
# and slicing is not redaction.
TOKEN_LIKE = re.compile(r"[A-Za-z0-9_-]{40,}")


def redact(text: str, limit: int = 300) -> str:
    """Strip token-shaped runs, then truncate. Never the other way round."""

    return TOKEN_LIKE.sub("[redacted]", text)[:limit]


class RefreshError(RuntimeError):
    """One renewal run cannot proceed, or did not produce a live fleet.

    `attention` marks the case where the schedule itself is working and
    something it renews needs a human. Reporting that as a broken schedule is
    the alarm that gets ignored.
    """

    def __init__(self, message: str, *, attention: bool = False) -> None:
        super().__init__(message)
        self.attention = attention


def fail(message: str, *, attention: bool = False) -> None:
    raise RefreshError(message, attention=attention)


def load_tool(path: Path, name: str) -> Any:
    """Load a sibling bin script as a module, the way its other callers do."""

    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        fail(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def account_home_tool() -> Any:
    return load_tool(ACCOUNT_HOME_TOOL, "fm_pi_account_home")


def credential_expiry_tool() -> Any:
    return load_tool(CREDENTIAL_EXPIRY_TOOL, "fm_credential_expiry")


def pi_executable() -> Path:
    """Locate the Pi entrypoint WITHOUT resolving it through its symlink.

    The unresolved path is the one that matters: this machine carries two Pi
    installs, and the Node beside each one is the Node that install works
    under. `bin/fm-crosscheck.py: pi_reviewer_command` picks its reviewer Node
    by the same sibling rule for the same reason.
    """

    override = os.environ.get("FM_PI_BIN")
    name = override or "pi"
    located = shutil.which(name)
    if not located:
        # `which` refuses a file without the execute bit exactly as it refuses
        # an absent one, and telling an operator who DID set FM_PI_BIN that it
        # is "not on PATH" sends them to the wrong problem.
        if override and Path(override).expanduser().exists():
            fail(f"FM_PI_BIN names {override}, which exists but is not executable")
        fail(
            f"Pi executable {name!r} is not on PATH; set FM_PI_BIN to its path. "
            "A scheduled run has almost no PATH, so it must set it."
        )
    return Path(located)


def pi_package_root(entrypoint: Path | None = None) -> Path:
    """Resolve the installed Pi package directory from its entrypoint.

    The package root is what this needs, rather than the launch command
    `fm-crosscheck.py` builds, because the two modules it drives are internal
    and Pi's `exports` map publishes neither, so they are reached by path.
    """

    resolved = (entrypoint or pi_executable()).resolve()
    root = resolved.parent.parent
    manifest_path = root / "package.json"
    if not manifest_path.is_file():
        fail(
            f"Pi entrypoint {resolved} does not sit inside a package directory "
            f"({root} carries no package.json)"
        )
    # Named, not merely shaped. Any directory holding a package.json satisfied
    # the old check, which pushed the real refusal one layer down into the
    # module import where it reads as a missing file rather than a wrong Pi.
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"Pi package manifest at {manifest_path} is unreadable: {type(exc).__name__}")
    if manifest.get("name") != PI_PACKAGE_NAME:
        fail(
            f"{root} is not a {PI_PACKAGE_NAME} install (its package.json names "
            f"{manifest.get('name')!r}); check FM_PI_BIN"
        )
    return root


def pi_node_floor(root: Path) -> int:
    """Read the major Node version this Pi install declares it needs."""

    try:
        manifest = json.loads((root / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return FALLBACK_NODE_MAJOR
    declared = ""
    engines = manifest.get("engines")
    if isinstance(engines, dict) and isinstance(engines.get("node"), str):
        declared = engines["node"]
    match = re.search(r">=\s*(\d+)", declared)
    return int(match.group(1)) if match else FALLBACK_NODE_MAJOR


def node_major(binary: str) -> int | None:
    try:
        completed = subprocess.run(
            [binary, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=NODE_PROBE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.match(r"v(\d+)\.", completed.stdout.decode("utf-8", errors="replace").strip())
    return int(match.group(1)) if match else None


def node_binary(entrypoint: Path | None = None) -> str:
    """Pin the Node that runs the adapter to the one this Pi works under.

    A Node older than the install's own floor is refused rather than tried.
    Both Pi installs on this machine declare `>=22.19.0`, and the one whose
    sibling Node is older does not merely warn: it dies inside undici with
    `webidl.util.markAsUncloneable is not a function`. Reporting that as a
    renewal failure would send an operator hunting the provider.
    """

    entrypoint = entrypoint or pi_executable()
    floor = pi_node_floor(pi_package_root(entrypoint))
    override = os.environ.get("FM_PI_NODE_BIN")
    if override:
        located = shutil.which(override) or override
        if not Path(located).is_file():
            fail(f"FM_PI_NODE_BIN does not name a file: {override}")
        candidates = [str(Path(located).resolve())]
    else:
        candidates = []
        sibling = entrypoint.parent / "node"
        if sibling.is_file():
            candidates.append(str(sibling.resolve()))
        located = shutil.which("node")
        if located:
            candidates.append(str(Path(located).resolve()))
    if not candidates:
        fail("node is not on PATH; set FM_PI_NODE_BIN to the Node that runs Pi")
    # Probed once each. A hanging Node costs NODE_PROBE_TIMEOUT_SECONDS, and
    # probing again to build the refusal message doubled that before the
    # adapter's own timeout could apply.
    probed = [(candidate, node_major(candidate)) for candidate in candidates]
    for candidate, major in probed:
        if major is not None and major >= floor:
            return candidate
    reported = ", ".join(
        f"{candidate} (v{major if major is not None else '?'})"
        for candidate, major in probed
    )
    fail(
        f"no Node meets the floor this Pi install declares (>= {floor}); tried: "
        f"{reported}. Set FM_PI_NODE_BIN to a newer Node."
    )
    raise AssertionError("unreachable")


def utc(seconds: float) -> str:
    moment = datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc)
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def expiry_seconds(entry: dict[str, Any]) -> float | None:
    """Read one pool entry's expiry, which Pi records in milliseconds."""

    value = entry.get("expires")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    seconds = float(value) / 1000.0
    return seconds if seconds > 0 else None


def select_due(
    pool: dict[str, Any],
    *,
    horizon_seconds: float,
    now: float,
    requested: list[str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split the pool into slots to renew now and slots to leave alone.

    Shape is judged by the account-home owner's own `entry_faults`, so "which
    Pi credentials are well formed" has one definition rather than two. A
    faulted slot is never renewed: a blank refresh token cannot be rotated, and
    a run that tried would report a provider error where the real answer is
    that a human has to log in.
    """

    home_tool = account_home_tool()
    names = sorted(pool) if requested is None else list(dict.fromkeys(requested))
    missing = [name for name in names if name not in pool]
    if missing:
        fail("Pi credential pool has no profile named: " + ", ".join(sorted(missing)))

    due: list[dict[str, Any]] = []
    held: list[dict[str, Any]] = []
    for name in names:
        entry = pool[name]
        record: dict[str, Any] = {
            "slot": name,
            "account": (
                home_tool.account_digest(entry) if isinstance(entry, dict) else "none"
            ),
            "expires_at": None,
            "expires_in_seconds": None,
            "reason": "",
        }
        faults = home_tool.entry_faults(entry)
        if faults:
            record["reason"] = "unrenewable: " + "; ".join(faults)
            held.append(record)
            continue
        expires = expiry_seconds(entry)
        if expires is None:
            record["reason"] = "unrenewable: has no readable expiry"
            held.append(record)
            continue
        record["expires_at"] = utc(expires)
        record["expires_in_seconds"] = int(expires - now)
        if expires - now <= horizon_seconds:
            record["reason"] = "due"
            due.append(record)
        else:
            record["reason"] = "outside the renewal horizon"
            held.append(record)
    return due, held


def private_directory(path: Path) -> None:
    """Create one owner-only directory, refusing to write through a link.

    `mkdir(parents=True)` applies its mode to the leaf only, so intermediates
    land at the caller's umask, and `exist_ok=True` follows a symlinked
    directory because `isdir` does. Both matter here: what lands underneath is
    a copy of every credential in the fleet.
    """

    missing: list[Path] = []
    walk = path
    while True:
        try:
            existing = walk.lstat()
        except FileNotFoundError:
            missing.append(walk)
            if walk.parent == walk:
                break
            walk = walk.parent
            continue
        except OSError as exc:
            fail(f"backup path is unreadable at {walk}: {exc.strerror}")
        if not stat.S_ISDIR(existing.st_mode) or walk.is_symlink():
            fail(f"refusing to write a credential backup through {walk}")
        break
    for component in reversed(missing):
        os.mkdir(component, 0o700)
        os.chmod(component, 0o700)
    os.chmod(path, 0o700)


def backup_pool(
    source: Path, backup_root: Path, *, now: float, expected: set[str]
) -> Path:
    """Copy the pool before anything rotates.

    Pi rewrites the credential file with a plain truncating `writeFileSync`
    rather than a temp file and a rename, so an interrupted write does not lose
    the slot being renewed - it loses every slot in the file. This copy is the
    only thing between that and eight accounts needing a browser.
    """

    private_directory(backup_root)
    stamp = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    # The stamp resolves to a second, so two runs inside one second collide.
    # The suffix is zero padded because pruning orders these by name, and an
    # unpadded 10 would sort before 2.
    handle = None
    for attempt in range(MAX_BACKUPS_PER_SECOND):
        destination = backup_root / f"auth.json.{stamp}-{attempt:02d}"
        try:
            handle = os.open(
                str(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
            )
            break
        except FileExistsError:
            continue
        except OSError as exc:
            fail(f"the pre-rotation copy cannot be written at {destination}: {exc.strerror}")
    if handle is None:
        fail(
            f"{MAX_BACKUPS_PER_SECOND} pre-rotation copies already exist for {stamp}; "
            "a renewal is looping rather than running"
        )
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(source.read_bytes())
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            os.unlink(destination)
        except OSError:
            pass
        raise
    # The read above is unlocked, which is the same non-atomic read this module
    # faults Pi for. A torn copy is worse than no copy, because it is only ever
    # reached for by an operator who already has a damaged pool, so the copy is
    # proved before it is offered as one.
    damage = pool_is_intact(destination, expected)
    if damage:
        try:
            os.unlink(destination)
        except OSError:
            pass
        fail(
            f"the pre-renewal copy of {source} did not come out intact "
            f"({damage}); nothing was rotated"
        )
    return destination


def prune_backups(backup_root: Path, keep: int) -> list[Path]:
    """Drop backups older than the newest `keep`, once the pool is proved good."""

    copies = sorted(
        (path for path in backup_root.glob("auth.json.*") if path.is_file()),
        key=lambda path: path.name,
    )
    removed: list[Path] = []
    for path in copies[: max(0, len(copies) - keep)]:
        try:
            path.unlink()
            removed.append(path)
        except OSError:
            # A backup that will not delete is not a reason to fail a renewal
            # that already succeeded; it is reported and left alone.
            pass
    return removed


def run_adapter(
    *, source: Path, slots: list[str], timeout_ms: int
) -> list[dict[str, Any]]:
    """Drive `fm-pi-refresh.mjs` and read back one record per slot."""

    if not REFRESH_ADAPTER.is_file():
        fail(f"the renewal adapter is missing at {REFRESH_ADAPTER}")
    entrypoint = pi_executable()
    command = [
        node_binary(entrypoint),
        str(REFRESH_ADAPTER),
        "--pi-root",
        str(pi_package_root(entrypoint)),
        "--pool",
        str(source),
        "--timeout-ms",
        str(timeout_ms),
    ]
    for slot in slots:
        command += ["--slot", slot]
    budget = (
        timeout_ms / 1000.0 + ADAPTER_LOCK_WAIT_SECONDS
    ) * len(slots) + ADAPTER_START_ALLOWANCE_SECONDS
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=budget,
            check=False,
        )
    except subprocess.TimeoutExpired:
        fail(
            f"the renewal adapter did not finish within {int(budget)}s for "
            f"{len(slots)} slots; the pool may hold a partially renewed set"
        )
    except OSError as exc:
        fail(f"the renewal adapter could not be launched: {exc.strerror or exc}")
    if len(completed.stdout) > MAX_ADAPTER_OUTPUT_BYTES:
        fail(
            f"the renewal adapter emitted more than {MAX_ADAPTER_OUTPUT_BYTES} "
            "bytes, which is not output this reads"
        )
    records: list[dict[str, Any]] = []
    for line in completed.stdout.decode("utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except ValueError:
            fail("the renewal adapter emitted a line that is not a JSON record")
        if not isinstance(value, dict) or "slot" not in value:
            fail("the renewal adapter emitted a record naming no slot")
        records.append(value)
    if not records:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        fail(
            "the renewal adapter reported nothing for "
            f"{len(slots)} slots (exit {completed.returncode})"
            + (f": {redact(detail)}" if detail else "")
        )
    seen = {record["slot"] for record in records}
    unreported = [slot for slot in slots if slot not in seen]
    if unreported:
        fail(
            "the renewal adapter reported no outcome for: " + ", ".join(unreported)
        )
    return records


def reproject(
    *, source: Path, destination_root: Path, slots: list[str]
) -> tuple[list[str], list[str]]:
    """Republish renewed slots into the account homes that already exist.

    Only existing homes are refreshed. Creating one is how an operator adds a
    reviewer to the fleet, and a renewal run is the wrong place to do it
    silently: the roster names account homes by path, so a home that appears on
    its own is a reviewer nobody added.
    """

    present = [slot for slot in slots if (destination_root / slot).is_dir()]
    absent = [slot for slot in slots if slot not in present]
    if not present:
        return [], absent
    command = [
        sys.executable,
        str(ACCOUNT_HOME_TOOL),
        "project",
        "--source",
        str(source),
        "--destination-root",
        str(destination_root),
    ]
    for slot in present:
        command += ["--profile", slot]
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        fail(
            "renewed credentials could not be republished into "
            f"{destination_root}: {redact(detail, 400)}"
        )
    return present, absent


def verify_homes(destination_root: Path, slots: list[str]) -> list[dict[str, Any]]:
    """Require every republished home to be usable, through the expiry owner."""

    expiry = credential_expiry_tool()
    records = []
    for slot in slots:
        record = expiry.inspect_profile(
            destination_root / slot,
            harness="pi",
            margin_seconds=VERIFY_MARGIN_SECONDS,
        )
        records.append({"slot": slot, "state": record["state"], "detail": record["detail"]})
        try:
            expiry.require_state(record, "usable", f"republished Pi account home {slot}")
        except expiry.CredentialExpiryError as exc:
            fail(str(exc))
    return records


def pool_is_intact(source: Path, expected: set[str]) -> str:
    """Name what is wrong with the pool after a run, or an empty string."""

    try:
        parsed = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return f"the pool no longer reads as JSON ({type(exc).__name__})"
    if not isinstance(parsed, dict):
        return "the pool is no longer a profile object"
    lost = sorted(expected - set(parsed))
    if lost:
        return "the pool lost profiles: " + ", ".join(lost)
    return ""


def render(rows: list[tuple[str, ...]], header: tuple[str, ...]) -> str:
    widths = [
        max(len(header[index]), *(len(row[index]) for row in rows))
        if rows
        else len(header[index])
        for index in range(len(header))
    ]
    lines = ["  ".join(header[i].ljust(widths[i]) for i in range(len(header))).rstrip()]
    for row in rows:
        lines.append("  ".join(row[i].ljust(widths[i]) for i in range(len(row))).rstrip())
    return "\n".join(lines)


def command_report(args: argparse.Namespace) -> int:
    source = Path(args.source).expanduser()
    pool = account_home_tool().read_pool(source)
    due, held = select_due(
        pool, horizon_seconds=args.horizon_seconds, now=time.time()
    )
    if args.json:
        print(
            json.dumps(
                {"due": due, "held": held, "horizon_seconds": args.horizon_seconds},
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    rows = [
        (
            record["slot"],
            record["expires_at"] or "-",
            record["account"],
            record["reason"],
        )
        for record in sorted(due + held, key=lambda item: item["slot"])
    ]
    print(render(rows, ("PROFILE", "EXPIRES", "ACCOUNT", "STATE")))
    print(f"due={len(due)} held={len(held)} horizon={args.horizon_seconds}s")
    return 0


def command_run_once(args: argparse.Namespace) -> int:
    """Run one renewal, stamping the heartbeat when launchd is the caller.

    The stamp is written whether or not the renewal succeeded, and carries
    which it was: a job that fails every fire must not read as a dead
    scheduler, and a scheduler that stopped firing must not read as healthy
    from its last success.
    """

    if not getattr(args, "scheduled", False):
        return _run_once(args)
    now = time.time()
    try:
        code = _run_once(args)
        azure_source = scheduled_azure_source(args)
        if code == 0 and azure_source is not None:
            azure_args = argparse.Namespace(**vars(args))
            azure_args.source = str(azure_source)
            azure_args.destination_root = str(scheduler_state_root() / "azure-account-homes")
            azure_args.backup_root = str(scheduler_state_root() / "azure-pool-backups")
            code = _run_once(azure_args)
    except RefreshError as exc:
        record_heartbeat(
            kind="attention" if exc.attention else "failed", detail=str(exc), now=now
        )
        raise
    record_heartbeat(
        kind="ok" if code == 0 else "failed",
        detail="renewed" if code == 0 else f"run-once exited {code}",
        now=now,
    )
    return code


def scheduled_azure_source(args: argparse.Namespace) -> Path | None:
    config_value = getattr(args, "azure_home_config", None)
    if not getattr(args, "scheduled", False) or not config_value:
        return None
    config = Path(config_value)
    try:
        metadata = config.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail(f"Azure Pi pool config is unreadable at {config}: {exc.strerror}")
    if not stat.S_ISREG(metadata.st_mode) or config.is_symlink():
        fail(f"Azure Pi pool config must be a regular non-symlink file at {config}")
    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail(f"Azure Pi pool config cannot be read at {config}: {exc.strerror}")
    if len(lines) != 1 or not lines[0]:
        fail(f"Azure Pi pool config must contain exactly one path at {config}")
    home = Path(lines[0])
    if not home.is_absolute() or home != home.resolve():
        fail(f"Azure Pi pool config must name a canonical absolute directory at {config}")
    source = home / "auth.json"
    if source.expanduser().resolve() == Path(args.source).expanduser().resolve():
        return None
    return source


def _run_once(args: argparse.Namespace) -> int:
    if args.all and args.slot:
        fail("--all and --slot name different selections; pass one")
    if not args.all and not args.slot:
        fail("name at least one --slot, or pass --all")
    source = Path(args.source).expanduser()
    destination_root = Path(args.destination_root).expanduser().resolve()
    backup_root = Path(args.backup_root).expanduser()
    home_tool = account_home_tool()
    pool = home_tool.read_pool(source)
    expected = set(pool)
    now = time.time()
    due, held = select_due(
        pool,
        horizon_seconds=args.horizon_seconds,
        now=now,
        requested=None if args.all else list(args.slot),
    )
    unrenewable = [record for record in held if record["reason"].startswith("unrenewable")]

    summary: dict[str, Any] = {
        "due": [record["slot"] for record in due],
        "held": [record["slot"] for record in held],
        "unrenewable": [record["slot"] for record in unrenewable],
        "renewed": [],
        "republished": [],
        "unprojected": [],
        "verified": [],
        "backup": "",
        "pruned": [],
    }

    if not due:
        if args.json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(f"nothing due within {args.horizon_seconds}s; {len(held)} profiles held")
            for record in unrenewable:
                print(f"  {record['slot']}: {record['reason']}", file=sys.stderr)
        # An unrenewable profile is a real problem, but it is a problem a
        # renewal run cannot fix: it needs a browser. Non-zero so a scheduled
        # run does not report success over a dying account, and marked as
        # needing attention rather than as a broken schedule, because the
        # schedule did exactly what it is for.
        if unrenewable:
            fail(
                "these profiles cannot be renewed and need an interactive login: "
                + ", ".join(record["slot"] for record in unrenewable),
                attention=True,
            )
        return 0

    backup = backup_pool(source, backup_root, now=now, expected=expected)
    summary["backup"] = str(backup)
    slots = [record["slot"] for record in due]
    records = run_adapter(source=source, slots=slots, timeout_ms=args.timeout_ms)

    damage = pool_is_intact(source, expected)
    if damage:
        fail(
            f"{damage}; the pre-renewal copy is at {backup} and can be restored "
            "over it once the cause is understood"
        )
    # Pruned here, not at the end. Every step below can refuse, and a recurring
    # refusal used to leave one more full copy of every credential in the fleet
    # at rest per scheduled run. Once the pool is proved intact the older copies
    # protect nothing, which is what BACKUP_KEEP's own comment says.
    summary["pruned"] = [str(path) for path in prune_backups(backup_root, BACKUP_KEEP)]

    renewed = [record["slot"] for record in records if record.get("outcome") == "refreshed"]
    problems = [record for record in records if record.get("outcome") != "refreshed"]
    summary["renewed"] = renewed
    unstable = [
        record["slot"]
        for record in records
        if record.get("outcome") == "refreshed" and record.get("account_stable") is False
    ]

    if renewed:
        republished, unprojected = reproject(
            source=source, destination_root=destination_root, slots=renewed
        )
        summary["republished"] = republished
        summary["unprojected"] = unprojected
        summary["verified"] = verify_homes(destination_root, republished)

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        rows = [
            (
                record["slot"],
                str(record.get("outcome", "?")),
                str(record.get("account", "-")),
                str(record.get("expires_after") or record.get("detail", "")),
            )
            for record in sorted(records, key=lambda item: item["slot"])
        ]
        print(render(rows, ("PROFILE", "OUTCOME", "ACCOUNT", "EXPIRES / DETAIL")))
        print(
            f"renewed={len(renewed)} republished={len(summary['republished'])} "
            f"held={len(held)} backup={backup}"
        )
        for slot in summary["unprojected"]:
            print(
                f"  {slot}: renewed in the pool but has no account home under "
                f"{destination_root}",
                file=sys.stderr,
            )

    if unstable:
        fail(
            "renewal changed the executing account for: "
            + ", ".join(sorted(unstable))
            + "; the reviewer roster identifies accounts by that value"
        )
    if problems:
        for record in problems:
            print(
                f"REFUSED {record['slot']}: {record.get('detail', record.get('outcome'))}",
                file=sys.stderr,
            )
        stranded = [
            record["slot"]
            for record in problems
            if record.get("outcome") == "rotated-unpersisted"
        ]
        if stranded:
            # Named apart from an ordinary failure because the recovery differs:
            # the provider has already retired what the host holds, so there is
            # nothing to retry and no copy that helps.
            fail(
                "the provider rotated these profiles and the rotation could not be "
                "stored, so each now needs an interactive login: "
                + ", ".join(sorted(stranded))
            )
        fail(f"{len(problems)} of {len(records)} due profiles were not renewed")
    if unrenewable:
        fail(
            "these profiles cannot be renewed and need an interactive login: "
            + ", ".join(record["slot"] for record in unrenewable),
            attention=True,
        )
    return 0


# ---------------------------------------------------------------------------
# The schedule
#
# Every fact about the schedule is read from ONE machine-global place: the
# plist at a fixed label. This machine carries nine Firstmate homes, each with
# its own checkout, and the credential pool they share is machine-global too.
# An earlier shape compared the installed job against the reporting checkout's
# own path, so exactly one home could ever report healthy, the other eight
# printed a warning at every session start forever, and the remedy that warning
# printed tore down the working job and pointed it at whichever home ran it.
#
# A heartbeat counts only when it carries the activation nonce baked into the
# installed plist. That is what makes "a manual run cannot fake scheduler
# liveness" a property rather than a convention: a hand-run `--scheduled`
# has no nonce, so it writes nothing at all. `bin/fm-report-retention.sh`
# holds itself to the same rule the same way.
# ---------------------------------------------------------------------------


def scheduler_platform() -> str:
    return os.environ.get("FM_PI_REFRESH_PLATFORM") or platform.system()


def default_state_root() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or "~/.local/state"
    return Path(base).expanduser() / "firstmate" / "pi-auth-refresh"


def scheduler_state_root() -> Path:
    override = os.environ.get("FM_PI_REFRESH_STATE_ROOT")
    return Path(override).expanduser() if override else default_state_root()


def launch_agents_dir() -> Path:
    return Path(
        os.environ.get("FM_PI_REFRESH_LAUNCH_AGENTS_DIR") or LAUNCH_AGENTS_DIR
    ).expanduser()


def plist_path() -> Path:
    return launch_agents_dir() / f"{SCHEDULER_LABEL}.plist"


def heartbeat_path(state_root: Path | None = None) -> Path:
    return (state_root or scheduler_state_root()) / "heartbeat.json"


def scheduler_interval() -> int:
    raw = os.environ.get("FM_PI_REFRESH_INTERVAL") or str(DEFAULT_INTERVAL_SECONDS)
    try:
        value = int(raw)
    except ValueError:
        fail(f"FM_PI_REFRESH_INTERVAL is not a whole number of seconds: {raw!r}")
    require_interval(value, "FM_PI_REFRESH_INTERVAL")
    return value


def require_interval(value: int, label: str) -> None:
    if not MIN_INTERVAL_SECONDS <= value <= MAX_INTERVAL_SECONDS:
        fail(
            f"{label} must be between {MIN_INTERVAL_SECONDS} and "
            f"{MAX_INTERVAL_SECONDS} seconds (got {value})"
        )


def write_private_json(path: Path, value: dict[str, Any]) -> None:
    private_directory(path.parent)
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    except OSError as exc:
        fail(f"state file is unreadable at {path}: {exc.strerror}")
    if existing is not None and (
        not stat.S_ISREG(existing.st_mode) or path.is_symlink()
    ):
        fail(f"refusing to write state through a non-regular path at {path}")
    temp = path.with_name(f".{path.name}.tmp")
    handle = os.open(
        str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def record_heartbeat(*, kind: str, detail: str, now: float) -> None:
    """Stamp proof of life, but only for the invocation launchd started.

    The nonce is the whole mechanism. It exists only in the installed plist's
    environment, so it reaches this process only when launchd started it. A
    hand-run `--scheduled` therefore writes nothing rather than overwriting a
    real heartbeat, which would be a denial rather than a forgery but is just
    as bad: the point is that the report reflects the schedule.
    """

    presented = os.environ.get("FM_PI_REFRESH_ACTIVATION_NONCE") or ""
    installed = installed_job().get("nonce") or ""
    if not presented or presented != installed:
        return
    write_private_json(
        heartbeat_path(),
        {
            "at": utc(now),
            "kind": kind,
            "ok": kind == "ok",
            "nonce": presented,
            "detail": redact(detail),
        },
    )


def resolve_runtime(override: str | None, default_name: str) -> str:
    """Resolve one absolute runtime path for the plist.

    A LaunchAgent inherits almost no PATH, so every runtime it needs is baked
    in as an absolute path rather than looked up at fire time.
    """

    candidate = override or default_name
    located = shutil.which(candidate)
    if not located:
        fail(f"cannot resolve {candidate!r} to an absolute path for the schedule")
    return str(Path(located).resolve())


def launchctl_binary() -> str:
    return os.environ.get("FM_PI_REFRESH_LAUNCHCTL") or "launchctl"


def run_launchctl(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [launchctl_binary(), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=LAUNCHCTL_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        # This runs at every session start. A traceback header is not an
        # operator sentence, and TimeoutExpired is a SubprocessError, which
        # main's refusal contract does not catch.
        fail(
            f"launchctl did not answer {' '.join(arguments[:2])} within "
            f"{LAUNCHCTL_TIMEOUT_SECONDS}s"
        )
    except OSError as exc:
        fail(f"launchctl could not be run: {exc.strerror or exc}")
    raise AssertionError("unreachable")


def launchd_holds_label() -> bool:
    if not shutil.which(launchctl_binary()):
        return False
    return run_launchctl(["print", f"gui/{os.getuid()}/{SCHEDULER_LABEL}"]).returncode == 0


def read_plist(path: Path) -> dict[str, Any] | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    except OSError:
        return None
    if not stat.S_ISREG(metadata.st_mode):
        return None
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def installed_job() -> dict[str, Any]:
    """Read the one installed schedule, from wherever it was installed.

    Everything downstream keys off this rather than off the reporting
    checkout, so every Firstmate home on the machine reports the same answer
    about the same job.
    """

    job = read_plist(plist_path())
    if job is None:
        return {}
    environment = job.get("EnvironmentVariables")
    environment = environment if isinstance(environment, dict) else {}
    arguments = job.get("ProgramArguments")
    arguments = arguments if isinstance(arguments, list) else []
    root = environment.get("FM_PI_REFRESH_STATE_ROOT")
    return {
        "arguments": [str(value) for value in arguments],
        "interval": job.get("StartInterval") if isinstance(job.get("StartInterval"), int) else None,
        "nonce": environment.get("FM_PI_REFRESH_ACTIVATION_NONCE"),
        "state_root": Path(root).expanduser() if isinstance(root, str) and root else None,
    }


def job_runs_this_tool(arguments: list[str]) -> str:
    """Name what is wrong with an installed job's command, or an empty string.

    Deliberately NOT a comparison against this checkout's own path: the job is
    machine-global and the reporting checkout is not. What matters is that the
    installed command is a renewal that stamps its own proof, whichever
    checkout installed it.
    """

    named = [value for value in arguments if Path(value).name == REFRESH_ENTRYPOINT_NAME]
    if not named:
        return (
            f"the installed schedule runs no {REFRESH_ENTRYPOINT_NAME}; it belongs "
            "to something else that claimed this label"
        )
    if not Path(named[0]).is_file():
        return f"the installed schedule runs {named[0]}, which is no longer there"
    index = arguments.index(named[0])
    verbs = arguments[index + 1 :]
    if "run-once" not in verbs:
        return "the installed schedule does not run a renewal"
    if "--scheduled" not in verbs:
        # Without it the job renews but never stamps, so it would sit at
        # unproven forever while working perfectly.
        return "the installed schedule never records proof of life"
    return ""


def scheduler_job(interval: int, state_root: Path, nonce: str) -> dict[str, Any]:
    entrypoint = pi_executable()
    node = node_binary(entrypoint)
    python = resolve_runtime(os.environ.get("FM_PI_REFRESH_PYTHON"), "python3")
    search = os.pathsep.join(
        [
            str(Path(node).parent),
            str(Path(python).parent),
            str(entrypoint.parent),
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    )
    return {
        "Label": SCHEDULER_LABEL,
        "ProgramArguments": [
            python,
            str(Path(__file__).resolve()),
            "run-once",
            "--all",
            "--scheduled",
            "--azure-home-config",
            str(
                Path(os.environ.get("FM_HOME") or BIN_DIR.parent).resolve()
                / "config"
                / "azure-worker-account-home"
            ),
        ],
        "EnvironmentVariables": {
            "PATH": search,
            # Pinned rather than inherited: the credential pool, the account
            # homes and the copy directory all resolve from it, and the state
            # root beside them is pinned already.
            "HOME": str(Path.home()),
            "FM_PI_BIN": str(entrypoint),
            "FM_PI_NODE_BIN": node,
            "FM_PI_REFRESH_STATE_ROOT": str(state_root),
            "FM_PI_REFRESH_INTERVAL": str(interval),
            "FM_PI_REFRESH_ACTIVATION_NONCE": nonce,
            # The job reads its own plist to check its nonce, so it has to be
            # told where that plist is. Without this the check only works when
            # the plist sits at the default path, which is true in production
            # and silently false anywhere it is installed elsewhere.
            "FM_PI_REFRESH_LAUNCH_AGENTS_DIR": str(launch_agents_dir()),
        },
        "RunAtLoad": True,
        "StartInterval": interval,
        "StandardOutPath": str(state_root / "run.out"),
        "StandardErrorPath": str(state_root / "run.err"),
    }


def write_plist(destination: Path, job: dict[str, Any]) -> None:
    try:
        existing = destination.lstat()
    except FileNotFoundError:
        existing = None
    except OSError as exc:
        fail(f"the schedule plist is unreadable at {destination}: {exc.strerror}")
    if existing is not None and (
        not stat.S_ISREG(existing.st_mode) or destination.is_symlink()
    ):
        fail(f"refusing to replace a non-regular schedule plist at {destination}")
    temp = destination.with_name(f".{destination.name}.tmp")
    handle = os.open(
        str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        with os.fdopen(handle, "wb") as stream:
            plistlib.dump(job, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, destination)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def command_install_scheduler(args: argparse.Namespace) -> int:
    if scheduler_platform() != "Darwin":
        fail(
            "the Pi renewal schedule is a macOS LaunchAgent; this host is "
            f"{scheduler_platform()} and has no scheduler adapter yet"
        )
    if not shutil.which(launchctl_binary()):
        fail("launchctl is unavailable, so no schedule can be installed")
    interval = args.interval_seconds or scheduler_interval()
    require_interval(interval, "--interval-seconds")
    state_root = scheduler_state_root()
    private_directory(state_root)
    nonce = secrets.token_hex(16)
    job = scheduler_job(interval, state_root, nonce)

    agents = launch_agents_dir()
    if not agents.exists():
        private_directory(agents)
    destination = plist_path()
    previous = destination.read_bytes() if destination.is_file() else None

    domain = f"gui/{os.getuid()}"
    write_plist(destination, job)
    run_launchctl(["bootout", f"{domain}/{SCHEDULER_LABEL}"])
    loaded = run_launchctl(["bootstrap", domain, str(destination)])
    if loaded.returncode != 0:
        # The plist was already published, so a refused bootstrap would
        # otherwise leave the new definition on disk with the old job running
        # and every report reading the file rather than launchd.
        detail = redact(loaded.stderr.decode("utf-8", errors="replace").strip())
        if previous is None:
            try:
                destination.unlink()
            except OSError:
                pass
        else:
            destination.write_bytes(previous)
            os.chmod(destination, 0o600)
            run_launchctl(["bootstrap", domain, str(destination)])
        fail(f"launchctl refused the Pi renewal schedule: {detail}")

    # Bind the LOADED job, not the file just written. A file check cannot tell
    # a bootstrapped definition from one launchd never accepted.
    if not launchd_holds_label():
        fail("launchctl accepted the Pi renewal schedule but launchd is not holding it")
    # `RunAtLoad` fires the first run asynchronously, so the job is loaded
    # before it has reported anything. `unproven` is the correct state at this
    # instant; only a job launchd is not holding is an installation failure.
    report = scheduler_report()
    if report["state"] not in {"installed", "unproven"}:
        fail("the Pi renewal schedule did not come up: " + report["detail"])
    print(
        f"installed {SCHEDULER_LABEL} every {interval}s at {destination}\n"
        f"  proof of life lands in {heartbeat_path(state_root)} on its first fire"
    )
    return 0


def command_uninstall_scheduler(_: argparse.Namespace) -> int:
    domain = f"gui/{os.getuid()}"
    destination = plist_path()
    if shutil.which(launchctl_binary()):
        run_launchctl(["bootout", f"{domain}/{SCHEDULER_LABEL}"])
        # The return code alone is not proof: a bootout can report failure for
        # a job already gone, and success for one that stays. Re-probe, and
        # never unlink the plist while launchd still holds the label, or the
        # job keeps rotating credentials with nothing left to describe it.
        if launchd_holds_label():
            fail(
                f"launchd still holds {SCHEDULER_LABEL} after bootout; the plist is "
                f"left at {destination} so the running job stays describable"
            )
    try:
        destination.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        fail(f"the schedule plist cannot be removed at {destination}: {exc.strerror}")
    print(f"removed {SCHEDULER_LABEL}")
    return 0


def scheduler_report(now: float | None = None) -> dict[str, Any]:
    """Describe the one machine-global schedule.

    launchd is asked FIRST, so a job that is loaded with no plist behind it is
    expressible instead of reading as absent.
    """

    moment = time.time() if now is None else now
    destination = plist_path()
    held = launchd_holds_label()
    record: dict[str, Any] = {
        "label": SCHEDULER_LABEL,
        "plist": str(destination),
        "plist_present": False,
        "loaded": held,
        "interval_seconds": None,
        "state_root": None,
        "heartbeat_at": None,
        "heartbeat_age_seconds": None,
        "heartbeat_kind": None,
        "state": "absent",
        "detail": "",
    }
    job = installed_job()
    if not job:
        if held:
            record["state"] = "orphaned"
            record["detail"] = (
                f"launchd holds {SCHEDULER_LABEL} but nothing describes it at "
                f"{destination}; bootout it or reinstall"
            )
        else:
            record["detail"] = f"no schedule is installed at {destination}"
        return record

    record["plist_present"] = True
    record["interval_seconds"] = job["interval"]
    record["state_root"] = str(job["state_root"]) if job["state_root"] else None
    problem = job_runs_this_tool(job["arguments"])
    if problem:
        record["state"] = "foreign"
        record["detail"] = problem
        return record
    if not held:
        record["state"] = "unloaded"
        record["detail"] = "the schedule is installed but launchd is not holding it"
        return record

    interval = job["interval"] or DEFAULT_INTERVAL_SECONDS
    limit = interval * HEARTBEAT_STALE_INTERVALS
    if job["state_root"] is None:
        record["state"] = "foreign"
        record["detail"] = "the installed schedule names no state root, so it cannot report"
        return record
    beat = heartbeat_path(job["state_root"])
    value = None
    try:
        if beat.is_file() and not beat.is_symlink():
            value = json.loads(beat.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        value = None
    if not isinstance(value, dict) or value.get("nonce") != job["nonce"]:
        # An unproven job that has been loaded far longer than its own interval
        # has not "not fired yet", it has stopped.
        try:
            age = moment - destination.lstat().st_mtime
        except OSError:
            age = 0.0
        if age > limit:
            record["state"] = "stale"
            record["detail"] = (
                f"the schedule was installed {int(age)}s ago and has never reported a "
                f"run of its own, past {limit}s of its own interval"
            )
            return record
        record["state"] = "unproven"
        record["detail"] = (
            "the schedule is loaded and has not reported a run of its own yet; it "
            "proves itself on its first fire"
        )
        return record

    try:
        stamp = datetime.datetime.strptime(value["at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (KeyError, TypeError, ValueError):
        record["state"] = "unproven"
        record["detail"] = f"the heartbeat at {beat} carries no readable instant"
        return record
    age = moment - stamp.timestamp()
    record["heartbeat_at"] = value["at"]
    record["heartbeat_age_seconds"] = int(age)
    record["heartbeat_kind"] = value.get("kind")
    if age > limit:
        record["state"] = "stale"
        record["detail"] = (
            f"the schedule last ran {int(age)}s ago, past {limit}s of its own interval"
        )
        return record
    if value.get("kind") == "attention":
        # The schedule is working. Something it renews cannot be renewed
        # without a human, and calling that an unavailable schedule is the
        # alarm that gets ignored.
        record["state"] = "attention"
        record["detail"] = "the schedule is running; " + str(value.get("detail", ""))[:200]
        return record
    if value.get("kind") != "ok":
        record["state"] = "failing"
        record["detail"] = "the last scheduled renewal failed: " + str(
            value.get("detail", "")
        )[:200]
        return record
    record["state"] = "installed"
    record["detail"] = f"last renewed {int(age)}s ago"
    return record


HEALTHY_SCHEDULER_STATES = ("installed", "attention")


def command_scheduler_status(args: argparse.Namespace) -> int:
    record = scheduler_report()
    if args.json:
        print(json.dumps(record, indent=2, sort_keys=True))
    else:
        print(f"{record['state']}: {record['detail']}")
        print(f"  plist     {record['plist']}")
        print(f"  interval  {record['interval_seconds']}")
        print(f"  heartbeat {record['heartbeat_at'] or '-'}")
    return 0 if record["state"] in HEALTHY_SCHEDULER_STATES else 1


def command_ensure(_: argparse.Namespace) -> int:
    """Report an unhealthy schedule in one line, and never install one.

    Installing a background owner that writes credentials is a deliberate act,
    so this reports and waits rather than repairing itself.
    """

    record = scheduler_report()
    if record["state"] in HEALTHY_SCHEDULER_STATES:
        return 0
    print(
        f"PI_AUTH_REFRESH: unavailable: {record['detail']} "
        f"(install: bin/fm-pi-refresh.py install-scheduler)",
        file=sys.stderr,
    )
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-pi-refresh.py", description=__doc__.splitlines()[0]
    )
    commands = parser.add_subparsers(dest="command", required=True)

    report = commands.add_parser(
        "report", help="name the profiles due for renewal without renewing one"
    )
    report.add_argument("--source", default=DEFAULT_SOURCE)
    report.add_argument(
        "--horizon-seconds", type=float, default=DEFAULT_HORIZON_SECONDS
    )
    report.add_argument("--json", action="store_true")
    report.set_defaults(handler=command_report)

    run = commands.add_parser(
        "run-once", help="renew due profiles, republish them, and verify the result"
    )
    run.add_argument("--source", default=DEFAULT_SOURCE)
    run.add_argument("--destination-root", default=DEFAULT_DESTINATION_ROOT)
    run.add_argument("--backup-root", default=DEFAULT_BACKUP_ROOT)
    run.add_argument(
        "--horizon-seconds", type=float, default=DEFAULT_HORIZON_SECONDS
    )
    run.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    run.add_argument("--slot", action="append", default=[])
    run.add_argument("--all", action="store_true")
    run.add_argument("--json", action="store_true")
    run.add_argument(
        "--scheduled",
        action="store_true",
        help="record the heartbeat, which only launchd's own invocation can do",
    )
    run.add_argument("--azure-home-config", help=argparse.SUPPRESS)
    run.set_defaults(handler=command_run_once)

    install = commands.add_parser(
        "install-scheduler", help="install the machine-global renewal LaunchAgent"
    )
    install.add_argument("--interval-seconds", type=int, default=0)
    install.set_defaults(handler=command_install_scheduler)

    uninstall = commands.add_parser(
        "uninstall-scheduler", help="remove the renewal LaunchAgent"
    )
    uninstall.set_defaults(handler=command_uninstall_scheduler)

    status = commands.add_parser(
        "scheduler-status",
        help="report whether the schedule is installed and proving itself",
    )
    status.add_argument("--json", action="store_true")
    status.set_defaults(handler=command_scheduler_status)

    ensure = commands.add_parser(
        "ensure",
        help="print one line when the schedule is unhealthy, and nothing when it is not",
    )
    ensure.set_defaults(handler=command_ensure)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except RefreshError as exc:
        print(f"PI REFRESH REFUSED: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # A traceback is not a refusal contract. Report the path and the errno
        # text, never the value being written.
        location = getattr(exc, "filename", None) or "a credential path"
        print(
            f"PI REFRESH REFUSED: {location}: {exc.strerror or exc}", file=sys.stderr
        )
        return 1
    except Exception as exc:  # noqa: BLE001 - the account-home owner raises its own
        if type(exc).__name__ == "ProjectionError":
            print(f"PI REFRESH REFUSED: {exc}", file=sys.stderr)
            return 1
        raise


if __name__ == "__main__":
    raise SystemExit(main())
