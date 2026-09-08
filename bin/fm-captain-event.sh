#!/usr/bin/env bash
# fm-captain-event.sh - optional, private semantic captain-event outbox.
#
# CONTRACT (this header owns the fm-captain-event.v1 storage format).
#   - Activation is explicit and home-local: config/captain-event-outbox must be
#     a regular single-link file containing exactly "enabled\n".  When it is
#     absent, every data command exits successfully without output or state
#     artifacts.  Malformed activation state is an error, never an implicit on
#     or off decision.
#   - Store: state/captain-events/events.jsonl under a mode-0700 directory, with
#     one canonical mode-0600 JSON object per line and a hard 10,000-event P0
#     ceiling (at most 81,920,000 serialized bytes).  Every object has exactly:
#       schema, seq, event_id, published_at_ms, occurred_at_ms, source_home,
#       source_role, task_id, incarnation, producer, harness_event_id,
#       audience, kind, summary, summary_truncated, refs.
#     schema is "fm-captain-event.v1"; audience is always "captain"; kind is
#     primary.message|primary.final for source_role=primary or
#     worker.message|worker.final for source_role=worker.  source_home is main
#     or secondmate:<stable-id>.  Worker rows require a task id; primary rows
#     forbid one.  refs is an object containing only pr_url, report_id,
#     report_path, and/or branch_outcome_seq with their validated value shapes.
#   - Identity is the SHA-256 of schema + source_home + source_role + task_id +
#     incarnation + producer + harness_event_id.  Retrying the same identity and
#     canonical payload returns its original seq without changing bytes.  The
#     same identity with any different semantic payload is a conflict and
#     refuses.  seq is a gap-free, monotonically increasing home-local integer.
#   - Every operation validates the complete journal, including canonical JSON,
#     exact keys, bounds, event identity, duplicate ids, and sequence ordering.
#     Records are separated and terminated only by LF; CRLF, bare CR, Unicode
#     separators, and any other malformed ending are invalid.  A malformed,
#     gapped, reordered, duplicate, unterminated, insecure, or oversized record
#     stops the operation before a cursor or event can advance.
#   - Publication is serialized by a private advisory lock.  A complete next
#     journal is fsync'd and atomically renamed, so a crash exposes either the
#     old journal or its exact old-byte-prefix successor, never a torn append.
#     Before that rename, the exact assigned event is atomically retained under
#     pending/.  append and recover finish a valid pending publication; read and
#     validate remain non-destructive and refuse while recovery is owed.
#   - summary is inert single-line text: ANSI/control characters are removed and
#     whitespace is collapsed.  At the first direct or append-style environment
#     assignment marker, the safe prefix is retained, one [REDACTED] marker is
#     emitted, and the remaining text is discarded without parsing shell syntax;
#     bare URI userinfo and other high-confidence credential shapes are redacted.
#     The result is capped at 600 Unicode codepoints.  One serialized event,
#     including its terminating newline, is capped at 8192 bytes.  No prompt,
#     reasoning, tool argument/result, terminal, environment value, credential
#     field, or arbitrary reference key exists in the schema.
#   - read --after is stateless: it validates the complete journal, prints only
#     rows with seq greater than the caller's cursor (up to --limit), and writes
#     no consumer cursor.  Every consumer owns its cursor and payload-hash ledger
#     outside Firstmate.  A cursor beyond the tail refuses.
#   - ack records a consumer's monotonic through-sequence and exact event id in
#     a private atomic receipt under acks/.  It never advances a read cursor or
#     removes journal bytes.  By contract a consumer calls it only AFTER the
#     matching event range and its own cursor are durably committed together;
#     transport receipt, parsing, or an attempted insert is not ingestion.
#   - This outbox mirrors semantic Pi call sites only.  It never acknowledges,
#     dispatches, merges, lands, completes, or retires work, and it does not
#     replace branch-outcome or public-followup ownership.
#
# Usage:
#   fm-captain-event.sh enabled
#     Exit 0 only when this home is explicitly enabled; exit 1 when absent.
#   fm-captain-event.sh append --source main|secondmate:<id> \
#       --source-role primary|worker [--task <id>] \
#       --incarnation <stable-id> --producer <name> \
#       --harness-event-id <stable-id> --audience captain \
#       --kind primary.message|primary.final|worker.message|worker.final \
#       --summary <text> [--summary-truncated true|false] \
#       [--occurred-at-ms <uint>] [--ref <allowlisted-key>=<value>]...
#     Publish or idempotently find an event; print its seq.
#   fm-captain-event.sh read --after <uint> [--limit <1..1000>]
#     Print canonical JSONL after the caller-owned cursor (default limit 100).
#   fm-captain-event.sh ack --consumer <safe-id> --through <positive-uint> \
#       --event-id sha256:<digest>
#     Record durable consumer ingestion through the exact named event.
#   fm-captain-event.sh validate
#     Validate all private state without changing it; print the journal tail.
#   fm-captain-event.sh recover
#     Finish an interrupted atomic publication; print the journal tail.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_CAPTAIN_EVENT_HOME="$FM_HOME"
export FM_CAPTAIN_EVENT_STATE="$STATE"
export FM_CAPTAIN_EVENT_CONFIG="$CONFIG"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for the captain-event outbox" >&2
  exit 1
