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
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterator, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schemas" / "claude-obsidian.handoff.v1.schema.json"
CONFIG_SCHEMA = "firstmate.context-handoff.config.v1"
CANDIDATE_SCHEMA = "firstmate.context-handoff.candidate.v1"
QUEUE_SCHEMA = "firstmate.context-handoff.queue.v1"
RECEIPT_SCHEMA = "firstmate.context-handoff.receipt.v1"
ACK_SCHEMA = "firstmate.context-handoff.ack.v1"
APPROVAL_SCHEMA = "firstmate.context-handoff.approval.v1"
BINDING_SCHEMA = "firstmate.context-handoff.consumer-binding.v1"
COMPACTION_BINDING_SCHEMA = "firstmate.context-handoff.compaction-binding.v1"
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
MAX_TRANSACTION_WRITES = 16
MAX_COMPACTION_RECORDS = 32
PROMPT_TEXT = "/firstmate-context-handoff:consume"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RECORD_ID = re.compile(r"^handoff-[0-9a-f]{48}$")
CANDIDATE_ID = re.compile(r"^candidate-[0-9a-f]{48}$")
PROVIDER_CLASS = re.compile(r"^[a-z][a-z0-9-]{1,63}$")
KINDS = {"decision", "preference", "gotcha", "project-fact", "next-step", "pointer"}
CONFIDENCES = {"verified", "inferred"}
SPHERES = {"privat", "geschaeftlich", "geteilt"}
TRIGGERS = {"manual", "threshold", "overflow"}
SOURCE_HARNESSES = {"pi", "claude"}
DISPOSITIONS = {"duplicate", "not-durable", "not-allowed", "needs-captain"}
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
        r"\b(bank|payment|card|wire transfer|financial transaction)\b",
        r"\btransaction(?:[_ -]?(?:id|number|details?|amount|reference))\b",
        r"\b(customer|order record|shipping address|billing address)\b",
        r"\border(?:[_ -]?(?:id|number|no\.?))?\s*[:#]?\s*[A-Z0-9-]{4,}\b",
        r"\b(street|road|avenue|postal address|zip code|postcode)\b",
        r"\b(email body|message body|chat body|inbox message)\b",
        r"\b(local-only|strictly private|do not share)\b",
        r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        r"\b\d{3}-\d{2}-\d{4}\b",
        r"\baccount balance\b",
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
        self.lock = self.root / ".lock"

    def initialize(self) -> None:
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
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise HandoffError("STATE_FILE_UNSAFE", "a handoff state record is not a private regular file")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise HandoffError("STATE_FILE_MODE", "a handoff state record does not have mode 0600")


def read_json_file(path: Path, *, max_bytes: int, require_private: bool = True) -> Any:
    if require_private:
        validate_private_file(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise HandoffError("RECORD_UNREADABLE", "a durable handoff record is unavailable") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > max_bytes:
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
    os.chmod(path, 0o600)
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
    os.chmod(path, 0o600)
    return sha256_bytes(data)


@contextmanager
def state_lock(layout: StateLayout) -> Iterator[None]:
    layout.initialize()
    fd = os.open(layout.lock, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    os.chmod(layout.lock, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
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


def load_config(home: Path) -> dict[str, Any] | None:
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
        try:
            canonical = source_root.resolve(strict=True)
        except OSError as exc:
            raise HandoffError("CONFIG_SOURCE_ROOT", "an approved source root is unavailable") from exc
        if path_has_symlink(source_root):
            raise HandoffError("CONFIG_SOURCE_ROOT", "an approved source root may not use symlinks")
        canonical_roots.append(str(canonical))
    value = dict(value)
    value["approved_source_roots"] = canonical_roots
    value["registration_allowlist"] = normalize_registration_allowlist(value)
    if value["registration_enabled"] or value["sealing_enabled"] or value["delivery_enabled"] or value["consumer_enabled"]:
        vault = validate_vault_binding(value)
        state_root = (home / "state" / "context-handoff").resolve(strict=False)
        if state_root == vault or vault in state_root.parents or state_root in vault.parents:
            raise HandoffError("STATE_VAULT_OVERLAP", "handoff state root must remain outside the selected Vault")
    if value["delivery_enabled"] or value["consumer_enabled"]:
        validate_runtime_config(value)
    return value


def validate_runtime_config(config: Mapping[str, Any]) -> None:
    vault = config.get("vault")
    recipient = config.get("recipient")
    transaction = config.get("transaction")
    consumer = config.get("consumer")
    if not all(isinstance(item, dict) for item in (vault, recipient, transaction, consumer)):
        raise HandoffError("CONFIG_RUNTIME", "enabled delivery and consumption require vault, recipient, transaction, and consumer bindings")
    assert isinstance(vault, dict) and isinstance(recipient, dict) and isinstance(transaction, dict) and isinstance(consumer, dict)
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
    }
    for values, required, code in (
        (vault, required_vault, "CONFIG_VAULT"),
        (recipient, required_recipient, "CONFIG_RECIPIENT"),
        (transaction, required_transaction, "CONFIG_TRANSACTION"),
    ):
        for name, expected in required.items():
            if not isinstance(values.get(name), expected) or (expected is str and not values.get(name)):
                raise HandoffError(code, f"runtime binding field {name} is invalid")
    for field in ("herdr_cli_sha256", "agent_session_sha256"):
        if not HEX64.fullmatch(str(recipient[field])):
            raise HandoffError("CONFIG_RECIPIENT", f"recipient field {field} is not SHA-256")
    for field in ("core_sha256", "module_sha256"):
        if not HEX64.fullmatch(str(transaction[field])):
            raise HandoffError("CONFIG_TRANSACTION", f"transaction field {field} is not SHA-256")
    create_prefixes = consumer.get("create_prefix_allowlist")
    replace_paths = consumer.get("replace_path_allowlist")
    coupled = consumer.get("required_coupled_paths")
    if not isinstance(create_prefixes, list) or not create_prefixes or not all(safe_relative_prefix(item) for item in create_prefixes):
        raise HandoffError("CONFIG_CONSUMER", "consumer create_prefix_allowlist is invalid")
    if not isinstance(replace_paths, list) or not replace_paths or not all(safe_relative_path(item) for item in replace_paths):
        raise HandoffError("CONFIG_CONSUMER", "consumer replace_path_allowlist is invalid")
    if not isinstance(coupled, list) or not all(isinstance(item, str) and item in replace_paths for item in coupled):
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
        "provider_class",
        "supersedes",
    }
    normalized: list[dict[str, Any]] = []
    for contract in contracts:
        if not isinstance(contract, dict) or set(contract) != expected_keys:
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract has unknown or missing fields")
        if not HEX64.fullmatch(str(contract.get("statement_sha256", ""))):
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract statement hash is invalid")
        if contract.get("kind") not in KINDS or contract.get("confidence") not in CONFIDENCES or contract.get("sphere") not in SPHERES:
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
        try:
            source = raw_source.resolve(strict=True)
        except OSError as exc:
            raise HandoffError("CONFIG_ELIGIBILITY", "an eligibility contract source is unavailable") from exc
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
                "provider_class": provider,
                "supersedes": sorted(supersedes),
            }
        )
    if len({canonical_json(contract) for contract in normalized}) != len(normalized):
        raise HandoffError("CONFIG_ELIGIBILITY", "registration_allowlist repeats an eligibility contract")
    return sorted(normalized, key=canonical_json)


