#!/usr/bin/env bash
# Private Forge adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-forge-firstmate.sh arm <forge-config.toml>
#   fm-procevent-forge-firstmate.sh classify <result-file>
#   fm-procevent-forge-firstmate.sh rearm <forge-config.toml> <result-file>
#   fm-procevent-forge-firstmate.sh terminal <result-file>
#   fm-procevent-forge-firstmate.sh source-id
#   fm-procevent-forge-firstmate.sh retire
#
# arm       Securely validate one explicit Forge TOML config, bind it to the
#           canonical source `forge-firstmate-private-v1`, and register the
#           adapter's blocking poll through bin/fm-procevent.sh.
# classify  Validate a captured page and print `records` or `malformed` without
#           printing any event content.
# rearm     Validate one captured records page from this source, advance only
#           from its committed cursor, and register the next bounded poll.
#           Call this after ordinary advisory handling and before the generic
#           `handled` acknowledgement. Repeating the same generation is safe.
# terminal  Exit 0 only for one completely validated records page. Each page is
#           terminal for its exact process-event registration generation, so a
#           handler must explicitly rearm from that captured page.
# source-id Print the one canonical source identity.
# retire    Idempotently retire the registered source. Captured pages and the
#           adapter cursor remain available; retirement never acknowledges or
#           deletes either one.
#
# The runner-only `poll <forge-config.toml>` command is intentionally omitted
# from Usage. It reads the token into the Python child only, makes a direct
# loopback HTTP request without proxy, redirect, netrc, or ambient credential
# handling, suppresses validated no-work responses internally, and prints one
# validated records page. Never run it in a conversational turn.
#
# This adapter is advisory transport only. It never mutates a backlog, routes or
# starts work, injects model context, approves a proposal, answers a decision,
# or treats any Forge byte as instruction or authority. Deterministic Forge
# event_id and revision values pass through unchanged for downstream
# deduplication; the adapter adds no queue and claims no exactly-once effect.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SOURCE_ID=forge-firstmate-private-v1
ADAPTER=forge-firstmate
LIFECYCLE_LOCK="$STATE/.forge-firstmate-private-v1.lifecycle.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
registration_file() { printf '%s/procevent/%s.source\n' "$STATE" "$SOURCE_ID"; }

python_adapter() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  python3 -I - "$@" <<'PY'
import contextlib
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import socket
import stat
import sys
import tempfile
import time
from pathlib import Path

try:
    import tomllib
except ImportError:
    print("error: Forge Firstmate adapter requires Python with tomllib", file=sys.stderr)
    sys.exit(1)

SOURCE_ID = "forge-firstmate-private-v1"
ADAPTER = "forge-firstmate"
INTERFACE = "forge.firstmate.private.v1"
EVENT_SCHEMA = "forge.firstmate.event.v1"
TASK_SCHEMA = "forge.firstmate.task-proposal.v1"
MORNING_SCHEMA = "forge.firstmate.morning-intelligence.v1"
STATE_SCHEMA = "fm-forge-firstmate-cursor.v1"
ROUTE = "/integrations/firstmate/v1/events"
MAX_CONFIG = 65_536
MAX_BODY = 196_608
MAX_RESULT = MAX_BODY + 1
MAX_HEADERS = 16_384
MAX_EVENTS = 8
REQUEST_SECONDS = 36.0
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
SHA256 = re.compile(r"sha256:([0-9a-f]{64})\Z")
CURSOR = re.compile(r"ffc1\.([0-9a-f]{64})\.([0-9]{1,10})\Z")
CAPTURE_ID = re.compile(r"[A-Za-z0-9_.:/-]{1,96}\Z")
ITEM_ID = re.compile(r"[A-Za-z0-9_-]{1,96}\Z")
STATE_TIMESTAMP = re.compile(r"[0-9]{1,20}\.[0-9]{9}\Z")
REQUEST_FINGERPRINT = re.compile(r"capture-request-sha256:[0-9a-f]{64}\Z")
ALLOWED_HOSTS = {
    "api.github.com", "arxiv.org", "developers.openai.com",
    "export.arxiv.org", "github.com", "huggingface.co", "openai.com",
    "raw.githubusercontent.com",
}
UNKNOWN_CURSOR = object()

class Refusal(Exception):
    pass

def refuse(message):
    raise Refusal(message)

