#!/usr/bin/env bash
# fm-memory-clerk.sh - bounded input and proposal mechanics for /memory-clerk.
#
# Usage:
#   fm-memory-clerk.sh inventory [--date YYYY-MM-DD] [--report data/<id>/report.md]...
#   fm-memory-clerk.sh write [--date YYYY-MM-DD] [--report data/<id>/report.md]... < proposal.json
#   fm-memory-clerk.sh -h | --help
#
# `inventory` prints one JSON object containing only these durable inputs:
# data/captain.md, primary-home data/captain-shared.md, data/learnings.md,
# data/backlog.md, data/done-archive.md, and up to three explicitly named
# data/<id>/report.md bodies. In a secondmate home captain-shared.md is reported
# as excluded-primary-owned and is never read. Missing optional files stay absent.
# No report body is read unless its exact path is passed with --report.
#
# Each source body is limited to 24,000 bytes, all included bodies together are
# limited to 64,000 bytes, and rendered inventory is limited to 160,000 bytes.
# An over-limit source is reported without partial content. Unsafe, symlinked,
# hardlinked, special, invalid-UTF-8, or unallowlisted inputs are refused.
#
# `write` accepts the same input selection plus a JSON object with exactly
# `items` and `coverage_notes`. It validates source digests against a fresh
# inventory, enforces the proposal schema and classification rules, renders at
# most 24 items and 12 coverage notes into at most 12,000 bytes, and atomically
# replaces data/memory-clerk/proposal-<date>.md with mode 0600. It writes no
# canonical memory, backlog, decision, report, project, or state record.
#
# Each item requires: key, destination_owner, source_pointer, source_digest,
# date, home_scope, classification, rationale, disposition, review_by, proposal.
# `date` must equal the pass date. `review_by` must be from that date through 90
# days later. Contradictions require review-required; duplicate proposal tuples
# are refused. The skill owns semantic curation; this command owns exact bounds,
# allowlists, filesystem safety, schema validation, and artifact publication.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  inventory|write)
    COMMAND=$1
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-memory-clerk: python3 is required\n' >&2
  exit 1
}

# Preserve the caller's stdin on fd 3 because stdin itself carries this Python
# program. Only the write command consumes fd 3.
exec python3 - "$FM_HOME" "$COMMAND" "$@" 3<&0 <<'PY'
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

SOURCE_LIMIT = 24_000
TOTAL_CONTENT_LIMIT = 64_000
INVENTORY_OUTPUT_LIMIT = 160_000
REPORT_LIMIT = 3
PROPOSAL_INPUT_LIMIT = 64_000
PROPOSAL_OUTPUT_LIMIT = 12_000
ITEM_LIMIT = 24
COVERAGE_NOTE_LIMIT = 12
REVIEW_WINDOW_DAYS = 90

AUTO_SOURCES = (
    ("data/captain.md", "captain-memory"),
    ("data/captain-shared.md", "shared-captain-memory"),
    ("data/learnings.md", "fleet-learning"),
    ("data/backlog.md", "structured-backlog-and-decisions"),
    ("data/done-archive.md", "completed-work-and-report-pointers"),
)
REPORT_RE = re.compile(r"data/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/report\.md\Z")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
KEY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")

DESTINATIONS = {
    "data/captain.md",
    "primary data/captain-shared.md",
    "data/learnings.md",
    "structured backlog",
    "structured decision lifecycle",
    "project documentation via normal delivery",
    "linked report",
    "no canonical change",
}
CLASSIFICATIONS = {
    "new",
    "duplicate",
    "contradiction",
    "supersession",
    "stale",
    "no-change",
}
DISPOSITIONS = {
    "review-required",
    "stow-candidate",
    "route-candidate",
    "no-change",
}


class ClerkError(Exception):
    """One deterministic memory-clerk refusal."""


def fail(message: str) -> None:
    raise ClerkError(message)


def lexists(path: Path) -> bool:
    return os.path.lexists(os.fspath(path))


def require_no_symlink_components(path: Path, *, allow_missing_tail: bool = False) -> None:
    absolute = path.absolute()
    current = Path(absolute.anchor)
    parts = absolute.parts[1:] if absolute.anchor else absolute.parts
    for index, part in enumerate(parts):
        current /= part
        if not lexists(current):
            if allow_missing_tail:
                return
            fail(f"path component is absent: {current}")
        if current.is_symlink():
            fail(f"path component is symlinked: {current}")
        if index < len(parts) - 1 and not current.is_dir():
            fail(f"path component is not a directory: {current}")


