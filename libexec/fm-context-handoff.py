#!/usr/bin/env python3
"""Curated Firstmate-to-Claude/Obsidian handoff boundary.

This file is the internal mechanics owner of candidate registration, canonical envelope
sealing, local queue/receipt mechanics, exact-recipient delivery, Claude hook
handling, the local MCP consumer, transaction approval binding, verification,
and source acknowledgement.

All persistent records live below FM_HOME/state/context-handoff, outside the
selected Vault.  config/context-handoff.json is local and default-off.  Run
``fm-context-handoff.py --help`` and each subcommand's help for exact mechanics.
No command reads a transcript, compaction summary, model reasoning, terminal
capture, ordinary Vault note during sealing, credential store, or auth state.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterator, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "claude-obsidian.handoff.v1.schema.json"
CONFIG_SCHEMA = "firstmate.context-handoff.config.v1"
CANDIDATE_SCHEMA = "firstmate.context-handoff.candidate.v1"
QUEUE_SCHEMA = "firstmate.context-handoff.queue.v1"
RECEIPT_SCHEMA = "firstmate.context-handoff.receipt.v1"
ACK_SCHEMA = "firstmate.context-handoff.ack.v1"
APPROVAL_SCHEMA = "firstmate.context-handoff.approval.v1"
BINDING_SCHEMA = "firstmate.context-handoff.consumer-binding.v1"
STATE_INITIALIZED_BYTES = b"firstmate.context-handoff.state.v1\n"
COMPACTION_BINDING_SCHEMA = "firstmate.context-handoff.compaction-binding.v1"
COMPACTION_RETIREMENT_SCHEMA = "firstmate.context-handoff.compaction-retirement.v1"
COMPACTION_ATTEMPT_SCHEMA = "firstmate.context-handoff.compaction-attempt.v1"
PI_COMPACTION_BINDING_SCHEMA = "firstmate.context-handoff.pi-compaction-binding.v1"
EXECUTION_CLAIM_SCHEMA = "firstmate.context-handoff.execution-claim.v1"
HANDOFF_SCHEMA = "claude-obsidian.handoff.v1"
TRANSACTION_SCHEMA = "claude-obsidian.transaction.v1"
TRANSACTION_PLAN_SCHEMA = "claude-obsidian.transaction-plan.v1"
TRANSACTION_RESULT_SCHEMA = "claude-obsidian.transaction-result.v1"
TRANSACTION_JOURNAL_SCHEMA = "claude-obsidian.transaction-journal.v1"
MAX_ENVELOPE_BYTES = 32 * 1024
MAX_ITEMS = 32
MAX_STATEMENT_BYTES = 2048
MAX_CONFIG_BYTES = 128 * 1024
MAX_HOOK_BYTES = 1024 * 1024
MAX_CORE_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_TRANSACTION_BUNDLE_BYTES = 128 * 1024
MAX_TRANSACTION_DEPENDENCY_BYTES = 8 * 1024 * 1024
MAX_HERDR_EXECUTABLE_BYTES = 32 * 1024 * 1024
MAX_ORPHAN_TRANSACTION_RUNTIMES = 8
MAX_ORPHAN_HERDR_RUNTIMES = 8
MAX_TRANSACTION_WRITES = 16
MAX_COMPACTION_RECORDS = 32
HERDR_PROBE_TIMEOUT_SECONDS = 3.0
HERDR_CAPABILITY_TIMEOUT_SECONDS = 1.0
HERDR_PROMPT_TIMEOUT_SECONDS = 3.0
DELIVERY_ACK_MARGIN_SECONDS = 1.5
PROMPT_TEXT = "/firstmate-context-handoff:consume"
TRANSACTION_RUNNER_BYTES = b"""from __future__ import annotations
import importlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(root))
package = importlib.import_module("claude_obsidian")
if Path(package.__file__).resolve().parent != root / "claude_obsidian":
    raise SystemExit(78)