def exact(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        refuse(f"{label} fields are invalid")

def text(value, label, minimum=0, maximum=None, normalized=False):
    if not isinstance(value, str):
        refuse(f"{label} is not text")
    if len(value) < minimum or (maximum is not None and len(value) > maximum):
        refuse(f"{label} is outside its bound")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        refuse(f"{label} contains controls")
    if normalized and " ".join(value.split()) != value:
        refuse(f"{label} is not normalized")
    return value

def integer(value, label, maximum):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        refuse(f"{label} is outside its bound")
    return value

def boolean(value, label):
    if not isinstance(value, bool):
        refuse(f"{label} is not boolean")
    return value

def sha(value, label):
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        refuse(f"{label} is not a SHA-256 reference")
    return value

def calendar_date(value, label):
    text(value, label, 10, 10)
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError:
        refuse(f"{label} is invalid")
    if parsed.isoformat() != value:
        refuse(f"{label} is not normalized")
    return value

def state_timestamp(value, label):
    if not isinstance(value, str) or STATE_TIMESTAMP.fullmatch(value) is None:
        refuse(f"{label} is invalid")
    return value

def branch(value):
    text(value, "branch", 1, 160)
    invalid = (
        value == "@" or value.startswith(("-", "/")) or value.endswith(("/", "."))
        or "//" in value or ".." in value or "@{" in value
        or any(not part or part.startswith(".") or part.endswith(".lock") for part in value.split("/"))
        or any(char.isspace() or char in "~^:?*[\\" for char in value)
    )
    if invalid:
        refuse("branch is invalid")
    return value

def ordered(value, fields):
    return {field: value[field] for field in fields}

def validate_capture(value):
    fields = ["source_kind", "source_ref", "request_fingerprint", "project",
              "repository_ref", "branch", "planning_horizon", "captured_at"]
    exact(value, fields, "capture provenance")
    if value["source_kind"] != "explicit_capture":
        refuse("capture source kind is invalid")
    sha(value["source_ref"], "capture source")
    if not isinstance(value["request_fingerprint"], str) or REQUEST_FINGERPRINT.fullmatch(value["request_fingerprint"]) is None:
        refuse("capture request fingerprint is invalid")
    text(value["project"], "capture project", 1, 128, True)
    sha(value["repository_ref"], "capture repository")
    branch(value["branch"])
    if value["planning_horizon"] not in {"now", "next", "eventually"}:
        refuse("planning horizon is invalid")
    state_timestamp(value["captured_at"], "capture timestamp")
    return ordered(value, fields)

def validate_evidence(value):
    fields = ["source_ref", "excerpt_hash", "observed_at"]
    exact(value, fields, "evidence provenance")
    sha(value["source_ref"], "evidence source")
    sha(value["excerpt_hash"], "evidence excerpt")
    text(value["observed_at"], "evidence timestamp", 1, 96)
    return ordered(value, fields)

def validate_task(record):
    fields = ["schema_version", "proposal_id", "cluster_id", "forge_status",
              "review_required", "title", "summary", "acceptance_criteria",
              "created_at", "updated_at", "capture_provenance", "evidence_provenance"]
    exact(record, fields, "task record")
    if record["schema_version"] != TASK_SCHEMA:
        refuse("task schema is unsupported")
    for name in ("proposal_id", "cluster_id"):
        if not isinstance(record[name], str) or CAPTURE_ID.fullmatch(record[name]) is None:
            refuse(f"task {name} is invalid")
    if record["forge_status"] != "pending_review" or record["review_required"] is not True:
        refuse("task review state is invalid")
    text(record["title"], "task title", 1, 140, True)
    text(record["summary"], "task summary", 1, 480, True)
    criteria = record["acceptance_criteria"]
    if not isinstance(criteria, list) or len(criteria) > 16:
        refuse("acceptance criteria exceed their bound")
    for criterion in criteria:
        text(criterion, "acceptance criterion", 1, 240, True)
    state_timestamp(record["created_at"], "task creation timestamp")
    state_timestamp(record["updated_at"], "task update timestamp")
    captures = record["capture_provenance"]
    evidence = record["evidence_provenance"]
    if not isinstance(captures, list) or not 1 <= len(captures) <= 16:
        refuse("capture provenance exceeds its bound")
    if not isinstance(evidence, list) or len(evidence) > 16:
        refuse("evidence provenance exceeds its bound")
    captures = [validate_capture(item) for item in captures]
    evidence = [validate_evidence(item) for item in evidence]
    capture_order = [(item["source_ref"], item["request_fingerprint"]) for item in captures]
    evidence_order = [(item["source_ref"], item["excerpt_hash"], item["observed_at"]) for item in evidence]
    if capture_order != sorted(capture_order) or len({item["source_ref"] for item in captures}) != len(captures):
        refuse("capture provenance ordering or identity is invalid")
    if evidence_order != sorted(evidence_order) or len(set(evidence_order)) != len(evidence_order):
        refuse("evidence provenance ordering or identity is invalid")
    result = ordered(record, fields)
    result["acceptance_criteria"] = list(criteria)
    result["capture_provenance"] = captures
    result["evidence_provenance"] = evidence
    return result

def parse_generated(value):
    text(value, "generation timestamp", 20, 40)
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})", value) is None:
        refuse("generation timestamp is not normalized RFC 3339")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        refuse("generation timestamp is invalid")
    if parsed.tzinfo is None:
        refuse("generation timestamp has no offset")
    return parsed