def eligibility_contract(
    config: Mapping[str, Any],
    *,
    source_record: str,
    source_sha256: str,
    statement: str,
    kind: str,
    confidence: str,
    sphere: str,
    provider_class: str,
    supersedes: Sequence[str],
) -> str:
    expected = {
        "source_record": source_record,
        "source_sha256": source_sha256,
        "statement_sha256": sha256_bytes(statement.encode("utf-8")),
        "kind": kind,
        "confidence": confidence,
        "sphere": sphere,
        "provider_class": provider_class,
        "supersedes": sorted(supersedes),
    }
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
    statement = validate_statement(item.get("statement"))
    provider = item.get("provider_class")
    if not isinstance(provider, str) or not PROVIDER_CLASS.fullmatch(provider) or provider not in config["allowed_provider_classes"]:
        raise HandoffError("PROVIDER_CLASS", "handoff item provider class is not authorized")
    supersedes = item.get("supersedes")
    if not isinstance(supersedes, list) or len(supersedes) > 16 or len(set(supersedes)) != len(supersedes) or not all(isinstance(value, str) and CANDIDATE_ID.fullmatch(value) for value in supersedes):
        raise HandoffError("SUPERSESSION", "handoff item supersession data is invalid")
    source_record = item.get("source_record")
    source_sha = item.get("source_sha256")
    if not isinstance(source_record, str) or len(source_record.encode("utf-8")) > 4096 or not isinstance(source_sha, str):
        raise HandoffError("SOURCE_FIELDS", "handoff item source fields are invalid")
    if verify_source:
        canonical_source, _ = validate_source_path(config, source_record, source_sha)
        source_record = str(canonical_source)
    eligibility_sha = eligibility_contract(
        config,
        source_record=source_record,
        source_sha256=source_sha,
        statement=statement,
        kind=item["kind"],
        confidence=item["confidence"],
        sphere=item["sphere"],
        provider_class=provider,
        supersedes=supersedes,
    )
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
        "provider_class": provider,
        "eligibility_sha256": eligibility_sha,
        "supersedes": sorted(supersedes),
    }


def candidate_identity(source_harness: str, session_hash: str, item_without_id: Mapping[str, Any]) -> str:
    identity = {"source_harness": source_harness, "source_session_hash": session_hash, "item": item_without_id}
    return "candidate-" + sha256_bytes(canonical_json(identity))[:48]


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


def read_candidate(path: Path, config: Mapping[str, Any]) -> dict[str, Any]:
    value = read_json_file(path, max_bytes=16 * 1024)
    if not isinstance(value, dict) or value.get("schema") != CANDIDATE_SCHEMA:
        raise HandoffError("CANDIDATE_RECORD", "candidate record is invalid")
    if value.get("source_harness") not in SOURCE_HARNESSES or not HEX64.fullmatch(str(value.get("source_session_hash", ""))):
        raise HandoffError("CANDIDATE_BINDING", "candidate source binding is invalid")
    item = validate_item(value.get("item"), config)
    if item["item_id"] != value.get("candidate_id") or path.stem != value.get("candidate_id"):
        raise HandoffError("CANDIDATE_ID", "candidate stable ID is invalid")
    return {**value, "item": item}