fi

exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
import os
import re
import stat
import sys
import time
import unicodedata
import uuid
from pathlib import Path

try:
    import fcntl
except ImportError:
    print(
        "error: python3 with the standard POSIX fcntl module is required for the captain-event outbox",
        file=sys.stderr,
    )
    raise SystemExit(1)

SCHEMA = "fm-captain-event.v1"
SUMMARY_MAX = 600
EVENT_MAX = 8192
MAX_SAFE_UINT = 9007199254740991
DEFAULT_LIMIT = 100
MAX_LIMIT = 1000
MAX_EVENTS = 10000
ACK_SCHEMA = "fm-captain-event-ack.v1"
ACK_KEYS = {"schema", "consumer", "through", "event_id", "acknowledged_at_ms"}
EVENT_KEYS = {
    "schema", "seq", "event_id", "published_at_ms", "occurred_at_ms",
    "source_home", "source_role", "task_id", "incarnation", "producer",
    "harness_event_id", "audience", "kind", "summary",
    "summary_truncated", "refs",
}
REF_KEYS = {"pr_url", "report_id", "report_path", "branch_outcome_seq"}
SLUG_RE = re.compile(r"^(?!\.)[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
PRODUCER_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
EVENT_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
GITHUB_PR_RE = re.compile(r"^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$")
GITLAB_MR_RE = re.compile(r"^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$")
ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ENV_ASSIGNMENT_START_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]{0,127}\s*(?:\+\s*)?=\s*")
AUTHORIZATION_HEADER_START_RE = re.compile(r"\b(?:Proxy-)?Authorization\s*:\s*", re.I)
CREDENTIAL_LABEL_CANDIDATE_RE = re.compile(
    r'(?:(?:"([A-Za-z0-9](?:[A-Za-z0-9 _-]{0,126}[A-Za-z0-9])?)")|'
    r'(?:(?<![A-Za-z0-9_-])([A-Za-z0-9](?:[A-Za-z0-9 _-]{0,126}[A-Za-z0-9])?)))\s*:\s*'
)
CREDENTIAL_LABEL_TERMS = {"secret", "password", "passwd", "passphrase", "pwd", "token", "authorization", "auth"}
CREDENTIAL_LABEL_SUFFIXES = ("secret", "password", "passphrase", "passwd", "pwd", "token")
CREDENTIAL_KEY_PREFIXES = {"access", "private", "api"}
CREDENTIAL_LABEL_COMPOUNDS = {
    "clientsecret", "clienttoken", "accesstoken", "accesskey", "secretkey",
    "apikey", "privatekey", "authtoken", "refreshtoken",
}
SECRET_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z0-9 ]{0,48}PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]{0,48}PRIVATE KEY-----|$)", re.I),
    re.compile(r"\b[A-Za-z][A-Za-z0-9+.-]{0,31}://[^\s/@\"']+@[^\s,;\"']+", re.I),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.I),
    re.compile(r"(?<![A-Za-z0-9_.-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_.-])"),
    re.compile(r"\b(?:password|passwd|api[_ -]?key|access[_ -]?token|pairing[_ -]?token|token|secret)\s*[:=]\s*[^\s,;]{6,}", re.I),
]

class OutboxError(Exception):
    pass


def die(message, code=1):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def is_uint(value, *, allow_zero=True):
    return type(value) is int and (value >= 0 if allow_zero else value >= 1) and value <= MAX_SAFE_UINT