def validate_morning_item(value, rank, local_date):
    fields = ["item_id", "rank", "category", "title", "summary",
              "relevance_summary", "disposition", "confidence", "previously_shown",
              "provenance", "feedback"]
    exact(value, fields, "morning item")
    if not isinstance(value["item_id"], str) or ITEM_ID.fullmatch(value["item_id"]) is None:
        refuse("morning item identity is invalid")
    if integer(value["rank"], "morning item rank", 10) != rank:
        refuse("morning item ranks are not contiguous")
    if value["category"] not in {"tool", "paper", "setup", "model"}:
        refuse("morning category is invalid")
    text(value["title"], "morning title", 1, 180, True)
    text(value["summary"], "morning summary", 1, 480, True)
    text(value["relevance_summary"], "morning relevance", 1, 480, True)
    if value["disposition"] not in {"try", "read", "watch", "skip"}:
        refuse("morning disposition is invalid")
    if value["confidence"] not in {"low", "medium", "high"}:
        refuse("morning confidence is invalid")
    boolean(value["previously_shown"], "morning prior display state")
    provenance_fields = ["source_ref", "locator_ref", "source_type", "source_host",
                         "published_date", "event_date"]
    provenance = value["provenance"]
    exact(provenance, provenance_fields, "morning provenance")
    sha(provenance["source_ref"], "morning source")
    sha(provenance["locator_ref"], "morning locator")
    if provenance["source_type"] not in {"official_docs", "official_release_notes",
                                          "official_repository", "primary_paper", "model_card"}:
        refuse("morning source type is invalid")
    if provenance["source_host"] not in ALLOWED_HOSTS:
        refuse("morning source host is invalid")
    for field in ("published_date", "event_date"):
        calendar_date(provenance[field], f"morning {field}")
        if provenance[field] > local_date:
            refuse(f"morning {field} is in the future")
    feedback_fields = ["state", "updated_at"]
    feedback = value["feedback"]
    exact(feedback, feedback_fields, "morning feedback")
    if feedback["state"] not in {"none", "saved", "tried", "useful", "dismissed", "not_relevant"}:
        refuse("morning feedback state is invalid")
    if feedback["state"] == "none":
        if feedback["updated_at"] is not None:
            refuse("empty feedback has an update timestamp")
    else:
        state_timestamp(feedback["updated_at"], "feedback timestamp")
    result = ordered(value, fields)
    result["provenance"] = ordered(provenance, provenance_fields)
    result["feedback"] = ordered(feedback, feedback_fields)
    return result

def validate_morning(record, now, enforce_freshness):
    fields = ["schema_version", "record_ref", "local_date", "generated_at", "freshness",
              "item_count", "repeated_item_count", "items"]
    exact(record, fields, "morning record")
    if record["schema_version"] != MORNING_SCHEMA:
        refuse("morning schema is unsupported")
    sha(record["record_ref"], "morning record")
    local_date = calendar_date(record["local_date"], "morning local date")
    generated = parse_generated(record["generated_at"])
    if record["generated_at"][:10] != local_date:
        refuse("morning generation date is inconsistent")
    generated_seconds = int(generated.timestamp())
    freshness_fields = ["state", "generated_unix_seconds", "fresh_until_unix_seconds", "policy_seconds"]
    freshness = record["freshness"]
    exact(freshness, freshness_fields, "freshness")
    if freshness["state"] not in {"fresh", "stale", "future"}:
        refuse("freshness state is invalid")
    if integer(freshness["generated_unix_seconds"], "generated epoch", 2**63 - 1) != generated_seconds:
        refuse("generated epoch is inconsistent")
    if integer(freshness["policy_seconds"], "freshness policy", 1_000_000) != 172_800:
        refuse("freshness policy is unsupported")
    fresh_until = integer(freshness["fresh_until_unix_seconds"], "freshness deadline", 2**63 - 1)
    if fresh_until != generated_seconds + 172_800:
        refuse("freshness deadline is inconsistent")
    if enforce_freshness:
        expected_state = "future" if generated_seconds > int(now) + 300 else ("fresh" if int(now) <= fresh_until else "stale")
        if freshness["state"] != expected_state:
            refuse("freshness state is inconsistent")
    count = integer(record["item_count"], "morning item count", 10)
    repeated = integer(record["repeated_item_count"], "morning repeat count", 10)
    items = record["items"]
    if not isinstance(items, list) or len(items) != count or count + repeated > 10:
        refuse("morning item accounting is invalid")
    items = [validate_morning_item(item, index + 1, local_date) for index, item in enumerate(items)]
    if len({item["item_id"] for item in items}) != len(items):
        refuse("morning item identity is duplicated")
    result = ordered(record, fields)
    result["freshness"] = ordered(freshness, freshness_fields)
    result["items"] = items
    return result