def _register_locked(home: Path, config: Mapping[str, Any] | None, args: argparse.Namespace, layout: StateLayout) -> dict[str, Any]:
    if not config_enabled(config, "registration_enabled"):
        raise HandoffError("REGISTRATION_DISABLED", "curated handoff registration is disabled")
    assert config is not None
    session_hash = source_session_hash(config, args.source_harness)
    source, _ = validate_source_path(config, args.source_record, args.source_sha256)
    statement = validate_statement(args.statement)
    if args.kind not in KINDS or args.confidence not in CONFIDENCES or args.sphere not in SPHERES:
        raise HandoffError("REGISTER_ENUM", "candidate classification is not allowlisted")
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
    retryable_count = len(retryable_records(layout, args.source_harness, session_hash, config))
    if retryable_count >= MAX_COMPACTION_RECORDS:
        raise HandoffError("COMPACTION_BACKPRESSURE", "retryable compaction records must drain before another candidate can register")
    claimed = claimed_candidate_ids(layout)
    pending_count = 0
    for path in layout.candidates.glob("candidate-*.json"):
        if path.stem in claimed:
            continue
        pending_candidate = read_candidate(path, config)
        if pending_candidate["source_harness"] == args.source_harness and pending_candidate["source_session_hash"] == session_hash:
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
        envelope, digest = read_envelope(layout, record_id, config)
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
        envelope, envelope_sha = read_envelope(layout, path.stem, config)
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
        envelope, digest = read_envelope(layout, path.stem, config)
        if envelope["source_harness"] == source_harness and envelope["source_session_hash"] == session_hash:
            candidates.append((str(queue.get("updated_at", "")), path.stem, digest))
    return [
        {"record_id": record_id, "envelope_sha256": digest}
        for _, record_id, digest in sorted(candidates)
    ]


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


def seal_candidates(home: Path, source_harness: str, session_hash: str, trigger: str) -> dict[str, Any]:
    config = load_config(home)
    if not config_enabled(config, "sealing_enabled"):
        return {"status": "disabled"}
    assert config is not None
    layout = StateLayout(home)
    with state_lock(layout):
        recover_orphan_queues_from_claims(layout, config)
        attempt_bindings = {
            item["record_id"]: item["envelope_sha256"]
            for item in retryable_records(layout, source_harness, session_hash, config)
        }
        claimed = claimed_candidate_ids(layout)
        matching: dict[str, dict[str, Any]] = {}
        for path in sorted(layout.candidates.glob("candidate-*.json")):
            candidate = read_candidate(path, config)
            if candidate["candidate_id"] in claimed:
                continue
            if candidate["source_harness"] == source_harness and candidate["source_session_hash"] == session_hash:
                matching[candidate["candidate_id"]] = candidate
        recovered = recover_unclaimed_records(layout, config, matching)
        matching = {key: value for key, value in matching.items() if key not in recovered}
        for record_id in sorted(set(recovered.values())):
            _, digest = read_envelope(layout, record_id, config)
            attempt_bindings[record_id] = digest
        if not matching:
            if attempt_bindings:
                return compaction_attempt_result("already-sealed", [{"record_id": key, "envelope_sha256": value} for key, value in attempt_bindings.items()])
            write_receipt(layout, "seal", "empty", "no-registered-candidates", source_harness=source_harness, trigger=trigger)
            return {"status": "empty"}
        if len(matching) > MAX_ITEMS:
            write_receipt(layout, "seal", "failed", "item-cap-exceeded", source_harness=source_harness, trigger=trigger, candidate_count=len(matching))
            return {"status": "seal-failed", "had_candidates": True, "reason": "item-cap-exceeded"}
        items = [matching[key]["item"] for key in sorted(matching)]
        envelope: dict[str, Any] = {
            "schema": HANDOFF_SCHEMA,
            "record_id": "",
            "source_harness": source_harness,
            "source_session_hash": session_hash,
            "trigger": trigger,
            "created_at": now_utc(),
            "items": items,
        }
        envelope["record_id"] = envelope_identity(envelope)
        data = canonical_json(envelope)
        if len(data) > MAX_ENVELOPE_BYTES:
            write_receipt(layout, "seal", "failed", "byte-cap-exceeded", source_harness=source_harness, trigger=trigger, candidate_count=len(items), envelope_bytes=len(data))
            return {"status": "seal-failed", "had_candidates": True, "reason": "byte-cap-exceeded"}
        if len(attempt_bindings) >= MAX_COMPACTION_RECORDS:
            write_receipt(layout, "seal", "failed", "compaction-record-cap-exceeded", source_harness=source_harness, trigger=trigger, retryable_count=len(attempt_bindings))
            return {"status": "seal-failed", "had_candidates": True, "reason": "compaction-record-cap-exceeded"}
        validate_envelope(envelope, config)
        try:
            digest = atomic_create(record_file(layout, envelope["record_id"]), data)
            update_queue(layout, envelope["record_id"], envelope_sha256=digest)
            for candidate_id in sorted(matching):
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