def parse_uint(text, label, *, allow_zero=True):
    if not re.fullmatch(r"0|[1-9][0-9]*", text or ""):
        raise OutboxError(f"{label} must be a canonical unsigned integer")
    value = int(text)
    if not is_uint(value, allow_zero=allow_zero):
        raise OutboxError(f"{label} is out of range")
    return value


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def load_json_unique(text, label):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise OutboxError(f"{label} contains duplicate key '{key}'")
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=unique)
    except OutboxError:
        raise
    except Exception as error:
        raise OutboxError(f"{label} is malformed JSON: {error}") from error


def lstat_regular(path, label, expected_mode=None):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise OutboxError(f"{label} is missing")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise OutboxError(f"{label} must be a regular non-symlink file")
    if info.st_nlink != 1:
        raise OutboxError(f"{label} must have exactly one hard link")
    if expected_mode is not None and stat.S_IMODE(info.st_mode) != expected_mode:
        raise OutboxError(f"{label} must have mode {expected_mode:04o}")
    return info


def require_real_directory(path, label):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise OutboxError(f"{label} is missing")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise OutboxError(f"{label} must be a real directory")


def fsync_directory(path):
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def activation_state(config):
    try:
        info = config.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise OutboxError("captain-event config directory must be a real directory")
    flag = config / "captain-event-outbox"
    try:
        info = flag.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise OutboxError("config/captain-event-outbox must be a regular single-link file")
    try:
        content = flag.read_bytes()
    except OSError as error:
        raise OutboxError(f"config/captain-event-outbox is unreadable: {error}") from error
    if content != b"enabled\n":
        raise OutboxError('config/captain-event-outbox must contain exactly "enabled\\n"')
    return True


def ensure_private_dir(path, label):
    created = False
    try:
        path.mkdir(mode=0o700)
        created = True
    except FileExistsError:
        pass
    except OSError as error:
        raise OutboxError(f"could not create {label}: {error}") from error
    if created:
        path.chmod(0o700)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise OutboxError(f"{label} must be a real directory")
    mode = stat.S_IMODE(info.st_mode)
    if mode != 0o700:
        raise OutboxError(f"{label} must have mode 0700 (found {mode:04o})")
    if created:
        fsync_directory(path.parent)


def validate_source(source):
    if source == "main":
        return
    if source.startswith("secondmate:") and SLUG_RE.fullmatch(source.split(":", 1)[1]):
        return
    raise OutboxError("source must be 'main' or 'secondmate:<stable-id>'")


def validate_token(value, label):
    if not TOKEN_RE.fullmatch(value or ""):
        raise OutboxError(f"{label} must be 1..256 characters from [A-Za-z0-9._:-]")


def redact_environment_assignments(value):
    match = ENV_ASSIGNMENT_START_RE.search(value)
    if match is None:
        return value
    return value[:match.start()] + "[REDACTED]"


def redact_authorization_headers(value):
    match = AUTHORIZATION_HEADER_START_RE.search(value)
    if match is None:
        return value
    return value[:match.start()] + "[REDACTED]"


def redact_credential_labels(value):
    for match in CREDENTIAL_LABEL_CANDIDATE_RE.finditer(value):
        label = match.group(1) or match.group(2)
        segments = [segment for segment in re.split(r"[ _-]+", label.lower()) if segment]
        collapsed = "".join(segments)
        has_term = any(segment in CREDENTIAL_LABEL_TERMS for segment in segments)
        has_suffix = any(collapsed.endswith(suffix) for suffix in CREDENTIAL_LABEL_SUFFIXES)
        has_key_term = any(
            segment in CREDENTIAL_KEY_PREFIXES and index + 1 < len(segments) and segments[index + 1] == "key"
            for index, segment in enumerate(segments)
        )
        has_compound = any(compound in collapsed for compound in CREDENTIAL_LABEL_COMPOUNDS)
        if has_term or has_suffix or has_key_term or has_compound:
            return value[:match.start()] + "[REDACTED]"
    return value


def clean_summary(value):
    value = unicodedata.normalize("NFC", value)
    value = ANSI_RE.sub("", value)
    value = "".join(
        " " if unicodedata.category(ch).startswith("C") or unicodedata.category(ch) in {"Zl", "Zp"} else ch
        for ch in value
    )
    value = re.sub(r"\s+", " ", value, flags=re.UNICODE).strip()
    value = redact_environment_assignments(value)
    value = redact_authorization_headers(value)
    value = redact_credential_labels(value)
    for pattern in SECRET_PATTERNS:
        value = pattern.sub("[REDACTED]", value)
    value = re.sub(r"\s+", " ", value, flags=re.UNICODE).strip()
    return value