def event_payload(kind, record):
    return {"kind": kind, "record": record}

def validate_event(value, now, enforce_freshness):
    fields = ["event_schema", "event_id", "stable_id", "revision", "kind", "record"]
    exact(value, fields, "event")
    if value["event_schema"] != EVENT_SCHEMA:
        refuse("event schema is unsupported")
    event_id = value["event_id"]
    if not isinstance(event_id, str) or re.fullmatch(r"forge-firstmate-event-[0-9a-f]{64}", event_id) is None:
        refuse("event identity is invalid")
    revision = sha(value["revision"], "event revision")
    kind = value["kind"]
    if kind == "task_proposal":
        record = validate_task(value["record"])
        expected_stable = f"forge:task-proposal:{record['proposal_id']}"
    elif kind == "morning_intelligence":
        record = validate_morning(value["record"], now, enforce_freshness)
        expected_stable = f"forge:morning-intelligence:{record['local_date']}"
    else:
        refuse("event kind is unsupported")
    if value["stable_id"] != expected_stable:
        refuse("stable event identity is inconsistent")
    canonical_payload = json.dumps(event_payload(kind, record), ensure_ascii=False,
                                   separators=(",", ":")).encode("utf-8")
    expected_revision = "sha256:" + hashlib.sha256(canonical_payload).hexdigest()
    if revision != expected_revision:
        refuse("event revision is inconsistent")
    identity_material = b"\0".join((EVENT_SCHEMA.encode(), expected_stable.encode(), revision.encode()))
    expected_event = "forge-firstmate-event-" + hashlib.sha256(identity_material).hexdigest()
    if event_id != expected_event:
        refuse("event identity is inconsistent")
    result = ordered(value, fields)
    result["record"] = record
    return result

def parse_cursor(value, label):
    if not isinstance(value, str) or len(value) > 96:
        refuse(f"{label} is invalid")
    match = CURSOR.fullmatch(value)
    if match is None:
        refuse(f"{label} is invalid")
    return match.group(1), int(match.group(2))

def snapshot_for(events):
    digest = hashlib.sha256(INTERFACE.encode())
    for event in events:
        digest.update(b"\0")
        digest.update(event["stable_id"].encode())
        digest.update(b"\0")
        digest.update(event["revision"].encode())
    return digest.hexdigest()

def validate_envelope(value, requested_cursor=UNKNOWN_CURSOR, require_records=False,
                      now=None, enforce_freshness=False):
    fields = ["interface_version", "result", "snapshot_id", "next_cursor", "has_more",
              "cursor_reset", "source_counts", "suppression_counts", "events"]
    exact(value, fields, "response")
    if value["interface_version"] != INTERFACE:
        refuse("interface version is unsupported")
    if value["result"] not in {"no_work", "no_change", "records"}:
        refuse("result is unsupported")
    snapshot = sha(value["snapshot_id"], "snapshot").split(":", 1)[1]
    cursor_snapshot, next_offset = parse_cursor(value["next_cursor"], "next cursor")
    if cursor_snapshot != snapshot:
        refuse("cursor snapshot is inconsistent")
    has_more = boolean(value["has_more"], "pagination state")
    cursor_reset = boolean(value["cursor_reset"], "cursor reset state")
    source_fields = ["review_gated_task_proposals", "morning_intelligence_records"]
    sources = value["source_counts"]
    exact(sources, source_fields, "source counts")
    task_total = integer(sources["review_gated_task_proposals"], "task source count", 512)
    morning_total = integer(sources["morning_intelligence_records"], "morning source count", 31)
    total = task_total + morning_total
    suppression_fields = ["non_explicit_task_records", "non_pending_task_records",
                          "non_task_dispositions", "older_morning_records"]
    suppressed = value["suppression_counts"]
    exact(suppressed, suppression_fields, "suppression counts")
    non_explicit = integer(suppressed["non_explicit_task_records"], "non-explicit count", 512)
    non_pending = integer(suppressed["non_pending_task_records"], "non-pending count", 512)
    non_task = integer(suppressed["non_task_dispositions"], "non-task count", 512)
    older = integer(suppressed["older_morning_records"], "older morning count", 4_096)
    if task_total + non_explicit + non_pending + non_task > 512 or morning_total + older > 4_096:
        refuse("source accounting exceeds its bound")
    events = value["events"]
    if not isinstance(events, list) or len(events) > MAX_EVENTS:
        refuse("event page exceeds its bound")
    now = time.time() if now is None else now
    events = [validate_event(event, now, enforce_freshness) for event in events]
    stable_ids = [event["stable_id"] for event in events]
    event_ids = [event["event_id"] for event in events]
    if stable_ids != sorted(stable_ids) or len(set(stable_ids)) != len(stable_ids) or len(set(event_ids)) != len(event_ids):
        refuse("event identities are duplicated or unordered")
    if sum(event["kind"] == "task_proposal" for event in events) > task_total:
        refuse("task page exceeds source accounting")
    if sum(event["kind"] == "morning_intelligence" for event in events) > morning_total:
        refuse("morning page exceeds source accounting")
    if requested_cursor is UNKNOWN_CURSOR:
        if next_offset < len(events):
            refuse("page offsets are inconsistent")
        requested = UNKNOWN_CURSOR
        expected_reset = None
        start = next_offset - len(events)
    else:
        requested = None if requested_cursor is None else parse_cursor(requested_cursor, "requested cursor")
        expected_reset = requested is not None and requested[0] != snapshot
        if cursor_reset != expected_reset:
            refuse("cursor reset is inconsistent")
        start = requested[1] if requested is not None and not expected_reset else 0
    if start > total or next_offset != start + len(events):
        refuse("page offsets are inconsistent")
    expected_size = min(MAX_EVENTS, total - start)
    if len(events) != expected_size:
        refuse("page size is inconsistent")
    if has_more != (next_offset < total):
        refuse("pagination flag is inconsistent")
    if value["result"] == "records":
        if not events:
            refuse("records result is empty")
    elif events or has_more:
        refuse("empty result carries records")
    elif value["result"] == "no_change":
        if requested is not UNKNOWN_CURSOR and (requested is None or expected_reset or start != total):
            refuse("no-change result is inconsistent")
    elif total != 0 or start != 0:
        refuse("no-work result is inconsistent")
    if require_records and value["result"] != "records":
        refuse("captured result is not a records page")
    if start == 0 and not has_more and total == len(events):
        if snapshot_for(events) != snapshot:
            refuse("complete snapshot identity is inconsistent")
    result = ordered(value, fields)
    result["source_counts"] = ordered(sources, source_fields)
    result["suppression_counts"] = ordered(suppressed, suppression_fields)
    result["events"] = events
    return result