def matching_candidate_present(layout: StateLayout, source_harness: str, session_hash: str) -> bool:
    layout.initialize()
    for path in sorted(layout.candidates.glob("candidate-*.json")):
        try:
            value = read_json_file(path, max_bytes=16 * 1024)
        except HandoffError:
            continue
        if (
            isinstance(value, dict)
            and value.get("schema") == CANDIDATE_SCHEMA
            and value.get("source_harness") == source_harness
            and value.get("source_session_hash") == session_hash
        ):
            return True
    return False


def seal_with_failure_receipt(home: Path, source_harness: str, session_hash: str, trigger: str) -> dict[str, Any]:
    try:
        return seal_candidates(home, source_harness, session_hash, trigger)
    except HandoffError as exc:
        layout = StateLayout(home)
        if not matching_candidate_present(layout, source_harness, session_hash):
            raise
        with state_lock(layout):
            write_receipt(layout, "seal", "failed", "registered-candidate-validation-failed", source_harness=source_harness, trigger=trigger, failure_code=exc.code)
        return {"status": "seal-failed", "had_candidates": True, "reason": "registered-candidate-validation-failed"}


def command_seal(args: argparse.Namespace) -> dict[str, Any]:
    if args.source_harness not in SOURCE_HARNESSES or args.trigger not in TRIGGERS:
        raise HandoffError("SEAL_ENUM", "seal source or trigger is invalid")
    home = resolve_home(args.fm_home)
    config = load_config(home)
    if not config_enabled(config, "sealing_enabled"):
        return {"status": "disabled"}
    assert config is not None
    event = parse_event_stdin()
    supplied = event.get("session_id")
    if supplied is not None and not isinstance(supplied, str):
        raise HandoffError("SESSION_ID", "session_id must be text")
    if args.source_harness == "claude":
        if not supplied:
            raise HandoffError("SESSION_ID", "Claude sealing requires its hook session_id")
        session_hash = hash_session("claude", supplied)
        expected = source_session_hash(config, "claude")
        if session_hash != expected:
            return {"status": "recipient-mismatch"}
    else:
        session_hash = source_session_hash(config, "pi", supplied)
    result = seal_with_failure_receipt(home, args.source_harness, session_hash, args.trigger)
    if args.standalone and result.get("status") in {"sealed", "already-sealed"}:
        mark_compaction(home, normalize_compaction_bindings(result.get("bindings")), True, args.trigger, "standalone-manual-seal")
        deliver_pending(home)
    return result


def mark_compaction(home: Path, bindings: Sequence[Mapping[str, str]], succeeded: bool, trigger: str, reason: str) -> dict[str, Any]:
    config = load_config(home)
    if config is None:
        return {"status": "disabled"}
    normalized = normalize_compaction_bindings([dict(item) for item in bindings])
    layout = StateLayout(home)
    with state_lock(layout):
        verified: list[tuple[str, str]] = []
        for item in normalized:
            record_id = item["record_id"]
            _, actual = read_envelope(layout, record_id, config)
            queue = read_queue(layout, record_id)
            if actual != item["envelope_sha256"] or queue.get("envelope_sha256") != actual:
                quarantine(layout, record_id, "record-payload-mismatch", expected_sha256=str(queue.get("envelope_sha256", "")), observed_sha256=actual)
                update_queue(layout, record_id, status="quarantined", reason="record-payload-mismatch")
                raise HandoffError("PAYLOAD_MISMATCH", "stable record ID binds changed payload bytes")
            verified.append((record_id, actual))
        status = "succeeded" if succeeded else "failed"
        queue_reason = "consumer-not-yet-notified" if succeeded else "source-compaction-failed"
        for record_id, actual in verified:
            update_queue(layout, record_id, status="pending", reason=queue_reason, compaction=status)
            write_receipt(layout, "compaction", status, reason, record_id=record_id, envelope_sha256=actual, trigger=trigger, attempt_record_count=len(verified))
        return {"status": f"compaction-{status}", "record_ids": [record_id for record_id, _ in verified]}


def command_compaction_outcome(args: argparse.Namespace) -> dict[str, Any]:
    home = resolve_home(args.fm_home)
    event = parse_event_stdin()
    trigger = event.get("trigger")
    raw_bindings = event.get("bindings")
    if raw_bindings is None and isinstance(event.get("record_id"), str) and isinstance(event.get("envelope_sha256"), str):
        raw_bindings = [{"record_id": event["record_id"], "envelope_sha256": event["envelope_sha256"]}]
    try:
        bindings = normalize_compaction_bindings(raw_bindings)
    except HandoffError:
        bindings = []
    if not bindings or trigger not in TRIGGERS:
        layout = StateLayout(home)
        with state_lock(layout):
            write_receipt(layout, "compaction", "failed", "outcome-without-seal-binding", trigger=str(trigger or "unknown"))
        return {"status": "unbound-outcome"}
    result = mark_compaction(home, bindings, args.outcome == "success", trigger, str(event.get("reason") or args.outcome))
    if args.outcome == "success":
        delivery = deliver_pending(home)
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