main = importlib.import_module("claude_obsidian.cli").main
raise SystemExit(main())
"""
HEX64 = re.compile(r"^[0-9a-f]{64}$")
LINUX_BOOT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
RECORD_ID = re.compile(r"^handoff-[0-9a-f]{48}$")
CANDIDATE_ID = re.compile(r"^candidate-[0-9a-f]{48}$")
PROVIDER_CLASS = re.compile(r"^[a-z][a-z0-9-]{1,63}$")
KINDS = {"decision", "preference", "gotcha", "project-fact", "next-step", "pointer"}
CONFIDENCES = {"verified", "inferred"}
SPHERES = {"privat", "geschaeftlich", "geteilt"}
SENSITIVITY_CLASSES = {"ordinary-project-context", "financial-data", "customer-record", "personal-address"}
ELIGIBLE_SENSITIVITY_CLASS = "ordinary-project-context"
TRIGGERS = {"manual", "threshold", "overflow"}
SOURCE_HARNESSES = {"pi", "claude"}
DISPOSITIONS = {"duplicate", "not-durable", "not-allowed", "needs-captain"}
SYNTHETIC_TRANSACTION_FIXTURE = ROOT / "tests" / "fixtures" / "context-handoff-transaction-core.sh"
FORBIDDEN_SOURCE_PARTS = {
    ".raw",
    "attachments",
    "auth",
    "credentials",
    "history",
    "ledger",
    "ledgers",
    "sessions",
    "transcripts",
    ".vault-meta",
}
RAW_CONTENT_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"(^|\s)(user|assistant|tool result|system)\s*:",
        r"\b(raw )?(chat|conversation|session) transcript\b",
        r"\bcompaction summary\b",
        r"\b(model reasoning|chain[- ]of[- ]thought|thinking block)\b",
        r"\b(tool stream|terminal (output|scrollback)|shell output)\b",
        r"<conversation>|<transcript>|\[assistant thinking\]",
    )
]
SENSITIVE_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|secret|cookie|session[_ -]?token|pin|tan)\b",
        r"\b(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b",
        r"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b",
        r"\b(?:\d[ -]*?){13,19}\b",
        r"\b(bank account|payment card|wire transfer|financial transaction)\b",
        r"\btransaction(?:[_ -]?(?:id|number|details?|amount|reference))\b",
        r"\b(customer (?:id|record|account|profile)|order record|shipping address|billing address)\b",
        r"\border(?:[_ -]?(?:id|number|no\.?))?\s*[:#]?\s*[A-Z0-9-]{4,}\b",
        r"\b(postal address|zip code|postcode)\b",
        r"\b(email body|message body|chat body|inbox message)\b",
        r"\b(local-only|strictly private|do not share)\b",
        r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        r"\b\d{3}-\d{2}-\d{4}\b",
        r"\b(?:taxpayer|tax)(?:[_ -]?(?:id|identifier|identification|number))\b",
        r"\baccount balance\b",
        r"\b(?:account holder|employee|patient)\s+(?:id|record|number|profile)\b",
        r"\bfinancial (?:data|details?|records?)\b",
        r"\b(?:assets?|liabilit(?:y|ies)|salary|wages?|payroll|compensation|income|revenue|profit|invoice)\b.{0,48}\b(?:\d[\d,.]*\s*(?:euros?|dollars?|pounds?)|(?:USD|EUR|GBP|CAD|AUD|JPY|CHF)\s*[\d,.]+)\b",
        r"\b(?:home|residential|mailing|delivery)\s+address\b",
        r"\b\d{1,6}\s+[A-Z0-9][A-Z0-9 .'-]{1,80}\s(?:st(?:reet)?|rd|road|ave(?:nue)?|blvd|lane|ln|drive|dr|court|ct)\b",
        r"\b(?:lives?|resides?)\s+at\s+\d{1,6}\s+[A-Z][A-Z0-9 .'-]{1,80}\b",
    )
]
MUTATING_TOOL_NAMES = re.compile(
    r"(write|edit|delete|remove|move|rename|git|github|install|credential|secret|notebookedit)",
    re.IGNORECASE,
)
HANDOFF_MCP_TOOLS = {
    f"mcp__firstmate-context-handoff__{name}"
    for name in (
        "register_curated_candidate",
        "next_curated_handoff",
        "record_curation_disposition",
        "prepare_handoff_save",
        "commit_handoff_save",
    )
}


class HandoffError(RuntimeError):
    """A bounded error safe to classify without printing record content."""

    def __init__(self, code: str, message: str, *, exit_code: int = 2) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code


class StateLayout:
    def __init__(self, home: Path) -> None:
        self.home = home
        self.root = home / "state" / "context-handoff"
        self.candidates = self.root / "candidates"
        self.records = self.root / "records"
        self.claims = self.root / "claims"
        self.queue = self.root / "queue"
        self.receipts = self.root / "receipts"
        self.quarantine = self.root / "quarantine"
        self.acks = self.root / "acks"
        self.approvals = self.root / "approvals"
        self.bundles = self.root / "bundles"
        self.bindings = self.root / "bindings"
        self.initialized = self.root / ".initialized"
        self.lock = self.root / ".lock"

    def initialize(self) -> None:
        fd: int | None = None
        locked = False
        try:
            fd = os.open(self.home, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0))
            checkpoint("before-initialization-lock")
            fcntl.flock(fd, fcntl.LOCK_EX)
            locked = True
            for directory in (
                self.root,
                self.candidates,
                self.records,
                self.claims,
                self.queue,
                self.receipts,
                self.quarantine,
                self.acks,
                self.approvals,
                self.bundles,
                self.bindings,
            ):
                ensure_private_directory(directory)
            if self.initialized.exists():
                validate_private_file(self.initialized)
                if self.initialized.read_bytes() != STATE_INITIALIZED_BYTES:
                    raise HandoffError("STATE_DURABILITY", "the handoff state initialization boundary is invalid")
            else:
                for directory in (
                    self.root,
                    self.candidates,
                    self.records,
                    self.claims,
                    self.queue,
                    self.receipts,
                    self.quarantine,
                    self.acks,
                    self.approvals,
                    self.bundles,
                    self.bindings,
                ):
                    failpoint("before-initialization-boundary-fsync")
                    fsync_directory(directory)
                    fsync_directory(directory.parent)
                atomic_create(self.initialized, STATE_INITIALIZED_BYTES)
        except OSError as exc:
            raise HandoffError("STATE_DURABILITY", "the handoff state directory chain could not be initialized durably") from exc
        finally:
            if fd is not None:
                if locked:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)


_schema_cache: dict[str, Any] | None = None


def authoritative_schema() -> dict[str, Any]:
    global _schema_cache
    if _schema_cache is None:
        value = read_json_file(SCHEMA_PATH, max_bytes=64 * 1024, require_private=False)
        if not isinstance(value, dict):
            raise HandoffError("SCHEMA_INVALID", "the tracked handoff schema is invalid")
        _schema_cache = value
    return _schema_cache


def now_utc() -> str:
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_NOW"):
        return os.environ["FM_HANDOFF_TEST_NOW"]
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path, *, max_bytes: int | None = None) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise HandoffError("SOURCE_UNREADABLE", "an approved source file is unavailable") from exc
    digest = hashlib.sha256()
    total = 0
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise HandoffError("SOURCE_NOT_REGULAR", "an approved source must be a regular file")
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if max_bytes is not None and total > max_bytes:
                raise HandoffError("SOURCE_TOO_LARGE", "a bounded source file exceeded its read limit")
            digest.update(chunk)
    finally:
        os.close(fd)
    return digest.hexdigest()


def path_has_symlink(path: Path) -> bool:
    absolute = path if path.is_absolute() else Path.cwd() / path
    parts = absolute.parts
    current = Path(parts[0]) if parts else Path("/")
    for part in parts[1:]:
        current = current / part
        try:
            if stat.S_ISLNK(current.lstat().st_mode):
                return True
        except FileNotFoundError:
            break
    return False


def ensure_private_directory(path: Path) -> None:
    if path_has_symlink(path):
        raise HandoffError("STATE_SYMLINK", "the handoff state root contains a symlink")
    absolute = path.absolute()
    missing: list[Path] = []
    current = absolute
    while not current.exists():
        missing.append(current)
        if current.parent == current:
            raise HandoffError("STATE_DIRECTORY", "the handoff state root has no existing parent")
        current = current.parent
    for directory in reversed(missing):
        created = False
        try:
            os.mkdir(directory, 0o700)
            created = True
            os.chmod(directory, 0o700)
            failpoint("before-created-directory-fsync")
            fsync_directory(directory)
            fsync_directory(directory.parent)
        except FileExistsError:
            if directory.is_symlink():
                raise HandoffError("STATE_SYMLINK", "the handoff state root contains a symlink")
        except OSError as exc:
            if created:
                try:
                    directory.rmdir()
                except OSError:
                    pass
            raise HandoffError("STATE_DURABILITY", "the handoff state directory could not be made durable") from exc
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode):
        raise HandoffError("STATE_NOT_DIRECTORY", "the handoff state root is not a directory")
    if info.st_uid != os.getuid():
        raise HandoffError("STATE_OWNER", "the handoff state root has another owner")
    original_mode = stat.S_IMODE(info.st_mode)
    if original_mode != 0o700:
        try:
            os.chmod(path, 0o700)
            failpoint("before-repaired-directory-fsync")
            fsync_directory(path)
        except OSError as exc:
            try:
                os.chmod(path, original_mode)
            except OSError:
                pass
            raise HandoffError("STATE_DURABILITY", "the handoff state directory repair could not be made durable") from exc


def validate_private_file(path: Path) -> None:
    if path.is_symlink():
        raise HandoffError("STATE_SYMLINK", "a handoff state record is a symlink")
    try:
        info = path.stat()
    except OSError as exc:
        raise HandoffError("RECORD_UNREADABLE", "a durable handoff record is unavailable") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise HandoffError("STATE_FILE_UNSAFE", "a handoff state record is not a private regular file")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise HandoffError("STATE_FILE_MODE", "a handoff state record does not have mode 0600")


def read_file_bytes(path: Path, *, max_bytes: int, require_private: bool = True) -> bytes:
    if require_private:
        validate_private_file(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise HandoffError("RECORD_UNREADABLE", "a durable handoff record is unavailable") from exc
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_size > max_bytes
            or (require_private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600))
        ):
            raise HandoffError("RECORD_BOUNDS", "a durable handoff record exceeds its supported bounds")
        data = b""
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > max_bytes:
            raise HandoffError("RECORD_BOUNDS", "a durable handoff record exceeds its supported bounds")
    finally:
        os.close(fd)
    return data


def read_json_file(path: Path, *, max_bytes: int, require_private: bool = True) -> Any:
    data = read_file_bytes(path, max_bytes=max_bytes, require_private=require_private)
    try:
        return json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("RECORD_JSON", "a durable handoff record is not canonical JSON") from exc


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def failpoint(name: str) -> None:
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_FAILPOINT") == name:
        os.environ.pop("FM_HANDOFF_TEST_FAILPOINT", None)
        raise OSError(errno.EIO, f"injected {name}")


def pausepoint(name: str) -> None:
    if os.environ.get("FM_HANDOFF_TESTING") != "1" or os.environ.get("FM_HANDOFF_TEST_PAUSEPOINT") != name:
        return
    marker = Path(os.environ["FM_HANDOFF_TEST_PAUSE_MARKER"])
    release = Path(os.environ["FM_HANDOFF_TEST_PAUSE_RELEASE"])
    marker.write_text("paused\n", encoding="utf-8")
    deadline = time.monotonic() + 5.0
    while not release.exists():
        if time.monotonic() >= deadline:
            raise HandoffError("TEST_PAUSE_TIMEOUT", "synthetic pausepoint timed out")
        time.sleep(0.01)


def checkpoint(name: str) -> None:
    if os.environ.get("FM_HANDOFF_TESTING") != "1" or os.environ.get("FM_HANDOFF_TEST_CHECKPOINT") != name:
        return
    Path(os.environ["FM_HANDOFF_TEST_CHECKPOINT_MARKER"]).write_text("reached\n", encoding="utf-8")


def rename_noreplace(source: Path, target: Path) -> None:
    if sys.platform.startswith("linux"):
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = getattr(libc, "renameat2", None)
        if renameat2 is not None:
            result = renameat2(
                ctypes.c_int(-100),
                ctypes.c_char_p(os.fsencode(source)),
                ctypes.c_int(-100),
                ctypes.c_char_p(os.fsencode(target)),
                ctypes.c_uint(1),
            )
            if result == 0:
                return
            error = ctypes.get_errno()
            if error != errno.ENOSYS:
                raise OSError(error, os.strerror(error), target)
    try:
        os.link(source, target, follow_symlinks=False)
        os.unlink(source)
    except FileExistsError:
        raise


def atomic_create(path: Path, data: bytes) -> str:
    ensure_private_directory(path.parent)
    digest = sha256_bytes(data)
    temporary = path.parent / f".{path.name}.tmp-{os.getpid()}-{os.urandom(8).hex()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fchmod(fd, 0o600)
        failpoint("before-file-fsync")
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        temporary.unlink(missing_ok=True)
        raise
    else:
        os.close(fd)
    try:
        failpoint("before-rename")
        rename_noreplace(temporary, path)
        failpoint("before-directory-fsync")
        fsync_directory(path.parent)
    except FileExistsError:
        temporary.unlink(missing_ok=True)
        validate_private_file(path)
        existing = path.read_bytes()
        if existing != data:
            raise HandoffError("CREATE_ONLY_MISMATCH", "a stable record ID already binds different bytes")
        fsync_directory(path.parent)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return digest


def atomic_replace(path: Path, data: bytes) -> str:
    ensure_private_directory(path.parent)
    temporary = path.parent / f".{path.name}.tmp-{os.getpid()}-{os.urandom(8).hex()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        temporary.unlink(missing_ok=True)
        raise
    else:
        os.close(fd)
    try:
        os.replace(temporary, path)
        fsync_directory(path.parent)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return sha256_bytes(data)


@contextmanager
def state_lock(layout: StateLayout) -> Iterator[None]:
    layout.initialize()
    fd = os.open(layout.lock, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    os.chmod(layout.lock, 0o600)
    try:
        checkpoint("before-state-lock")
        fcntl.flock(fd, fcntl.LOCK_EX)
        recover_transaction_runtime_snapshots(layout)
        recover_herdr_runtime_snapshots(layout)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def resolve_home(argument: str | None = None) -> Path:
    raw = argument or os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or str(ROOT)
    path = Path(raw).expanduser()
    try:
        return path.resolve(strict=True)
    except OSError as exc:
        raise HandoffError("HOME_INVALID", "the selected Firstmate home is unavailable") from exc


def load_config(home: Path, *, validate_active_bindings: bool = True) -> dict[str, Any] | None:
    override = os.environ.get("FM_HANDOFF_CONFIG")
    path = Path(override).expanduser() if override else home / "config" / "context-handoff.json"
    if not path.exists():
        return None
    if path.is_symlink() or path_has_symlink(path):
        raise HandoffError("CONFIG_SYMLINK", "the context handoff configuration may not use symlinks")
    value = read_json_file(path, max_bytes=MAX_CONFIG_BYTES, require_private=False)
    if not isinstance(value, dict) or value.get("schema") != CONFIG_SCHEMA:
        raise HandoffError("CONFIG_SCHEMA", f"configuration must declare schema={CONFIG_SCHEMA}")
    for name in ("registration_enabled", "sealing_enabled", "delivery_enabled", "consumer_enabled"):
        if not isinstance(value.get(name), bool):
            raise HandoffError("CONFIG_FIELD", f"configuration field {name} must be boolean")
    roots = value.get("approved_source_roots")
    classes = value.get("allowed_provider_classes")
    if not isinstance(roots, list) or not roots or not all(isinstance(item, str) and item for item in roots):
        raise HandoffError("CONFIG_SOURCE_ROOTS", "approved_source_roots must be a non-empty path list")
    if not isinstance(classes, list) or not classes or not all(isinstance(item, str) and PROVIDER_CLASS.fullmatch(item) for item in classes):
        raise HandoffError("CONFIG_PROVIDER_CLASSES", "allowed_provider_classes must be a non-empty class list")
    canonical_roots: list[str] = []
    for root in roots:
        source_root = Path(root).expanduser()
        if not source_root.is_absolute() or path_has_symlink(source_root):
            raise HandoffError("CONFIG_SOURCE_ROOT", "an approved source root may not use symlinks")
        canonical = source_root.resolve(strict=False)
        canonical_roots.append(str(canonical))
    value = dict(value)
    value["approved_source_roots"] = canonical_roots
    value["registration_allowlist"] = normalize_registration_allowlist(value)
    validate_runtime_config(value)
    if validate_active_bindings and any(value[name] for name in ("registration_enabled", "sealing_enabled", "delivery_enabled", "consumer_enabled")):
        vault = validate_vault_binding(value)
        state_root = (home / "state" / "context-handoff").resolve(strict=False)
        if state_root == vault or vault in state_root.parents or state_root in vault.parents:
            raise HandoffError("STATE_VAULT_OVERLAP", "handoff state root must remain outside the selected Vault")
    return value


def validate_runtime_config(config: Mapping[str, Any]) -> None:
    vault = config.get("vault")
    recipient = config.get("recipient")
    transaction = config.get("transaction")
    consumer = config.get("consumer")
    any_enabled = any(config[name] for name in ("registration_enabled", "sealing_enabled", "delivery_enabled", "consumer_enabled"))
    recipient_enabled = any(config[name] for name in ("sealing_enabled", "delivery_enabled", "consumer_enabled"))
    if not any_enabled:
        return
    if not isinstance(vault, dict):
        raise HandoffError("CONFIG_VAULT", "enabled handoff phases require a Vault binding")
    if recipient_enabled and not isinstance(recipient, dict):
        raise HandoffError("CONFIG_RECIPIENT", "enabled sealing, delivery, and consumption require a Claude recipient binding")
    if config["consumer_enabled"] and (not isinstance(transaction, dict) or not isinstance(consumer, dict)):
        raise HandoffError("CONFIG_RUNTIME", "enabled consumption requires transaction and consumer bindings")
    required_vault = {"path": str, "device": int, "inode": int}
    required_recipient = {
        "herdr_cli_path": str,
        "herdr_cli_sha256": str,
        "session": str,
        "workspace_id": str,
        "tab_id": str,
        "pane_id": str,
        "agent": str,
        "agent_session_sha256": str,
    }
    required_transaction = {
        "python_path": str,
        "core_path": str,
        "core_sha256": str,
        "module_path": str,
        "module_sha256": str,
        "dependency_root": str,
        "dependency_manifest": list,
    }
    bindings: list[tuple[Mapping[str, Any], Mapping[str, type], str]] = [(vault, required_vault, "CONFIG_VAULT")]
    if recipient_enabled:
        assert isinstance(recipient, dict)
        bindings.append((recipient, required_recipient, "CONFIG_RECIPIENT"))
    if config["consumer_enabled"]:
        assert isinstance(transaction, dict) and isinstance(consumer, dict)
        bindings.append((transaction, required_transaction, "CONFIG_TRANSACTION"))
    for values, required, code in bindings:
        for name, expected in required.items():
            if not isinstance(values.get(name), expected) or (expected is str and not values.get(name)):
                raise HandoffError(code, f"runtime binding field {name} is invalid")
    if recipient_enabled:
        assert isinstance(recipient, dict)
        if recipient["agent"] != "claude":
            raise HandoffError("CONFIG_RECIPIENT", "the supported recipient agent must be claude")
        for field in ("herdr_cli_sha256", "agent_session_sha256"):
            if not HEX64.fullmatch(str(recipient[field])):
                raise HandoffError("CONFIG_RECIPIENT", f"recipient field {field} is not SHA-256")
    if config["consumer_enabled"]:
        assert isinstance(transaction, dict) and isinstance(consumer, dict)
        for field in ("core_sha256", "module_sha256"):
            if not HEX64.fullmatch(str(transaction[field])):
                raise HandoffError("CONFIG_TRANSACTION", f"transaction field {field} is not SHA-256")
        validate_transaction_manifest(transaction)
        create_prefixes = consumer.get("create_prefix_allowlist")
        replace_paths = consumer.get("replace_path_allowlist")
        coupled = consumer.get("required_coupled_paths")
        if not isinstance(create_prefixes, list) or not create_prefixes or not all(safe_relative_prefix(item) for item in create_prefixes):
            raise HandoffError("CONFIG_CONSUMER", "consumer create_prefix_allowlist is invalid")
        if not isinstance(replace_paths, list) or not replace_paths or not all(safe_relative_path(item) for item in replace_paths):
            raise HandoffError("CONFIG_CONSUMER", "consumer replace_path_allowlist is invalid")
        if not isinstance(coupled, list) or not coupled or not all(isinstance(item, str) and item in replace_paths for item in coupled):
            raise HandoffError("CONFIG_CONSUMER", "consumer required_coupled_paths is invalid")


def config_enabled(config: Mapping[str, Any] | None, key: str) -> bool:
    return bool(config and config.get(key) is True)


def hash_session(source_harness: str, session_id: str) -> str:
    return hashlib.sha256(f"firstmate-context-handoff-v1\0{source_harness}\0{session_id}".encode("utf-8")).hexdigest()


def source_session_hash(config: Mapping[str, Any], source_harness: str, supplied: str | None = None) -> str:
    if source_harness == "claude":
        recipient = config.get("recipient")
        if not isinstance(recipient, dict) or not HEX64.fullmatch(str(recipient.get("agent_session_sha256", ""))):
            raise HandoffError("CLAUDE_SESSION_UNBOUND", "Claude candidate registration requires the exact configured session generation")
        return str(recipient["agent_session_sha256"])
    raw = supplied or os.environ.get("FM_HANDOFF_SESSION_ID") or os.environ.get("PI_SESSION_ID")
    if not raw:
        raise HandoffError("PI_SESSION_UNBOUND", "Pi candidate registration requires PI_SESSION_ID")
    return hash_session("pi", raw)


def safe_relative_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 1024 or "\\" in value or "\x00" in value:
        return False
    pure = PurePosixPath(value)
    return not pure.is_absolute() and all(part not in {"", ".", ".."} for part in pure.parts)


def safe_relative_prefix(value: Any) -> bool:
    return isinstance(value, str) and value.endswith("/") and safe_relative_path(value[:-1])


def within(path: Path, roots: Sequence[str]) -> bool:
    return any(path == Path(root) or Path(root) in path.parents for root in roots)


def validate_source_path(config: Mapping[str, Any], source_record: str, expected_sha: str) -> tuple[Path, str]:
    if not HEX64.fullmatch(expected_sha):
        raise HandoffError("SOURCE_HASH", "source_sha256 must be a lowercase SHA-256")
    raw = Path(source_record).expanduser()
    if not raw.is_absolute() or path_has_symlink(raw):
        raise HandoffError("SOURCE_PATH", "source_record must be an approved absolute no-symlink path")
    try:
        path = raw.resolve(strict=True)
    except OSError as exc:
        raise HandoffError("SOURCE_PATH", "source_record is unavailable") from exc
    if not within(path, list(config["approved_source_roots"])):
        raise HandoffError("SOURCE_NOT_APPROVED", "source_record is outside approved source roots")
    lowered_parts = {part.lower() for part in path.parts}
    if lowered_parts & FORBIDDEN_SOURCE_PARTS:
        raise HandoffError("SOURCE_CATEGORY", "source_record belongs to a prohibited source category")
    actual = sha256_file(path)
    if actual != expected_sha:
        raise HandoffError("SOURCE_HASH_MISMATCH", "source_record no longer matches source_sha256")
    return path, actual


def normalize_registration_allowlist(config: Mapping[str, Any]) -> list[dict[str, Any]]:
    contracts = config.get("registration_allowlist")
    if not isinstance(contracts, list):
        raise HandoffError("CONFIG_ELIGIBILITY", "registration_allowlist must be an array of exact eligibility contracts")
    expected_keys = {
        "source_record",
        "source_sha256",
        "statement_sha256",
        "kind",
        "confidence",
        "sphere",
        "sensitivity_class",
        "provider_class",
        "supersedes",
    }
    normalized: list[dict[str, Any]] = []
    for contract in contracts:
        if not isinstance(contract, dict) or set(contract) != expected_keys:
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract has unknown or missing fields")
        if not HEX64.fullmatch(str(contract.get("statement_sha256", ""))):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract statement hash is invalid")
        if contract.get("kind") not in KINDS or contract.get("confidence") not in CONFIDENCES or contract.get("sphere") not in SPHERES or contract.get("sensitivity_class") not in SENSITIVITY_CLASSES:
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract classification is invalid")
        provider = contract.get("provider_class")
        if not isinstance(provider, str) or not PROVIDER_CLASS.fullmatch(provider):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract provider class is invalid")
        supersedes = contract.get("supersedes")
        if not isinstance(supersedes, list) or len(supersedes) > 16 or len(set(supersedes)) != len(supersedes) or not all(isinstance(value, str) and CANDIDATE_ID.fullmatch(value) for value in supersedes):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract supersession list is invalid")
        source_record = contract.get("source_record")
        source_sha = contract.get("source_sha256")
        if not isinstance(source_record, str) or not isinstance(source_sha, str) or not HEX64.fullmatch(source_sha):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract source binding is invalid")
        raw_source = Path(source_record).expanduser()
        if not raw_source.is_absolute() or path_has_symlink(raw_source):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract source path is invalid")
        source = raw_source.resolve(strict=False)
        if not within(source, list(config["approved_source_roots"])) or {part.lower() for part in source.parts} & FORBIDDEN_SOURCE_PARTS:
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract source is outside the approved category")
        normalized.append(
            {
                "source_record": str(source),
                "source_sha256": source_sha,
                "statement_sha256": contract["statement_sha256"],
                "kind": contract["kind"],
                "confidence": contract["confidence"],
                "sphere": contract["sphere"],
                "sensitivity_class": contract["sensitivity_class"],
                "provider_class": provider,
                "supersedes": sorted(supersedes),
            }
        )
    if len({canonical_json(contract) for contract in normalized}) != len(normalized):
        raise HandoffError("CONFIG_ELIGIBILITY", "registration_allowlist repeats an eligibility contract")
    return sorted(normalized, key=canonical_json)


def eligibility_payload(
    *,
    source_record: str,
    source_sha256: str,
    statement: str,
    kind: str,
    confidence: str,
    sphere: str,
    sensitivity_class: str,
    provider_class: str,
    supersedes: Sequence[str],
) -> dict[str, Any]:
    return {
        "source_record": source_record,
        "source_sha256": source_sha256,
        "statement_sha256": sha256_bytes(statement.encode("utf-8")),
        "kind": kind,
        "confidence": confidence,
        "sphere": sphere,
        "sensitivity_class": sensitivity_class,
        "provider_class": provider_class,
        "supersedes": sorted(supersedes),
    }


def eligibility_contract(
    config: Mapping[str, Any],
    *,
    source_record: str,
    source_sha256: str,
    statement: str,
    kind: str,
    confidence: str,
    sphere: str,
    sensitivity_class: str,
    provider_class: str,
    supersedes: Sequence[str],
) -> str:
    expected = eligibility_payload(
        source_record=source_record,
        source_sha256=source_sha256,
        statement=statement,
        kind=kind,
        confidence=confidence,
        sphere=sphere,
        sensitivity_class=sensitivity_class,
        provider_class=provider_class,
        supersedes=supersedes,
    )
    if expected not in config["registration_allowlist"]:
        raise HandoffError("ELIGIBILITY_CONTRACT", "candidate fields lack an exact reviewed eligibility contract")
    return sha256_bytes(canonical_json(expected))


def validate_statement(statement: Any) -> str:
    if not isinstance(statement, str) or not statement or statement != statement.strip():
        raise HandoffError("STATEMENT_TEXT", "statement must be non-empty trimmed plain text")
    if len(statement.encode("utf-8")) > MAX_STATEMENT_BYTES or len(statement) > 2048:
        raise HandoffError("STATEMENT_CAP", "statement exceeds the 2048-byte cap")
    if any(ord(character) < 32 or ord(character) == 127 for character in statement):
        raise HandoffError("STATEMENT_CONTROL", "statement may not contain control characters or line breaks")
    if any(pattern.search(statement) for pattern in RAW_CONTENT_PATTERNS):
        raise HandoffError("RAW_CONTENT", "raw conversation, summary, reasoning, tool, or terminal material is not eligible")
    if any(pattern.search(statement) for pattern in SENSITIVE_PATTERNS):
        raise HandoffError("SENSITIVE_CONTENT", "sensitive or regulated content is not eligible")
    return statement


def validate_item(item: Any, config: Mapping[str, Any], *, verify_source: bool = True) -> dict[str, Any]:
    if not isinstance(item, dict):
        raise HandoffError("ITEM_TYPE", "handoff item must be an object")
    expected_keys = {
        "item_id",
        "kind",
        "statement",
        "source_record",
        "source_sha256",
        "confidence",
        "sphere",
        "sensitivity_class",
        "provider_class",
        "eligibility_sha256",
        "supersedes",
    }
    if set(item) != expected_keys:
        raise HandoffError("ITEM_FIELDS", "handoff item has unknown or missing fields")
    if not CANDIDATE_ID.fullmatch(str(item.get("item_id", ""))):
        raise HandoffError("ITEM_ID", "handoff item has an invalid item_id")
    if item.get("kind") not in KINDS or item.get("confidence") not in CONFIDENCES or item.get("sphere") not in SPHERES:
        raise HandoffError("ITEM_ENUM", "handoff item has an invalid allowlisted classification")
    if item.get("sensitivity_class") not in SENSITIVITY_CLASSES:
        raise HandoffError("ITEM_ENUM", "handoff item has an invalid sensitivity classification")
    if item["sensitivity_class"] != ELIGIBLE_SENSITIVITY_CLASS:
        raise HandoffError("SENSITIVE_CLASS", "sensitive or regulated classifications are not eligible")
    statement = validate_statement(item.get("statement"))
    provider = item.get("provider_class")
    if not isinstance(provider, str) or not PROVIDER_CLASS.fullmatch(provider):
        raise HandoffError("PROVIDER_CLASS", "handoff item provider class is invalid")
    if verify_source and provider not in config["allowed_provider_classes"]:
        raise HandoffError("PROVIDER_CLASS", "handoff item provider class is not authorized")
    supersedes = item.get("supersedes")
    if not isinstance(supersedes, list) or len(supersedes) > 16 or len(set(supersedes)) != len(supersedes) or not all(isinstance(value, str) and CANDIDATE_ID.fullmatch(value) for value in supersedes):
        raise HandoffError("SUPERSESSION", "handoff item supersession data is invalid")
    source_record = item.get("source_record")
    source_sha = item.get("source_sha256")
    if not isinstance(source_record, str) or len(source_record.encode("utf-8")) > 4096 or not isinstance(source_sha, str) or not HEX64.fullmatch(source_sha):
        raise HandoffError("SOURCE_FIELDS", "handoff item source fields are invalid")
    if verify_source:
        canonical_source, _ = validate_source_path(config, source_record, source_sha)
        source_record = str(canonical_source)
    eligibility_args = {
        "source_record": source_record,
        "source_sha256": source_sha,
        "statement": statement,
        "kind": item["kind"],
        "confidence": item["confidence"],
        "sphere": item["sphere"],
        "sensitivity_class": item["sensitivity_class"],
        "provider_class": provider,
        "supersedes": supersedes,
    }
    if verify_source:
        eligibility_sha = eligibility_contract(config, **eligibility_args)
    else:
        eligibility_sha = sha256_bytes(canonical_json(eligibility_payload(**eligibility_args)))
    if item.get("eligibility_sha256") != eligibility_sha:
        raise HandoffError("ELIGIBILITY_BINDING", "handoff item does not match its reviewed eligibility contract")
    return {
        "item_id": item["item_id"],
        "kind": item["kind"],
        "statement": statement,
        "source_record": source_record,
        "source_sha256": source_sha,
        "confidence": item["confidence"],
        "sphere": item["sphere"],
        "sensitivity_class": item["sensitivity_class"],
        "provider_class": provider,
        "eligibility_sha256": eligibility_sha,
        "supersedes": sorted(supersedes),
    }


def candidate_identity(source_harness: str, session_hash: str, item_without_id: Mapping[str, Any]) -> str:
    identity = {"source_harness": source_harness, "source_session_hash": session_hash, "item": item_without_id}
    return "candidate-" + sha256_bytes(canonical_json(identity))[:48]


def stored_candidate_identity(value: Mapping[str, Any]) -> str | None:
    item = value.get("item")
    if not isinstance(item, dict) or item.get("item_id") != value.get("candidate_id"):
        return None
    return candidate_identity(
        str(value.get("source_harness")),
        str(value.get("source_session_hash")),
        {key: entry for key, entry in item.items() if key != "item_id"},
    )


def envelope_identity(envelope: Mapping[str, Any]) -> str:
    identity = {key: envelope[key] for key in ("schema", "source_harness", "source_session_hash", "trigger", "items")}
    return "handoff-" + sha256_bytes(canonical_json(identity))[:48]


def validate_envelope(value: Any, config: Mapping[str, Any], *, verify_sources: bool = True) -> dict[str, Any]:
    schema = authoritative_schema()
    if not isinstance(value, dict):
        raise HandoffError("ENVELOPE_TYPE", "handoff envelope must be an object")
    expected = set(schema["required"])
    if set(value) != expected:
        raise HandoffError("ENVELOPE_FIELDS", "handoff envelope has unknown or missing fields")
    if value.get("schema") != HANDOFF_SCHEMA or value.get("source_harness") not in SOURCE_HARNESSES or value.get("trigger") not in TRIGGERS:
        raise HandoffError("ENVELOPE_ENUM", "handoff envelope has an invalid lifecycle classification")
    if not RECORD_ID.fullmatch(str(value.get("record_id", ""))) or not HEX64.fullmatch(str(value.get("source_session_hash", ""))):
        raise HandoffError("ENVELOPE_ID", "handoff envelope identity is invalid")
    created_at = value.get("created_at")
    if not isinstance(created_at, str) or len(created_at) > 64:
        raise HandoffError("ENVELOPE_TIME", "handoff envelope timestamp is invalid")
    try:
        parsed_created_at = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HandoffError("ENVELOPE_TIME", "handoff envelope timestamp is invalid") from exc
    if parsed_created_at.tzinfo is None:
        raise HandoffError("ENVELOPE_TIME", "handoff envelope timestamp must include a UTC offset")
    items = value.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        raise HandoffError("ENVELOPE_ITEMS", "handoff envelope violates the item cap")
    normalized = [validate_item(item, config, verify_source=verify_sources) for item in items]
    if len({item["item_id"] for item in normalized}) != len(normalized):
        raise HandoffError("ENVELOPE_DUPLICATE", "handoff envelope repeats an item")
    result = dict(value)
    result["items"] = normalized
    if envelope_identity(result) != result["record_id"]:
        raise HandoffError("ENVELOPE_BINDING", "handoff record ID does not match its canonical payload")
    data = canonical_json(result)
    if len(data) > MAX_ENVELOPE_BYTES:
        raise HandoffError("ENVELOPE_BYTES", "handoff envelope violates the byte cap")
    return result


def write_receipt(layout: StateLayout, event: str, status: str, reason: str, **fields: Any) -> dict[str, Any]:
    body = {
        "schema": RECEIPT_SCHEMA,
        "event": event,
        "status": status,
        "reason": reason,
        "recorded_at": now_utc(),
        **fields,
    }
    receipt_id = "receipt-" + sha256_bytes(canonical_json(body))[:48]
    value = {"receipt_id": receipt_id, **body}
    atomic_create(layout.receipts / f"{receipt_id}.json", canonical_json(value))
    return value


def quarantine(layout: StateLayout, record_id: str, reason: str, **fields: Any) -> None:
    body = {
        "schema": "firstmate.context-handoff.quarantine.v1",
        "record_id": record_id,
        "reason": reason,
        "recorded_at": now_utc(),
        **fields,
    }
    quarantine_id = "quarantine-" + sha256_bytes(canonical_json(body))[:48]
    atomic_create(layout.quarantine / f"{quarantine_id}.json", canonical_json({"quarantine_id": quarantine_id, **body}))


def queue_path(layout: StateLayout, record_id: str) -> Path:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return layout.queue / f"{record_id}.json"


def read_queue(layout: StateLayout, record_id: str) -> dict[str, Any]:
    path = queue_path(layout, record_id)
    value = read_json_file(path, max_bytes=64 * 1024)
    if not isinstance(value, dict) or value.get("schema") != QUEUE_SCHEMA or value.get("record_id") != record_id:
        raise HandoffError("QUEUE_RECORD", "queue record is invalid")
    return value


def update_queue(layout: StateLayout, record_id: str, **changes: Any) -> dict[str, Any]:
    path = queue_path(layout, record_id)
    current = read_queue(layout, record_id) if path.exists() else {
        "schema": QUEUE_SCHEMA,
        "record_id": record_id,
        "status": "pending",
        "reason": "sealed-awaiting-compaction-result",
        "attempts": 0,
        "compaction": "sealed",
        "created_at": now_utc(),
    }
    current.update(changes)
    current["updated_at"] = now_utc()
    atomic_replace(path, canonical_json(current))
    return current


def read_candidate_binding(path: Path) -> dict[str, Any]:
    value = read_json_file(path, max_bytes=16 * 1024)
    expected_keys = {"schema", "candidate_id", "source_harness", "source_session_hash", "registered_at", "item"}
    if not isinstance(value, dict) or set(value) != expected_keys or value.get("schema") != CANDIDATE_SCHEMA:
        raise HandoffError("CANDIDATE_RECORD", "candidate record is invalid")
    if value.get("source_harness") not in SOURCE_HARNESSES or not HEX64.fullmatch(str(value.get("source_session_hash", ""))):
        raise HandoffError("CANDIDATE_BINDING", "candidate source binding is invalid")
    if not CANDIDATE_ID.fullmatch(str(value.get("candidate_id", ""))) or path.stem != value.get("candidate_id") or not isinstance(value.get("registered_at"), str) or not isinstance(value.get("item"), dict):
        raise HandoffError("CANDIDATE_ID", "candidate stable ID is invalid")
    return value


def validate_candidate(value: Mapping[str, Any], path: Path, config: Mapping[str, Any]) -> dict[str, Any]:
    item = validate_item(value.get("item"), config)
    bound = stored_candidate_identity({**value, "item": item})
    if bound is None or path.stem != value.get("candidate_id") or bound != value.get("candidate_id"):
        raise HandoffError("CANDIDATE_ID", "candidate stable ID is invalid")
    return {**value, "item": item}


def read_candidate(path: Path, config: Mapping[str, Any]) -> dict[str, Any]:
    return validate_candidate(read_candidate_binding(path), path, config)


def _register_locked(home: Path, config: Mapping[str, Any] | None, args: argparse.Namespace, layout: StateLayout) -> dict[str, Any]:
    if not config_enabled(config, "registration_enabled"):
        raise HandoffError("REGISTRATION_DISABLED", "curated handoff registration is disabled")
    assert config is not None
    session_hash = source_session_hash(config, args.source_harness)
    source, _ = validate_source_path(config, args.source_record, args.source_sha256)
    statement = validate_statement(args.statement)
    if args.kind not in KINDS or args.confidence not in CONFIDENCES or args.sphere not in SPHERES:
        raise HandoffError("REGISTER_ENUM", "candidate classification is not allowlisted")
    if args.sensitivity_class not in SENSITIVITY_CLASSES:
        raise HandoffError("REGISTER_ENUM", "candidate sensitivity classification is not allowlisted")
    if args.sensitivity_class != ELIGIBLE_SENSITIVITY_CLASS:
        raise HandoffError("SENSITIVE_CLASS", "sensitive or regulated classifications are not eligible")
    if args.provider_class not in config["allowed_provider_classes"]:
        raise HandoffError("PROVIDER_CLASS", "candidate provider class is not authorized")
    supersedes = sorted(set(args.supersedes or []))
    if len(supersedes) > 16 or not all(CANDIDATE_ID.fullmatch(value) for value in supersedes):
        raise HandoffError("SUPERSESSION", "candidate supersession data is invalid")
    eligibility_sha = eligibility_contract(
        config,
        source_record=str(source),
        source_sha256=args.source_sha256,
        statement=statement,
        kind=args.kind,
        confidence=args.confidence,
        sphere=args.sphere,
        sensitivity_class=args.sensitivity_class,
        provider_class=args.provider_class,
        supersedes=supersedes,
    )
    item_without_id = {
        "kind": args.kind,
        "statement": statement,
        "source_record": str(source),
        "source_sha256": args.source_sha256,
        "confidence": args.confidence,
        "sphere": args.sphere,
        "sensitivity_class": args.sensitivity_class,
        "provider_class": args.provider_class,
        "eligibility_sha256": eligibility_sha,
        "supersedes": supersedes,
    }
    candidate_id = candidate_identity(args.source_harness, session_hash, item_without_id)
    item = {"item_id": candidate_id, **item_without_id}
    value = {
        "schema": CANDIDATE_SCHEMA,
        "candidate_id": candidate_id,
        "source_harness": args.source_harness,
        "source_session_hash": session_hash,
        "registered_at": now_utc(),
        "item": item,
    }
    candidate_path = layout.candidates / f"{candidate_id}.json"
    if candidate_path.exists():
        existing = read_candidate(candidate_path, config)
        if (
            existing.get("candidate_id") != candidate_id
            or existing.get("source_harness") != args.source_harness
            or existing.get("source_session_hash") != session_hash
            or existing.get("item") != item
        ):
            quarantine(layout, candidate_id, "candidate-id-payload-mismatch")
            raise HandoffError("CREATE_ONLY_MISMATCH", "a stable candidate ID already binds different bytes")
        return {"status": "registered", "candidate_id": candidate_id}
    recover_orphan_queues_from_claims(layout, config)
    retire_stale_active_state(layout, args.source_harness, session_hash, config)
    active_count = len(active_queue_records(layout, config))
    if active_count >= MAX_COMPACTION_RECORDS:
        raise HandoffError("COMPACTION_BACKPRESSURE", "active handoff records must reach a terminal disposition before another candidate can register")
    claimed = claimed_candidate_ids(layout)
    pending_count = 0
    for path in layout.candidates.glob("candidate-*.json"):
        if path.stem in claimed:
            continue
        pending_binding = read_candidate_binding(path)
        if pending_binding["source_harness"] == args.source_harness and pending_binding["source_session_hash"] == session_hash:
            validate_candidate(pending_binding, path, config)
        pending_count += 1
    if pending_count >= MAX_ITEMS:
        raise HandoffError("CANDIDATE_BACKPRESSURE", "the bounded candidate register must seal before accepting another item")
    if load_config(home) != config:
        raise HandoffError("CONFIG_CHANGED", "handoff configuration changed during candidate registration")
    validate_source_path(config, args.source_record, args.source_sha256)
    try:
        atomic_create(candidate_path, canonical_json(value))
    except HandoffError as exc:
        if exc.code == "CREATE_ONLY_MISMATCH":
            quarantine(layout, candidate_id, "candidate-id-payload-mismatch")
        raise
    write_receipt(layout, "candidate-register", "registered", "curated-item-accepted", candidate_id=candidate_id)
    return {"status": "registered", "candidate_id": candidate_id}


def command_register(args: argparse.Namespace) -> dict[str, Any]:
    home = resolve_home(args.fm_home)
    layout = StateLayout(home)
    with state_lock(layout):
        return _register_locked(home, load_config(home), args, layout)


def claimed_candidate_ids(layout: StateLayout) -> set[str]:
    result: set[str] = set()
    for path in sorted(layout.claims.glob("candidate-*.json")):
        value = read_json_file(path, max_bytes=4096)
        if isinstance(value, dict) and value.get("candidate_id") == path.stem and RECORD_ID.fullmatch(str(value.get("record_id", ""))):
            result.add(path.stem)
        else:
            raise HandoffError("CLAIM_RECORD", "candidate claim record is invalid")
    return result


def record_file(layout: StateLayout, record_id: str) -> Path:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return layout.records / f"{record_id}.json"


def read_envelope(layout: StateLayout, record_id: str, config: Mapping[str, Any], *, verify_sources: bool = True) -> tuple[dict[str, Any], str]:
    path = record_file(layout, record_id)
    validate_private_file(path)
    data = path.read_bytes()
    if len(data) > MAX_ENVELOPE_BYTES:
        raise HandoffError("ENVELOPE_BYTES", "handoff envelope violates the byte cap")
    try:
        raw = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("ENVELOPE_JSON", "handoff envelope is invalid JSON") from exc
    value = validate_envelope(raw, config, verify_sources=verify_sources)
    if canonical_json(value) != data:
        raise HandoffError("ENVELOPE_CANONICAL", "handoff envelope is not canonically serialized")
    return value, sha256_bytes(data)


def recover_orphan_queues_from_claims(layout: StateLayout, config: Mapping[str, Any]) -> None:
    record_claims: dict[str, set[str]] = {}
    for path in sorted(layout.claims.glob("candidate-*.json")):
        value = read_json_file(path, max_bytes=4096)
        record_id = value.get("record_id") if isinstance(value, dict) else None
        candidate_id = value.get("candidate_id") if isinstance(value, dict) else None
        if not isinstance(record_id, str) or not RECORD_ID.fullmatch(record_id) or candidate_id != path.stem:
            raise HandoffError("CLAIM_RECORD", "candidate claim record is invalid")
        if not queue_path(layout, record_id).exists():
            record_claims.setdefault(record_id, set()).add(candidate_id)
    for record_id, candidate_ids in sorted(record_claims.items()):
        fsync_directory(layout.records)
        envelope, digest = read_envelope(layout, record_id, config, verify_sources=False)
        if not candidate_ids.issubset({item["item_id"] for item in envelope["items"]}):
            raise HandoffError("CLAIM_RECORD", "candidate claim does not belong to its sealed record")
        update_queue(layout, record_id, envelope_sha256=digest)
        write_receipt(layout, "seal-recovery", "recovered", "claimed-record-queue-recovered", record_id=record_id, envelope_sha256=digest)


def recover_unclaimed_records(layout: StateLayout, config: Mapping[str, Any], candidates: Mapping[str, dict[str, Any]]) -> dict[str, str]:
    recovered: dict[str, str] = {}
    wanted = set(candidates)
    if not wanted:
        return recovered
    for path in sorted(layout.records.glob("handoff-*.json")):
        envelope, envelope_sha = read_envelope(layout, path.stem, config, verify_sources=False)
        matched = wanted & {item["item_id"] for item in envelope["items"]}
        if matched:
            fsync_directory(layout.records)
            update_queue(layout, envelope["record_id"], envelope_sha256=envelope_sha)
            failpoint("after-recovery-queue-before-claims")
        for candidate_id in matched:
            claim = {
                "schema": "firstmate.context-handoff.claim.v1",
                "candidate_id": candidate_id,
                "record_id": envelope["record_id"],
                "envelope_sha256": envelope_sha,
                "claimed_at": envelope["created_at"],
            }
            atomic_create(layout.claims / f"{candidate_id}.json", canonical_json(claim))
            recovered[candidate_id] = envelope["record_id"]
    return recovered


def retryable_records(layout: StateLayout, source_harness: str, session_hash: str, config: Mapping[str, Any]) -> list[dict[str, str]]:
    candidates: list[tuple[str, str, str]] = []
    for path in sorted(layout.queue.glob("handoff-*.json")):
        queue = read_queue(layout, path.stem)
        if queue.get("status") in {"acknowledged", "quarantined"} or queue.get("compaction") == "succeeded":
            continue
        envelope, digest = read_envelope(layout, path.stem, config, verify_sources=False)
        if envelope["source_harness"] == source_harness and envelope["source_session_hash"] == session_hash:
            candidates.append((str(queue.get("updated_at", "")), path.stem, digest))
    return [
        {"record_id": record_id, "envelope_sha256": digest}
        for _, record_id, digest in sorted(candidates)
    ]


def active_queue_records(layout: StateLayout, config: Mapping[str, Any]) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for path in sorted(layout.queue.glob("handoff-*.json")):
        queue = read_queue(layout, path.stem)
        if queue.get("status") in {"acknowledged", "quarantined"}:
            continue
        envelope, digest = read_envelope(layout, path.stem, config, verify_sources=False)
        records.append(
            {
                "record_id": path.stem,
                "envelope_sha256": digest,
                "source_harness": str(envelope["source_harness"]),
                "source_session_hash": str(envelope["source_session_hash"]),
                "compaction": str(queue.get("compaction", "sealed")),
                "updated_at": str(queue.get("updated_at", "")),
            }
        )
    return sorted(records, key=lambda item: (item["updated_at"], item["record_id"]))


def retire_stale_active_state(
    layout: StateLayout,
    source_harness: str,
    session_hash: str,
    config: Mapping[str, Any],
) -> None:
    claimed = claimed_candidate_ids(layout)
    candidates: list[tuple[str, str, Path, dict[str, Any]]] = []
    for path in sorted(layout.candidates.glob("candidate-*.json")):
        if path.stem in claimed:
            continue
        value = read_candidate_binding(path)
        candidates.append((str(value["registered_at"]), path.stem, path, value))
    candidates.sort(key=lambda item: (item[0], item[1]))
    while len(candidates) >= MAX_ITEMS:
        stale_index = next(
            (
                index
                for index, (_, _, _, value) in enumerate(candidates)
                if value["source_harness"] == source_harness and value["source_session_hash"] != session_hash
            ),
            None,
        )
        if stale_index is None:
            break
        _, candidate_id, path, value = candidates.pop(stale_index)
        observed_sha = sha256_file(path, max_bytes=16 * 1024)
        quarantine(
            layout,
            candidate_id,
            "stale-session-candidate-retired",
            observed_sha256=observed_sha,
            source_harness=value["source_harness"],
            source_session_hash=value["source_session_hash"],
            replacement_session_hash=session_hash,
        )
        retired_path = layout.quarantine / f"retired-{candidate_id}.json"
        try:
            rename_noreplace(path, retired_path)
            fsync_directory(layout.quarantine)
            fsync_directory(layout.candidates)
        except FileExistsError:
            if read_file_bytes(retired_path, max_bytes=16 * 1024) != read_file_bytes(path, max_bytes=16 * 1024):
                raise HandoffError("CREATE_ONLY_MISMATCH", "retired candidate evidence binds different bytes")
            durable_unlink(path)

    active = active_queue_records(layout, config)
    while len(active) >= MAX_COMPACTION_RECORDS:
        stale_index = next(
            (
                index
                for index, item in enumerate(active)
                if item["compaction"] != "succeeded" and item["source_harness"] == source_harness and item["source_session_hash"] != session_hash
            ),
            None,
        )
        if stale_index is None:
            break
        item = active.pop(stale_index)
        quarantine(
            layout,
            item["record_id"],
            "stale-session-record-retired",
            observed_sha256=item["envelope_sha256"],
            source_harness=item["source_harness"],
            source_session_hash=item["source_session_hash"],
            replacement_session_hash=session_hash,
        )
        update_queue(
            layout,
            item["record_id"],
            status="quarantined",
            reason="stale-session-record-retired",
        )


def normalize_compaction_bindings(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_COMPACTION_RECORDS:
        raise HandoffError("COMPACTION_BINDING", "compaction attempt binding count is invalid")
    normalized: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"record_id", "envelope_sha256"}:
            raise HandoffError("COMPACTION_BINDING", "compaction attempt binding is invalid")
        record_id = item.get("record_id")
        envelope_sha = item.get("envelope_sha256")
        if not isinstance(record_id, str) or not RECORD_ID.fullmatch(record_id) or record_id in seen or not isinstance(envelope_sha, str) or not HEX64.fullmatch(envelope_sha):
            raise HandoffError("COMPACTION_BINDING", "compaction attempt binding is invalid")
        seen.add(record_id)
        normalized.append({"record_id": record_id, "envelope_sha256": envelope_sha})
    return sorted(normalized, key=lambda item: item["record_id"])


def compaction_attempt_result(status: str, bindings: Sequence[Mapping[str, str]]) -> dict[str, Any]:
    normalized = normalize_compaction_bindings([dict(item) for item in bindings])
    result: dict[str, Any] = {"status": status, "bindings": normalized}
    if len(normalized) == 1:
        result.update(normalized[0])
    return result


def pi_compaction_binding_path(layout: StateLayout, session_hash: str) -> Path:
    if not HEX64.fullmatch(session_hash):
        raise HandoffError("PI_ATTEMPT", "Pi compaction session identity is invalid")
    return layout.bindings / f"pi-compaction-{session_hash[:48]}.json"


def read_pi_compaction_binding(path: Path) -> dict[str, Any]:
    value = read_json_file(path, max_bytes=32 * 1024)
    expected = {
        "schema",
        "attempt_id",
        "source_session_hash",
        "process_capability_sha256",
        "process_generation",
        "process_platform",
        "process_boot_id",
        "process_pid",
        "process_group",
        "process_session",
        "process_start_token",
        "trigger",
        "bindings",
        "terminal_outcome",
        "terminal_reason",
        "terminal_at",
    }
    if (
        not isinstance(value, dict)
        or set(value) != expected
        or value.get("schema") != PI_COMPACTION_BINDING_SCHEMA
        or not re.fullmatch(r"pi-attempt-[0-9a-f]{48}", str(value.get("attempt_id", "")))
        or not HEX64.fullmatch(str(value.get("source_session_hash", "")))
        or not HEX64.fullmatch(str(value.get("process_capability_sha256", "")))
        or not isinstance(value.get("process_generation"), int)
        or value.get("process_generation", 0) < 1
        or value.get("process_platform") not in {"linux", "darwin", "test"}
        or not isinstance(value.get("process_pid"), int)
        or value.get("process_pid", 0) < 1
        or not isinstance(value.get("process_group"), int)
        or value.get("process_group", 0) < 1
        or not isinstance(value.get("process_session"), int)
        or value.get("process_session", 0) < 1
        or not isinstance(value.get("process_start_token"), str)
        or value.get("trigger") not in TRIGGERS
    ):
        raise HandoffError("PI_ATTEMPT", "durable Pi compaction binding is invalid")
    platform = value["process_platform"]
    boot_id = value.get("process_boot_id")
    if (platform in {"linux", "test"} and (not isinstance(boot_id, str) or not boot_id):
        raise HandoffError("PI_ATTEMPT", "durable Pi process boot identity is invalid")
    if platform == "darwin" and boot_id is not None:
        raise HandoffError("PI_ATTEMPT", "durable Pi process boot identity is invalid")
    value["bindings"] = normalize_compaction_bindings(value.get("bindings"))
    terminal = value.get("terminal_outcome")
    if terminal is None:
        if value.get("terminal_reason") is not None or value.get("terminal_at") is not None:
            raise HandoffError("PI_ATTEMPT", "durable Pi terminal binding is incomplete")
    elif (
        terminal not in {"succeeded", "failed"}
        or not isinstance(value.get("terminal_reason"), str)
        or not value["terminal_reason"]
        or not isinstance(value.get("terminal_at"), str)
    ):
        raise HandoffError("PI_ATTEMPT", "durable Pi terminal binding is invalid")
    return value


def pi_process_claim_matches(binding: Mapping[str, Any], claim: Mapping[str, Any]) -> bool:
    return all(binding.get(name) == claim.get(name) for name in (
        "process_capability_sha256",
        "process_generation",
        "process_platform",
        "process_boot_id",
        "process_pid",
        "process_group",
        "process_session",
        "process_start_token",
    ))


def apply_pi_terminal_binding(layout: StateLayout, config: Mapping[str, Any], binding: Mapping[str, Any]) -> dict[str, Any]:
    terminal = binding.get("terminal_outcome")
    if terminal not in {"succeeded", "failed"}:
        raise HandoffError("PI_ATTEMPT", "Pi compaction attempt has no terminal result")
    body = {
        "schema": COMPACTION_ATTEMPT_SCHEMA,
        "bindings": binding["bindings"],
        "status": terminal,
        "trigger": binding["trigger"],
        "reason": binding["terminal_reason"],
        "recorded_at": binding["terminal_at"],
    }
    journal = {"attempt_id": "attempt-" + sha256_bytes(canonical_json(body))[:48], **body}
    path = layout.bindings / f"{journal['attempt_id']}.json"
    atomic_create(path, canonical_json(journal))
    failpoint("after-compaction-attempt-before-queues")
    result = apply_compaction_attempt(layout, config, journal)
    durable_unlink(path)
    return result


def seal_pi_attempt(home: Path, config: Mapping[str, Any], session_hash: str, trigger: str) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        claim = current_pi_process_claim()
        path = pi_compaction_binding_path(layout, session_hash)
        if path.exists():
            existing = read_pi_compaction_binding(path)
            if existing["source_session_hash"] != session_hash:
                raise HandoffError("PI_ATTEMPT", "Pi compaction binding belongs to another session")
            if existing["terminal_outcome"] is None:
                if pi_process_claim_matches(existing, claim):
                    return {
                        **compaction_attempt_result("already-sealed", existing["bindings"]),
                        "attempt_id": existing["attempt_id"],
                    }
                if pi_process_binding_owner_is_live(existing):
                    return {"status": "attempt-conflict"}
                quarantine(layout, existing["attempt_id"], "dead-pi-compaction-attempt-retired", source_session_hash=session_hash)
            else:
                apply_pi_terminal_binding(layout, config, existing)
        result = _seal_candidates_locked(layout, config, "pi", session_hash, trigger)
        if result.get("status") not in {"sealed", "already-sealed"}:
            if path.exists():
                durable_unlink(path)
            return result
        attempt_id = "pi-attempt-" + os.urandom(24).hex()
        binding = {
            "schema": PI_COMPACTION_BINDING_SCHEMA,
            "attempt_id": attempt_id,
            "source_session_hash": session_hash,
            **claim,
            "trigger": trigger,
            "bindings": normalize_compaction_bindings(result.get("bindings")),
            "terminal_outcome": None,
            "terminal_reason": None,
            "terminal_at": None,
        }
        atomic_replace(path, canonical_json(binding))
        return {**result, "attempt_id": attempt_id}


def seal_candidates(
    home: Path,
    source_harness: str,
    session_hash: str,
    trigger: str,
    *,
    verify_locked: Callable[[StateLayout, Mapping[str, Any]], None] | None = None,
    reuse_locked: Callable[[StateLayout, Mapping[str, Any]], Mapping[str, Any] | None] | None = None,
    commit_locked: Callable[[StateLayout, Mapping[str, Any], Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    config = load_config(home)
    if not config_enabled(config, "sealing_enabled"):
        return {"status": "disabled"}
    assert config is not None
    layout = StateLayout(home)
    with state_lock(layout):
        if verify_locked is not None:
            verify_locked(layout, config)
        if reuse_locked is not None:
            reused = reuse_locked(layout, config)
            if reused is not None:
                return dict(reused)
        result = _seal_candidates_locked(layout, config, source_harness, session_hash, trigger)
        if commit_locked is not None:
            commit_locked(layout, config, result)
        return result


def _seal_candidates_locked(
    layout: StateLayout,
    config: Mapping[str, Any],
    source_harness: str,
    session_hash: str,
    trigger: str,
) -> dict[str, Any]:
    replay_compaction_attempts(layout, config)
    recover_orphan_queues_from_claims(layout, config)
    attempt_bindings = {
        item["record_id"]: item["envelope_sha256"]
        for item in retryable_records(layout, source_harness, session_hash, config)
    }
    claimed = claimed_candidate_ids(layout)
    matching: dict[str, dict[str, Any]] = {}
    for path in sorted(layout.candidates.glob("candidate-*.json")):
        if path.stem in claimed:
            continue
        try:
            candidate_binding = read_candidate_binding(path)
        except HandoffError as exc:
            write_receipt(
                layout,
                "seal",
                "failed",
                "registered-candidate-validation-failed",
                source_harness=source_harness,
                trigger=trigger,
                failure_code=exc.code,
            )
            return {
                "status": "seal-failed",
                "had_candidates": True,
                "reason": "registered-candidate-validation-failed",
            }
        if candidate_binding["source_harness"] != source_harness or candidate_binding["source_session_hash"] != session_hash:
            continue
        try:
            candidate = validate_candidate(candidate_binding, path, config)
        except HandoffError as exc:
            write_receipt(
                layout,
                "seal",
                "failed",
                "registered-candidate-validation-failed",
                source_harness=source_harness,
                trigger=trigger,
                failure_code=exc.code,
            )
            return {
                "status": "seal-failed",
                "had_candidates": True,
                "reason": "registered-candidate-validation-failed",
            }
        matching[candidate["candidate_id"]] = candidate
    recovered = recover_unclaimed_records(layout, config, matching)
    matching = {key: value for key, value in matching.items() if key not in recovered}
    for record_id in sorted(set(recovered.values())):
        _, digest = read_envelope(layout, record_id, config, verify_sources=False)
        attempt_bindings[record_id] = digest
    if not matching:
        if attempt_bindings:
            return compaction_attempt_result("already-sealed", [{"record_id": key, "envelope_sha256": value} for key, value in attempt_bindings.items()])
        write_receipt(layout, "seal", "empty", "no-registered-candidates", source_harness=source_harness, trigger=trigger)
        return {"status": "empty"}
    if len(attempt_bindings) >= MAX_COMPACTION_RECORDS:
        return compaction_attempt_result("already-sealed", [{"record_id": key, "envelope_sha256": value} for key, value in attempt_bindings.items()])
    selected: dict[str, dict[str, Any]] = {}
    envelope: dict[str, Any] = {}
    data = b""
    created_at = now_utc()
    for candidate_id in sorted(matching):
        proposed = {**selected, candidate_id: matching[candidate_id]}
        proposed_envelope: dict[str, Any] = {
            "schema": HANDOFF_SCHEMA,
            "record_id": "",
            "source_harness": source_harness,
            "source_session_hash": session_hash,
            "trigger": trigger,
            "created_at": created_at,
            "items": [proposed[key]["item"] for key in sorted(proposed)],
        }
        proposed_envelope["record_id"] = envelope_identity(proposed_envelope)
        proposed_data = canonical_json(proposed_envelope)
        if len(proposed) > MAX_ITEMS or len(proposed_data) > MAX_ENVELOPE_BYTES:
            break
        selected = proposed
        envelope = proposed_envelope
        data = proposed_data
    if not selected:
        write_receipt(layout, "seal", "failed", "byte-cap-exceeded", source_harness=source_harness, trigger=trigger, candidate_count=len(matching))
        return {"status": "seal-failed", "had_candidates": True, "reason": "byte-cap-exceeded"}
    items = envelope["items"]
    validate_envelope(envelope, config)
    try:
        digest = atomic_create(record_file(layout, envelope["record_id"]), data)
        update_queue(layout, envelope["record_id"], envelope_sha256=digest)
        for candidate_id in sorted(selected):
            claim = {
                "schema": "firstmate.context-handoff.claim.v1",
                "candidate_id": candidate_id,
                "record_id": envelope["record_id"],
                "envelope_sha256": digest,
                "claimed_at": envelope["created_at"],
            }
            atomic_create(layout.claims / f"{candidate_id}.json", canonical_json(claim))
        write_receipt(layout, "seal", "sealed", "durable-before-compaction", record_id=envelope["record_id"], envelope_sha256=digest, source_harness=source_harness, trigger=trigger, item_count=len(items), envelope_bytes=len(data))
    except BaseException as exc:
        reason = "atomic-seal-failed"
        try:
            write_receipt(layout, "seal", "failed", reason, source_harness=source_harness, trigger=trigger, candidate_count=len(items))
        except BaseException:
            pass
        if isinstance(exc, HandoffError) and exc.code == "CREATE_ONLY_MISMATCH":
            quarantine(layout, envelope["record_id"], "record-id-payload-mismatch")
        return {"status": "seal-failed", "had_candidates": True, "reason": reason}
    attempt_bindings[envelope["record_id"]] = digest
    return compaction_attempt_result("sealed", [{"record_id": key, "envelope_sha256": value} for key, value in attempt_bindings.items()])


def parse_event_stdin(max_bytes: int = MAX_HOOK_BYTES) -> dict[str, Any]:
    data = sys.stdin.buffer.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise HandoffError("INPUT_CAP", "hook or extension input exceeded its byte cap")
    try:
        value = json.loads(data or b"{}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("INPUT_JSON", "hook or extension input is not JSON") from exc
    if not isinstance(value, dict):
        raise HandoffError("INPUT_TYPE", "hook or extension input must be an object")
    return value


def matching_nonempty_state(layout: StateLayout, source_harness: str, session_hash: str) -> bool:
    layout.initialize()
    candidate_owners: dict[str, bool | None] = {}
    for path in sorted(layout.candidates.glob("candidate-*.json")):
        try:
            value = read_candidate_binding(path)
        except HandoffError:
            candidate_owners[path.stem] = None
            continue
        if stored_candidate_identity(value) != value["candidate_id"]:
            candidate_owners[path.stem] = None
            continue
        candidate_owners[path.stem] = value["source_harness"] == source_harness and value["source_session_hash"] == session_hash

    claimed: set[str] = set()
    record_claims: dict[str, list[str]] = {}
    for path in sorted(layout.claims.glob("candidate-*.json")):
        try:
            value = read_json_file(path, max_bytes=4096)
        except HandoffError:
            return True
        record_id = value.get("record_id") if isinstance(value, dict) else None
        candidate_id = value.get("candidate_id") if isinstance(value, dict) else None
        if (
            not isinstance(value, dict)
            or set(value) != {"schema", "candidate_id", "record_id", "envelope_sha256", "claimed_at"}
            or value.get("schema") != "firstmate.context-handoff.claim.v1"
            or not isinstance(record_id, str)
            or not RECORD_ID.fullmatch(record_id)
            or not isinstance(candidate_id, str)
            or candidate_id != path.stem
            or not CANDIDATE_ID.fullmatch(candidate_id)
            or not HEX64.fullmatch(str(value.get("envelope_sha256", "")))
            or not isinstance(value.get("claimed_at"), str)
        ):
            return True
        claimed.add(candidate_id)
        record_claims.setdefault(record_id, []).append(candidate_id)

    queue_states: dict[str, bool | None] = {}
    for path in sorted(layout.queue.glob("handoff-*.json")):
        try:
            queue = read_queue(layout, path.stem)
        except HandoffError:
            queue_states[path.stem] = None
            continue
        queue_states[path.stem] = (
            queue.get("status") in {"acknowledged", "quarantined"}
            and queue.get("compaction") in {"sealed", "succeeded", "failed"}
            and isinstance(queue.get("reason"), str)
            and isinstance(queue.get("attempts"), int)
            and queue.get("attempts", -1) >= 0
            and isinstance(queue.get("created_at"), str)
            and isinstance(queue.get("updated_at"), str)
            and HEX64.fullmatch(str(queue.get("envelope_sha256", ""))) is not None
        )

    record_ids = set(queue_states) | set(record_claims) | {path.stem for path in layout.records.glob("handoff-*.json")}
    for record_id in sorted(record_ids):
        if queue_states.get(record_id) is True:
            continue
        try:
            envelope, _digest = read_envelope(layout, record_id, {}, verify_sources=False)
        except HandoffError:
            envelope_owner = None
        else:
            envelope_owner = envelope["source_harness"] == source_harness and envelope["source_session_hash"] == session_hash
        claim_owners = [candidate_owners.get(candidate_id) for candidate_id in record_claims.get(record_id, [])]
        if envelope_owner is not None:
            if any(owner is None or owner != envelope_owner for owner in claim_owners):
                return True
            if envelope_owner:
                return True
            continue
        if any(owner is True for owner in claim_owners):
            return True
        if claim_owners and all(owner is False for owner in claim_owners):
            continue
        return True

    return any(owner is not False for candidate_id, owner in candidate_owners.items() if candidate_id not in claimed)


def block_failed_claude_precompact(
    home: Path,
    config: Mapping[str, Any] | None,
    trigger: str,
    failure_code: str,
    *,
    session_hash: str | None = None,
) -> dict[str, Any] | None:
    layout = StateLayout(home)
    with state_lock(layout):
        if session_hash is None:
            if config is None:
                return None
            session_hash = str(config["recipient"]["agent_session_sha256"])
        if not matching_nonempty_state(layout, "claude", session_hash):
            return None
        write_receipt(layout, "seal", "failed", "claude-precompact-binding-failed", source_harness="claude", trigger=trigger, failure_code=failure_code)
    return {"decision": "block", "reason": "Already-curated handoff candidates could not be bound to the exact Claude endpoint; compaction was stopped."}


def seal_with_failure_receipt(
    home: Path,
    source_harness: str,
    session_hash: str,
    trigger: str,
    *,
    verify_locked: Callable[[StateLayout, Mapping[str, Any]], None] | None = None,
    reuse_locked: Callable[[StateLayout, Mapping[str, Any]], Mapping[str, Any] | None] | None = None,
    commit_locked: Callable[[StateLayout, Mapping[str, Any], Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    try:
        return seal_candidates(home, source_harness, session_hash, trigger, verify_locked=verify_locked, reuse_locked=reuse_locked, commit_locked=commit_locked)
    except (HandoffError, OSError) as raw_exc:
        exc = raw_exc if isinstance(raw_exc, HandoffError) else HandoffError("STATE_DURABILITY", "compaction binding publication was not durable")
        if exc.code == "GENERATION_REPLACED":
            raise
        layout = StateLayout(home)
        with state_lock(layout):
            if not matching_nonempty_state(layout, source_harness, session_hash):
                raise
            write_receipt(layout, "seal", "failed", "registered-candidate-validation-failed", source_harness=source_harness, trigger=trigger, failure_code=exc.code)
        return {"status": "seal-failed", "had_candidates": True, "reason": "registered-candidate-validation-failed"}


def seal_binding_failure_receipt(
    home: Path,
    static_config: Mapping[str, Any] | None,
    source_harness: str,
    session_hash: str,
    trigger: str,
    exc: HandoffError,
) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        if not matching_nonempty_state(layout, source_harness, session_hash):
            write_receipt(layout, "seal", "empty", "no-registered-candidates-unhealthy-binding", source_harness=source_harness, trigger=trigger, failure_code=exc.code)
            return {"status": "disabled"}
        write_receipt(layout, "seal", "failed", "seal-binding-failed", source_harness=source_harness, trigger=trigger, failure_code=exc.code)
    return {"status": "seal-failed", "had_candidates": True, "reason": "seal-binding-failed"}


def command_seal(args: argparse.Namespace) -> dict[str, Any]:
    if args.source_harness not in SOURCE_HARNESSES or args.trigger not in TRIGGERS:
        raise HandoffError("SEAL_ENUM", "seal source or trigger is invalid")
    home = resolve_home(args.fm_home)
    event = parse_event_stdin()
    supplied = event.get("session_id")
    if supplied is not None and not isinstance(supplied, str):
        raise HandoffError("SESSION_ID", "session_id must be text")
    if args.source_harness == "claude":
        if not supplied:
            raise HandoffError("SESSION_ID", "Claude sealing requires its hook session_id")
        session_hash = hash_session("claude", supplied)
    else:
        raw_session = supplied or os.environ.get("FM_HANDOFF_SESSION_ID") or os.environ.get("PI_SESSION_ID")
        if not raw_session:
            raise HandoffError("PI_SESSION_UNBOUND", "Pi candidate sealing requires PI_SESSION_ID")
        session_hash = hash_session("pi", raw_session)
    try:
        static_config = load_config(home, validate_active_bindings=False)
    except HandoffError as exc:
        return seal_binding_failure_receipt(home, None, args.source_harness, session_hash, args.trigger, exc)
    if not config_enabled(static_config, "sealing_enabled"):
        return {"status": "disabled"}
    assert static_config is not None
    if args.source_harness == "claude":
        expected = source_session_hash(static_config, "claude")
        if session_hash != expected:
            return {"status": "recipient-mismatch"}
    try:
        config = load_config(home)
    except HandoffError as exc:
        return seal_binding_failure_receipt(home, static_config, args.source_harness, session_hash, args.trigger, exc)
    if not config_enabled(config, "sealing_enabled"):
        return {"status": "disabled"}
    if args.source_harness == "pi" and not args.standalone:
        try:
            result = seal_pi_attempt(home, config, session_hash, args.trigger)
        except (HandoffError, OSError) as raw_exc:
            exc = raw_exc if isinstance(raw_exc, HandoffError) else HandoffError("STATE_DURABILITY", "Pi compaction binding publication was not durable")
            return seal_binding_failure_receipt(home, static_config, args.source_harness, session_hash, args.trigger, exc)
    else:
        result = seal_with_failure_receipt(home, args.source_harness, session_hash, args.trigger)
    if args.standalone and result.get("status") in {"sealed", "already-sealed"}:
        mark_compaction(home, normalize_compaction_bindings(result.get("bindings")), True, args.trigger, "standalone-manual-seal")
        deliver_pending(home)
    return result


def compaction_attempt_journal(bindings: Sequence[Mapping[str, str]], status: str, trigger: str, reason: str) -> dict[str, Any]:
    body = {
        "schema": COMPACTION_ATTEMPT_SCHEMA,
        "bindings": normalize_compaction_bindings([dict(item) for item in bindings]),
        "status": status,
        "trigger": trigger,
        "reason": reason,
        "recorded_at": now_utc(),
    }
    return {"attempt_id": "attempt-" + sha256_bytes(canonical_json(body))[:48], **body}


def read_compaction_attempt(path: Path) -> dict[str, Any]:
    data = read_file_bytes(path, max_bytes=16 * 1024)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("COMPACTION_ATTEMPT", "durable compaction attempt result is invalid") from exc
    if (
        not isinstance(value, dict)
        or set(value) != {"attempt_id", "schema", "bindings", "status", "trigger", "reason", "recorded_at"}
        or value.get("schema") != COMPACTION_ATTEMPT_SCHEMA
        or value.get("attempt_id") != path.stem
        or value.get("status") not in {"succeeded", "failed"}
        or value.get("trigger") not in TRIGGERS
        or not isinstance(value.get("reason"), str)
        or not isinstance(value.get("recorded_at"), str)
    ):
        raise HandoffError("COMPACTION_ATTEMPT", "durable compaction attempt result is invalid")
    body = {
        "schema": COMPACTION_ATTEMPT_SCHEMA,
        "bindings": normalize_compaction_bindings(value.get("bindings")),
        "status": value["status"],
        "trigger": value["trigger"],
        "reason": value["reason"],
        "recorded_at": value["recorded_at"],
    }
    normalized = {"attempt_id": "attempt-" + sha256_bytes(canonical_json(body))[:48], **body}
    if normalized["attempt_id"] != path.stem or canonical_json(normalized) != data:
        raise HandoffError("COMPACTION_ATTEMPT", "durable compaction attempt identity is invalid")
    return normalized


def apply_compaction_attempt(layout: StateLayout, config: Mapping[str, Any], journal: Mapping[str, Any]) -> dict[str, Any]:
    verified: list[tuple[str, str]] = []
    for item in journal["bindings"]:
        record_id = item["record_id"]
        _, actual = read_envelope(layout, record_id, config, verify_sources=False)
        queue = read_queue(layout, record_id)
        if actual != item["envelope_sha256"] or queue.get("envelope_sha256") != actual:
            quarantine(layout, record_id, "record-payload-mismatch", expected_sha256=str(queue.get("envelope_sha256", "")), observed_sha256=actual)
            update_queue(layout, record_id, status="quarantined", reason="record-payload-mismatch")
            raise HandoffError("PAYLOAD_MISMATCH", "stable record ID binds changed payload bytes")
        verified.append((record_id, actual))
    status = str(journal["status"])
    queue_reason = "consumer-not-yet-notified" if status == "succeeded" else "source-compaction-failed"
    for record_id, actual in verified:
        if read_queue(layout, record_id).get("status") not in {"acknowledged", "quarantined"}:
            update_queue(layout, record_id, status="pending", reason=queue_reason, compaction=status)
        write_receipt(
            layout,
            "compaction",
            status,
            str(journal["reason"]),
            record_id=record_id,
            envelope_sha256=actual,
            trigger=str(journal["trigger"]),
            attempt_record_count=len(verified),
            recorded_at=str(journal["recorded_at"]),
        )
        failpoint("after-compaction-record-apply")
    return {"status": f"compaction-{status}", "record_ids": [record_id for record_id, _ in verified]}


def retire_invalid_compaction_attempt(layout: StateLayout, path: Path, failure_code: str) -> None:
    try:
        observed_sha = sha256_file(path, max_bytes=MAX_ENVELOPE_BYTES)
    except HandoffError:
        observed_sha = ""
    quarantine(layout, path.stem, "compaction-attempt-record-invalid", failure_code=failure_code, observed_sha256=observed_sha)
    durable_unlink(path)


def replay_compaction_attempts(layout: StateLayout, config: Mapping[str, Any]) -> None:
    for path in sorted(layout.bindings.glob("attempt-*.json")):
        try:
            journal = read_compaction_attempt(path)
        except HandoffError as exc:
            retire_invalid_compaction_attempt(layout, path, exc.code)
            continue
        apply_compaction_attempt(layout, config, journal)
        durable_unlink(path)


def _mark_compaction_locked(
    layout: StateLayout,
    config: Mapping[str, Any],
    bindings: Sequence[Mapping[str, str]],
    succeeded: bool,
    trigger: str,
    reason: str,
) -> dict[str, Any]:
    replay_compaction_attempts(layout, config)
    journal = compaction_attempt_journal(bindings, "succeeded" if succeeded else "failed", trigger, reason)
    path = layout.bindings / f"{journal['attempt_id']}.json"
    atomic_create(path, canonical_json(journal))
    failpoint("after-compaction-attempt-before-queues")
    result = apply_compaction_attempt(layout, config, journal)
    durable_unlink(path)
    return result


def mark_compaction(home: Path, bindings: Sequence[Mapping[str, str]], succeeded: bool, trigger: str, reason: str) -> dict[str, Any]:
    config = load_config(home)
    if config is None:
        return {"status": "disabled"}
    layout = StateLayout(home)
    with state_lock(layout):
        return _mark_compaction_locked(layout, config, bindings, succeeded, trigger, reason)


def mark_pi_compaction(
    home: Path,
    session_hash: str,
    attempt_id: str,
    bindings: Sequence[Mapping[str, str]],
    succeeded: bool,
    trigger: str,
    reason: str,
) -> dict[str, Any]:
    config = load_config(home)
    if config is None:
        return {"status": "disabled"}
    layout = StateLayout(home)
    with state_lock(layout):
        path = pi_compaction_binding_path(layout, session_hash)
        if not path.exists():
            write_receipt(layout, "compaction", "rejected", "pi-attempt-unbound", attempt_id=attempt_id, trigger=trigger)
            return {"status": "outcome-rejected"}
        binding = read_pi_compaction_binding(path)
        claim = current_pi_process_claim()
        normalized = normalize_compaction_bindings([dict(item) for item in bindings])
        if (
            binding["source_session_hash"] != session_hash
            or binding["attempt_id"] != attempt_id
            or binding["bindings"] != normalized
            or binding["trigger"] != trigger
            or not pi_process_claim_matches(binding, claim)
        ):
            write_receipt(layout, "compaction", "rejected", "pi-attempt-authority-mismatch", attempt_id=attempt_id, trigger=trigger)
            return {"status": "outcome-rejected"}
        terminal = "succeeded" if succeeded else "failed"
        if binding["terminal_outcome"] is not None and binding["terminal_outcome"] != terminal:
            write_receipt(layout, "compaction", "rejected", "pi-terminal-outcome-immutable", attempt_id=attempt_id, trigger=trigger)
            return {"status": "outcome-rejected"}
        if binding["terminal_outcome"] is None:
            binding["terminal_outcome"] = terminal
            binding["terminal_reason"] = reason
            binding["terminal_at"] = now_utc()
            atomic_replace(path, canonical_json(binding))
            failpoint("after-pi-terminal-before-queues")
        return apply_pi_terminal_binding(layout, config, binding)


def command_compaction_outcome(args: argparse.Namespace) -> dict[str, Any]:
    home = resolve_home(args.fm_home)
    event = parse_event_stdin()
    trigger = event.get("trigger")
    raw_bindings = event.get("bindings")
    attempt_id = event.get("attempt_id")
    supplied_session = event.get("session_id")
    if raw_bindings is None and isinstance(event.get("record_id"), str) and isinstance(event.get("envelope_sha256"), str):
        raw_bindings = [{"record_id": event["record_id"], "envelope_sha256": event["envelope_sha256"]}]
    try:
        bindings = normalize_compaction_bindings(raw_bindings)
    except HandoffError:
        bindings = []
    if (
        not bindings
        or trigger not in TRIGGERS
        or not isinstance(attempt_id, str)
        or re.fullmatch(r"pi-attempt-[0-9a-f]{48}", attempt_id) is None
        or not isinstance(supplied_session, str)
        or not supplied_session
    ):
        layout = StateLayout(home)
        with state_lock(layout):
            write_receipt(layout, "compaction", "failed", "outcome-without-seal-binding", trigger=str(trigger or "unknown"))
        return {"status": "unbound-outcome"}
    result = mark_pi_compaction(
        home,
        hash_session("pi", supplied_session),
        attempt_id,
        bindings,
        args.outcome == "success",
        trigger,
        str(event.get("reason") or args.outcome),
    )
    if args.outcome == "success" and result.get("status") == "compaction-succeeded":
        raw_deadline = event.get("adapter_deadline_epoch_ms")
        deadline: float | None = None
        if isinstance(raw_deadline, (int, float)):
            deadline = float(raw_deadline) / 1000.0 if float(raw_deadline) <= time.time() * 1000.0 + 15_000.0 else time.time()
        delivery = deliver_pending(home, deadline_epoch=deadline)
        result["delivery"] = delivery.get("status")
    return result


def validate_vault_binding(config: Mapping[str, Any]) -> Path:
    vault = config["vault"]
    raw = Path(vault["path"]).expanduser()
    if path_has_symlink(raw):
        raise HandoffError("VAULT_SYMLINK", "selected Vault path may not use symlinks")
    try:
        path = raw.resolve(strict=True)
        info = path.stat()
    except OSError as exc:
        raise HandoffError("VAULT_UNAVAILABLE", "selected Vault is unavailable") from exc
    if not path.is_dir() or info.st_dev != vault["device"] or info.st_ino != vault["inode"]:
        raise HandoffError("VAULT_IDENTITY", "selected Vault object differs from its reviewed binding")
    return path


def validate_executable(path_text: str, expected_sha: str, code: str) -> Path:
    path = Path(path_text).expanduser()
    if not path.is_absolute() or path_has_symlink(path):
        raise HandoffError(code, "an executable binding is not an absolute no-symlink path")
    try:
        canonical = path.resolve(strict=True)
    except OSError as exc:
        raise HandoffError(code, "an executable binding is unavailable") from exc
    if sha256_file(canonical) != expected_sha:
        raise HandoffError(code, "an executable binding no longer matches its reviewed SHA-256")
    return canonical


def recover_herdr_runtime_snapshots(layout: StateLayout) -> None:
    candidates = sorted(
        path
        for path in layout.bindings.iterdir()
        if re.fullmatch(r"\.herdr-runtime-[a-z0-9_]+", path.name)
    )
    overflow = len(candidates) > MAX_ORPHAN_HERDR_RUNTIMES
    changed = False
    for path in candidates[:MAX_ORPHAN_HERDR_RUNTIMES]:
        if path.is_symlink() or not path.is_dir():
            raise HandoffError("HERDR_RUNTIME_UNSAFE", "orphan Herdr runtime is not a private directory")
        info = path.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise HandoffError("HERDR_RUNTIME_UNSAFE", "orphan Herdr runtime is not private")
        shutil.rmtree(path)
        changed = True
    if changed:
        fsync_directory(layout.bindings)
    if overflow:
        raise HandoffError("HERDR_RUNTIME_BACKPRESSURE", "orphan Herdr runtime recovery exceeded its bounded batch")


@contextmanager
def herdr_runtime(config: Mapping[str, Any], layout: StateLayout) -> Iterator[Path]:
    recipient = config["recipient"]
    source = validate_executable(recipient["herdr_cli_path"], recipient["herdr_cli_sha256"], "HERDR_IDENTITY")
    data = read_file_bytes(source, max_bytes=MAX_HERDR_EXECUTABLE_BYTES, require_private=False)
    if sha256_bytes(data) != recipient["herdr_cli_sha256"]:
        raise HandoffError("HERDR_IDENTITY", "Herdr executable bytes changed before snapshotting")
    recover_herdr_runtime_snapshots(layout)
    snapshot = Path(tempfile.mkdtemp(prefix=".herdr-runtime-", dir=layout.bindings))
    os.chmod(snapshot, 0o700)
    executable = snapshot / source.name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(executable, flags, 0o700)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fchmod(fd, 0o700)
        os.fsync(fd)
    finally:
        os.close(fd)
    fsync_directory(snapshot)
    try:
        yield executable
    finally:
        shutil.rmtree(snapshot, ignore_errors=True)
        fsync_directory(layout.bindings)


def recipient_context_matches(config: Mapping[str, Any], *, require_environment: bool) -> bool:
    recipient = config["recipient"]
    vault = validate_vault_binding(config)
    if require_environment:
        expected = {
            "HERDR_SESSION": recipient["session"],
            "HERDR_WORKSPACE_ID": recipient["workspace_id"],
            "HERDR_TAB_ID": recipient["tab_id"],
            "HERDR_PANE_ID": recipient["pane_id"],
        }
        if any(os.environ.get(key) != value for key, value in expected.items()):
            return False
        try:
            if Path.cwd().resolve(strict=True) != vault:
                return False
        except OSError:
            return False
    return True


def run_bounded(
    command: Sequence[str],
    *,
    timeout: float = 15.0,
    input_bytes: bytes | None = None,
    on_spawn: Callable[[subprocess.Popen[bytes]], None] | None = None,
    release_gate: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    process: subprocess.Popen[bytes] | None = None
    gate_read: int | None = None
    gate_write: int | None = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    stdin_offset = 0
    deadline = time.monotonic() + timeout
    try:
        process_command = list(command)
        pass_fds: tuple[int, ...] = ()
        process_environment = os.environ.copy()
        if release_gate:
            gate_read, gate_write = os.pipe()
            process_command = [
                "/bin/sh",
                "-c",
                'IFS= read -r token <&"$1" || exit 76; [ "$token" = 1 ] || exit 76; shift; exec "$@"',
                "firstmate-release-gate",
                str(gate_read),
                *command,
            ]
            pass_fds = (gate_read,)
            process_environment.pop("ENV", None)
            process_environment.pop("BASH_ENV", None)
            pausepoint("before-release-gate-spawn")
        process = subprocess.Popen(
            process_command,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=process_environment,
            pass_fds=pass_fds,
        )
        if gate_read is not None:
            os.close(gate_read)
            gate_read = None
        if on_spawn is not None:
            on_spawn(process)
        if gate_write is not None:
            os.write(gate_write, b"1\n")
            os.close(gate_write)
            gate_write = None
            if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_EXIT_AFTER_APPLY_SPAWN") == "1":
                os._exit(86)
        assert process.stdout is not None and process.stderr is not None
        for stream, label in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, label)
        if input_bytes is not None:
            assert process.stdin is not None
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            events = selector.select(remaining)
            if not events:
                raise TimeoutError
            for key, _mask in events:
                stream = key.fileobj
                if key.data == "stdin":
                    assert input_bytes is not None
                    try:
                        written = os.write(stream.fileno(), input_bytes[stdin_offset : stdin_offset + 64 * 1024])
                    except BrokenPipeError:
                        written = len(input_bytes) - stdin_offset
                    stdin_offset += written
                    if stdin_offset >= len(input_bytes):
                        selector.unregister(stream)
                        stream.close()
                    continue
                target = stdout if key.data == "stdout" else stderr
                chunk = os.read(stream.fileno(), min(64 * 1024, MAX_CORE_OUTPUT_BYTES + 1 - len(target)))
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                target.extend(chunk)
                if len(target) > MAX_CORE_OUTPUT_BYTES:
                    raise HandoffError("SUBPROCESS_OUTPUT_CAP", "a bound local adapter exceeded its output cap")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        returncode = process.wait(timeout=remaining)
        return subprocess.CompletedProcess(list(command), returncode, bytes(stdout), bytes(stderr))
    except HandoffError:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        raise
    except (OSError, TimeoutError, subprocess.TimeoutExpired) as exc:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        raise HandoffError("SUBPROCESS_FAILED", "a bound local adapter did not complete") from exc
    finally:
        selector.close()
        for descriptor in (gate_read, gate_write):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if process is not None:
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def recipient_agent_matches(config: Mapping[str, Any], agent: Any, *, require_idle: bool) -> tuple[bool, str | None]:
    recipient = config["recipient"]
    if not isinstance(agent, dict):
        return False, None
    exact = (
        agent.get("pane_id") == recipient["pane_id"]
        and agent.get("workspace_id") == recipient["workspace_id"]
        and agent.get("tab_id") == recipient["tab_id"]
        and agent.get("agent") == recipient["agent"]
    )
    session = agent.get("agent_session")
    session_value: str | None = None
    if not isinstance(session, dict) or session.get("agent") != recipient["agent"] or session.get("kind") != "id" or not isinstance(session.get("value"), str):
        exact = False
    else:
        session_value = session["value"]
        if hash_session("claude", session_value) != recipient["agent_session_sha256"]:
            exact = False
    vault = validate_vault_binding(config)
    for key in ("cwd", "foreground_cwd"):
        value = agent.get(key)
        try:
            if not isinstance(value, str) or Path(value).resolve(strict=True) != vault:
                exact = False
        except OSError:
            exact = False
    if not exact:
        return False, None
    status = agent.get("agent_status")
    if status not in {"idle", "working", "blocked", "done"}:
        return False, None
    if require_idle and status not in {"idle", "done"}:
        return False, None
    return True, session_value


def probe_recipient(
    config: Mapping[str, Any],
    layout: StateLayout,
    *,
    require_idle: bool = True,
    herdr: Path | None = None,
) -> tuple[bool, str, Path, str | None]:
    if herdr is None:
        with herdr_runtime(config, layout) as snapshot:
            return probe_recipient(config, layout, require_idle=require_idle, herdr=snapshot)
    recipient = config["recipient"]
    completed = run_bounded([str(herdr), "agent", "get", recipient["pane_id"], "--session", recipient["session"]], timeout=HERDR_PROBE_TIMEOUT_SECONDS)
    if completed.returncode != 0:
        return False, "recipient-unavailable", herdr, None
    try:
        response = json.loads(completed.stdout)
        agent = response["result"]["agent"]
    except (KeyError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        return False, "recipient-ambiguous", herdr, None
    matches, session_value = recipient_agent_matches(config, agent, require_idle=require_idle)
    if not matches:
        if isinstance(agent, dict) and require_idle and agent.get("agent_status") in {"working", "blocked"}:
            return False, "recipient-not-idle", herdr, None
        return False, "recipient-identity-mismatch", herdr, None
    return True, "recipient-ready", herdr, session_value


def supports_atomic_idle_generation_prompt(herdr: Path) -> bool:
    completed = run_bounded([str(herdr), "agent", "prompt", "--help"], timeout=HERDR_CAPABILITY_TIMEOUT_SECONDS)
    if completed.returncode != 0:
        return False
    try:
        help_text = (completed.stdout + b"\n" + completed.stderr).decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return False
    options = set(help_text.replace(",", " ").split())
    return {"--expected-agent-session", "--idempotency-key", "--require-idle"}.issubset(options)


def delivery_idempotency_key(config: Mapping[str, Any], queue: Mapping[str, Any], record_id: str) -> str:
    return sha256_bytes(
        canonical_json(
            {
                "schema": "firstmate.context-handoff.delivery.v1",
                "record_id": record_id,
                "envelope_sha256": queue.get("envelope_sha256"),
                "agent_session_sha256": config["recipient"]["agent_session_sha256"],
            }
        )
    )


def deliver_pending(home: Path, *, deadline_epoch: float | None = None) -> dict[str, Any]:
    config = load_config(home)
    if not config_enabled(config, "delivery_enabled"):
        return {"status": "disabled"}
    assert config is not None
    layout = StateLayout(home)
    with state_lock(layout):
        replay_compaction_attempts(layout, config)
        pending: list[str] = []
        for path in sorted(layout.queue.glob("handoff-*.json")):
            queue = read_queue(layout, path.stem)
            if queue.get("status") == "pending" and queue.get("compaction") == "succeeded":
                pending.append(path.stem)
        if not pending:
            return {"status": "nothing-pending"}
        record_id = pending[0]
        minimum_budget = HERDR_PROBE_TIMEOUT_SECONDS + HERDR_CAPABILITY_TIMEOUT_SECONDS + HERDR_PROMPT_TIMEOUT_SECONDS + DELIVERY_ACK_MARGIN_SECONDS
        if deadline_epoch is not None and deadline_epoch - time.time() < minimum_budget:
            reason = "delivery-deadline-insufficient"
            update_queue(layout, record_id, reason=reason)
            write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
            return {"status": "pending", "reason": reason, "pending_count": len(pending)}
        with herdr_runtime(config, layout) as herdr:
            ready, reason, _herdr, session_value = probe_recipient(config, layout, herdr=herdr)
            if not ready:
                update_queue(layout, record_id, reason=reason, attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1)
                write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
                return {"status": "pending", "reason": reason, "pending_count": len(pending)}
            pausepoint("after-recipient-probe")
            if not session_value or not supports_atomic_idle_generation_prompt(herdr):
                reason = "recipient-atomic-idle-generation-prompt-unsupported"
                update_queue(layout, record_id, reason=reason, attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1)
                write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
                return {"status": "pending", "reason": reason, "pending_count": len(pending)}
            if deadline_epoch is not None and deadline_epoch - time.time() < HERDR_PROMPT_TIMEOUT_SECONDS + DELIVERY_ACK_MARGIN_SECONDS:
                reason = "delivery-deadline-insufficient"
                update_queue(layout, record_id, reason=reason)
                write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
                return {"status": "pending", "reason": reason, "pending_count": len(pending)}
            recipient = config["recipient"]
            queue = read_queue(layout, record_id)
            idempotency_key = delivery_idempotency_key(config, queue, record_id)
            completed = run_bounded(
                [
                    str(herdr),
                    "agent",
                    "prompt",
                    recipient["pane_id"],
                    PROMPT_TEXT,
                    "--expected-agent-session",
                    session_value,
                    "--session",
                    recipient["session"],
                    "--timeout",
                    "2000",
                    "--idempotency-key",
                    idempotency_key,
                    "--require-idle",
                ],
                timeout=HERDR_PROMPT_TIMEOUT_SECONDS,
            )
        prompt_matches = False
        if completed.returncode == 0:
            try:
                response = json.loads(completed.stdout)
                prompt_matches, _ = recipient_agent_matches(config, response["result"]["agent"], require_idle=True)
                acknowledgement = response["result"]["delivery"]
                prompt_matches = (
                    prompt_matches
                    and isinstance(acknowledgement, dict)
                    and acknowledgement.get("accepted") is True
                    and acknowledgement.get("idempotency_key") == idempotency_key
                    and isinstance(acknowledgement.get("duplicate"), bool)
                )
            except (KeyError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
                prompt_matches = False
        if not prompt_matches:
            reason = "recipient-notification-precondition-failed"
            update_queue(layout, record_id, reason=reason, attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1)
            write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
            return {"status": "pending", "reason": reason, "pending_count": len(pending)}
        failpoint("after-recipient-ack-before-queue")
        update_queue(
            layout,
            record_id,
            status="notified",
            reason="recipient-notified",
            attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1,
            notified_at=now_utc(),
            delivery_idempotency_key=idempotency_key,
        )
        write_receipt(layout, "delivery", "notified", "exact-recipient-generation-notified", record_id=record_id, pending_count=len(pending), idempotency_key=idempotency_key)
        return {"status": "notified", "record_id": record_id, "pending_count": len(pending)}


def command_deliver(args: argparse.Namespace) -> dict[str, Any]:
    return deliver_pending(resolve_home(args.fm_home))


def synthetic_boot_identity() -> str:
    return os.environ.get("FM_HANDOFF_TEST_PROCESS_BOOT_ID", "synthetic-boot-1")


def current_linux_boot_id() -> str | None:
    try:
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return boot_id if LINUX_BOOT_ID.fullmatch(boot_id) else None


def current_boot_identity(platform: str) -> str | None:
    if platform == "test" and os.environ.get("FM_HANDOFF_TESTING") == "1":
        return synthetic_boot_identity()
    if platform == "linux":
        return current_linux_boot_id()
    return None


def linux_process_claim(process_group: int) -> dict[str, Any]:
    boot_id = current_linux_boot_id()
    try:
        info = (Path("/proc") / str(process_group) / "stat").read_text(encoding="utf-8")
        close = info.rfind(")")
        fields = info[close + 1 :].split() if close >= 0 else []
        start_time = fields[19]
        recorded_group = int(fields[2])
        recorded_session = int(fields[3])
        owner = (Path("/proc") / str(process_group)).stat().st_uid
    except (OSError, IndexError, ValueError) as exc:
        raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is unavailable") from exc
    if recorded_group != process_group or owner != os.getuid() or not start_time.isdigit() or boot_id is None:
        raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is inconsistent")
    identity = f"linux\0{boot_id}\0{process_group}\0{recorded_session}\0{start_time}\0{owner}"
    return {
        "process_capability_sha256": sha256_bytes(identity.encode("utf-8")),
        "process_generation": int(start_time),
        "process_platform": "linux",
        "process_boot_id": boot_id,
        "process_group": process_group,
        "process_session": recorded_session,
        "process_start_token": start_time,
    }


def darwin_process_claim(process_group: int) -> dict[str, Any]:
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("pbi_flags", ctypes.c_uint32),
            ("pbi_status", ctypes.c_uint32),
            ("pbi_xstatus", ctypes.c_uint32),
            ("pbi_pid", ctypes.c_uint32),
            ("pbi_ppid", ctypes.c_uint32),
            ("pbi_uid", ctypes.c_uint32),
            ("pbi_gid", ctypes.c_uint32),
            ("pbi_ruid", ctypes.c_uint32),
            ("pbi_rgid", ctypes.c_uint32),
            ("pbi_svuid", ctypes.c_uint32),
            ("pbi_svgid", ctypes.c_uint32),
            ("rfu_1", ctypes.c_uint32),
            ("pbi_comm", ctypes.c_char * 16),
            ("pbi_name", ctypes.c_char * 32),
            ("pbi_nfiles", ctypes.c_uint32),
            ("pbi_pgid", ctypes.c_uint32),
            ("pbi_pjobc", ctypes.c_uint32),
            ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32),
            ("pbi_nice", ctypes.c_int32),
            ("pbi_start_tvsec", ctypes.c_uint64),
            ("pbi_start_tvusec", ctypes.c_uint64),
        ]

    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidinfo = library.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        value = ProcBSDInfo()
        size = ctypes.sizeof(value)
        result = proc_pidinfo(process_group, 3, 0, ctypes.byref(value), size)
        session = os.getsid(process_group)
    except (OSError, AttributeError) as exc:
        raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is unavailable") from exc
    if result != size or value.pbi_pgid != process_group or value.pbi_uid != os.getuid() or value.pbi_start_tvusec >= 1_000_000:
        raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is inconsistent")
    start_token = f"{value.pbi_start_tvsec}:{value.pbi_start_tvusec}"
    identity = f"darwin\0{process_group}\0{session}\0{start_token}\0{value.pbi_uid}"
    return {
        "process_capability_sha256": sha256_bytes(identity.encode("utf-8")),
        "process_generation": int(value.pbi_start_tvsec) * 1_000_000 + int(value.pbi_start_tvusec),
        "process_platform": "darwin",
        "process_boot_id": None,
        "process_group": process_group,
        "process_session": session,
        "process_start_token": start_token,
    }


def current_process_claim() -> dict[str, Any]:
    test_value = os.environ.get("FM_HANDOFF_TEST_PROCESS_CAPABILITY")
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and test_value is not None:
        generation_text = os.environ.get("FM_HANDOFF_TEST_PROCESS_GENERATION", "1")
        boot_id = synthetic_boot_identity()
        if not test_value or len(test_value.encode("utf-8")) > 256 or not boot_id or len(boot_id.encode("utf-8")) > 256 or not generation_text.isdigit() or int(generation_text) < 1:
            raise HandoffError("PROCESS_CAPABILITY", "the synthetic hook process capability is invalid")
        return {
            "process_capability_sha256": sha256_bytes(f"test\0{boot_id}\0{test_value}".encode("utf-8")),
            "process_generation": int(generation_text),
            "process_platform": "test",
            "process_boot_id": boot_id,
            "process_group": int(generation_text),
            "process_session": int(generation_text),
            "process_start_token": test_value,
        }
    process_group = os.getpgrp()
    if sys.platform.startswith("linux"):
        return linux_process_claim(process_group)
    if sys.platform == "darwin":
        return darwin_process_claim(process_group)
    raise HandoffError("PROCESS_CAPABILITY", "the current platform lacks a collision-safe Claude process generation")


def linux_pi_process_claim(process_pid: int) -> dict[str, Any]:
    boot_id = current_linux_boot_id()
    try:
        info = (Path("/proc") / str(process_pid) / "stat").read_text(encoding="utf-8")
        close = info.rfind(")")
        fields = info[close + 1 :].split() if close >= 0 else []
        process_group = int(fields[2])
        process_session = int(fields[3])
        start_time = fields[19]
        owner = (Path("/proc") / str(process_pid)).stat().st_uid
    except (OSError, IndexError, ValueError) as exc:
        raise HandoffError("PI_PROCESS_CAPABILITY", "the Pi process capability is unavailable") from exc
    if owner != os.getuid() or not start_time.isdigit() or boot_id is None:
        raise HandoffError("PI_PROCESS_CAPABILITY", "the Pi process capability is inconsistent")
    identity = f"pi-linux\0{boot_id}\0{process_pid}\0{process_group}\0{process_session}\0{start_time}\0{owner}"
    return {
        "process_capability_sha256": sha256_bytes(identity.encode("utf-8")),
        "process_generation": int(start_time),
        "process_platform": "linux",
        "process_boot_id": boot_id,
        "process_pid": process_pid,
        "process_group": process_group,
        "process_session": process_session,
        "process_start_token": start_time,
    }


def darwin_pi_process_claim(process_pid: int) -> dict[str, Any]:
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("pbi_flags", ctypes.c_uint32),
            ("pbi_status", ctypes.c_uint32),
            ("pbi_xstatus", ctypes.c_uint32),
            ("pbi_pid", ctypes.c_uint32),
            ("pbi_ppid", ctypes.c_uint32),
            ("pbi_uid", ctypes.c_uint32),
            ("pbi_gid", ctypes.c_uint32),
            ("pbi_ruid", ctypes.c_uint32),
            ("pbi_rgid", ctypes.c_uint32),
            ("pbi_svuid", ctypes.c_uint32),
            ("pbi_svgid", ctypes.c_uint32),
            ("rfu_1", ctypes.c_uint32),
            ("pbi_comm", ctypes.c_char * 16),
            ("pbi_name", ctypes.c_char * 32),
            ("pbi_nfiles", ctypes.c_uint32),
            ("pbi_pgid", ctypes.c_uint32),
            ("pbi_pjobc", ctypes.c_uint32),
            ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32),
            ("pbi_nice", ctypes.c_int32),
            ("pbi_start_tvsec", ctypes.c_uint64),
            ("pbi_start_tvusec", ctypes.c_uint64),
        ]

    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidinfo = library.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        value = ProcBSDInfo()
        size = ctypes.sizeof(value)
        result = proc_pidinfo(process_pid, 3, 0, ctypes.byref(value), size)
        process_session = os.getsid(process_pid)
    except (OSError, AttributeError) as exc:
        raise HandoffError("PI_PROCESS_CAPABILITY", "the Pi process capability is unavailable") from exc
    if result != size or value.pbi_pid != process_pid or value.pbi_uid != os.getuid() or value.pbi_start_tvusec >= 1_000_000:
        raise HandoffError("PI_PROCESS_CAPABILITY", "the Pi process capability is inconsistent")
    start_token = f"{value.pbi_start_tvsec}:{value.pbi_start_tvusec}"
    identity = f"pi-darwin\0{process_pid}\0{value.pbi_pgid}\0{process_session}\0{start_token}\0{value.pbi_uid}"
    return {
        "process_capability_sha256": sha256_bytes(identity.encode("utf-8")),
        "process_generation": int(value.pbi_start_tvsec) * 1_000_000 + int(value.pbi_start_tvusec),
        "process_platform": "darwin",
        "process_boot_id": None,
        "process_pid": process_pid,
        "process_group": int(value.pbi_pgid),
        "process_session": process_session,
        "process_start_token": start_token,
    }


def current_pi_process_claim() -> dict[str, Any]:
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_PROCESS_CAPABILITY") is not None:
        claim = current_process_claim()
        return {**claim, "process_pid": claim["process_generation"]}
    process_pid = os.getppid()
    if sys.platform.startswith("linux"):
        return linux_pi_process_claim(process_pid)
    if sys.platform == "darwin":
        return darwin_pi_process_claim(process_pid)
    raise HandoffError("PI_PROCESS_CAPABILITY", "the current platform lacks a collision-safe Pi process generation")


def pi_process_binding_owner_is_live(value: Mapping[str, Any]) -> bool:
    platform = value.get("process_platform")
    process_pid = value.get("process_pid")
    if not isinstance(platform, str) or not isinstance(process_pid, int) or process_pid < 1:
        return True
    if process_binding_boot_is_current(value) is False:
        return False
    if platform == "test" and os.environ.get("FM_HANDOFF_TESTING") == "1":
        live = os.environ.get("FM_HANDOFF_TEST_LIVE_PROCESS_CAPABILITY")
        boot_id = value.get("process_boot_id")
        return isinstance(boot_id, str) and bool(live) and value.get("process_capability_sha256") == sha256_bytes(f"test\0{boot_id}\0{live}".encode("utf-8"))
    try:
        claim = linux_pi_process_claim(process_pid) if platform == "linux" else darwin_pi_process_claim(process_pid) if platform == "darwin" else None
    except HandoffError:
        return False
    return claim is not None and pi_process_claim_matches(value, claim)


def current_process_identity() -> tuple[str, int]:
    claim = current_process_claim()
    return str(claim["process_capability_sha256"]), int(claim["process_generation"])


def process_binding_boot_is_current(value: Mapping[str, Any]) -> bool | None:
    platform = value.get("process_platform")
    if not isinstance(platform, str):
        return None
    current_boot = current_boot_identity(platform)
    if current_boot is None:
        return None
    recorded = value.get("process_boot_id")
    return isinstance(recorded, str) and recorded == current_boot


def process_binding_owner_is_live(value: Mapping[str, Any]) -> bool:
    platform = value.get("process_platform")
    process_group = value.get("process_group")
    if not isinstance(platform, str) or not isinstance(process_group, int) or process_group < 1:
        return True
    if process_binding_boot_is_current(value) is False:
        return False
    if platform == "test" and os.environ.get("FM_HANDOFF_TESTING") == "1":
        live = os.environ.get("FM_HANDOFF_TEST_LIVE_PROCESS_CAPABILITY")
        boot_id = value.get("process_boot_id")
        return isinstance(boot_id, str) and bool(live) and value.get("process_capability_sha256") == sha256_bytes(f"test\0{boot_id}\0{live}".encode("utf-8"))
    if platform not in {"linux", "darwin"}:
        return True
    if platform == "linux" and not (Path("/proc") / str(process_group)).exists():
        return False
    if platform == "darwin":
        try:
            os.kill(process_group, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    try:
        claim = linux_process_claim(process_group) if platform == "linux" else darwin_process_claim(process_group) if platform == "darwin" else None
    except HandoffError:
        return True
    return claim is not None and all(claim.get(name) == value.get(name) for name in (
        "process_capability_sha256",
        "process_generation",
        "process_platform",
        "process_boot_id",
        "process_group",
        "process_session",
        "process_start_token",
    ))


def process_generations_are_comparable(existing: Mapping[str, Any], current: Mapping[str, Any]) -> bool:
    platform = current.get("process_platform")
    if existing.get("process_platform") != platform:
        return False
    if platform in {"linux", "test"}:
        boot_id = current.get("process_boot_id")
        return isinstance(boot_id, str) and bool(boot_id) and existing.get("process_boot_id") == boot_id
    return platform == "darwin"


def current_process_capability() -> str:
    return current_process_identity()[0]


def endpoint_binding_key(config: Mapping[str, Any]) -> str:
    recipient = config["recipient"]
    text = "\0".join(str(recipient[key]) for key in ("session", "workspace_id", "tab_id", "pane_id"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:48]


def config_identity(config: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json({key: config.get(key) for key in ("schema", "vault", "recipient", "transaction", "consumer")}))


def bind_claude_session(home: Path, config: Mapping[str, Any], payload: Mapping[str, Any]) -> bool:
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or hash_session("claude", session_id) != config["recipient"]["agent_session_sha256"]:
        return False
    layout = StateLayout(home)
    with state_lock(layout):
        current_config = load_config(home)
        if current_config != config:
            return False
        try:
            recipient_ready, _reason, _herdr, _session_value = probe_recipient(config, layout, require_idle=False)
        except HandoffError:
            return False
        if not recipient_ready:
            return False
        process_claim = current_process_claim()
        capability = str(process_claim["process_capability_sha256"])
        generation = int(process_claim["process_generation"])
        binding_key = endpoint_binding_key(config)
        path = layout.bindings / f"{binding_key}.json"
        if path.exists():
            existing = read_json_file(path, max_bytes=4096)
            existing_generation = existing.get("process_generation", -1) if isinstance(existing, dict) else -1
            existing_capability = existing.get("process_capability_sha256") if isinstance(existing, dict) else None
            if not isinstance(existing_generation, int):
                raise HandoffError("CONSUMER_SESSION", "consumer session generation claim is invalid")
            if existing_capability != capability and (process_binding_owner_is_live(existing) or (process_generations_are_comparable(existing, process_claim) and existing_generation >= generation)):
                return False
            if existing_capability == capability and existing_generation != generation:
                return False
        claim = {
            "schema": BINDING_SCHEMA,
            "binding_key": binding_key,
            "session_hash": config["recipient"]["agent_session_sha256"],
            "process_capability_sha256": capability,
            "process_generation": generation,
            "process_platform": process_claim["process_platform"],
            "process_boot_id": process_claim["process_boot_id"],
            "process_group": process_claim["process_group"],
            "process_session": process_claim["process_session"],
            "process_start_token": process_claim["process_start_token"],
            "config_sha256": config_identity(config),
            "state": "claiming",
            "vault_path": str(config["vault"]["path"]),
            "bound_at": now_utc(),
        }
        atomic_replace(path, canonical_json(claim))
        if not recipient_context_matches(config, require_environment=True):
            return False
        claim["state"] = "active"
        claim["vault_path"] = str(validate_vault_binding(config))
        atomic_replace(path, canonical_json(claim))
        retire_replaced_compaction_bindings_locked(layout, config, capability)
    return True


def require_active_process_binding(
    config: Mapping[str, Any],
    layout: StateLayout,
    *,
    validate_live_vault: bool = True,
) -> None:
    path = layout.bindings / f"{endpoint_binding_key(config)}.json"
    value = read_json_file(path, max_bytes=4096)
    process_claim = current_process_claim()
    capability = str(process_claim["process_capability_sha256"])
    generation = int(process_claim["process_generation"])
    if (
        not isinstance(value, dict)
        or value.get("schema") != BINDING_SCHEMA
        or value.get("session_hash") != config["recipient"]["agent_session_sha256"]
        or value.get("process_capability_sha256") != capability
        or value.get("process_generation") != generation
        or any(value.get(name) != process_claim[name] for name in ("process_platform", "process_boot_id", "process_group", "process_session", "process_start_token"))
        or value.get("config_sha256") != config_identity(config)
        or value.get("state") != "active"
        or value.get("vault_path") != (str(validate_vault_binding(config)) if validate_live_vault else str(config["vault"]["path"]))
    ):
        raise HandoffError("CONSUMER_SESSION", "consumer session generation is not bound")


def require_consumer_binding(home: Path, config: Mapping[str, Any]) -> None:
    if not config_enabled(config, "consumer_enabled"):
        raise HandoffError("CONSUMER_DISABLED", "the Claude handoff consumer is disabled")
    if not recipient_context_matches(config, require_environment=True):
        raise HandoffError("CONSUMER_ENDPOINT", "consumer process is not the exact authorized Herdr endpoint and Vault")
    layout = StateLayout(home)
    recipient_ready, _reason, _herdr, _session_value = probe_recipient(config, layout, require_idle=False)
    if not recipient_ready:
        raise HandoffError("CONSUMER_SESSION", "consumer process is not bound to the exact live Claude session generation")
    require_active_process_binding(config, layout)


def compaction_binding_path(layout: StateLayout, config: Mapping[str, Any], capability: str | None = None) -> Path:
    process_capability = capability or current_process_capability()
    if not HEX64.fullmatch(process_capability):
        raise HandoffError("PROCESS_CAPABILITY", "Claude compaction capability is invalid")
    return layout.bindings / f"compaction-{endpoint_binding_key(config)}-{process_capability}.json"


def session_compaction_bindings_locked(
    layout: StateLayout,
    session_hash: str,
) -> list[tuple[Path, dict[str, Any], list[dict[str, str]]]]:
    matches: list[tuple[Path, dict[str, Any], list[dict[str, str]]]] = []
    paths: list[Path] = []
    for path in sorted(layout.bindings.glob("compaction-*-*.json")):
        try:
            value = read_compaction_binding_header(path)
        except HandoffError:
            continue
        if value["session_hash"] == session_hash:
            paths.append(path)
    if len(paths) > MAX_COMPACTION_RECORDS:
        raise HandoffError("COMPACTION_BACKPRESSURE", "durable Claude compaction bindings exceed their session bound")
    owned_records: set[str] = set()
    for path in paths:
        value, bindings = read_compaction_binding_locked(layout, path)
        record_ids = {item["record_id"] for item in bindings}
        if owned_records & record_ids:
            raise HandoffError("COMPACTION_BINDING", "multiple durable Claude attempts own the same sealed record")
        owned_records.update(record_ids)
        if value["session_hash"] == session_hash:
            matches.append((path, value, bindings))
    return matches


def read_compaction_binding_header(path: Path) -> dict[str, Any]:
    value = read_json_file(path, max_bytes=16 * 1024)
    binding_key = value.get("binding_key") if isinstance(value, dict) else None
    bound_session = value.get("session_hash") if isinstance(value, dict) else None
    bound_capability = value.get("process_capability_sha256") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("schema") != COMPACTION_BINDING_SCHEMA
        or not isinstance(binding_key, str)
        or not re.fullmatch(r"[0-9a-f]{48}", binding_key)
        or not isinstance(bound_session, str)
        or not HEX64.fullmatch(bound_session)
        or not isinstance(bound_capability, str)
        or not HEX64.fullmatch(bound_capability)
        or not HEX64.fullmatch(str(value.get("config_sha256", "")))
        or path.name != f"compaction-{binding_key}-{bound_capability}.json"
        or value.get("trigger") not in TRIGGERS
        or not valid_compaction_terminal_tuple(value)
    ):
        raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding is invalid")
    return value


def valid_compaction_terminal_tuple(value: Mapping[str, Any]) -> bool:
    fields = {"terminal_outcome", "terminal_reason", "terminal_at"}
    if not fields.intersection(value):
        return True
    outcome = value.get("terminal_outcome")
    reason = value.get("terminal_reason")
    recorded_at = value.get("terminal_at")
    if outcome not in {"succeeded", "failed"} or not isinstance(reason, str) or not reason or len(reason.encode("utf-8")) > 512 or not isinstance(recorded_at, str) or len(recorded_at) > 64:
        return False
    try:
        parsed = datetime.fromisoformat(recorded_at.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def read_compaction_binding_locked(
    layout: StateLayout,
    path: Path,
    *,
    config: Mapping[str, Any] | None = None,
    session_hash: str | None = None,
    process_capability: str | None = None,
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    value = read_compaction_binding_header(path)
    binding_key = str(value["binding_key"])
    bound_session = str(value["session_hash"])
    bound_capability = str(value["process_capability_sha256"])
    if session_hash is not None and bound_session != session_hash:
        raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding belongs to another hook session")
    if process_capability is not None and bound_capability != process_capability:
        raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding belongs to another process capability")
    if config is not None and (binding_key != endpoint_binding_key(config) or value.get("config_sha256") != config_identity(config)):
        raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding no longer matches its bound configuration")
    raw_bindings = value.get("bindings")
    if raw_bindings is None and isinstance(value.get("record_id"), str) and isinstance(value.get("envelope_sha256"), str):
        raw_bindings = [{"record_id": value["record_id"], "envelope_sha256": value["envelope_sha256"]}]
    bindings = normalize_compaction_bindings(raw_bindings)
    for item in bindings:
        envelope, actual = read_envelope(layout, item["record_id"], config or {}, verify_sources=False)
        if actual != item["envelope_sha256"] or envelope.get("source_harness") != "claude" or envelope.get("source_session_hash") != bound_session:
            raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding no longer matches its exact envelope")
    return value, bindings


def reuse_compaction_binding_locked(layout: StateLayout, config: Mapping[str, Any]) -> dict[str, Any] | None:
    matches = session_compaction_bindings_locked(layout, config["recipient"]["agent_session_sha256"])
    if not matches:
        return None
    if len(matches) != 1:
        raise HandoffError("COMPACTION_BINDING", "Claude hook session owns multiple unresolved compaction attempts")
    path, value, bindings = matches[0]
    if value.get("terminal_outcome") is not None:
        apply_terminal_compaction_binding_locked(layout, path, value, bindings)
        return None
    if value["process_capability_sha256"] != current_process_capability():
        raise HandoffError("GENERATION_REPLACED", "another Claude process generation has an unresolved compaction attempt")
    return compaction_attempt_result("already-sealed", bindings)


def retire_replaced_compaction_bindings_locked(layout: StateLayout, config: Mapping[str, Any], replacement_capability: str) -> None:
    session_hash = str(config["recipient"]["agent_session_sha256"])
    binding_prefix = f"compaction-{endpoint_binding_key(config)}-"
    for path in sorted(layout.bindings.glob("compaction-*-*.json")):
        try:
            header = read_compaction_binding_header(path)
        except HandoffError as exc:
            if path.name.startswith(binding_prefix):
                retire_invalid_compaction_binding(layout, path, exc.code)
            continue
        if header["session_hash"] != session_hash:
            continue
        try:
            value, bindings = read_compaction_binding_locked(layout, path)
        except HandoffError as exc:
            retire_invalid_compaction_binding(layout, path, exc.code)
            continue
        if value["process_capability_sha256"] == replacement_capability:
            continue
        if value.get("terminal_outcome") is not None:
            apply_terminal_compaction_binding_locked(layout, path, value, bindings)
            continue
        retirement = {
            "schema": COMPACTION_RETIREMENT_SCHEMA,
            "reason": "dead-process-capability-retired",
            "replacement_process_capability_sha256": replacement_capability,
            "binding": value,
        }
        atomic_create(layout.quarantine / f"retired-{path.name}", canonical_json(retirement))
        durable_unlink(path)


def retire_invalid_compaction_binding(layout: StateLayout, path: Path, failure_code: str) -> None:
    try:
        observed_sha = sha256_file(path, max_bytes=16 * 1024)
    except HandoffError:
        observed_sha = ""
    quarantine(layout, path.stem, "compaction-binding-record-invalid", failure_code=failure_code, observed_sha256=observed_sha)
    durable_unlink(path)


def durable_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    fsync_directory(path.parent)


def _persist_compaction_binding_locked(layout: StateLayout, config: Mapping[str, Any], result: Mapping[str, Any], trigger: str) -> None:
    require_active_process_binding(config, layout)
    path = compaction_binding_path(layout, config)
    if result.get("status") not in {"sealed", "already-sealed"}:
        durable_unlink(path)
        return
    bindings = normalize_compaction_bindings(result.get("bindings"))
    for item in bindings:
        envelope, actual = read_envelope(layout, item["record_id"], config, verify_sources=False)
        if actual != item["envelope_sha256"] or envelope.get("source_harness") != "claude" or envelope.get("source_session_hash") != config["recipient"]["agent_session_sha256"]:
            raise HandoffError("COMPACTION_BINDING", "Claude PreCompact seal binding is inconsistent")
    existing = session_compaction_bindings_locked(layout, config["recipient"]["agent_session_sha256"])
    if existing:
        if len(existing) != 1 or existing[0][1]["process_capability_sha256"] != current_process_capability():
            raise HandoffError("GENERATION_REPLACED", "another Claude process generation has an unresolved compaction attempt")
        existing_value = existing[0][1]
        existing_bindings = existing[0][2]
        if existing_bindings != bindings or existing_value.get("trigger") != trigger:
            raise HandoffError("COMPACTION_BINDING", "current Claude process generation already binds another compaction attempt")
        return
    binding = {
        "schema": COMPACTION_BINDING_SCHEMA,
        "binding_key": endpoint_binding_key(config),
        "session_hash": config["recipient"]["agent_session_sha256"],
        "process_capability_sha256": current_process_capability(),
        "config_sha256": config_identity(config),
        "bindings": bindings,
        "trigger": trigger,
        "bound_at": now_utc(),
    }
    failpoint("before-compaction-binding-publication")
    atomic_replace(path, canonical_json(binding))


def load_compaction_binding(home: Path, config: Mapping[str, Any]) -> tuple[list[dict[str, str]], str] | None:
    layout = StateLayout(home)
    with state_lock(layout):
        path = compaction_binding_path(layout, config)
        if not path.exists():
            return None
        value, bindings = read_compaction_binding_locked(
            layout,
            path,
            config=config,
            session_hash=config["recipient"]["agent_session_sha256"],
            process_capability=current_process_capability(),
        )
        return bindings, str(value["trigger"])


def clear_compaction_binding(home: Path, config: Mapping[str, Any]) -> None:
    layout = StateLayout(home)
    with state_lock(layout):
        durable_unlink(compaction_binding_path(layout, config))


def terminal_compaction_binding_locked(layout: StateLayout, session_hash: str) -> tuple[Path, dict[str, Any], list[dict[str, str]]] | None:
    capability = current_process_capability()
    matches: list[tuple[Path, dict[str, Any], list[dict[str, str]]]] = []
    for path, value, bindings in session_compaction_bindings_locked(layout, session_hash):
        if value["process_capability_sha256"] == capability:
            matches.append((path, value, bindings))
    if len(matches) > 1:
        raise HandoffError("COMPACTION_BINDING", "Claude terminal event matches multiple durable attempts")
    return matches[0] if matches else None


def apply_terminal_compaction_binding_locked(
    layout: StateLayout,
    path: Path,
    value: Mapping[str, Any],
    bindings: Sequence[Mapping[str, str]],
) -> dict[str, Any]:
    terminal = value.get("terminal_outcome")
    if terminal not in {"succeeded", "failed"} or not isinstance(value.get("terminal_reason"), str):
        raise HandoffError("COMPACTION_BINDING", "durable Claude compaction outcome is invalid")
    failpoint("after-compaction-terminal-before-queues")
    result = _mark_compaction_locked(
        layout,
        {},
        bindings,
        terminal == "succeeded",
        str(value["trigger"]),
        str(value["terminal_reason"]),
    )
    durable_unlink(path)
    return result


def replay_terminal_compaction_bindings_locked(layout: StateLayout, session_hash: str) -> None:
    owned_records: set[str] = set()
    for path, value, bindings in session_compaction_bindings_locked(layout, session_hash):
        record_ids = {item["record_id"] for item in bindings}
        if owned_records & record_ids:
            raise HandoffError("COMPACTION_BINDING", "multiple durable Claude attempts own the same sealed record")
        owned_records.update(record_ids)
        if value.get("terminal_outcome") is not None:
            apply_terminal_compaction_binding_locked(layout, path, value, bindings)


def consume_compaction_binding(home: Path, session_hash: str, succeeded: bool, reason: str) -> dict[str, Any] | None:
    layout = StateLayout(home)
    with state_lock(layout):
        session_matches = session_compaction_bindings_locked(layout, session_hash)
        terminal_matches = [item for item in session_matches if item[1].get("terminal_outcome") is not None]
        if len(terminal_matches) > 1:
            raise HandoffError("COMPACTION_BINDING", "Claude terminal recovery matches multiple durable attempts")
        if terminal_matches:
            return apply_terminal_compaction_binding_locked(layout, *terminal_matches[0])
        located = terminal_compaction_binding_locked(layout, session_hash)
        if located is None:
            return None
        path, value, bindings = located
        terminal = value.get("terminal_outcome")
        if terminal is None:
            terminal = "succeeded" if succeeded else "failed"
            value = {
                **value,
                "terminal_outcome": terminal,
                "terminal_reason": reason,
                "terminal_at": now_utc(),
            }
            atomic_replace(path, canonical_json(value))
        return apply_terminal_compaction_binding_locked(layout, path, value, bindings)


def hook_output(value: Mapping[str, Any] | None = None, *, stderr: bool = False) -> None:
    if value:
        stream = sys.stderr if stderr else sys.stdout
        stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        stream.write("\n")


def command_claude_hook(args: argparse.Namespace) -> dict[str, Any] | None:
    home = resolve_home(args.fm_home)
    payload = parse_event_stdin()
    event_name = payload.get("hook_event_name")
    precompact_config: dict[str, Any] | None = None
    precompact_trigger = "manual" if payload.get("trigger") == "manual" else "threshold"
    if event_name == "PreCompact":
        session_id = payload.get("session_id")
        try:
            precompact_config = load_config(home, validate_active_bindings=False)
        except HandoffError as exc:
            if not isinstance(session_id, str):
                return None
            return block_failed_claude_precompact(home, None, precompact_trigger, exc.code, session_hash=hash_session("claude", session_id))
        if precompact_config is None or not config_enabled(precompact_config, "sealing_enabled"):
            return None
        if not isinstance(session_id, str) or hash_session("claude", session_id) != precompact_config["recipient"]["agent_session_sha256"]:
            return None
    if event_name in {"PostCompact", "StopFailure"}:
        session_id = payload.get("session_id")
        if not isinstance(session_id, str):
            return None
        consume_compaction_binding(
            home,
            hash_session("claude", session_id),
            event_name == "PostCompact",
            "claude-post-compact" if event_name == "PostCompact" else "claude-provider-failure",
        )
        return None
    else:
        try:
            config = load_config(home)
        except HandoffError as exc:
            if event_name == "PreToolUse":
                return guard_deny("The context handoff safety boundary is unhealthy; mutation was denied.")
            if precompact_config is not None:
                return block_failed_claude_precompact(home, precompact_config, precompact_trigger, exc.code)
            raise
    if config is None:
        return None
    if event_name == "PreToolUse":
        return guard_decision(home, config, payload)
    if event_name not in {"PostCompact", "StopFailure"} and not config_enabled(config, "sealing_enabled") and not config_enabled(config, "consumer_enabled"):
        return None
    if event_name == "SessionStart":
        if not config_enabled(config, "consumer_enabled") or not bind_claude_session(home, config, payload):
            return None
        layout = StateLayout(home)
        with state_lock(layout):
            locked_config = current_consumer_config(home)
            pending = len(claimable_records_locked(home, locked_config, layout, suppress_invalid=True))
        if pending:
            output: dict[str, Any] = {"systemMessage": f"Curated context handoff: {pending} bounded record(s) await Claude curation."}
            if payload.get("source") == "compact":
                output["hookSpecificOutput"] = {
                    "hookEventName": "SessionStart",
                    "additionalContext": "Bounded curated handoff records are pending. Use /firstmate-context-handoff:consume; do not treat the generated compact summary as knowledge.",
                }
            return output
        return None
    if event_name == "PreCompact":
        try:
            bound = bind_claude_session(home, config, payload)
        except HandoffError as exc:
            bound = False
            failure_code = exc.code
        else:
            failure_code = "CONSUMER_ENDPOINT"
        if not bound:
            return block_failed_claude_precompact(home, config, precompact_trigger, failure_code)

        def verify_live_generation(layout: StateLayout, locked_config: Mapping[str, Any]) -> None:
            if locked_config != config:
                raise HandoffError("GENERATION_REPLACED", "the exact Claude endpoint changed before sealing")
            try:
                require_active_process_binding(config, layout)
                recipient_ready, _reason, _herdr, _session_value = probe_recipient(config, layout, require_idle=False)
            except HandoffError as generation_exc:
                raise HandoffError("GENERATION_REPLACED", "the exact live Claude generation could not be revalidated") from generation_exc
            if not recipient_ready:
                raise HandoffError("GENERATION_REPLACED", "the exact live Claude generation was replaced before sealing")

        def commit_live_binding(layout: StateLayout, locked_config: Mapping[str, Any], sealed: Mapping[str, Any]) -> None:
            _persist_compaction_binding_locked(layout, locked_config, sealed, precompact_trigger)

        def reuse_live_binding(layout: StateLayout, locked_config: Mapping[str, Any]) -> Mapping[str, Any] | None:
            return reuse_compaction_binding_locked(layout, locked_config)

        pausepoint("before-compaction-binding-lock")
        try:
            result = seal_with_failure_receipt(
                home,
                "claude",
                config["recipient"]["agent_session_sha256"],
                precompact_trigger,
                verify_locked=verify_live_generation,
                reuse_locked=reuse_live_binding,
                commit_locked=commit_live_binding,
            )
        except HandoffError as exc:
            return block_failed_claude_precompact(home, config, precompact_trigger, exc.code)
        if result.get("status") == "seal-failed" and result.get("had_candidates"):
            return {"decision": "block", "reason": "Already-curated handoff candidates could not be sealed durably; compaction was stopped."}
        return None
    return None


def deterministic_operation_id(record_id: str) -> str:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return "handoff-" + hashlib.sha256(record_id.encode("ascii")).hexdigest()[:32]


def approval_records(layout: StateLayout, record_id: str) -> list[Path]:
    directory = layout.approvals / record_id
    if not directory.exists():
        return []
    ensure_private_directory(directory)
    return sorted(directory.glob("*.json"))


def guard_deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def validate_guard_tool_authority(
    config: Mapping[str, Any],
    layout: StateLayout,
    tool_name: str,
    tool_input: Any,
) -> None:
    if not isinstance(tool_input, dict):
        raise HandoffError("GUARD_INPUT", "mutation-capable MCP tool input must be an object")
    short_name = tool_name.removeprefix("mcp__firstmate-context-handoff__")
    if short_name == "register_curated_candidate":
        if not config_enabled(config, "registration_enabled"):
            raise HandoffError("REGISTER_DISABLED", "candidate registration is disabled")
        statement = tool_input.get("statement")
        source_record = tool_input.get("source_record")
        source_sha = tool_input.get("source_sha256")
        supersedes = tool_input.get("supersedes")
        if not isinstance(statement, str) or not isinstance(source_record, str) or not isinstance(source_sha, str) or not isinstance(supersedes, list):
            raise HandoffError("GUARD_INPUT", "candidate registration input is incomplete")
        validate_statement(statement)
        validate_source_path(config, source_record, source_sha)
        eligibility_contract(
            config,
            source_record=source_record,
            source_sha256=source_sha,
            statement=statement,
            kind=str(tool_input.get("kind", "")),
            confidence=str(tool_input.get("confidence", "")),
            sphere=str(tool_input.get("sphere", "")),
            sensitivity_class=str(tool_input.get("sensitivity_class", "")),
            provider_class=str(tool_input.get("provider_class", "")),
            supersedes=[str(value) for value in supersedes],
        )
        return
    record_id = tool_input.get("record_id")
    if not isinstance(record_id, str) or not RECORD_ID.fullmatch(record_id):
        raise HandoffError("GUARD_INPUT", "mutation-capable handoff input lacks a valid record ID")
    envelope, digest = read_envelope(layout, record_id, config)
    queue = read_queue(layout, record_id)
    if queue.get("envelope_sha256") != digest or any(item["provider_class"] not in config["allowed_provider_classes"] for item in envelope["items"]):
        raise HandoffError("PAYLOAD_MISMATCH", "guard record authority no longer matches the durable envelope")
    require_active_save_authority(layout, record_id, queue)
    if short_name == "prepare_handoff_save":
        duplicate_check = tool_input.get("duplicate_check")
        searched = duplicate_check.get("searched_paths") if isinstance(duplicate_check, dict) else None
        if not isinstance(duplicate_check, dict) or duplicate_check.get("result") != "no-match" or not isinstance(searched, list) or not searched or len(searched) > 5 or not all(safe_relative_path(path) for path in searched):
            raise HandoffError("DUPLICATE_CHECK", "Save guard requires the current bounded duplicate-search authority")
        normalized = validate_save_bundle(config, record_id, tool_input.get("bundle"))
        reviewed_paths = [write["path"] for write in normalized["writes"]]
        content_sensitivity = tool_input.get("content_sensitivity")
        if not isinstance(content_sensitivity, dict) or set(content_sensitivity) != set(reviewed_paths) or any(value != ELIGIBLE_SENSITIVITY_CLASS for value in content_sensitivity.values()):
            raise HandoffError("SENSITIVITY_CLASSIFICATION", "Save guard requires current ordinary-context authority for every path")
        return
    if short_name == "record_curation_disposition":
        disposition = tool_input.get("disposition")
        rationale = tool_input.get("rationale")
        if disposition not in DISPOSITIONS or not isinstance(rationale, str) or not 1 <= len(rationale) <= 500:
            raise HandoffError("DISPOSITION_INPUT", "curation disposition guard input is invalid")
        validate_statement(rationale)
        return
    if short_name != "commit_handoff_save":
        raise HandoffError("MCP_TOOL", "unknown mutation-capable handoff tool")
    approval_sha = tool_input.get("approval_sha256")
    if not isinstance(approval_sha, str) or not HEX64.fullmatch(approval_sha):
        raise HandoffError("GUARD_INPUT", "Save commit lacks a valid approval binding")
    approval = load_approval(layout, record_id, approval_sha)
    require_active_save_authority(layout, record_id, queue, approval)
    bundle_path = Path(str(approval.get("bundle_path", "")))
    if approval.get("dependency_manifest_sha256") != validate_transaction_manifest(config["transaction"])[2] or sha256_file(bundle_path, max_bytes=MAX_TRANSACTION_BUNDLE_BYTES) != approval.get("bundle_file_sha256"):
        raise HandoffError("SAVE_AUTHORITY_REVOKED", "Save commit approval no longer binds current reviewed bytes")


def heal_guard_terminal_retry(
    home: Path,
    config: Mapping[str, Any],
    layout: StateLayout,
    tool_name: str,
    tool_input: Any,
) -> bool:
    if not isinstance(tool_input, dict):
        return False
    record_id = tool_input.get("record_id")
    if not isinstance(record_id, str) or not RECORD_ID.fullmatch(record_id):
        return False
    short_name = tool_name.removeprefix("mcp__firstmate-context-handoff__")
    completed = find_completed_approval(home, config, record_id)
    if completed is not None:
        return short_name != "commit_handoff_save" or tool_input.get("approval_sha256") == completed.get("approval_sha256")
    disposition_path = disposition_path_for(layout, record_id)
    if short_name != "record_curation_disposition" or not disposition_path.exists():
        return False
    value = read_json_file(disposition_path, max_bytes=16 * 1024)
    if (
        not isinstance(value, dict)
        or value.get("disposition") != tool_input.get("disposition")
        or value.get("rationale") != tool_input.get("rationale")
    ):
        return False
    return recover_terminal_disposition_ack(layout, record_id)


def guard_decision(home: Path, config: Mapping[str, Any], payload: Mapping[str, Any]) -> dict[str, Any] | None:
    if not config_enabled(config, "consumer_enabled"):
        return None
    tool_name = str(payload.get("tool_name", ""))
    if tool_name in {"Write", "Edit", "NotebookEdit"}:
        return guard_deny("Direct file mutation is disabled for this Vault curator; use the bounded handoff transaction consumer.")
    if tool_name in {"Bash", "PowerShell"}:
        return guard_deny("Shell mutation is denied; Save apply is available only through the serialized handoff MCP commit.")
    lowered = tool_name.lower()
    if MUTATING_TOOL_NAMES.search(tool_name):
        return guard_deny("Delete, move, Git, installation, credential, and other mutation tools are not authorized for this Vault curator.")
    if lowered.startswith("mcp__") and tool_name not in HANDOFF_MCP_TOOLS:
        return guard_deny("Unrelated MCP tools are not authorized to mutate this Vault or outside paths.")
    if tool_name in HANDOFF_MCP_TOOLS - {"mcp__firstmate-context-handoff__next_curated_handoff"}:
        session_id = payload.get("session_id")
        try:
            if not isinstance(session_id, str) or hash_session("claude", session_id) != config["recipient"]["agent_session_sha256"]:
                raise HandoffError("CONSUMER_SESSION", "hook session is not the configured Claude generation")
            layout = StateLayout(home)
            with state_lock(layout):
                current_config = current_consumer_config(home)
                if current_config != config:
                    raise HandoffError("CONFIG_CHANGED", "guard configuration changed before authority validation")
                require_consumer_binding(home, current_config)
                tool_input = payload.get("tool_input")
                if not heal_guard_terminal_retry(home, current_config, layout, tool_name, tool_input):
                    validate_guard_tool_authority(current_config, layout, tool_name, tool_input)
        except HandoffError:
            return guard_deny("The mutation-capable handoff tool is not bound to current source, queue, approval, hook, and recipient authority.")
    return None


def validate_transaction_manifest(transaction: Mapping[str, Any]) -> tuple[Path, dict[str, str], str, str, str]:
    root_value = transaction.get("dependency_root")
    manifest = transaction.get("dependency_manifest")
    if not isinstance(root_value, str) or not root_value or not isinstance(manifest, list) or not manifest:
        raise HandoffError("CONFIG_TRANSACTION", "transaction dependency manifest is required")
    root = Path(root_value).expanduser()
    if not root.is_absolute() or path_has_symlink(root):
        raise HandoffError("CONFIG_TRANSACTION", "transaction dependency root must be an absolute no-symlink directory")
    try:
        root = root.resolve(strict=True)
    except OSError as exc:
        raise HandoffError("CONFIG_TRANSACTION", "transaction dependency root is unavailable") from exc
    if not root.is_dir():
        raise HandoffError("CONFIG_TRANSACTION", "transaction dependency root is not a directory")
    entries: dict[str, str] = {}
    normalized: list[dict[str, str]] = []
    for item in manifest:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            raise HandoffError("CONFIG_TRANSACTION", "transaction dependency manifest entry is invalid")
        relative = item.get("path")
        digest = item.get("sha256")
        if not safe_relative_path(relative) or not isinstance(digest, str) or not HEX64.fullmatch(digest) or relative in entries:
            raise HandoffError("CONFIG_TRANSACTION", "transaction dependency manifest entry is invalid")
        entries[str(relative)] = digest
        normalized.append({"path": str(relative), "sha256": digest})
    core = Path(str(transaction.get("core_path", ""))).expanduser()
    module = Path(str(transaction.get("module_path", ""))).expanduser()
    if not core.is_absolute() or not module.is_absolute() or path_has_symlink(core) or path_has_symlink(module):
        raise HandoffError("CONFIG_TRANSACTION", "transaction entrypoint and module must be absolute no-symlink paths")
    try:
        core_relative = core.resolve(strict=True).relative_to(root).as_posix()
        module_relative = module.resolve(strict=True).relative_to(root).as_posix()
    except (OSError, ValueError) as exc:
        raise HandoffError("CONFIG_TRANSACTION", "transaction entrypoint and module must be inside the dependency root") from exc
    required = {core_relative}
    if not (root / core_relative).is_file() or not (root / module_relative).is_file():
        raise HandoffError("CONFIG_TRANSACTION", "transaction entrypoint or module is not a regular file")
    if core_relative == module_relative:
        if os.environ.get("FM_HANDOFF_TESTING") != "1" or core.resolve(strict=True) != SYNTHETIC_TRANSACTION_FIXTURE.resolve(strict=True):
            raise HandoffError("CONFIG_TRANSACTION", "same-file transaction authority is limited to the tracked synthetic fixture")
    else:
        if core_relative != "scripts/claude-obsidian.py" or module_relative != "claude_obsidian/transaction.py":
            raise HandoffError("CONFIG_TRANSACTION", "production transaction paths must bind the installed claude-obsidian entrypoint and package")
        module_root = (root / module_relative).parent
        if module_root.name != "claude_obsidian" or not (module_root / "__init__.py").is_file() or not (module_root / "cli.py").is_file():
            raise HandoffError("CONFIG_TRANSACTION", "transaction package does not expose the pinned CLI closure")
        for path in sorted(module_root.rglob("*.py")):
            if path.is_symlink() or not path.is_file():
                raise HandoffError("CONFIG_TRANSACTION", "transaction package contains an unsafe Python dependency")
            required.add(path.relative_to(root).as_posix())
    if set(entries) != required:
        raise HandoffError("CONFIG_TRANSACTION", "transaction dependency manifest must cover the complete executable package")
    if entries.get(core_relative) != transaction.get("core_sha256") or entries.get(module_relative) != transaction.get("module_sha256"):
        raise HandoffError("CONFIG_TRANSACTION", "transaction entrypoint or module hash differs from its dependency manifest")
    normalized.sort(key=lambda item: item["path"])
    return root, entries, sha256_bytes(canonical_json(normalized)), core_relative, module_relative


def recover_transaction_runtime_snapshots(layout: StateLayout) -> None:
    candidates = sorted(
        path
        for path in layout.bindings.iterdir()
        if re.fullmatch(r"\.transaction-runtime-[a-z0-9_]+", path.name)
    )
    overflow = len(candidates) > MAX_ORPHAN_TRANSACTION_RUNTIMES
    changed = False
    for path in candidates[:MAX_ORPHAN_TRANSACTION_RUNTIMES]:
        if path.is_symlink() or not path.is_dir():
            raise HandoffError("TRANSACTION_RUNTIME_UNSAFE", "orphan transaction runtime is not a private directory")
        info = path.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise HandoffError("TRANSACTION_RUNTIME_UNSAFE", "orphan transaction runtime is not private")
        shutil.rmtree(path)
        changed = True
    if changed:
        fsync_directory(layout.bindings)
    if overflow:
        raise HandoffError("TRANSACTION_RUNTIME_BACKPRESSURE", "orphan transaction runtime recovery exceeded its bounded batch")


@contextmanager
def transaction_runtime(config: Mapping[str, Any], layout: StateLayout) -> Iterator[tuple[list[str], str]]:
    transaction = config["transaction"]
    python_path = Path(transaction["python_path"])
    if not python_path.is_absolute() or path_has_symlink(python_path) or not python_path.resolve(strict=True).is_file():
        raise HandoffError("PYTHON_IDENTITY", "transaction interpreter binding is unavailable")
    root, entries, manifest_sha, core_relative, module_relative = validate_transaction_manifest(transaction)
    recover_transaction_runtime_snapshots(layout)
    snapshot = Path(tempfile.mkdtemp(prefix=".transaction-runtime-", dir=layout.bindings))
    os.chmod(snapshot, 0o700)
    total = 0
    try:
        for relative, expected_sha in sorted(entries.items()):
            source = root.joinpath(*PurePosixPath(relative).parts)
            data = read_file_bytes(source, max_bytes=MAX_TRANSACTION_DEPENDENCY_BYTES, require_private=False)
            total += len(data)
            if total > MAX_TRANSACTION_DEPENDENCY_BYTES or sha256_bytes(data) != expected_sha:
                raise HandoffError("TRANSACTION_DEPENDENCY_IDENTITY", "transaction dependency bytes no longer match the reviewed manifest")
            target = snapshot.joinpath(*PurePosixPath(relative).parts)
            ensure_private_directory(target.parent)
            atomic_create(target, data)
        if core_relative == module_relative:
            command = [str(python_path.resolve(strict=True)), str(snapshot / core_relative)]
        else:
            runner = snapshot / ".firstmate-transaction-runner.py"
            atomic_create(runner, TRANSACTION_RUNNER_BYTES)
            command = [str(python_path.resolve(strict=True)), "-I", "-S", str(runner)]
        yield command, manifest_sha
    finally:
        shutil.rmtree(snapshot, ignore_errors=True)


def safe_vault_target(vault: Path, relative: str) -> Path:
    if not safe_relative_path(relative):
        raise HandoffError("TRANSACTION_PATH", "transaction target path is unsafe")
    parts = PurePosixPath(relative).parts
    lowered = {part.lower() for part in parts}
    if ".obsidian" in lowered or ".git" in lowered or ".vault-meta" in lowered or ".raw" in lowered:
        raise HandoffError("TRANSACTION_PATH", "transaction target uses a forbidden Vault namespace")
    target = vault.joinpath(*parts)
    current = vault
    for part in parts[:-1]:
        current = current / part
        if current.exists() and current.is_symlink():
            raise HandoffError("TRANSACTION_SYMLINK", "transaction target traverses a symlink")
    if target.exists() and target.is_symlink():
        raise HandoffError("TRANSACTION_SYMLINK", "transaction target is a symlink")
    try:
        parent = target.parent.resolve(strict=True)
    except OSError as exc:
        raise HandoffError("TRANSACTION_PARENT", "transaction target parent is unavailable") from exc
    if vault != parent and vault not in parent.parents:
        raise HandoffError("TRANSACTION_ESCAPE", "transaction target escapes the selected Vault")
    return target


def validate_save_bundle(config: Mapping[str, Any], record_id: str, bundle: Any) -> dict[str, Any]:
    if not isinstance(bundle, dict):
        raise HandoffError("BUNDLE_TYPE", "Save bundle must be an object")
    allowed_keys = {"schema", "operation_id", "operation_type", "expected_hashes", "writes", "address_requests", "source_manifest_updates"}
    if set(bundle) - allowed_keys:
        raise HandoffError("BUNDLE_FIELDS", "Save bundle has unsupported fields")
    operation_id = deterministic_operation_id(record_id)
    if bundle.get("schema") != TRANSACTION_SCHEMA or bundle.get("operation_type") != "save" or bundle.get("operation_id") != operation_id:
        raise HandoffError("BUNDLE_AUTHORITY", "automatic authority permits only the deterministic Save operation")
    writes = bundle.get("writes")
    expected_hashes = bundle.get("expected_hashes")
    if not isinstance(writes, list) or not 1 <= len(writes) <= MAX_TRANSACTION_WRITES or not isinstance(expected_hashes, dict):
        raise HandoffError("BUNDLE_BOUNDS", "Save bundle violates write bounds")
    if bundle.get("address_requests", []) not in ([], None) or bundle.get("source_manifest_updates", {}) not in ({}, None):
        raise HandoffError("BUNDLE_MANAGED", "automatic Save may not request managed metadata updates")
    vault = validate_vault_binding(config)
    consumer = config["consumer"]
    create_prefixes = tuple(consumer["create_prefix_allowlist"])
    replace_allowlist = set(consumer["replace_path_allowlist"])
    paths: list[str] = []
    create_paths: list[str] = []
    normalized_writes: list[dict[str, Any]] = []
    for write in writes:
        if not isinstance(write, dict) or set(write) != {"path", "mode", "content"}:
            raise HandoffError("BUNDLE_WRITE", "Save writes must use only path, mode, and inline content")
        relative = write.get("path")
        mode = write.get("mode")
        content = write.get("content")
        if not isinstance(relative, str) or mode not in {"create", "replace"} or not isinstance(content, str):
            raise HandoffError("BUNDLE_WRITE", "Save write fields are invalid")
        validate_statement_segments(content)
        target = safe_vault_target(vault, relative)
        if mode == "create":
            if not relative.startswith(create_prefixes) or expected_hashes.get(relative, "missing") is not None or target.exists():
                raise HandoffError("BUNDLE_CREATE", "automatic Save create target is not allowlisted and absent")
            create_paths.append(relative)
        else:
            if relative not in replace_allowlist or not target.is_file() or target.is_symlink():
                raise HandoffError("BUNDLE_REPLACE", "automatic Save replacement is not an allowlisted coupled path")
            expected = expected_hashes.get(relative)
            if not isinstance(expected, str) or not HEX64.fullmatch(expected) or sha256_file(target) != expected:
                raise HandoffError("BUNDLE_EXPECTED_HASH", "allowlisted replacement expected hash does not match")
        paths.append(relative)
        normalized_writes.append({"path": relative, "mode": mode, "content": content})
    if len(paths) != len(set(paths)) or set(expected_hashes) != set(paths):
        raise HandoffError("BUNDLE_PATH_SET", "Save expected_hashes must bind every unique write path exactly")
    if len(create_paths) != 1:
        raise HandoffError("BUNDLE_DESTRUCTIVE", "automatic Save requires exactly one new non-canonical note")
    required_paths = set(consumer["required_coupled_paths"])
    if set(paths) != required_paths | {create_paths[0]}:
        raise HandoffError("BUNDLE_COUPLED", "automatic Save must contain exactly one new note and only the required coupled replacements")
    normalized = {
        "schema": TRANSACTION_SCHEMA,
        "operation_id": operation_id,
        "operation_type": "save",
        "expected_hashes": {key: expected_hashes[key] for key in sorted(expected_hashes)},
        "writes": normalized_writes,
        "address_requests": [],
        "source_manifest_updates": {},
    }
    if len(canonical_json(normalized)) > MAX_TRANSACTION_BUNDLE_BYTES:
        raise HandoffError("BUNDLE_BYTES", "Save bundle exceeds its bounded staging cap")
    return normalized


def validate_statement_segments(content: str) -> None:
    if len(content.encode("utf-8")) > 64 * 1024 or "\x00" in content:
        raise HandoffError("BUNDLE_CONTENT_CAP", "Save content exceeds its bounded plain-text cap")
    if any(pattern.search(content) for pattern in RAW_CONTENT_PATTERNS + SENSITIVE_PATTERNS):
        raise HandoffError("BUNDLE_CONTENT", "Save content contains raw or sensitive material")


def core_json_call(
    command: Sequence[str],
    *,
    expected_codes: set[int] = {0},
    on_spawn: Callable[[subprocess.Popen[bytes]], None] | None = None,
    release_gate: bool = False,
) -> tuple[dict[str, Any] | None, int]:
    completed = run_bounded(command, timeout=30.0, on_spawn=on_spawn, release_gate=release_gate)
    if completed.returncode not in expected_codes:
        return None, completed.returncode
    if completed.returncode != 0:
        return None, completed.returncode
    try:
        value = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HandoffError("CORE_OUTPUT", "transaction core returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise HandoffError("CORE_OUTPUT", "transaction core returned an invalid result")
    return value, completed.returncode


def execution_claim_path(layout: StateLayout, record_id: str) -> Path:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return layout.bindings / f"execution-{record_id}.json"


def process_identity(pid: int) -> tuple[str, str] | None:
    if pid <= 0:
        return None
    if sys.platform.startswith("linux"):
        try:
            raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        except (FileNotFoundError, PermissionError, OSError):
            return None
        closing = raw.rfind(")")
        fields = raw[closing + 2 :].split()
        if closing < 0 or len(fields) < 20:
            return None
        return fields[19], fields[0]
    ps = Path("/bin/ps")
    if not ps.is_file():
        return None
    completed = subprocess.run(
        [str(ps), "-p", str(pid), "-o", "lstart=", "-o", "state="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    output = completed.stdout.decode("utf-8", "replace").strip()
    if completed.returncode != 0 or not output:
        return None
    parts = output.rsplit(maxsplit=1)
    return (parts[0], parts[1]) if len(parts) == 2 else None


def require_no_active_execution_claim(layout: StateLayout, record_id: str) -> None:
    path = execution_claim_path(layout, record_id)
    if not path.exists():
        return
    claim = read_json_file(path, max_bytes=16 * 1024)
    if not isinstance(claim, dict) or claim.get("schema") != EXECUTION_CLAIM_SCHEMA or claim.get("record_id") != record_id:
        raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "durable transaction execution claim is invalid")
    if claim.get("state") == "spawning":
        pid = claim.get("owner_pid")
        token = claim.get("owner_start_token")
        if not isinstance(pid, int) or not isinstance(token, str) or not token:
            raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "durable transaction owner identity is invalid")
        identity = process_identity(pid) if isinstance(pid, int) else None
        if identity is None and isinstance(pid, int):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                durable_unlink(path)
                return
            except PermissionError:
                pass
        elif identity is not None and (identity[0] != token or identity[1].upper().startswith("Z")):
            durable_unlink(path)
            return
    elif claim.get("state") == "running":
        pid = claim.get("child_pid")
        token = claim.get("child_start_token")
        identity = process_identity(pid) if isinstance(pid, int) else None
        if identity is None and isinstance(pid, int):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                durable_unlink(path)
                return
            except PermissionError:
                pass
        elif identity is not None and (identity[0] != token or identity[1].upper().startswith("Z")):
            durable_unlink(path)
            return
    else:
        raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "durable transaction execution claim has an invalid state")
    raise HandoffError("TRANSACTION_RECOVERY_PENDING", "a claimed transaction child must be confirmed reaped before another consumer transition")


def consumer_record(home: Path, config: Mapping[str, Any], record_id: str) -> tuple[dict[str, Any], dict[str, Any], str]:
    require_consumer_binding(home, config)
    layout = StateLayout(home)
    try:
        envelope, digest = read_envelope(layout, record_id, config)
        queue = read_queue(layout, record_id)
    except HandoffError as exc:
        safe_record_id = record_id if RECORD_ID.fullmatch(record_id) else "handoff-" + "0" * 48
        quarantine(layout, safe_record_id, exc.code.lower())
        if RECORD_ID.fullmatch(record_id) and queue_path(layout, record_id).exists():
            update_queue(layout, record_id, status="quarantined", reason=exc.code.lower())
        raise
    if queue.get("envelope_sha256") != digest:
        quarantine(layout, record_id, "record-payload-mismatch", expected_sha256=str(queue.get("envelope_sha256", "")), observed_sha256=digest)
        update_queue(layout, record_id, status="quarantined", reason="record-payload-mismatch")
        raise HandoffError("PAYLOAD_MISMATCH", "stable record ID binds changed payload bytes")
    if queue.get("status") == "quarantined":
        raise HandoffError("RECORD_QUARANTINED", "record is quarantined for manual or captain review")
    if any(item["provider_class"] not in config["allowed_provider_classes"] for item in envelope["items"]):
        quarantine(layout, record_id, "provider-class-refused")
        update_queue(layout, record_id, status="quarantined", reason="provider-class-refused")
        raise HandoffError("PROVIDER_CLASS", "record provider class is not authorized")
    return envelope, queue, digest


def ack_path_for(layout: StateLayout, record_id: str) -> Path:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return layout.acks / f"{record_id}.json"


def disposition_path_for(layout: StateLayout, record_id: str) -> Path:
    if not RECORD_ID.fullmatch(record_id):
        raise HandoffError("RECORD_ID", "record ID is invalid")
    return layout.quarantine / f"disposition-{record_id}.json"


def require_active_save_authority(
    layout: StateLayout,
    record_id: str,
    queue: Mapping[str, Any],
    approval: Mapping[str, Any] | None = None,
) -> None:
    if queue.get("status") not in {"pending", "notified"} or queue.get("compaction") != "succeeded":
        raise HandoffError("SAVE_AUTHORITY_REVOKED", "record is not active for automatic Save")
    if ack_path_for(layout, record_id).exists() or disposition_path_for(layout, record_id).exists():
        raise HandoffError("SAVE_AUTHORITY_REVOKED", "a terminal acknowledgement or disposition revoked automatic Save authority")
    if approval is not None:
        if (
            approval.get("record_id") != record_id
            or approval.get("operation_id") != deterministic_operation_id(record_id)
            or queue.get("active_bundle_sha256") != approval.get("bundle_file_sha256")
        ):
            raise HandoffError("SAVE_AUTHORITY_REVOKED", "reviewed Save plan is not the active record authority")


def verify_completed_transaction(home: Path, config: Mapping[str, Any], record_id: str, approval: Mapping[str, Any]) -> dict[str, Any]:
    vault = validate_vault_binding(config)
    operation_id = deterministic_operation_id(record_id)
    operation = vault / ".vault-meta" / "transactions" / operation_id
    journal_path = operation / "journal.json"
    result_path = operation / "changed-paths.json"
    for path in (journal_path, result_path):
        if not path.is_file() or path.is_symlink() or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise HandoffError("TRANSACTION_INCOMPLETE", "transaction journal or result is absent or unsafe")
    journal = read_json_file(journal_path, max_bytes=8 * 1024 * 1024, require_private=False)
    result = read_json_file(result_path, max_bytes=8 * 1024 * 1024, require_private=False)
    if not isinstance(journal, dict) or not isinstance(result, dict):
        raise HandoffError("TRANSACTION_RESULT", "transaction journal or result is invalid")
    correlated = (
        journal.get("schema") == TRANSACTION_JOURNAL_SCHEMA
        and result.get("schema") == TRANSACTION_RESULT_SCHEMA
        and result.get("status") == "complete"
        and journal.get("operation_id") == result.get("operation_id") == operation_id
        and journal.get("operation_type") == result.get("operation_type") == "save"
        and journal.get("input_bundle_sha256") == result.get("bundle_sha256") == approval.get("bundle_sha256")
        and journal.get("approval_sha256") == result.get("approval_sha256") == approval.get("approval_sha256")
        and journal.get("expanded_bundle_sha256") == result.get("expanded_bundle_sha256")
    )
    if correlated and journal.get("state") != "complete":
        raise HandoffError("TRANSACTION_RECOVERY_PENDING", "transaction result is durable before its correlated journal completion")
    if not correlated or journal.get("state") != "complete":
        raise HandoffError("TRANSACTION_BINDING", "transaction result does not match its reviewed approval binding")
    changed = result.get("changed_paths")
    hashes = result.get("hashes")
    reviewed_paths = approval.get("changed_paths")
    reviewed_hashes = approval.get("hashes")
    if (
        not isinstance(changed, list)
        or not isinstance(hashes, dict)
        or not isinstance(reviewed_paths, list)
        or not isinstance(reviewed_hashes, dict)
        or len(reviewed_paths) != len(set(reviewed_paths))
        or changed != reviewed_paths
        or hashes != reviewed_hashes
        or set(changed) != set(hashes)
    ):
        raise HandoffError("TRANSACTION_PATHS", "transaction changed-path result is invalid")
    journal_writes = journal.get("writes")
    if (
        journal.get("applied") != reviewed_paths
        or not isinstance(journal_writes, list)
        or [write.get("path") if isinstance(write, dict) else None for write in journal_writes] != reviewed_paths
    ):
        raise HandoffError("TRANSACTION_APPLIED", "transaction journal does not prove every changed path was applied")
    for relative in reviewed_paths:
        target = safe_vault_target(vault, relative)
        if not target.is_file() or sha256_file(target) != reviewed_hashes.get(relative):
            raise HandoffError("TRANSACTION_HASH", "transaction changed-path hash verification failed")
    if (vault / ".vault-meta" / "mutation.lock").exists():
        raise HandoffError("TRANSACTION_LOCK", "transaction mutation lock remains held")
    result_sha = sha256_file(result_path)
    layout = StateLayout(home)
    ack_path = ack_path_for(layout, record_id)
    if ack_path.exists():
        existing_ack = read_json_file(ack_path, max_bytes=64 * 1024)
        if (
            not isinstance(existing_ack, dict)
            or existing_ack.get("schema") != ACK_SCHEMA
            or existing_ack.get("record_id") != record_id
            or existing_ack.get("operation_id") != operation_id
            or existing_ack.get("approval_sha256") != approval["approval_sha256"]
            or existing_ack.get("result_sha256") != result_sha
            or existing_ack.get("changed_path_hashes") != {key: hashes[key] for key in sorted(hashes)}
        ):
            raise HandoffError("ACK_MISMATCH", "existing source acknowledgement does not match the verified transaction")
        queue_before = read_queue(layout, record_id)
        update_queue(layout, record_id, status="acknowledged", reason="transaction-verified-and-acked", operation_id=operation_id, ack_sha256=sha256_bytes(canonical_json(existing_ack)))
        if queue_before.get("status") != "acknowledged":
            write_receipt(layout, "consumer", "acknowledged", "transaction-ack-recovered", record_id=record_id, operation_id=operation_id, result_sha256=result_sha)
        return existing_ack
    ack = {
        "schema": ACK_SCHEMA,
        "record_id": record_id,
        "disposition": "saved",
        "operation_id": operation_id,
        "approval_sha256": approval["approval_sha256"],
        "result_sha256": result_sha,
        "changed_path_hashes": {key: hashes[key] for key in sorted(hashes)},
        "acknowledged_at": now_utc(),
    }
    atomic_create(ack_path, canonical_json(ack))
    failpoint("after-ack-before-queue")
    update_queue(layout, record_id, status="acknowledged", reason="transaction-verified-and-acked", operation_id=operation_id, ack_sha256=sha256_bytes(canonical_json(ack)))
    write_receipt(layout, "consumer", "acknowledged", "transaction-verified", record_id=record_id, operation_id=operation_id, result_sha256=result_sha)
    return ack


def run_approved_transaction_apply(
    home: Path,
    config: Mapping[str, Any],
    layout: StateLayout,
    record_id: str,
    approval: Mapping[str, Any],
) -> tuple[dict[str, Any] | None, int]:
    approval_sha = str(approval.get("approval_sha256", ""))
    if not HEX64.fullmatch(approval_sha):
        raise HandoffError("APPROVAL_BINDING", "reviewed approval SHA is invalid")
    vault = validate_vault_binding(config)
    bundle_path = Path(str(approval.get("bundle_path", "")))
    if sha256_file(bundle_path, max_bytes=MAX_TRANSACTION_BUNDLE_BYTES) != approval.get("bundle_file_sha256"):
        raise HandoffError("BUNDLE_MISMATCH", "approved Save bundle bytes changed")
    claim_path = execution_claim_path(layout, record_id)
    owner_identity = process_identity(os.getpid())
    if owner_identity is None:
        raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "transaction owner identity could not be bound")
    claim = {
        "schema": EXECUTION_CLAIM_SCHEMA,
        "record_id": record_id,
        "operation_id": approval["operation_id"],
        "approval_sha256": approval_sha,
        "bundle_file_sha256": approval["bundle_file_sha256"],
        "state": "spawning",
        "owner_pid": os.getpid(),
        "owner_start_token": owner_identity[0],
        "claimed_at": now_utc(),
    }
    atomic_create(claim_path, canonical_json(claim))
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_EXIT_AFTER_EXECUTION_CLAIM") == "1":
        os._exit(87)

    def bind_child(process: subprocess.Popen[bytes]) -> None:
        identity = process_identity(process.pid)
        if identity is None:
            raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "transaction child identity could not be bound")
        atomic_replace(
            claim_path,
            canonical_json(
                {
                    **claim,
                    "state": "running",
                    "child_pid": process.pid,
                    "child_start_token": identity[0],
                }
            ),
        )

    try:
        with transaction_runtime(config, layout) as (transaction_command, manifest_sha):
            if approval.get("dependency_manifest_sha256") != manifest_sha:
                raise HandoffError("SAVE_AUTHORITY_REVOKED", "reviewed Save plan does not bind the current transaction dependency manifest")
            return core_json_call(
                [*transaction_command, "transaction", "apply", str(bundle_path), "--vault", str(vault), "--approved-plan-sha256", approval_sha],
                expected_codes={0, 75},
                on_spawn=bind_child,
                release_gate=True,
            )
    finally:
        durable_unlink(claim_path)


def find_completed_approval(home: Path, config: Mapping[str, Any], record_id: str) -> dict[str, Any] | None:
    layout = StateLayout(home)
    operation_id = deterministic_operation_id(record_id)
    result_path = validate_vault_binding(config) / ".vault-meta" / "transactions" / operation_id / "changed-paths.json"
    if not result_path.is_file():
        return None
    result = read_json_file(result_path, max_bytes=8 * 1024 * 1024, require_private=False)
    if (
        not isinstance(result, dict)
        or result.get("schema") != TRANSACTION_RESULT_SCHEMA
        or result.get("status") != "complete"
        or not HEX64.fullmatch(str(result.get("approval_sha256", "")))
    ):
        raise HandoffError("TRANSACTION_BINDING", "completed transaction result lacks an exact reviewed approval binding")
    approval = load_approval(layout, record_id, result["approval_sha256"])
    try:
        return verify_completed_transaction(home, config, record_id, approval)
    except HandoffError as exc:
        if exc.code in {"TRANSACTION_INCOMPLETE", "TRANSACTION_LOCK", "TRANSACTION_RECOVERY_PENDING"}:
            require_no_active_execution_claim(layout, record_id)
            replayed, code = run_approved_transaction_apply(home, config, layout, record_id, approval)
            if code != 0 or replayed is None or replayed.get("schema") != TRANSACTION_RESULT_SCHEMA or replayed.get("status") != "complete":
                raise HandoffError("TRANSACTION_RECOVERY_PENDING", "transaction recovery did not reach a verified terminal result")
            return verify_completed_transaction(home, config, record_id, approval)
        raise


def recover_terminal_disposition_ack(layout: StateLayout, record_id: str) -> bool:
    path = ack_path_for(layout, record_id)
    disposition_path = disposition_path_for(layout, record_id)
    disposition_record: dict[str, Any] | None = None
    if disposition_path.exists():
        value = read_json_file(disposition_path, max_bytes=16 * 1024)
        if not isinstance(value, dict) or value.get("schema") != "firstmate.context-handoff.disposition.v1" or value.get("record_id") != record_id or value.get("disposition") not in DISPOSITIONS or not isinstance(value.get("recorded_at"), str):
            raise HandoffError("DISPOSITION_RECORD", "durable curation disposition is invalid")
        disposition_record = value
        if not path.exists():
            atomic_create(path, canonical_json({"schema": ACK_SCHEMA, "record_id": record_id, "disposition": value["disposition"], "acknowledged_at": value["recorded_at"]}))
    if not path.exists():
        return False
    ack = read_json_file(path, max_bytes=64 * 1024)
    disposition = ack.get("disposition") if isinstance(ack, dict) else None
    if not isinstance(ack, dict) or ack.get("schema") != ACK_SCHEMA or ack.get("record_id") != record_id or disposition not in DISPOSITIONS:
        return False
    if disposition_record is not None and disposition_record.get("disposition") != disposition:
        raise HandoffError("ACK_MISMATCH", "durable disposition and acknowledgement do not match")
    status = "quarantined" if disposition == "needs-captain" else "acknowledged"
    queue_before = read_queue(layout, record_id)
    update_queue(layout, record_id, status=status, reason=f"curation-{disposition}")
    if queue_before.get("status") != status:
        write_receipt(layout, "consumer", status, f"curation-{disposition}-ack-recovered", record_id=record_id)
    return True


def claimable_records_locked(
    home: Path,
    config: Mapping[str, Any],
    layout: StateLayout,
    *,
    suppress_invalid: bool = False,
) -> list[tuple[str, dict[str, Any], dict[str, Any], str]]:
    replay_terminal_compaction_bindings_locked(layout, str(config["recipient"]["agent_session_sha256"]))
    replay_compaction_attempts(layout, config)
    require_consumer_binding(home, config)
    for ack_path in sorted(layout.acks.glob("handoff-*.json")):
        validate_private_file(ack_path)
    candidates: list[tuple[str, str]] = []
    for path in sorted(layout.queue.glob("handoff-*.json")):
        queue = read_queue(layout, path.stem)
        if queue.get("status") in {"pending", "notified"} and queue.get("compaction") == "succeeded":
            candidates.append((str(queue.get("created_at", "")), path.stem))
    claimable: list[tuple[str, dict[str, Any], dict[str, Any], str]] = []
    for _, record_id in sorted(candidates):
        if recover_terminal_disposition_ack(layout, record_id):
            continue
        healed = find_completed_approval(home, config, record_id)
        if healed:
            continue
        if ack_path_for(layout, record_id).exists():
            quarantine(layout, record_id, "acknowledgement-recovery-incomplete")
            update_queue(layout, record_id, status="quarantined", reason="acknowledgement-recovery-incomplete")
            if suppress_invalid:
                continue
            raise HandoffError("ACK_INCOMPLETE", "durable acknowledgement could not be reconciled with its terminal result")
        try:
            envelope, queue, digest = consumer_record(home, config, record_id)
        except HandoffError:
            if suppress_invalid:
                continue
            raise
        claimable.append((record_id, envelope, queue, digest))
    return claimable


def _mcp_next_locked(home: Path, config: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    claimable = claimable_records_locked(home, config, layout)
    if claimable:
        record_id, envelope, _queue, digest = claimable[0]
        return {
            "status": "ready",
            "record_id": record_id,
            "envelope_sha256": digest,
            "items": envelope["items"],
            "curation_contract": {
                "producer_is_proposal_only": True,
                "allowed_automatic_disposition": "new-note save with allowlisted coupled replacements",
                "quarantine": ["deletion", "canonical replacement", "merge", "ambiguity", "sensitive", "out-of-contract"],
            },
        }
    return {"status": "empty"}


def current_consumer_config(home: Path) -> dict[str, Any]:
    config = load_config(home)
    if config is None or not config_enabled(config, "consumer_enabled"):
        raise HandoffError("CONSUMER_DISABLED", "the Claude handoff consumer is disabled")
    return config


def mcp_next(home: Path) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_next_locked(home, current_consumer_config(home), layout)


def _mcp_disposition_locked(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    record_id = arguments.get("record_id")
    disposition = arguments.get("disposition")
    rationale = arguments.get("rationale")
    if not isinstance(record_id, str) or disposition not in DISPOSITIONS or not isinstance(rationale, str) or not 1 <= len(rationale) <= 500:
        raise HandoffError("DISPOSITION_INPUT", "consumer disposition input is invalid")
    validate_statement(rationale)
    require_consumer_binding(home, config)
    require_no_active_execution_claim(layout, record_id)
    completed = find_completed_approval(home, config, record_id)
    if completed is not None:
        return {
            "status": "acknowledged",
            "record_id": record_id,
            "disposition": "saved",
            "operation_id": completed["operation_id"],
        }
    value = {
        "schema": "firstmate.context-handoff.disposition.v1",
        "record_id": record_id,
        "disposition": disposition,
        "rationale": rationale,
        "recorded_at": now_utc(),
    }
    path = layout.quarantine / f"disposition-{record_id}.json"
    if path.exists():
        existing = read_json_file(path, max_bytes=16 * 1024)
        if (
            not isinstance(existing, dict)
            or existing.get("schema") != value["schema"]
            or existing.get("record_id") != record_id
            or existing.get("disposition") != disposition
            or existing.get("rationale") != rationale
        ):
            quarantine(layout, record_id, "disposition-mismatch")
            update_queue(layout, record_id, status="quarantined", reason="disposition-mismatch")
            raise HandoffError("DISPOSITION_MISMATCH", "record already binds another curation disposition")
        if not recover_terminal_disposition_ack(layout, record_id):
            raise HandoffError("ACK_INCOMPLETE", "durable disposition acknowledgement could not be recovered")
        status = "quarantined" if disposition == "needs-captain" else "acknowledged"
        return {"status": status, "record_id": record_id, "disposition": disposition}
    _envelope, queue_before, _digest = consumer_record(home, config, record_id)
    vault = validate_vault_binding(config)
    operation = vault / ".vault-meta" / "transactions" / deterministic_operation_id(record_id)
    if operation.exists() or (vault / ".vault-meta" / "mutation.lock").exists():
        raise HandoffError("TRANSACTION_RECOVERY_PENDING", "transaction state must be reconciled before a non-save disposition")
    require_active_save_authority(layout, record_id, queue_before)
    atomic_create(path, canonical_json(value))
    status = "quarantined" if disposition == "needs-captain" else "acknowledged"
    ack_path = ack_path_for(layout, record_id)
    ack = {
        "schema": ACK_SCHEMA,
        "record_id": record_id,
        "disposition": disposition,
        "acknowledged_at": now_utc(),
    }
    atomic_create(ack_path, canonical_json(ack))
    failpoint("after-ack-before-queue")
    update_queue(layout, record_id, status=status, reason=f"curation-{disposition}")
    write_receipt(layout, "consumer", status, f"curation-{disposition}", record_id=record_id)
    return {"status": status, "record_id": record_id, "disposition": disposition}


def mcp_disposition(home: Path, arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_disposition_locked(home, current_consumer_config(home), arguments, layout)


def _mcp_prepare_save_locked(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    record_id = arguments.get("record_id")
    bundle = arguments.get("bundle")
    duplicate_check = arguments.get("duplicate_check")
    content_sensitivity = arguments.get("content_sensitivity")
    if not isinstance(record_id, str):
        raise HandoffError("PREPARE_INPUT", "Save preparation input is invalid")
    require_consumer_binding(home, config)
    require_no_active_execution_claim(layout, record_id)
    completed = find_completed_approval(home, config, record_id)
    if completed is not None:
        return {"status": "acknowledged", "record_id": record_id, "operation_id": completed["operation_id"], "changed_path_hashes": completed["changed_path_hashes"]}
    _envelope, queue, _digest = consumer_record(home, config, record_id)
    require_active_save_authority(layout, record_id, queue)
    try:
        if not isinstance(duplicate_check, dict):
            raise HandoffError("DUPLICATE_CHECK", "Save requires a bounded no-match duplicate search disposition")
        searched = duplicate_check.get("searched_paths")
        if duplicate_check.get("result") != "no-match" or not isinstance(searched, list) or not searched or len(searched) > 5 or not all(safe_relative_path(path) for path in searched):
            raise HandoffError("DUPLICATE_CHECK", "Save requires a bounded no-match duplicate search disposition")
        normalized = validate_save_bundle(config, record_id, bundle)
        reviewed_paths = [write["path"] for write in normalized["writes"]]
        if not isinstance(content_sensitivity, dict) or set(content_sensitivity) != set(reviewed_paths) or not all(isinstance(value, str) and value in SENSITIVITY_CLASSES for value in content_sensitivity.values()):
            raise HandoffError("SENSITIVITY_CLASSIFICATION", "Save requires an exact sensitivity classification for every write path")
        if any(value != ELIGIBLE_SENSITIVITY_CLASS for value in content_sensitivity.values()):
            raise HandoffError("SENSITIVE_CLASS", "sensitive or regulated Save classifications are not eligible")
    except HandoffError as exc:
        quarantine(layout, record_id, f"curation-{exc.code.lower()}")
        update_queue(layout, record_id, status="quarantined", reason=f"curation-{exc.code.lower()}")
        raise
    data = canonical_json(normalized)
    bundle_sha = sha256_bytes(data)
    bundle_dir = layout.bundles / record_id
    ensure_private_directory(bundle_dir)
    bundle_path = bundle_dir / f"{bundle_sha}.json"
    atomic_create(bundle_path, data)
    vault = validate_vault_binding(config)
    with transaction_runtime(config, layout) as (transaction_command, manifest_sha):
        plan, code = core_json_call([*transaction_command, "transaction", "inspect", str(bundle_path), "--vault", str(vault)])
    if code != 0 or plan is None:
        raise HandoffError("TRANSACTION_INSPECT", "transaction core refused the proposed Save plan")
    if plan.get("schema") != TRANSACTION_PLAN_SCHEMA or plan.get("operation_id") != deterministic_operation_id(record_id) or plan.get("operation_type") != "save" or not HEX64.fullmatch(str(plan.get("input_bundle_sha256", ""))) or not HEX64.fullmatch(str(plan.get("approval_sha256", ""))):
        raise HandoffError("TRANSACTION_PLAN", "transaction inspect result does not match the proposed Save bundle")
    reviewed_hashes = {
        write["path"]: sha256_bytes(write["content"].encode("utf-8"))
        for write in normalized["writes"]
    }
    if plan.get("changed_paths") != reviewed_paths or plan.get("hashes") != reviewed_hashes:
        raise HandoffError("TRANSACTION_PLAN", "transaction inspect did not bind the complete proposed path and hash plan")
    approval = {
        "schema": APPROVAL_SCHEMA,
        "record_id": record_id,
        "operation_id": deterministic_operation_id(record_id),
        "bundle_path": str(bundle_path.resolve(strict=True)),
        "bundle_file_sha256": bundle_sha,
        "bundle_sha256": plan["input_bundle_sha256"],
        "approval_sha256": plan["approval_sha256"],
        "vault_path": str(vault),
        "vault_identity": plan.get("vault_identity"),
        "changed_paths": reviewed_paths,
        "hashes": {key: reviewed_hashes[key] for key in sorted(reviewed_hashes)},
        "core_path": str(config["transaction"]["core_path"]),
        "core_sha256": config["transaction"]["core_sha256"],
        "module_path": str(config["transaction"]["module_path"]),
        "module_sha256": config["transaction"]["module_sha256"],
        "dependency_manifest_sha256": manifest_sha,
        "reviewed_at": now_utc(),
    }
    approval_dir = layout.approvals / record_id
    ensure_private_directory(approval_dir)
    approval_path = approval_dir / f"{bundle_sha}.json"
    if approval_path.exists():
        existing_approval = read_json_file(approval_path, max_bytes=64 * 1024)
        if not isinstance(existing_approval, dict) or {
            key: value for key, value in existing_approval.items() if key != "reviewed_at"
        } != {
            key: value for key, value in approval.items() if key != "reviewed_at"
        }:
            quarantine(layout, record_id, "approval-binding-mismatch", bundle_file_sha256=bundle_sha)
            update_queue(layout, record_id, status="quarantined", reason="approval-binding-mismatch")
            raise HandoffError("APPROVAL_MISMATCH", "stable reviewed bundle bytes bind a different transaction plan")
        approval = existing_approval
    else:
        atomic_create(approval_path, canonical_json(approval))
    update_queue(layout, record_id, reason="save-plan-inspected", operation_id=approval["operation_id"], active_bundle_sha256=bundle_sha)
    return {
        "status": "review-required",
        "record_id": record_id,
        "operation_id": approval["operation_id"],
        "bundle_sha256": bundle_sha,
        "input_bundle_sha256": approval["bundle_sha256"],
        "approval_sha256": approval["approval_sha256"],
        "changed_paths": approval["changed_paths"],
        "hashes": approval["hashes"],
    }


def mcp_prepare_save(home: Path, arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_prepare_save_locked(home, current_consumer_config(home), arguments, layout)


def load_approval(layout: StateLayout, record_id: str, approval_sha: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    for path in approval_records(layout, record_id):
        value = read_json_file(path, max_bytes=64 * 1024)
        if isinstance(value, dict) and value.get("schema") == APPROVAL_SCHEMA and value.get("approval_sha256") == approval_sha:
            matches.append(value)
    if len(matches) != 1:
        raise HandoffError("APPROVAL_BINDING", "reviewed approval SHA does not bind exactly one staged Save plan")
    return matches[0]


def _mcp_commit_save_locked(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    record_id = arguments.get("record_id")
    approval_sha = arguments.get("approval_sha256")
    if not isinstance(record_id, str) or not isinstance(approval_sha, str) or not HEX64.fullmatch(approval_sha):
        raise HandoffError("COMMIT_INPUT", "Save commit input is invalid")
    require_consumer_binding(home, config)
    require_no_active_execution_claim(layout, record_id)
    completed = find_completed_approval(home, config, record_id)
    if completed is not None:
        return {"status": "acknowledged", "record_id": record_id, "operation_id": completed["operation_id"], "changed_path_hashes": completed["changed_path_hashes"]}
    _envelope, queue, _digest = consumer_record(home, config, record_id)
    approval = load_approval(layout, record_id, approval_sha)
    ack_path = ack_path_for(layout, record_id)
    if ack_path.exists():
        ack = read_json_file(ack_path, max_bytes=64 * 1024)
        if not isinstance(ack, dict) or ack.get("schema") != ACK_SCHEMA or ack.get("disposition") != "saved" or ack.get("approval_sha256") != approval_sha:
            raise HandoffError("SAVE_AUTHORITY_REVOKED", "terminal acknowledgement revoked automatic Save authority")
        verified = verify_completed_transaction(home, config, record_id, approval)
        return {"status": "acknowledged", "record_id": record_id, "operation_id": verified["operation_id"], "changed_path_hashes": verified["changed_path_hashes"]}
    require_active_save_authority(layout, record_id, queue, approval)
    vault = validate_vault_binding(config)
    bundle_path = Path(approval["bundle_path"])
    if sha256_file(bundle_path, max_bytes=MAX_TRANSACTION_BUNDLE_BYTES) != approval["bundle_file_sha256"]:
        quarantine(layout, record_id, "approved-bundle-payload-mismatch")
        update_queue(layout, record_id, status="quarantined", reason="approved-bundle-payload-mismatch")
        raise HandoffError("BUNDLE_MISMATCH", "approved Save bundle bytes changed")
    claim_path = execution_claim_path(layout, record_id)
    owner_identity = process_identity(os.getpid())
    if owner_identity is None:
        raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "transaction owner identity could not be bound")
    claim = {
        "schema": EXECUTION_CLAIM_SCHEMA,
        "record_id": record_id,
        "operation_id": approval["operation_id"],
        "approval_sha256": approval_sha,
        "bundle_file_sha256": approval["bundle_file_sha256"],
        "state": "spawning",
        "owner_pid": os.getpid(),
        "owner_start_token": owner_identity[0],
        "claimed_at": now_utc(),
    }
    atomic_create(claim_path, canonical_json(claim))
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and os.environ.get("FM_HANDOFF_TEST_EXIT_AFTER_EXECUTION_CLAIM") == "1":
        os._exit(87)

    def bind_child(process: subprocess.Popen[bytes]) -> None:
        identity = process_identity(process.pid)
        if identity is None:
            raise HandoffError("TRANSACTION_EXECUTION_CLAIM", "transaction child identity could not be bound")
        atomic_replace(
            claim_path,
            canonical_json(
                {
                    **claim,
                    "state": "running",
                    "child_pid": process.pid,
                    "child_start_token": identity[0],
                }
            ),
        )
    try:
        with transaction_runtime(config, layout) as (transaction_command, manifest_sha):
            if approval.get("dependency_manifest_sha256") != manifest_sha:
                raise HandoffError("SAVE_AUTHORITY_REVOKED", "reviewed Save plan does not bind the current transaction dependency manifest")
            result, code = core_json_call(
                [*transaction_command, "transaction", "apply", str(bundle_path), "--vault", str(vault), "--approved-plan-sha256", approval_sha],
                expected_codes={0, 75},
                on_spawn=bind_child,
                release_gate=True,
            )
    finally:
        durable_unlink(claim_path)
    if code == 75:
        update_queue(layout, record_id, status="pending", reason="fresh-inspect-required", active_bundle_sha256=None)
        write_receipt(layout, "consumer", "pending", "fresh-inspect-required", record_id=record_id, operation_id=approval["operation_id"])
        return {"status": "pending", "reason": "fresh-inspect-required", "record_id": record_id}
    if result is None or result.get("schema") != TRANSACTION_RESULT_SCHEMA or result.get("status") != "complete":
        update_queue(layout, record_id, status="pending", reason="transaction-apply-failed")
        write_receipt(layout, "consumer", "failed", "transaction-apply-failed", record_id=record_id, operation_id=approval["operation_id"])
        raise HandoffError("TRANSACTION_APPLY", "transaction core did not return a complete result")
    ack = verify_completed_transaction(home, config, record_id, approval)
    return {"status": "acknowledged", "record_id": record_id, "operation_id": ack["operation_id"], "changed_path_hashes": ack["changed_path_hashes"]}


def mcp_commit_save(home: Path, arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_commit_save_locked(home, current_consumer_config(home), arguments, layout)


def mcp_register(home: Path, arguments: Mapping[str, Any]) -> dict[str, Any]:
    namespace = argparse.Namespace(
        fm_home=str(home),
        source_harness="claude",
        kind=arguments.get("kind"),
        statement=arguments.get("statement"),
        source_record=arguments.get("source_record"),
        source_sha256=arguments.get("source_sha256"),
        confidence=arguments.get("confidence"),
        sphere=arguments.get("sphere"),
        sensitivity_class=arguments.get("sensitivity_class"),
        provider_class=arguments.get("provider_class"),
        supersedes=arguments.get("supersedes") or [],
    )
    layout = StateLayout(home)
    with state_lock(layout):
        current_config = current_consumer_config(home)
        require_consumer_binding(home, current_config)
        return _register_locked(home, current_config, namespace, layout)


def mcp_tool_schemas() -> list[dict[str, Any]]:
    item_properties = {
        "kind": {"type": "string", "enum": sorted(KINDS)},
        "statement": {"type": "string", "maxLength": 2048},
        "source_record": {"type": "string"},
        "source_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "confidence": {"type": "string", "enum": sorted(CONFIDENCES)},
        "sphere": {"type": "string", "enum": sorted(SPHERES)},
        "sensitivity_class": {"type": "string", "enum": sorted(SENSITIVITY_CLASSES)},
        "provider_class": {"type": "string"},
        "supersedes": {"type": "array", "items": {"type": "string"}, "maxItems": 16},
    }
    return [
        {
            "name": "register_curated_candidate",
            "description": "Register one already-curated Claude durable fact or pointer; never pass raw conversation or sensitive material.",
            "inputSchema": {"type": "object", "additionalProperties": False, "required": list(item_properties), "properties": item_properties},
        },
        {
            "name": "next_curated_handoff",
            "description": "Return the next validated bounded handoff for Claude's final relevance and routing decision.",
            "inputSchema": {"type": "object", "additionalProperties": False, "properties": {}},
        },
        {
            "name": "record_curation_disposition",
            "description": "Durably record duplicate, non-durable, not-allowed, or needs-captain disposition without Vault mutation.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["record_id", "disposition", "rationale"],
                "properties": {"record_id": {"type": "string"}, "disposition": {"type": "string", "enum": sorted(DISPOSITIONS)}, "rationale": {"type": "string", "maxLength": 500}},
            },
        },
        {
            "name": "prepare_handoff_save",
            "description": "Validate and inspect one non-destructive allowlisted Save bundle, binding the exact Vault approval SHA for review.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["record_id", "duplicate_check", "content_sensitivity", "bundle"],
                "properties": {
                    "record_id": {"type": "string"},
                    "duplicate_check": {"type": "object"},
                    "content_sensitivity": {"type": "object", "additionalProperties": {"type": "string", "enum": sorted(SENSITIVITY_CLASSES)}},
                    "bundle": {"type": "object"},
                },
            },
        },
        {
            "name": "commit_handoff_save",
            "description": "Apply an exact reviewed Save plan once through claude-obsidian.transaction.v1, verify it completely, then acknowledge the source.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["record_id", "approval_sha256"],
                "properties": {"record_id": {"type": "string"}, "approval_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"}},
            },
        },
    ]


def mcp_call(home: Path, name: str, arguments: Any) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        raise HandoffError("MCP_ARGUMENTS", "MCP tool arguments must be an object")
    handlers = {
        "register_curated_candidate": lambda: mcp_register(home, arguments),
        "next_curated_handoff": lambda: mcp_next(home),
        "record_curation_disposition": lambda: mcp_disposition(home, arguments),
        "prepare_handoff_save": lambda: mcp_prepare_save(home, arguments),
        "commit_handoff_save": lambda: mcp_commit_save(home, arguments),
    }
    if name not in handlers:
        raise HandoffError("MCP_TOOL", "unknown context handoff MCP tool")
    return handlers[name]()


def bounded_mcp_frames(stream: Any) -> Iterator[bytes | None]:
    while True:
        raw = stream.readline(MAX_HOOK_BYTES + 1)
        if not raw:
            return
        if len(raw) <= MAX_HOOK_BYTES:
            yield raw
            continue
        while raw and not raw.endswith(b"\n"):
            raw = stream.readline(MAX_HOOK_BYTES + 1)
        yield None


def command_mcp_server(args: argparse.Namespace) -> None:
    home = resolve_home(args.fm_home)
    for raw in bounded_mcp_frames(sys.stdin.buffer):
        if raw is None:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32000, "message": "Request exceeds maximum frame size"},
            }
            sys.stdout.write(json.dumps(response, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            return
        request: Any = None
        try:
            request = json.loads(raw)
            if not isinstance(request, dict):
                continue
            method = request.get("method")
            request_id = request.get("id")
            if method == "notifications/initialized":
                continue
            if method == "initialize":
                result = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "firstmate-context-handoff", "version": "1.0.0"},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": mcp_tool_schemas()}
            elif method == "tools/call":
                params = request.get("params")
                if not isinstance(params, dict):
                    raise HandoffError("MCP_PARAMS", "MCP call params must be an object")
                value = mcp_call(home, str(params.get("name", "")), params.get("arguments", {}))
                result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))}], "isError": False}
            else:
                raise HandoffError("MCP_METHOD", "unknown MCP method")
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except HandoffError as exc:
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id") if isinstance(request, dict) else None,
                "result": {"content": [{"type": "text", "text": json.dumps({"status": "error", "code": exc.code}, sort_keys=True)}], "isError": True},
            }
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        sys.stdout.write(json.dumps(response, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def command_status(args: argparse.Namespace) -> dict[str, Any]:
    home = resolve_home(args.fm_home)
    config = load_config(home)
    layout = StateLayout(home)
    layout.initialize()
    counts = {"registered": 0, "sealed": 0, "pending": 0, "notified": 0, "acknowledged": 0, "quarantined": 0, "receipts": 0}
    counts["registered"] = len(list(layout.candidates.glob("candidate-*.json")))
    counts["sealed"] = len(list(layout.records.glob("handoff-*.json")))
    counts["receipts"] = len(list(layout.receipts.glob("receipt-*.json")))
    reasons: dict[str, int] = {}
    for path in layout.queue.glob("handoff-*.json"):
        queue = read_queue(layout, path.stem)
        status = str(queue.get("status", "pending"))
        if status in counts:
            counts[status] += 1
        reason = str(queue.get("reason", "unknown"))
        reasons[reason] = reasons.get(reason, 0) + 1
    return {
        "schema": "firstmate.context-handoff.status.v1",
        "enabled": {
            key: config_enabled(config, key)
            for key in ("registration_enabled", "sealing_enabled", "delivery_enabled", "consumer_enabled")
        },
        "counts": counts,
        "pending_reasons": reasons,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Register, seal, deliver, curate, and verify bounded context handoffs without transcripts or direct Vault writes.")
    parser.add_argument("--fm-home", help="Exact Firstmate home; defaults to FM_HOME, FM_ROOT_OVERRIDE, then this code root.")
    sub = parser.add_subparsers(dest="command", required=True)

    register = sub.add_parser("register", help="Register one already-curated durable fact or pointer while context is healthy.")
    register.add_argument("--source-harness", choices=sorted(SOURCE_HARNESSES), required=True)
    register.add_argument("--kind", choices=sorted(KINDS), required=True)
    register.add_argument("--statement", required=True)
    register.add_argument("--source-record", required=True)
    register.add_argument("--source-sha256", required=True)
    register.add_argument("--confidence", choices=sorted(CONFIDENCES), required=True)
    register.add_argument("--sphere", choices=sorted(SPHERES), required=True)
    register.add_argument("--sensitivity-class", choices=sorted(SENSITIVITY_CLASSES), required=True)
    register.add_argument("--provider-class", required=True)
    register.add_argument("--supersedes", action="append", default=[])

    seal = sub.add_parser("seal", help="Atomically seal only pre-registered candidates; reads a bounded JSON event with session_id from stdin.")
    seal.add_argument("--source-harness", choices=sorted(SOURCE_HARNESSES), required=True)
    seal.add_argument("--trigger", choices=sorted(TRIGGERS), required=True)
    seal.add_argument("--standalone", action="store_true", help="Treat this explicit manual seal as complete and attempt delivery without compaction.")

    outcome = sub.add_parser("compaction-outcome", help="Bind a success or failure event to an exact bounded sealed-record set; reads bindings, trigger, and reason from stdin.")
    outcome.add_argument("outcome", choices=["success", "failure"])

    sub.add_parser("deliver", help="Idempotently notify only the exact configured live Herdr Claude session; never launches or restarts one.")
    sub.add_parser("claude-hook", help="Handle bounded Claude lifecycle/PreToolUse JSON from stdin without reading transcript_path or compact_summary.")
    sub.add_parser("mcp-server", help="Run the local stdio MCP consumer for Claude curation and transaction-only Save apply.")
    sub.add_parser("status", help="Report feature switches, counts, and pending reasons without record contents.")
    sub.add_parser("print-schema", help="Print the authoritative claude-obsidian.handoff.v1 JSON Schema.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "register":
            result = command_register(args)
        elif args.command == "seal":
            result = command_seal(args)
        elif args.command == "compaction-outcome":
            result = command_compaction_outcome(args)
        elif args.command == "deliver":
            result = command_deliver(args)
        elif args.command == "claude-hook":
            result = command_claude_hook(args)
        elif args.command == "mcp-server":
            command_mcp_server(args)
            return 0
        elif args.command == "status":
            result = command_status(args)
        elif args.command == "print-schema":
            sys.stdout.buffer.write(canonical_json(authoritative_schema()))
            return 0
        else:
            parser.error("unknown command")
            return 2
        if args.command == "claude-hook":
            denied = (
                isinstance(result, dict)
                and isinstance(result.get("hookSpecificOutput"), dict)
                and result["hookSpecificOutput"].get("hookEventName") == "PreToolUse"
                and result["hookSpecificOutput"].get("permissionDecision") == "deny"
            )
            hook_output(result, stderr=denied)
            if denied:
                return 2
        else:
            sys.stdout.write(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
        return 0
    except HandoffError as exc:
        if args.command == "claude-hook":
            if exc.code in {"STATE_FILE_MODE", "STATE_SYMLINK", "PAYLOAD_MISMATCH"}:
                hook_output(guard_deny("The context handoff safety boundary is unhealthy; mutation was denied."), stderr=True)
                return 2
            return exc.exit_code
        sys.stderr.write(f"context handoff: {exc.code}: {exc.message}\n")
        return exc.exit_code
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