def duplicate_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            refuse("JSON contains a duplicate field")
        value[key] = item
    return value

def decode_json(raw):
    if len(raw) > MAX_BODY:
        refuse("response body exceeds its bound")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=duplicate_object,
                          parse_constant=lambda _value: refuse("JSON constant is invalid"))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        refuse("response JSON is malformed")

def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)

def inspect_private(info, maximum, label):
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
        refuse(f"{label} is not a private single-linked regular file")
    if info.st_size <= 0 or info.st_size > maximum:
        refuse(f"{label} exceeds its byte bound")

def open_parent(path):
    absolute = os.path.abspath(path)
    if "\n" in absolute or "\r" in absolute or "\0" in absolute:
        refuse("path contains unsupported bytes")
    parts = Path(absolute).parts
    if not parts or parts[0] != os.path.sep or any(part in {"", ".", ".."} for part in parts[1:]):
        refuse("path is not confined")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        refuse("platform cannot reject symlinks")
    descriptor = os.open(os.path.sep, flags)
    try:
        for part in parts[1:-1]:
            next_descriptor = os.open(part, flags | nofollow, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return absolute, descriptor, parts[-1]
    except Exception:
        os.close(descriptor)
        raise

def read_private_once(path, maximum, label):
    absolute, parent, name = open_parent(path)
    descriptor = None
    try:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        inspect_private(before, maximum, label)
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=parent)
        opened = os.fstat(descriptor)
        if identity(before) != identity(opened):
            refuse(f"{label} changed before it was opened")
        chunks = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                refuse(f"{label} was truncated during read")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            refuse(f"{label} grew during read")
        after = os.fstat(descriptor)
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if identity(opened) != identity(after) or identity(opened) != identity(current):
            refuse(f"{label} changed during read")
        return absolute, identity(opened), b"".join(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)

def read_private(path, maximum, label):
    first = read_private_once(path, maximum, label)
    second = read_private_once(path, maximum, label)
    if first != second:
        refuse(f"{label} changed between verified reads")
    return first[0], first[2]

def parse_listen(value):
    text(value, "bridge listen address", 1, 128)
    if value.startswith("["):
        match = re.fullmatch(r"\[([^]]+)]:(\d{1,5})", value)
    else:
        match = re.fullmatch(r"([^:]+):(\d{1,5})", value)
    if match is None:
        refuse("bridge listen address is invalid")
    try:
        address = ipaddress.ip_address(match.group(1))
    except ValueError:
        refuse("bridge listen address is invalid")
    port = int(match.group(2))
    if not address.is_loopback or not 1 <= port <= 65_535:
        refuse("bridge listen address is not an active loopback socket")
    return address, port