def run_bounded(command: Sequence[str], *, timeout: float = 15.0, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    stdin_offset = 0
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ.copy(),
        )
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
        if process is not None:
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def probe_recipient(config: Mapping[str, Any], *, require_idle: bool = True) -> tuple[bool, str, Path]:
    recipient = config["recipient"]
    herdr = validate_executable(recipient["herdr_cli_path"], recipient["herdr_cli_sha256"], "HERDR_IDENTITY")
    completed = run_bounded([str(herdr), "agent", "get", recipient["pane_id"], "--session", recipient["session"]], timeout=10.0)
    if completed.returncode != 0:
        return False, "recipient-unavailable", herdr
    try:
        response = json.loads(completed.stdout)
        agent = response["result"]["agent"]
    except (KeyError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        return False, "recipient-ambiguous", herdr
    if not isinstance(agent, dict):
        return False, "recipient-ambiguous", herdr
    exact = (
        agent.get("pane_id") == recipient["pane_id"]
        and agent.get("workspace_id") == recipient["workspace_id"]
        and agent.get("tab_id") == recipient["tab_id"]
        and agent.get("agent") == recipient["agent"]
    )
    session = agent.get("agent_session")
    if not isinstance(session, dict) or session.get("agent") != recipient["agent"] or session.get("kind") != "id" or not isinstance(session.get("value"), str):
        exact = False
    elif hash_session("claude", session["value"]) != recipient["agent_session_sha256"]:
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
        return False, "recipient-identity-mismatch", herdr
    status = agent.get("agent_status")
    if status not in {"idle", "working", "blocked", "done"}:
        return False, "recipient-not-alive", herdr
    if require_idle and status not in {"idle", "done"}:
        return False, "recipient-not-idle", herdr
    return True, "recipient-ready", herdr


def deliver_pending(home: Path) -> dict[str, Any]:
    config = load_config(home)
    if not config_enabled(config, "delivery_enabled"):
        return {"status": "disabled"}
    assert config is not None
    layout = StateLayout(home)
    with state_lock(layout):
        pending: list[str] = []
        for path in sorted(layout.queue.glob("handoff-*.json")):
            queue = read_queue(layout, path.stem)
            if queue.get("status") == "pending" and queue.get("compaction") == "succeeded":
                pending.append(path.stem)
        if not pending:
            return {"status": "nothing-pending"}
        record_id = pending[0]
        ready, reason, _herdr = probe_recipient(config)
        if not ready:
            update_queue(layout, record_id, reason=reason, attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1)
            write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
            return {"status": "pending", "reason": reason, "pending_count": len(pending)}
        reason = "recipient-atomic-generation-prompt-unsupported"
        update_queue(layout, record_id, reason=reason, attempts=int(read_queue(layout, record_id).get("attempts", 0)) + 1)
        write_receipt(layout, "delivery", "pending", reason, record_id=record_id, pending_count=len(pending))
        return {"status": "pending", "reason": reason, "pending_count": len(pending)}


def command_deliver(args: argparse.Namespace) -> dict[str, Any]:
    return deliver_pending(resolve_home(args.fm_home))


def current_process_capability() -> str:
    test_value = os.environ.get("FM_HANDOFF_TEST_PROCESS_CAPABILITY")
    if os.environ.get("FM_HANDOFF_TESTING") == "1" and test_value is not None:
        if not test_value or len(test_value.encode("utf-8")) > 256:
            raise HandoffError("PROCESS_CAPABILITY", "the synthetic hook process capability is invalid")
        return sha256_bytes(f"test\0{test_value}".encode("utf-8"))
    process_group = os.getpgrp()
    session = os.getsid(0)
    if sys.platform.startswith("linux"):
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
        if recorded_group != process_group or recorded_session != session or owner != os.getuid() or not start_time.isdigit():
            raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is inconsistent")
        identity = f"linux\0{process_group}\0{session}\0{start_time}\0{owner}"
    else:
        try:
            completed = subprocess.run(
                ["/bin/ps", "-p", str(process_group), "-o", "pgid=", "-o", "sid=", "-o", "lstart=", "-o", "command="],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2.0,
                check=False,
                env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is unavailable") from exc
        try:
            output = completed.stdout.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError as exc:
            raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is unavailable") from exc
        if completed.returncode != 0 or not output or len(output.encode("utf-8")) > 4096:
            raise HandoffError("PROCESS_CAPABILITY", "the current Claude process capability is unavailable")
        identity = f"posix\0{process_group}\0{session}\0{output}"
    return sha256_bytes(identity.encode("utf-8"))


def endpoint_binding_key(config: Mapping[str, Any]) -> str:
    recipient = config["recipient"]
    text = "\0".join(str(recipient[key]) for key in ("session", "workspace_id", "tab_id", "pane_id"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:48]


def bind_claude_session(home: Path, config: Mapping[str, Any], payload: Mapping[str, Any]) -> bool:
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or hash_session("claude", session_id) != config["recipient"]["agent_session_sha256"]:
        return False
    if not recipient_context_matches(config, require_environment=True):
        return False
    layout = StateLayout(home)
    binding = {
        "schema": BINDING_SCHEMA,
        "binding_key": endpoint_binding_key(config),
        "session_hash": config["recipient"]["agent_session_sha256"],
        "process_capability_sha256": current_process_capability(),
        "vault_path": str(validate_vault_binding(config)),
        "bound_at": now_utc(),
    }
    with state_lock(layout):
        atomic_replace(layout.bindings / f"{binding['binding_key']}.json", canonical_json(binding))
    return True


def require_consumer_binding(home: Path, config: Mapping[str, Any]) -> None:
    if not config_enabled(config, "consumer_enabled"):
        raise HandoffError("CONSUMER_DISABLED", "the Claude handoff consumer is disabled")
    if not recipient_context_matches(config, require_environment=True):
        raise HandoffError("CONSUMER_ENDPOINT", "consumer process is not the exact authorized Herdr endpoint and Vault")
    recipient_ready, _reason, _herdr = probe_recipient(config, require_idle=False)
    if not recipient_ready:
        raise HandoffError("CONSUMER_SESSION", "consumer process is not bound to the exact live Claude session generation")
    layout = StateLayout(home)
    path = layout.bindings / f"{endpoint_binding_key(config)}.json"
    value = read_json_file(path, max_bytes=4096)
    if (
        not isinstance(value, dict)
        or value.get("schema") != BINDING_SCHEMA
        or value.get("session_hash") != config["recipient"]["agent_session_sha256"]
        or value.get("process_capability_sha256") != current_process_capability()
        or value.get("vault_path") != str(validate_vault_binding(config))
    ):
        raise HandoffError("CONSUMER_SESSION", "consumer session generation is not bound")


def compaction_binding_path(layout: StateLayout, config: Mapping[str, Any]) -> Path:
    return layout.bindings / f"compaction-{endpoint_binding_key(config)}.json"


def durable_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    fsync_directory(path.parent)


def persist_compaction_binding(home: Path, config: Mapping[str, Any], result: Mapping[str, Any], trigger: str) -> None:
    layout = StateLayout(home)
    with state_lock(layout):
        path = compaction_binding_path(layout, config)
        if result.get("status") not in {"sealed", "already-sealed"}:
            durable_unlink(path)
            return
        bindings = normalize_compaction_bindings(result.get("bindings"))
        for item in bindings:
            envelope, actual = read_envelope(layout, item["record_id"], config)
            if actual != item["envelope_sha256"] or envelope.get("source_harness") != "claude" or envelope.get("source_session_hash") != config["recipient"]["agent_session_sha256"]:
                raise HandoffError("COMPACTION_BINDING", "Claude PreCompact seal binding is inconsistent")
        binding = {
            "schema": COMPACTION_BINDING_SCHEMA,
            "binding_key": endpoint_binding_key(config),
            "session_hash": config["recipient"]["agent_session_sha256"],
            "process_capability_sha256": current_process_capability(),
            "bindings": bindings,
            "trigger": trigger,
            "bound_at": now_utc(),
        }
        atomic_replace(path, canonical_json(binding))


def load_compaction_binding(home: Path, config: Mapping[str, Any]) -> tuple[list[dict[str, str]], str] | None:
    layout = StateLayout(home)
    with state_lock(layout):
        path = compaction_binding_path(layout, config)
        if not path.exists():
            return None
        value = read_json_file(path, max_bytes=16 * 1024)
        if (
            not isinstance(value, dict)
            or value.get("schema") != COMPACTION_BINDING_SCHEMA
            or value.get("binding_key") != endpoint_binding_key(config)
            or value.get("session_hash") != config["recipient"]["agent_session_sha256"]
            or value.get("process_capability_sha256") != current_process_capability()
            or value.get("trigger") not in TRIGGERS
        ):
            raise HandoffError("COMPACTION_BINDING", "durable Claude PreCompact binding is invalid")
        raw_bindings = value.get("bindings")
        if raw_bindings is None and isinstance(value.get("record_id"), str) and isinstance(value.get("envelope_sha256"), str):
            raw_bindings = [{"record_id": value["record_id"], "envelope_sha256": value["envelope_sha256"]}]
        bindings = normalize_compaction_bindings(raw_bindings)
        return bindings, str(value["trigger"])


def clear_compaction_binding(home: Path, config: Mapping[str, Any]) -> None:
    layout = StateLayout(home)
    with state_lock(layout):
        durable_unlink(compaction_binding_path(layout, config))


def hook_output(value: Mapping[str, Any] | None = None, *, stderr: bool = False) -> None:
    if value:
        stream = sys.stderr if stderr else sys.stdout
        stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        stream.write("\n")


def command_claude_hook(args: argparse.Namespace) -> dict[str, Any] | None:
    home = resolve_home(args.fm_home)
    payload = parse_event_stdin()
    event_name = payload.get("hook_event_name")
    try:
        config = load_config(home)
    except HandoffError:
        if event_name == "PreToolUse":
            return guard_deny("The context handoff safety boundary is unhealthy; mutation was denied.")
        raise
    if config is None:
        return None
    if event_name == "PreToolUse":
        return guard_decision(home, config, payload)
    if not config_enabled(config, "sealing_enabled") and not config_enabled(config, "consumer_enabled"):
        return None
    if event_name == "SessionStart":
        if not config_enabled(config, "consumer_enabled") or not bind_claude_session(home, config, payload):
            return None
        layout = StateLayout(home)
        with state_lock(layout):
            pending = sum(1 for path in layout.queue.glob("handoff-*.json") if read_queue(layout, path.stem).get("status") in {"pending", "notified"})
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
        if not config_enabled(config, "sealing_enabled") or not bind_claude_session(home, config, payload):
            return None
        trigger = "manual" if payload.get("trigger") == "manual" else "threshold"
        result = seal_with_failure_receipt(home, "claude", config["recipient"]["agent_session_sha256"], trigger)
        persist_compaction_binding(home, config, result, trigger)
        if result.get("status") == "seal-failed" and result.get("had_candidates"):
            return {"decision": "block", "reason": "Already-curated handoff candidates could not be sealed durably; compaction was stopped."}
        return None
    if event_name == "PostCompact":
        if not config_enabled(config, "sealing_enabled") or not bind_claude_session(home, config, payload):
            return None
        binding = load_compaction_binding(home, config)
        if binding:
            mark_compaction(home, binding[0], True, binding[1], "claude-post-compact")
            clear_compaction_binding(home, config)
        return None
    if event_name == "StopFailure":
        if not config_enabled(config, "sealing_enabled") or not bind_claude_session(home, config, payload):
            return None
        binding = load_compaction_binding(home, config)
        if binding:
            mark_compaction(home, binding[0], False, binding[1], "claude-provider-failure")
            clear_compaction_binding(home, config)
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
    if lowered.startswith("mcp__") and lowered not in HANDOFF_MCP_TOOLS:
        return guard_deny("Unrelated MCP tools are not authorized to mutate this Vault or outside paths.")
    return None


def validate_transaction_core(config: Mapping[str, Any]) -> tuple[Path, Path, Path]:
    transaction = config["transaction"]
    python_path = Path(transaction["python_path"])
    if not python_path.is_absolute() or path_has_symlink(python_path) or not python_path.resolve(strict=True).is_file():
        raise HandoffError("PYTHON_IDENTITY", "transaction Python executable binding is unavailable")
    core = validate_executable(transaction["core_path"], transaction["core_sha256"], "TRANSACTION_CORE_IDENTITY")
    module = validate_executable(transaction["module_path"], transaction["module_sha256"], "TRANSACTION_MODULE_IDENTITY")
    return python_path.resolve(strict=True), core, module


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
    if not create_paths:
        raise HandoffError("BUNDLE_DESTRUCTIVE", "automatic Save requires at least one new non-canonical note")
    if not set(consumer["required_coupled_paths"]).issubset(paths):
        raise HandoffError("BUNDLE_COUPLED", "automatic Save lacks required coupled index, log, or hot updates")
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


def core_json_call(command: Sequence[str], *, expected_codes: set[int] = {0}) -> tuple[dict[str, Any] | None, int]:
    completed = run_bounded(command, timeout=30.0)
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
    common = (
        journal.get("schema") == TRANSACTION_JOURNAL_SCHEMA
        and result.get("schema") == TRANSACTION_RESULT_SCHEMA
        and journal.get("state") == "complete"
        and result.get("status") == "complete"
        and journal.get("operation_id") == result.get("operation_id") == operation_id
        and journal.get("operation_type") == result.get("operation_type") == "save"
        and journal.get("input_bundle_sha256") == result.get("bundle_sha256") == approval.get("bundle_sha256")
        and journal.get("approval_sha256") == result.get("approval_sha256") == approval.get("approval_sha256")
        and journal.get("expanded_bundle_sha256") == result.get("expanded_bundle_sha256")
    )
    if not common:
        raise HandoffError("TRANSACTION_BINDING", "transaction result does not match its reviewed approval binding")
    changed = result.get("changed_paths")
    hashes = result.get("hashes")
    if not isinstance(changed, list) or not isinstance(hashes, dict) or set(changed) != set(hashes):
        raise HandoffError("TRANSACTION_PATHS", "transaction changed-path result is invalid")
    if journal.get("applied") != changed:
        raise HandoffError("TRANSACTION_APPLIED", "transaction journal does not prove every changed path was applied")
    for relative in changed:
        target = safe_vault_target(vault, relative)
        if not target.is_file() or sha256_file(target) != hashes.get(relative):
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
        if exc.code in {"TRANSACTION_INCOMPLETE", "TRANSACTION_LOCK"}:
            return None
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


def _mcp_next_locked(home: Path, config: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    require_consumer_binding(home, config)
    for ack_path in sorted(layout.acks.glob("handoff-*.json")):
        validate_private_file(ack_path)
    candidates: list[tuple[str, str]] = []
    for path in sorted(layout.queue.glob("handoff-*.json")):
        queue = read_queue(layout, path.stem)
        if queue.get("status") in {"pending", "notified"} and queue.get("compaction") == "succeeded":
            candidates.append((str(queue.get("created_at", "")), path.stem))
    for _, record_id in sorted(candidates):
        if recover_terminal_disposition_ack(layout, record_id):
            continue
        healed = find_completed_approval(home, config, record_id)
        if healed:
            continue
        if ack_path_for(layout, record_id).exists():
            quarantine(layout, record_id, "acknowledgement-recovery-incomplete")
            update_queue(layout, record_id, status="quarantined", reason="acknowledgement-recovery-incomplete")
            raise HandoffError("ACK_INCOMPLETE", "durable acknowledgement could not be reconciled with its terminal result")
        envelope, queue, digest = consumer_record(home, config, record_id)
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


def mcp_next(home: Path, config: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_next_locked(home, config, layout)


def _mcp_disposition_locked(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    record_id = arguments.get("record_id")
    disposition = arguments.get("disposition")
    rationale = arguments.get("rationale")
    if not isinstance(record_id, str) or disposition not in DISPOSITIONS or not isinstance(rationale, str) or not 1 <= len(rationale) <= 500:
        raise HandoffError("DISPOSITION_INPUT", "consumer disposition input is invalid")
    validate_statement(rationale)
    require_consumer_binding(home, config)
    completed = find_completed_approval(home, config, record_id)
    if completed is not None:
        return {
            "status": "acknowledged",
            "record_id": record_id,
            "disposition": "saved",
            "operation_id": completed["operation_id"],
        }
    _envelope, queue_before, _digest = consumer_record(home, config, record_id)
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


def mcp_disposition(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_disposition_locked(home, config, arguments, layout)


def _mcp_prepare_save_locked(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any], layout: StateLayout) -> dict[str, Any]:
    record_id = arguments.get("record_id")
    bundle = arguments.get("bundle")
    duplicate_check = arguments.get("duplicate_check")
    if not isinstance(record_id, str):
        raise HandoffError("PREPARE_INPUT", "Save preparation input is invalid")
    require_consumer_binding(home, config)
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
    python_path, core, module = validate_transaction_core(config)
    vault = validate_vault_binding(config)
    plan, code = core_json_call([str(python_path), str(core), "transaction", "inspect", str(bundle_path), "--vault", str(vault)])
    if code != 0 or plan is None:
        raise HandoffError("TRANSACTION_INSPECT", "transaction core refused the proposed Save plan")
    if plan.get("schema") != TRANSACTION_PLAN_SCHEMA or plan.get("operation_id") != deterministic_operation_id(record_id) or plan.get("operation_type") != "save" or not HEX64.fullmatch(str(plan.get("input_bundle_sha256", ""))) or not HEX64.fullmatch(str(plan.get("approval_sha256", ""))):
        raise HandoffError("TRANSACTION_PLAN", "transaction inspect result does not match the proposed Save bundle")
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
        "changed_paths": plan.get("changed_paths"),
        "hashes": plan.get("hashes"),
        "core_path": str(core),
        "core_sha256": config["transaction"]["core_sha256"],
        "module_path": str(module),
        "module_sha256": config["transaction"]["module_sha256"],
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


def mcp_prepare_save(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_prepare_save_locked(home, config, arguments, layout)


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
    python_path, core, _module = validate_transaction_core(config)
    vault = validate_vault_binding(config)
    bundle_path = Path(approval["bundle_path"])
    if sha256_file(bundle_path, max_bytes=MAX_TRANSACTION_BUNDLE_BYTES) != approval["bundle_file_sha256"]:
        quarantine(layout, record_id, "approved-bundle-payload-mismatch")
        update_queue(layout, record_id, status="quarantined", reason="approved-bundle-payload-mismatch")
        raise HandoffError("BUNDLE_MISMATCH", "approved Save bundle bytes changed")
    result, code = core_json_call(
        [str(python_path), str(core), "transaction", "apply", str(bundle_path), "--vault", str(vault), "--approved-plan-sha256", approval_sha],
        expected_codes={0, 75},
    )
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


def mcp_commit_save(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any]) -> dict[str, Any]:
    layout = StateLayout(home)
    with state_lock(layout):
        return _mcp_commit_save_locked(home, config, arguments, layout)


def mcp_register(home: Path, config: Mapping[str, Any], arguments: Mapping[str, Any]) -> dict[str, Any]:
    namespace = argparse.Namespace(
        fm_home=str(home),
        source_harness="claude",
        kind=arguments.get("kind"),
        statement=arguments.get("statement"),
        source_record=arguments.get("source_record"),
        source_sha256=arguments.get("source_sha256"),
        confidence=arguments.get("confidence"),
        sphere=arguments.get("sphere"),
        provider_class=arguments.get("provider_class"),
        supersedes=arguments.get("supersedes") or [],
    )
    layout = StateLayout(home)
    with state_lock(layout):
        current_config = load_config(home)
        if current_config is None or not config_enabled(current_config, "consumer_enabled"):
            raise HandoffError("CONSUMER_DISABLED", "the Claude handoff consumer is disabled")
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
                "required": ["record_id", "duplicate_check", "bundle"],
                "properties": {
                    "record_id": {"type": "string"},
                    "duplicate_check": {"type": "object"},
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
    config = load_config(home)
    if config is None or not config_enabled(config, "consumer_enabled"):
        raise HandoffError("CONSUMER_DISABLED", "the Claude handoff consumer is disabled")
    if not isinstance(arguments, dict):
        raise HandoffError("MCP_ARGUMENTS", "MCP tool arguments must be an object")
    handlers = {
        "register_curated_candidate": lambda: mcp_register(home, config, arguments),
        "next_curated_handoff": lambda: mcp_next(home, config),
        "record_curation_disposition": lambda: mcp_disposition(home, config, arguments),
        "prepare_handoff_save": lambda: mcp_prepare_save(home, config, arguments),
        "commit_handoff_save": lambda: mcp_commit_save(home, config, arguments),
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
            continue
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