def canonical_pr_url(value):
    github = GITHUB_PR_RE.fullmatch(value)
    if github:
        owner, repo, _number = github.groups()
        return "--" not in owner and repo not in {".", ".."}
    gitlab = GITLAB_MR_RE.fullmatch(value)
    if not gitlab:
        return False
    host, path, _number = gitlab.groups()
    if host == "github.com" or host.startswith(".") or host.endswith(".") or ".." in host:
        return False
    if any(len(label) > 63 or label.startswith("-") or label.endswith("-") for label in host.split(".")):
        return False
    if len(path) < 3 or len(path) > 1024 or path.startswith("/") or path.endswith("/") or "//" in path:
        return False
    segments = path.split("/")
    if len(segments) < 2 or len(segments) > 20:
        return False
    return all(
        1 <= len(segment) <= 255
        and segment not in {".", ".."}
        and not segment.startswith("-")
        and not segment.endswith((".git", ".atom"))
        for segment in segments
    )


def parse_refs(values):
    refs = {}
    for item in values:
        if "=" not in item:
            raise OutboxError("each --ref must be <allowlisted-key>=<value>")
        key, value = item.split("=", 1)
        if key not in REF_KEYS:
            raise OutboxError(f"reference key '{key}' is not allowlisted")
        if key in refs:
            raise OutboxError(f"reference key '{key}' was supplied more than once")
        if key == "pr_url":
            if len(value) > 2048 or any(
                ch.isspace() or unicodedata.category(ch).startswith("C") for ch in value
            ) or not canonical_pr_url(value):
                raise OutboxError("pr_url must be a canonical supported PR or MR URL")
            refs[key] = value
        elif key == "report_id":
            if not SLUG_RE.fullmatch(value):
                raise OutboxError("report_id must be a safe slug")
            refs[key] = value
        elif key == "report_path":
            if not re.fullmatch(r"data/[A-Za-z0-9][A-Za-z0-9._-]{0,127}/report\.md", value):
                raise OutboxError("report_path must be data/<safe-id>/report.md")
            refs[key] = value
        else:
            refs[key] = parse_uint(value, "branch_outcome_seq", allow_zero=False)
    return refs