def require_safe_directory(path: Path, *, create: bool = False, mode: int = 0o700) -> None:
    require_no_symlink_components(path.parent)
    if not lexists(path):
        if not create:
            fail(f"directory is absent: {path}")
        try:
            path.mkdir(mode=mode)
        except OSError as exc:
            fail(f"could not create directory {path}: {exc}")
    if path.is_symlink() or not path.is_dir():
        fail(f"path is not an ordinary directory: {path}")


def safe_regular_metadata(path: Path) -> os.stat_result | None:
    require_no_symlink_components(path.parent, allow_missing_tail=True)
    if lexists(path.parent) and not path.parent.is_dir():
        fail(f"source parent is not a directory: {path.parent}")
    if not lexists(path):
        return None
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"could not inspect source {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"source is not an ordinary regular file: {path}")
    if info.st_nlink != 1:
        fail(f"source is hardlinked: {path}")
    return info


def read_safe_regular(path: Path, expected: os.stat_result) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open source {path}: {exc}")
    try:
        actual = os.fstat(fd)
        if not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1:
            fail(f"source changed to an unsafe file while reading: {path}")
        if (actual.st_dev, actual.st_ino, actual.st_size) != (
            expected.st_dev,
            expected.st_ino,
            expected.st_size,
        ):
            fail(f"source changed while reading: {path}")
        chunks: list[bytes] = []
        remaining = actual.st_size
        while remaining:
            chunk = os.read(fd, min(remaining, 65_536))
            if not chunk:
                fail(f"source ended early while reading: {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1):
            fail(f"source grew while reading: {path}")
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
            actual.st_dev,
            actual.st_ino,
            actual.st_size,
            actual.st_mtime_ns,
        ):
            fail(f"source changed while reading: {path}")
        return b"".join(chunks)
    finally:
        os.close(fd)


def parse_date(value: str, label: str) -> dt.date:
    if not DATE_RE.fullmatch(value):
        fail(f"{label} must be YYYY-MM-DD")
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        fail(f"{label} is not a real calendar date")


def parse_args(arguments: list[str]) -> tuple[str, list[str]]:
    pass_date = dt.datetime.now(dt.timezone.utc).date().isoformat()
    reports: list[str] = []
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        if arg in {"--date", "--report"}:
            index += 1
            if index >= len(arguments):
                fail(f"{arg} requires a value")
            value = arguments[index]
            if arg == "--date":
                pass_date = value
            else:
                reports.append(value)
        elif arg.startswith("--date="):
            pass_date = arg.split("=", 1)[1]
        elif arg.startswith("--report="):
            reports.append(arg.split("=", 1)[1])
        else:
            fail(f"unsupported argument: {arg}")
        index += 1

    parse_date(pass_date, "date")
    if len(reports) > REPORT_LIMIT:
        fail(f"at most {REPORT_LIMIT} targeted reports may be read")
    if len(set(reports)) != len(reports):
        fail("targeted report paths must be unique")
    for report in reports:
        match = REPORT_RE.fullmatch(report)
        if not match or match.group(1) in {".", ".."}:
            fail("targeted report must match data/<privacy-safe-id>/report.md")
    return pass_date, reports


def role_for_home(home: Path) -> str:
    marker = home / ".fm-secondmate-home"
    info = safe_regular_metadata(marker)
    return "secondmate" if info is not None else "primary"


def source_record(
    home: Path,
    pointer: str,
    kind: str,
    remaining: int,
    *,
    excluded: bool = False,
) -> tuple[dict[str, Any], int]:
    if excluded:
        return {
            "pointer": pointer,
            "kind": kind,
            "status": "excluded-primary-owned",
            "bytes": 0,
            "sha256": None,
        }, remaining

    path = home / pointer
    info = safe_regular_metadata(path)
    if info is None:
        return {
            "pointer": pointer,
            "kind": kind,
            "status": "absent",
            "bytes": 0,
            "sha256": None,
        }, remaining
    if info.st_size > SOURCE_LIMIT:
        return {
            "pointer": pointer,
            "kind": kind,
            "status": "omitted-source-limit",
            "bytes": info.st_size,
            "sha256": None,
        }, remaining
    if info.st_size > remaining:
        return {
            "pointer": pointer,
            "kind": kind,
            "status": "omitted-total-limit",
            "bytes": info.st_size,
            "sha256": None,
        }, remaining

    raw = read_safe_regular(path, info)
    try:
        content = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"source is not valid UTF-8: {pointer}")
    digest = hashlib.sha256(raw).hexdigest()
    return {
        "pointer": pointer,
        "kind": kind,
        "status": "included",
        "bytes": len(raw),
        "sha256": f"sha256:{digest}",
        "content": content,
    }, remaining - len(raw)