def read_config(path):
    absolute, raw = read_private(path, MAX_CONFIG, "Forge config")
    try:
        document = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError):
        refuse("Forge config TOML is malformed")
    bridge = document.get("bridge") if isinstance(document, dict) else None
    if not isinstance(bridge, dict) or not isinstance(bridge.get("listen"), str) or not isinstance(bridge.get("token"), str):
        refuse("Forge config is missing bridge.listen or bridge.token")
    address, port = parse_listen(bridge["listen"])
    try:
        token = bridge["token"].encode("ascii")
    except UnicodeEncodeError:
        refuse("Forge token is not an ASCII header value")
    if not 1 <= len(token) <= 256 or any(byte < 33 or byte > 126 for byte in token):
        refuse("Forge token is empty, oversized, or not header-safe")
    return absolute, address, port, token

def state_paths(state_root):
    root = os.path.abspath(state_root)
    os.makedirs(root, mode=0o700, exist_ok=True)
    info = os.lstat(root)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        refuse("adapter state root is unsafe")
    return root, os.path.join(root, SOURCE_ID + ".cursor.json")

@contextlib.contextmanager
def state_lock(state_root):
    root, state_path = state_paths(state_root)
    lock_path = os.path.join(root, "." + SOURCE_ID + ".cursor.lock")
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            refuse("adapter cursor lock is unsafe")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield state_path
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)

def load_state(path):
    if not os.path.lexists(path):
        return None
    _, raw = read_private(path, 8_192, "adapter cursor")
    document = decode_json(raw)
    fields = ["schema", "config_path", "cursor", "last_generation", "last_result_sha256"]
    exact(document, fields, "adapter cursor")
    if document["schema"] != STATE_SCHEMA:
        refuse("adapter cursor schema is unsupported")
    text(document["config_path"], "adapter config path", 1, 4_096)
    if document["cursor"] is not None:
        parse_cursor(document["cursor"], "adapter cursor")
    integer(document["last_generation"], "adapter generation", 2**63 - 1)
    if document["last_result_sha256"] is not None and (not isinstance(document["last_result_sha256"], str) or HEX64.fullmatch(document["last_result_sha256"]) is None):
        refuse("adapter result receipt is invalid")
    if (document["last_generation"] == 0) != (document["last_result_sha256"] is None):
        refuse("adapter result receipt is inconsistent")
    return document