def identity_for(event):
    identity = {
        "schema": SCHEMA,
        "source_home": event["source_home"],
        "source_role": event["source_role"],
        "task_id": event["task_id"],
        "incarnation": event["incarnation"],
        "producer": event["producer"],
        "harness_event_id": event["harness_event_id"],
    }
    digest = hashlib.sha256(canonical_json(identity).encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def validate_refs(refs):
    if type(refs) is not dict or not set(refs).issubset(REF_KEYS):
        raise OutboxError("event refs contains a non-allowlisted key")
    normalized = parse_refs([
        f"{key}={value}" for key, value in refs.items()
    ])
    if normalized != refs:
        raise OutboxError("event refs is not canonical")


def validate_event(event, expected_seq=None, label="event"):
    if type(event) is not dict or set(event) != EVENT_KEYS:
        raise OutboxError(f"{label} does not have the exact {SCHEMA} field set")
    if event["schema"] != SCHEMA:
        raise OutboxError(f"{label} has an unsupported schema")
    if not is_uint(event["seq"], allow_zero=False) or event["seq"] > MAX_EVENTS:
        raise OutboxError(f"{label} seq is invalid or exceeds the hard P0 event bound")
    if expected_seq is not None and event["seq"] != expected_seq:
        raise OutboxError(f"{label} breaks the gap-free sequence at {expected_seq}")
    if not EVENT_ID_RE.fullmatch(event["event_id"] or ""):
        raise OutboxError(f"{label} event_id is invalid")
    if not is_uint(event["published_at_ms"]):
        raise OutboxError(f"{label} published_at_ms is invalid")
    if event["occurred_at_ms"] is not None and not is_uint(event["occurred_at_ms"]):
        raise OutboxError(f"{label} occurred_at_ms is invalid")
    validate_source(event["source_home"])
    if event["source_role"] not in {"primary", "worker"}:
        raise OutboxError(f"{label} source_role is invalid")
    task = event["task_id"]
    if event["source_role"] == "primary":
        if task is not None:
            raise OutboxError(f"{label} primary event must not carry a task_id")
        allowed_kinds = {"primary.message", "primary.final"}
    else:
        if type(task) is not str or not SLUG_RE.fullmatch(task):
            raise OutboxError(f"{label} worker event requires a safe task_id")
        allowed_kinds = {"worker.message", "worker.final"}
    validate_token(event["incarnation"], f"{label} incarnation")
    if type(event["producer"]) is not str or not PRODUCER_RE.fullmatch(event["producer"]):
        raise OutboxError(f"{label} producer is invalid")
    validate_token(event["harness_event_id"], f"{label} harness_event_id")
    if event["audience"] != "captain":
        raise OutboxError(f"{label} audience is not captain")
    if event["kind"] not in allowed_kinds:
        raise OutboxError(f"{label} kind does not match source_role")
    if type(event["summary"]) is not str or not event["summary"]:
        raise OutboxError(f"{label} summary is empty")
    if clean_summary(event["summary"]) != event["summary"] or len(event["summary"]) > SUMMARY_MAX:
        raise OutboxError(f"{label} summary is not canonical bounded inert text")
    if type(event["summary_truncated"]) is not bool:
        raise OutboxError(f"{label} summary_truncated is not boolean")
    validate_refs(event["refs"])
    if identity_for(event) != event["event_id"]:
        raise OutboxError(f"{label} event_id does not match its identity tuple")
    encoded = (canonical_json(event) + "\n").encode("utf-8")
    if len(encoded) > EVENT_MAX:
        raise OutboxError(f"{label} exceeds {EVENT_MAX} bytes")
    return encoded


def check_private_file(path, label):
    if not path.exists() and not path.is_symlink():
        return None
    return lstat_regular(path, label, 0o600)


def load_journal(journal):
    info = check_private_file(journal, "captain-event journal")
    if info is None:
        return []
    if info.st_size > MAX_EVENTS * EVENT_MAX:
        raise OutboxError("captain-event journal exceeds its hard P0 byte bound")
    try:
        raw = journal.read_bytes()
    except OSError as error:
        raise OutboxError(f"captain-event journal is unreadable: {error}") from error
    if not raw:
        raise OutboxError("captain-event journal exists but is unexpectedly empty")
    if not raw.endswith(b"\n"):
        raise OutboxError("captain-event journal has a torn unterminated tail")
    raw_lines = raw[:-1].split(b"\n")
    if len(raw_lines) > MAX_EVENTS:
        raise OutboxError("captain-event journal exceeds its hard P0 event bound")
    rows = []
    seen = set()
    for index, raw_line in enumerate(raw_lines, 1):
        if len(raw_line) + 1 > EVENT_MAX:
            raise OutboxError(f"captain-event journal row {index} exceeds {EVENT_MAX} bytes")
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError as error:
            raise OutboxError(f"captain-event journal row {index} is not UTF-8") from error
        event = load_json_unique(line, f"captain-event journal row {index}")
        validate_event(event, index, f"captain-event journal row {index}")
        if canonical_json(event) != line:
            raise OutboxError(f"captain-event journal row {index} is not canonical JSON")
        if event["event_id"] in seen:
            raise OutboxError(f"captain-event journal duplicates event_id {event['event_id']}")
        seen.add(event["event_id"])
        rows.append(event)
    return rows


def atomic_write(path, payload, mode=0o600):
    parent = path.parent
    temp = parent / f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    fd = None
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = None
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        os.chmod(path, mode)
        fsync_directory(parent)
    finally:
        if fd is not None:
            os.close(fd)
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def encode_journal(rows):
    return b"".join(validate_event(row, index, f"captain-event row {index}") for index, row in enumerate(rows, 1))


def write_journal(journal, rows):
    atomic_write(journal, encode_journal(rows))


def pending_files(root, pending):
    unexpected = []
    files = []
    for path in root.iterdir():
        if path.name in {"events.jsonl", ".lock", "pending", "acks"}:
            continue
        if re.fullmatch(r"\.events\.jsonl\.[1-9][0-9]*\.[0-9a-f]{32}\.tmp", path.name):
            lstat_regular(path, f"journal temporary {path.name}", 0o600)
            unexpected.append(path)
        else:
            raise OutboxError(f"unexpected private outbox entry '{path.name}'")
    for path in pending.iterdir():
        if re.fullmatch(r"\.[0-9a-f]{64}\.json\.[1-9][0-9]*\.[0-9a-f]{32}\.tmp", path.name):
            lstat_regular(path, f"pending temporary {path.name}", 0o600)
            unexpected.append(path)
            continue
        if not re.fullmatch(r"[0-9a-f]{64}\.json", path.name):
            raise OutboxError(f"unexpected pending entry '{path.name}'")
        files.append(path)
    return files, unexpected


def load_pending(path):
    lstat_regular(path, f"pending event {path.name}", 0o600)
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1 or len(raw) > EVENT_MAX:
        raise OutboxError(f"pending event {path.name} is malformed or oversized")
    try:
        line = raw[:-1].decode("utf-8")
    except UnicodeDecodeError as error:
        raise OutboxError(f"pending event {path.name} is not UTF-8") from error
    event = load_json_unique(line, f"pending event {path.name}")
    validate_event(event, label=f"pending event {path.name}")
    if canonical_json(event) != line or path.name != event["event_id"].split(":", 1)[1] + ".json":
        raise OutboxError(f"pending event {path.name} identity or encoding is inconsistent")
    return event


def remove_durable(path):
    path.unlink()
    fsync_directory(path.parent)


def recover_pending(root, pending, journal, rows, extra_temporary=()):
    files, temporary = pending_files(root, pending)
    events = [load_pending(path) for path in files]
    events.sort(key=lambda row: (row["seq"], row["event_id"]))
    simulated_rows = list(rows)
    removals = []
    seen_seq = set()
    for event in events:
        if event["seq"] in seen_seq:
            raise OutboxError(f"multiple pending events reserve seq {event['seq']}")
        seen_seq.add(event["seq"])
        seq = event["seq"]
        path = pending / (event["event_id"].split(":", 1)[1] + ".json")
        if seq <= len(simulated_rows):
            if simulated_rows[seq - 1] != event:
                raise OutboxError(f"pending seq {seq} conflicts with the published journal")
            removals.append(path)
            continue
        if seq != len(simulated_rows) + 1:
            raise OutboxError(f"pending seq {seq} would create a journal gap")
        if any(row["event_id"] == event["event_id"] for row in simulated_rows):
            raise OutboxError(f"pending event {event['event_id']} reuses an earlier identity")
        simulated_rows.append(event)
        removals.append(path)
    payload = encode_journal(simulated_rows)
    if simulated_rows != rows:
        atomic_write(journal, payload)
    for path in removals:
        remove_durable(path)
    for path in temporary:
        remove_durable(path)
    for path in extra_temporary:
        remove_durable(path)
    return simulated_rows


def semantic_payload(event):
    return {key: value for key, value in event.items() if key not in {"seq", "published_at_ms"}}


def load_ack(path):
    lstat_regular(path, f"captain-event acknowledgement {path.name}", 0o600)
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1 or len(raw) > 1024:
        raise OutboxError(f"captain-event acknowledgement {path.name} is malformed or oversized")
    try:
        line = raw[:-1].decode("utf-8")
    except UnicodeDecodeError as error:
        raise OutboxError(f"captain-event acknowledgement {path.name} is not UTF-8") from error
    record = load_json_unique(line, f"captain-event acknowledgement {path.name}")
    if type(record) is not dict or set(record) != ACK_KEYS or record.get("schema") != ACK_SCHEMA:
        raise OutboxError(f"captain-event acknowledgement {path.name} has an invalid schema")
    consumer = record.get("consumer")
    if type(consumer) is not str or not SLUG_RE.fullmatch(consumer) or path.name != consumer + ".json":
        raise OutboxError(f"captain-event acknowledgement {path.name} has an invalid consumer identity")
    if not is_uint(record.get("through"), allow_zero=False):
        raise OutboxError(f"captain-event acknowledgement {path.name} has an invalid through sequence")
    if not EVENT_ID_RE.fullmatch(record.get("event_id") or ""):
        raise OutboxError(f"captain-event acknowledgement {path.name} has an invalid event id")
    if not is_uint(record.get("acknowledged_at_ms")):
        raise OutboxError(f"captain-event acknowledgement {path.name} has an invalid timestamp")
    if canonical_json(record) != line:
        raise OutboxError(f"captain-event acknowledgement {path.name} is not canonical JSON")
    return record


def load_acks(acks):
    records = {}
    temporary = []
    for path in acks.iterdir():
        if re.fullmatch(r"\.[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json\.[1-9][0-9]*\.[0-9a-f]{32}\.tmp", path.name):
            lstat_regular(path, f"acknowledgement temporary {path.name}", 0o600)
            temporary.append(path)
            continue
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json", path.name):
            raise OutboxError(f"unexpected acknowledgement entry '{path.name}'")
        record = load_ack(path)
        records[record["consumer"]] = record
    return records, temporary


def open_lock(lock_path, exclusive):
    existed = lock_path.exists() or lock_path.is_symlink()
    if existed:
        lstat_regular(lock_path, "captain-event lock", 0o600)
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise OutboxError(f"could not open captain-event lock: {error}") from error
    try:
        if not existed:
            os.fchmod(fd, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            raise OutboxError("captain-event lock must be a mode-0600 regular single-link file")
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        return fd
    except Exception:
        os.close(fd)
        raise


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="fm-captain-event.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("enabled")
    append = sub.add_parser("append")
    append.add_argument("--source", required=True)
    append.add_argument("--source-role", required=True, choices=["primary", "worker"])
    append.add_argument("--task")
    append.add_argument("--incarnation", required=True)
    append.add_argument("--producer", required=True)
    append.add_argument("--harness-event-id", required=True)
    append.add_argument("--audience", required=True, choices=["captain"])
    append.add_argument("--kind", required=True)
    append.add_argument("--summary", required=True)
    append.add_argument("--summary-truncated", choices=["true", "false"], default="false")
    append.add_argument("--occurred-at-ms")
    append.add_argument("--ref", action="append", default=[])
    read = sub.add_parser("read")
    read.add_argument("--after", required=True)
    read.add_argument("--limit", default=str(DEFAULT_LIMIT))
    ack = sub.add_parser("ack")
    ack.add_argument("--consumer", required=True)
    ack.add_argument("--through", required=True)
    ack.add_argument("--event-id", required=True)
    sub.add_parser("validate")
    sub.add_parser("recover")
    return parser.parse_args(argv)


def build_request(args):
    validate_source(args.source)
    validate_token(args.incarnation, "incarnation")
    validate_token(args.harness_event_id, "harness_event_id")
    if not PRODUCER_RE.fullmatch(args.producer or ""):
        raise OutboxError("producer must be a lowercase safe token")
    if args.source_role == "primary":
        if args.task is not None:
            raise OutboxError("primary events must not supply --task")
        allowed = {"primary.message", "primary.final"}
        task = None
    else:
        if not SLUG_RE.fullmatch(args.task or ""):
            raise OutboxError("worker events require a safe --task")
        allowed = {"worker.message", "worker.final"}
        task = args.task
    if args.kind not in allowed:
        raise OutboxError("kind does not match source-role")
    summary = clean_summary(args.summary)
    if not summary:
        raise OutboxError("summary is empty after inert-text normalization")
    was_truncated = args.summary_truncated == "true" or len(summary) > SUMMARY_MAX
    summary = summary[:SUMMARY_MAX]
    occurred = None if args.occurred_at_ms is None else parse_uint(args.occurred_at_ms, "occurred-at-ms")
    request = {
        "schema": SCHEMA,
        "source_home": args.source,
        "source_role": args.source_role,
        "task_id": task,
        "incarnation": args.incarnation,
        "producer": args.producer,
        "harness_event_id": args.harness_event_id,
        "audience": args.audience,
        "kind": args.kind,
        "summary": summary,
        "summary_truncated": was_truncated,
        "refs": parse_refs(args.ref),
        "occurred_at_ms": occurred,
    }
    request["event_id"] = identity_for(request)
    return request


def main(argv):
    args = parse_args(argv)
    home = Path(os.environ["FM_CAPTAIN_EVENT_HOME"])
    state = Path(os.environ["FM_CAPTAIN_EVENT_STATE"])
    config = Path(os.environ["FM_CAPTAIN_EVENT_CONFIG"])
    try:
        active = activation_state(config)
    except OutboxError as error:
        die(str(error))
    if args.command == "enabled":
        return 0 if active else 1
    if not active:
        return 0

    try:
        require_real_directory(home, "Firstmate home")
        require_real_directory(state, "captain-event state directory")
        root = state / "captain-events"
        pending = root / "pending"
        acks = root / "acks"
        ensure_private_dir(root, "state/captain-events")
        ensure_private_dir(pending, "state/captain-events/pending")
        ensure_private_dir(acks, "state/captain-events/acks")
        journal = root / "events.jsonl"
        lock_path = root / ".lock"
        exclusive = args.command in {"append", "recover", "ack"}
        lock_fd = open_lock(lock_path, exclusive)
        try:
            rows = load_journal(journal)
            acknowledgements, acknowledgement_temporary = load_acks(acks)
            for acknowledgement in acknowledgements.values():
                through = acknowledgement["through"]
                if through > len(rows) or rows[through - 1]["event_id"] != acknowledgement["event_id"]:
                    raise OutboxError(f"consumer acknowledgement '{acknowledgement['consumer']}' is ahead of or conflicts with the journal")
            files, temporary = pending_files(root, pending)
            if args.command in {"read", "validate"} and acknowledgement_temporary:
                raise OutboxError("captain-event acknowledgement recovery is required before a non-destructive read")
            if args.command in {"read", "validate", "ack"} and (files or temporary):
                raise OutboxError("captain-event publication recovery is required before this operation")
            if args.command in {"append", "recover"}:
                rows = recover_pending(root, pending, journal, rows, acknowledgement_temporary)
            if args.command == "recover":
                print(len(rows))
                return 0
            if args.command == "validate":
                print(len(rows))
                return 0
            if args.command == "read":
                after = parse_uint(args.after, "after")
                limit = parse_uint(args.limit, "limit", allow_zero=False)
                if limit > MAX_LIMIT:
                    raise OutboxError(f"limit must be <= {MAX_LIMIT}")
                if after > len(rows):
                    raise OutboxError("after cursor is ahead of the validated journal tail")
                for row in rows[after:after + limit]:
                    print(canonical_json(row))
                return 0
            if args.command == "ack":
                if not SLUG_RE.fullmatch(args.consumer or ""):
                    raise OutboxError("consumer must be a safe id")
                through = parse_uint(args.through, "through", allow_zero=False)
                if through > len(rows):
                    raise OutboxError("acknowledgement is ahead of the validated journal tail")
                if not EVENT_ID_RE.fullmatch(args.event_id or "") or rows[through - 1]["event_id"] != args.event_id:
                    raise OutboxError("acknowledgement event id does not match the through sequence")
                previous = acknowledgements.get(args.consumer)
                if previous and through < previous["through"]:
                    raise OutboxError("consumer acknowledgement cannot move backwards")
                if previous and through == previous["through"]:
                    if args.event_id != previous["event_id"]:
                        raise OutboxError("consumer acknowledgement conflicts at its current sequence")
                    for path in acknowledgement_temporary:
                        remove_durable(path)
                    print(through)
                    return 0
                record = {
                    "schema": ACK_SCHEMA,
                    "consumer": args.consumer,
                    "through": through,
                    "event_id": args.event_id,
                    "acknowledged_at_ms": int(time.time() * 1000),
                }
                atomic_write(acks / f"{args.consumer}.json", (canonical_json(record) + "\n").encode("utf-8"))
                for path in acknowledgement_temporary:
                    remove_durable(path)
                print(through)
                return 0

            request = build_request(args)
            event_id = request["event_id"]
            for row in rows:
                if row["event_id"] != event_id:
                    continue
                if semantic_payload(row) != request:
                    raise OutboxError(f"event identity {event_id} conflicts with its published payload")
                print(row["seq"])
                return 0
            if len(rows) >= MAX_EVENTS:
                raise OutboxError(f"captain-event journal reached its hard {MAX_EVENTS}-event P0 bound")
            seq = len(rows) + 1
            event = {
                **request,
                "seq": seq,
                "published_at_ms": int(time.time() * 1000),
            }
            validate_event(event, seq)
            pending_path = pending / (event_id.split(":", 1)[1] + ".json")
            if pending_path.exists() or pending_path.is_symlink():
                existing = load_pending(pending_path)
                if existing != event:
                    raise OutboxError(f"pending event identity {event_id} conflicts")
            else:
                atomic_write(pending_path, validate_event(event, seq))
            crash = os.environ.get("FM_CAPTAIN_EVENT_TEST_CRASH", "")
            if crash == "after-pending":
                os._exit(97)
            rows.append(event)
            write_journal(journal, rows)
            if crash == "after-replace":
                os._exit(98)
            remove_durable(pending_path)
            print(seq)
            return 0
        finally:
            os.close(lock_fd)
    except OutboxError as error:
        die(str(error))
    except OSError as error:
        die(f"captain-event state operation failed: {error}")


raise SystemExit(main(sys.argv[1:]))
PY