def gather(home: Path, pass_date: str, reports: list[str]) -> dict[str, Any]:
    require_no_symlink_components(home)
    if not home.is_dir():
        fail(f"FM_HOME is not a directory: {home}")
    data = home / "data"
    if lexists(data):
        require_safe_directory(data)
    role = role_for_home(home)
    remaining = TOTAL_CONTENT_LIMIT
    sources: list[dict[str, Any]] = []
    for pointer, kind in AUTO_SOURCES:
        record, remaining = source_record(
            home,
            pointer,
            kind,
            remaining,
            excluded=(role == "secondmate" and pointer == "data/captain-shared.md"),
        )
        sources.append(record)
    for pointer in reports:
        record, remaining = source_record(
            home,
            pointer,
            "explicit-targeted-report",
            remaining,
        )
        sources.append(record)

    pass_day = parse_date(pass_date, "date")
    return {
        "schema": "fm-memory-clerk-inventory.v1",
        "proposal_date": pass_date,
        "default_review_by": (pass_day + dt.timedelta(days=30)).isoformat(),
        "home_scope": f"{role}:this-home",
        "authority": "durable source records remain authoritative; this inventory is read-only",
        "limits": {
            "source_bytes": SOURCE_LIMIT,
            "total_content_bytes": TOTAL_CONTENT_LIMIT,
            "targeted_reports": REPORT_LIMIT,
            "proposal_items": ITEM_LIMIT,
            "proposal_bytes": PROPOSAL_OUTPUT_LIMIT,
        },
        "sources": sources,
    }