def write_state(path, value):
    parent = os.path.dirname(path)
    if os.path.islink(path):
        refuse("adapter cursor is a symlink")
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    descriptor, temporary = tempfile.mkstemp(prefix=".forge-firstmate-cursor.", dir=parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = None
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if os.path.exists(temporary):
            os.unlink(temporary)

def initial_state(config_path):
    return {"schema": STATE_SCHEMA, "config_path": config_path, "cursor": None,
            "last_generation": 0, "last_result_sha256": None}

def load_bound_state(state_root, config_path, create=False):
    _root, path = state_paths(state_root)
    current = load_state(path)
    if current is None:
        if not create:
            refuse("adapter cursor is not initialized")
        current = initial_state(config_path)
        write_state(path, current)
    if current["config_path"] != config_path:
        refuse("adapter cursor is bound to a different config path")
    return path, current

def parse_headers(raw):
    try:
        lines = raw.decode("iso-8859-1").split("\r\n")
    except UnicodeDecodeError:
        refuse("HTTP headers are malformed")
    if not lines or not re.fullmatch(r"HTTP/1\.[01] [0-9]{3}(?: [\x20-\x7e]*)?", lines[0]):
        refuse("HTTP status line is malformed")
    status_code = int(lines[0].split(" ", 2)[1])
    headers = {}
    for line in lines[1:]:
        if not line or line[:1].isspace() or ":" not in line:
            refuse("HTTP header framing is malformed")
        name, value = line.split(":", 1)
        name = name.lower()
        if re.fullmatch(r"[!#$%&'*+.^_`|~0-9a-z-]+", name) is None:
            refuse("HTTP header name is malformed")
        headers.setdefault(name, []).append(value.strip())
    return status_code, headers

def one_header(headers, name):
    values = headers.get(name, [])
    if len(values) != 1:
        refuse(f"HTTP {name} header is missing or ambiguous")
    return values[0]

def request_page(address, port, token, cursor):
    query = f"interface={INTERFACE}&limit=8&wait_seconds=30"
    if cursor is not None:
        query += "&cursor=" + cursor
    host = f"[{address}]" if address.version == 6 else str(address)
    target = ROUTE + "?" + query
    request = (f"GET {target} HTTP/1.1\r\nHost: {host}:{port}\r\n"
               "Accept: application/json\r\nCache-Control: no-store\r\nPragma: no-cache\r\n"
               "Connection: close\r\nx-notes-automation-token: ").encode("ascii") + token + b"\r\n\r\n"
    deadline = time.monotonic() + REQUEST_SECONDS
    family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
    connection = socket.socket(family, socket.SOCK_STREAM)
    try:
        connection.settimeout(min(5.0, REQUEST_SECONDS))
        connection.connect((str(address), port))
        connection.settimeout(max(0.1, deadline - time.monotonic()))
        connection.sendall(request)
        received = bytearray()
        marker = -1
        while marker < 0:
            if len(received) > MAX_HEADERS + 4:
                refuse("HTTP headers exceed their bound")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                refuse("HTTP response exceeded its time bound")
            connection.settimeout(remaining)
            chunk = connection.recv(4_096)
            if not chunk:
                refuse("HTTP response ended before its headers")
            received.extend(chunk)
            marker = received.find(b"\r\n\r\n")
        if marker > MAX_HEADERS:
            refuse("HTTP headers exceed their bound")
        status_code, headers = parse_headers(bytes(received[:marker]))
        if status_code != 200:
            refuse("Forge returned a non-success HTTP status")
        if "transfer-encoding" in headers:
            refuse("HTTP transfer encoding is unsupported")
        length_text = one_header(headers, "content-length")
        if not length_text.isdigit():
            refuse("HTTP content length is invalid")
        length = int(length_text)
        if not 1 <= length <= MAX_BODY:
            refuse("HTTP body exceeds its bound")
        cache_directives = {part.strip().lower() for part in one_header(headers, "cache-control").split(",")}
        if cache_directives != {"no-store", "max-age=0"} or one_header(headers, "pragma").lower() != "no-cache":
            refuse("HTTP response is cacheable")
        content_type = one_header(headers, "content-type").lower().replace(" ", "")
        if content_type not in {"application/json", "application/json;charset=utf-8"}:
            refuse("HTTP response content type is unsupported")
        body = bytearray(received[marker + 4:])
        if len(body) > length:
            refuse("HTTP response carries bytes beyond its body")
        while len(body) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                refuse("HTTP response exceeded its time bound")
            connection.settimeout(remaining)
            chunk = connection.recv(min(65_536, length - len(body)))
            if not chunk:
                refuse("HTTP response body is truncated")
            body.extend(chunk)
        return bytes(body)
    except (OSError, TimeoutError, socket.timeout):
        refuse("loopback Forge request failed")
    finally:
        connection.close()

def read_result(path):
    _absolute, raw = read_private(path, MAX_RESULT, "process-event result")
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    return raw

def validate_result(path, requested_cursor=UNKNOWN_CURSOR):
    value = decode_json(read_result(path))
    return validate_envelope(value, requested_cursor=requested_cursor, require_records=True)

def result_generation(path, state_root):
    absolute = os.path.abspath(path)
    inbox = os.path.abspath(os.path.join(state_root, "procevent-inbox"))
    if os.path.dirname(absolute) != inbox or os.path.islink(inbox) or not os.path.isdir(inbox):
        refuse("result is outside the process-event inbox")
    match = re.fullmatch(re.escape(SOURCE_ID) + r"\.([0-9]+)\.result", os.path.basename(absolute))
    if match is None or int(match.group(1)) < 1:
        refuse("result does not identify a Forge generation")
    adapter_path = absolute[:-len(".result")] + ".adapter"
    _adapter_absolute, adapter_raw = read_private(adapter_path, 64, "result adapter identity")
    if adapter_raw != (ADAPTER + "\n").encode():
        refuse("result belongs to a different adapter")
    return int(match.group(1)), absolute

def command_prepare_arm(config, state_root):
    config_path, _address, _port, _token = read_config(config)
    with state_lock(state_root):
        load_bound_state(state_root, config_path, create=True)
    print(config_path)

def command_prepare_rearm(config, result, state_root, registered):
    config_path, _address, _port, _token = read_config(config)
    generation, result_path = result_generation(result, state_root)
    raw = read_result(result_path)
    digest = hashlib.sha256(raw).hexdigest()
    with state_lock(state_root):
        state_path, current = load_bound_state(state_root, config_path)
        if generation < current["last_generation"]:
            validate_envelope(decode_json(raw), require_records=True)
            print("stale\t" + config_path)
            return
        if generation == current["last_generation"]:
            if digest != current["last_result_sha256"]:
                refuse("captured generation conflicts with its cursor receipt")
            validate_envelope(decode_json(raw), require_records=True)
            print("repeat\t" + config_path)
            return
        if generation != current["last_generation"] + 1:
            refuse("captured generation is not the next cursor generation")
        if registered != "0":
            refuse("previous source generation is still registered")
        page = validate_envelope(decode_json(raw), requested_cursor=current["cursor"], require_records=True)
        updated = dict(current)
        updated["cursor"] = page["next_cursor"]
        updated["last_generation"] = generation
        updated["last_result_sha256"] = digest
        write_state(state_path, updated)
    print("new\t" + config_path)

def command_poll(config, state_root):
    config_path, address, port, token = read_config(config)
    with state_lock(state_root):
        state_path, current = load_bound_state(state_root, config_path)
    while True:
        requested = current["cursor"]
        page = validate_envelope(decode_json(request_page(address, port, token, requested)),
                                 requested_cursor=requested, enforce_freshness=True)
        with state_lock(state_root):
            latest = load_state(state_path)
            if latest is None or latest["config_path"] != config_path:
                refuse("adapter cursor changed unexpectedly")
            if latest["cursor"] != requested or latest["last_generation"] != current["last_generation"]:
                current = latest
                continue
            if page["result"] != "records" and page["next_cursor"] != requested:
                latest = dict(latest)
                latest["cursor"] = page["next_cursor"]
                write_state(state_path, latest)
            current = latest
        if page["result"] == "records":
            output = json.dumps(page, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            if len(output) > MAX_BODY:
                refuse("validated page exceeds its output bound")
            sys.stdout.buffer.write(output + b"\n")
            sys.stdout.buffer.flush()
            return
        time.sleep(0.05)

def main(arguments):
    command = arguments[0] if arguments else ""
    if command == "prepare-arm" and len(arguments) == 3:
        command_prepare_arm(arguments[1], arguments[2])
    elif command == "prepare-rearm" and len(arguments) == 5:
        command_prepare_rearm(arguments[1], arguments[2], arguments[3], arguments[4])
    elif command == "poll" and len(arguments) == 3:
        command_poll(arguments[1], arguments[2])
    elif command in {"classify", "terminal"} and len(arguments) == 2:
        try:
            validate_result(arguments[1])
            if command == "classify":
                print("records")
        except Refusal:
            if command == "classify":
                print("malformed")
                return
            raise
    else:
        refuse("internal adapter invocation is invalid")

try:
    main(sys.argv[1:])
except Refusal as error:
    print(f"error: Forge Firstmate adapter refused: {error}", file=sys.stderr)
    sys.exit(1)
except Exception:
    print("error: Forge Firstmate adapter refused an unexpected local failure", file=sys.stderr)
    sys.exit(1)
PY
}

register_source() {
  local config=$1
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-forge-firstmate.sh" poll "$config"
}

cmd_arm() {
  local requested=${1-} config registration
  [ "$#" -eq 1 ] || usage
  registration=$(registration_file)
  (
    fm_lock_acquire_wait "$LIFECYCLE_LOCK" || die "cannot lock Forge source lifecycle"
    trap 'fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    config=$(python_adapter prepare-arm "$requested" "$STATE") || exit 1
    if [ -f "$registration" ] && [ ! -L "$registration" ]; then
      printf 'already-armed: %s\n' "$SOURCE_ID"
    else
      register_source "$config" || exit 1
      printf 'armed: %s\n' "$SOURCE_ID"
    fi
  )
}

cmd_rearm() {
  local requested=${1-} result=${2-} registration registered=0 plan mode config
  [ "$#" -eq 2 ] || usage
  registration=$(registration_file)
  (
    fm_lock_acquire_wait "$LIFECYCLE_LOCK" || die "cannot lock Forge source lifecycle"
    trap 'fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    if [ -f "$registration" ] && [ ! -L "$registration" ]; then
      registered=1
    elif [ -e "$registration" ] || [ -L "$registration" ]; then
      die "Forge source registration is unsafe"
    fi
    plan=$(python_adapter prepare-rearm "$requested" "$result" "$STATE" "$registered") || exit 1
    mode=${plan%%$'\t'*}
    config=${plan#*$'\t'}
    case "$mode" in
      stale)
        printf 'already-past: %s\n' "$SOURCE_ID"
        ;;
      repeat)
        if [ "$registered" -eq 1 ]; then
          printf 'already-armed: %s\n' "$SOURCE_ID"
        else
          register_source "$config" || exit 1
          printf 'rearmed: %s\n' "$SOURCE_ID"
        fi
        ;;
      new)
        register_source "$config" || exit 1
        printf 'rearmed: %s\n' "$SOURCE_ID"
        ;;
      *) die "Forge cursor preparation returned an invalid result" ;;
    esac
  )
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  (
    fm_lock_acquire_wait "$LIFECYCLE_LOCK" || die "cannot lock Forge source lifecycle"
    trap 'fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
  )
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; python_adapter classify "$1" ;;
  rearm) shift; cmd_rearm "$@" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; python_adapter terminal "$1" ;;
  source-id) shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID" ;;
  retire) shift; cmd_retire "$@" ;;
  poll) shift; [ "$#" -eq 1 ] || usage; python_adapter poll "$1" "$STATE" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