def render_inventory(inventory: dict[str, Any]) -> bytes:
    rendered = (json.dumps(inventory, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(rendered) > INVENTORY_OUTPUT_LIMIT:
        fail(f"rendered inventory exceeds {INVENTORY_OUTPUT_LIMIT} bytes")
    return rendered


def one_line(value: Any, label: str, maximum: int, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    if not value and not allow_empty:
        fail(f"{label} must not be empty")
    if len(value) > maximum:
        fail(f"{label} exceeds {maximum} characters")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail(f"{label} must be one printable line")
    return value


def read_payload() -> dict[str, Any]:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(3, min(65_536, PROPOSAL_INPUT_LIMIT + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > PROPOSAL_INPUT_LIMIT:
            fail(f"proposal JSON exceeds {PROPOSAL_INPUT_LIMIT} bytes")
    raw = b"".join(chunks)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"proposal JSON is invalid: {exc}")
    if not isinstance(payload, dict):
        fail("proposal JSON root must be an object")
    if set(payload) != {"items", "coverage_notes"}:
        fail("proposal JSON must contain exactly items and coverage_notes")
    return payload


def validate_payload(payload: dict[str, Any], inventory: dict[str, Any]) -> tuple[list[dict[str, str]], list[str]]:
    raw_items = payload["items"]
    raw_notes = payload["coverage_notes"]
    if not isinstance(raw_items, list):
        fail("items must be an array")
    if len(raw_items) > ITEM_LIMIT:
        fail(f"items exceeds the {ITEM_LIMIT}-item limit")
    if not isinstance(raw_notes, list):
        fail("coverage_notes must be an array")
    if len(raw_notes) > COVERAGE_NOTE_LIMIT:
        fail(f"coverage_notes exceeds the {COVERAGE_NOTE_LIMIT}-note limit")
    notes = [one_line(note, f"coverage_notes[{index}]", 320) for index, note in enumerate(raw_notes)]

    included = {
        source["pointer"]: source["sha256"]
        for source in inventory["sources"]
        if source["status"] == "included"
    }
    role = inventory["home_scope"].split(":", 1)[0]
    pass_date = inventory["proposal_date"]
    pass_day = parse_date(pass_date, "date")
    required = {
        "key",
        "destination_owner",
        "source_pointer",
        "source_digest",
        "date",
        "home_scope",
        "classification",
        "rationale",
        "disposition",
        "review_by",
        "proposal",
    }
    items: list[dict[str, str]] = []
    keys: set[str] = set()
    tuples: set[tuple[str, str, str]] = set()
    for index, raw_item in enumerate(raw_items):
        label = f"items[{index}]"
        if not isinstance(raw_item, dict) or set(raw_item) != required:
            fail(f"{label} must contain exactly the required item fields")
        item = {
            "key": one_line(raw_item["key"], f"{label}.key", 64),
            "destination_owner": one_line(raw_item["destination_owner"], f"{label}.destination_owner", 80),
            "source_pointer": one_line(raw_item["source_pointer"], f"{label}.source_pointer", 180),
            "source_digest": one_line(raw_item["source_digest"], f"{label}.source_digest", 71),
            "date": one_line(raw_item["date"], f"{label}.date", 10),
            "home_scope": one_line(raw_item["home_scope"], f"{label}.home_scope", 40),
            "classification": one_line(raw_item["classification"], f"{label}.classification", 20),
            "rationale": one_line(raw_item["rationale"], f"{label}.rationale", 320),
            "disposition": one_line(raw_item["disposition"], f"{label}.disposition", 24),
            "review_by": one_line(raw_item["review_by"], f"{label}.review_by", 10),
            "proposal": one_line(raw_item["proposal"], f"{label}.proposal", 500),
        }
        if not KEY_RE.fullmatch(item["key"]):
            fail(f"{label}.key must be a privacy-safe slug")
        folded_key = item["key"].casefold()
        if folded_key in keys:
            fail(f"duplicate item key: {item['key']}")
        keys.add(folded_key)
        if item["destination_owner"] not in DESTINATIONS:
            fail(f"{label}.destination_owner is not an authoritative owner")
        expected_digest = included.get(item["source_pointer"])
        if expected_digest is None:
            fail(f"{label}.source_pointer was not included by the bounded inventory")
        if not DIGEST_RE.fullmatch(item["source_digest"]):
            fail(f"{label}.source_digest must be sha256:<64 lowercase hex>")
        if item["source_digest"] != expected_digest:
            fail(f"{label}.source_digest does not match the current source")
        if item["date"] != pass_date:
            fail(f"{label}.date must equal the proposal date {pass_date}")
        review_day = parse_date(item["review_by"], f"{label}.review_by")
        if review_day < pass_day or review_day > pass_day + dt.timedelta(days=REVIEW_WINDOW_DAYS):
            fail(f"{label}.review_by must be within {REVIEW_WINDOW_DAYS} days of the proposal date")
        if item["classification"] not in CLASSIFICATIONS:
            fail(f"{label}.classification is unsupported")
        if item["disposition"] not in DISPOSITIONS:
            fail(f"{label}.disposition is unsupported")
        if item["classification"] == "contradiction" and item["disposition"] != "review-required":
            fail(f"{label}: contradictions require review-required")
        if item["classification"] == "supersession" and item["disposition"] not in {
            "review-required",
            "stow-candidate",
            "route-candidate",
        }:
            fail(f"{label}: supersession requires review, stow, or routing")
        if item["classification"] == "no-change" and item["disposition"] != "no-change":
            fail(f"{label}: no-change classification requires no-change disposition")
        if item["destination_owner"] == "structured decision lifecycle":
            if item["source_pointer"] not in {"data/backlog.md", "data/done-archive.md"}:
                fail(f"{label}: decision lifecycle proposals require a structured decision source")
            if item["disposition"] not in {"review-required", "route-candidate"}:
                fail(f"{label}: decision lifecycle proposals require review or routing")
        if item["destination_owner"] == "primary data/captain-shared.md":
            if role == "primary":
                if item["home_scope"] != "primary:this-home":
                    fail(f"{label}: primary shared-captain proposals stay in the primary home")
            else:
                if item["home_scope"] != "primary:via-main-firstmate":
                    fail(f"{label}: secondmates must route shared-captain proposals through the main firstmate")
                if item["disposition"] not in {"review-required", "route-candidate"}:
                    fail(f"{label}: secondmate shared-captain proposals require review or routing")
        else:
            expected_scope = f"{role}:this-home"
            if item["home_scope"] != expected_scope:
                fail(f"{label}.home_scope must be {expected_scope}")
        normalized_proposal = " ".join(item["proposal"].casefold().split())
        dedup_tuple = (item["destination_owner"], item["source_pointer"], normalized_proposal)
        if dedup_tuple in tuples:
            fail(f"{label} duplicates an existing destination/source/proposal tuple")
        tuples.add(dedup_tuple)
        items.append(item)
    return items, notes


def render_proposal(inventory: dict[str, Any], items: list[dict[str, str]], notes: list[str]) -> bytes:
    pass_date = inventory["proposal_date"]
    lines = [
        f"# Memory clerk proposal - {pass_date}",
        "",
        "This private artifact is a bounded proposal and does not mutate canonical memory or operational records.",
        "Model-authored prose here is not a decision, approval, completion fact, or source of current worker state.",
        "Canonical owners must apply accepted changes through their existing inspect-then-update workflows.",
        "",
        f"- Schema: `fm-memory-clerk-proposal.v1`",
        f"- Home/scope: `{inventory['home_scope']}`",
        f"- Proposal date: `{pass_date}`",
        f"- Default review date: `{inventory['default_review_by']}`",
        f"- Proposed items: `{len(items)}` of at most `{ITEM_LIMIT}`",
        f"- Output limit: `{PROPOSAL_OUTPUT_LIMIT}` bytes",
        "",
        "## Input coverage",
        "",
    ]
    for source in inventory["sources"]:
        digest = source["sha256"] or "-"
        lines.append(
            f"- `{source['pointer']}` - {source['status']}; bytes `{source['bytes']}`; digest `{digest}`."
        )
    lines.extend(["", "## Proposed items", ""])
    if not items:
        lines.append("No canonical changes are proposed by this pass.")
    for item in items:
        lines.extend(
            [
                f"### {item['key']}",
                "",
                f"- Destination owner: `{item['destination_owner']}`",
                f"- Source pointer: `{item['source_pointer']}`",
                f"- Source digest: `{item['source_digest']}`",
                f"- Date: `{item['date']}`",
                f"- Home/scope: `{item['home_scope']}`",
                f"- Classification: `{item['classification']}`",
                f"- Rationale: {item['rationale']}",
                f"- Disposition: `{item['disposition']}`",
                f"- Review by: `{item['review_by']}`",
                f"- Proposal: {item['proposal']}",
                "",
            ]
        )
    lines.extend(["## Coverage notes", ""])
    if notes:
        lines.extend(f"- {note}" for note in notes)
    else:
        lines.append("- No additional coverage exception was recorded.")
    lines.extend(
        [
            "",
            "## Next owner action",
            "",
            "Review accepted memory-file recommendations through `/stow` and route every other recommendation through its named canonical owner.",
            "Prefer rewrites and pruning over append-only growth, and let unreviewed items expire at their review date.",
            "",
        ]
    )
    rendered = "\n".join(lines).encode("utf-8")
    if len(rendered) > PROPOSAL_OUTPUT_LIMIT:
        fail(f"rendered proposal exceeds {PROPOSAL_OUTPUT_LIMIT} bytes")
    return rendered


def publish(home: Path, pass_date: str, rendered: bytes) -> str:
    data = home / "data"
    if not lexists(data):
        require_no_symlink_components(home)
        try:
            data.mkdir(mode=0o700)
        except OSError as exc:
            fail(f"could not create data directory: {exc}")
    require_safe_directory(data)
    destination_dir = data / "memory-clerk"
    require_safe_directory(destination_dir, create=True, mode=0o700)
    destination = destination_dir / f"proposal-{pass_date}.md"
    existing = safe_regular_metadata(destination)
    if existing is not None and existing.st_nlink != 1:
        fail(f"proposal destination is hardlinked: {destination}")

    try:
        fd, temporary_name = tempfile.mkstemp(prefix=".proposal.", dir=destination_dir)
    except OSError as exc:
        fail(f"could not create proposal temporary file: {exc}")
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        os.chmod(destination, 0o600)
    except OSError as exc:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            temporary.unlink()
        except OSError:
            pass
        fail(f"could not publish proposal: {exc}")
    return f"data/memory-clerk/proposal-{pass_date}.md"


def main() -> int:
    if len(sys.argv) < 3:
        fail("internal invocation is incomplete")
    home = Path(sys.argv[1]).expanduser().absolute()
    command = sys.argv[2]
    pass_date, reports = parse_args(sys.argv[3:])
    inventory = gather(home, pass_date, reports)
    if command == "inventory":
        sys.stdout.buffer.write(render_inventory(inventory))
        return 0
    if command == "write":
        payload = read_payload()
        items, notes = validate_payload(payload, inventory)
        rendered = render_proposal(inventory, items, notes)
        print(publish(home, pass_date, rendered))
        return 0
    fail(f"unsupported command: {command}")
    return 2


try:
    raise SystemExit(main())
except ClerkError as exc:
    print(f"fm-memory-clerk: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
