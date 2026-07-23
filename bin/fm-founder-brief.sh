#!/usr/bin/env bash
# Own the durable Telegram founder communication lifecycle.
#
# Commands:
#   fm-founder-brief.sh create <task-id> <phase>
#   fm-founder-brief.sh deliver <task-id> <phase>
#   fm-founder-brief.sh verify <task-id> <phase>
#   fm-founder-brief.sh phase <task-id> <phase>
#   fm-founder-brief.sh during-create <task-id> <phase>
#   fm-founder-brief.sh during <task-id> <phase>
#   fm-founder-brief.sh post-create <task-id> <phase>
#   fm-founder-brief.sh post <task-id> <phase>
#   fm-founder-brief.sh verify-complete <task-id>
#   fm-founder-brief.sh decision-create <digest-id>
#   fm-founder-brief.sh decision-deliver <digest-id>
#   fm-founder-brief.sh remind-decisions
#   fm-founder-brief.sh ingest-update <private-update.json>
#   fm-founder-brief.sh route-update <private-update.json>
#   fm-founder-brief.sh relay-once
#   fm-founder-brief.sh reply-create <update-id>
#   fm-founder-brief.sh reply <update-id>
#   fm-founder-brief.sh outcome-create <update-id>
#   fm-founder-brief.sh outcome <update-id>
#   fm-founder-brief.sh regression-run
#   fm-founder-brief.sh conversation-canary-create
#   fm-founder-brief.sh conversation-canary-verify
#   fm-founder-brief.sh canary-delivery
#   fm-founder-brief.sh canary-buttons
#   fm-founder-brief.sh incident-create <conversation|lifecycle|decision> <canary>
#   fm-founder-brief.sh incident-transition <conversation|lifecycle|decision> <diagnosis|repair|revalidation>
#   fm-founder-brief.sh incident-restore <conversation|lifecycle|decision>
#   fm-founder-brief.sh incident-status <conversation|lifecycle|decision>
#
# `create` atomically scaffolds private `data/<task-id>/founder-brief.md` and
# refuses to overwrite it.
# `deliver` validates that file, durably publishes an outbound record, sends it
# through Telegram, validates the Telegram acknowledgment, and atomically
# publishes a receipt.
# `verify` is the non-sending gate used by lifecycle commands.
# `phase` is the explicit command for a newly authorized investigation,
# planning, implementation, review, release, deployment, remediation, or other
# phase; it is an alias for `deliver` and returns as soon as delivery is
# acknowledged, without waiting for a captain reply or approval.
# `during-create` scaffolds `data/<task-id>/founder-during.md`.
# `during` records that task's latest material milestone, risk, blocker, or
# proof transition, then sends one current digest grouped by project for all
# active task records.
# An unchanged aggregate is deduped and never produces no-change chatter.
# `post-create` scaffolds `data/<task-id>/founder-post.md`.
# `post` sends the completed phase or task outcome, proof, remaining limits,
# and next step, then retires that task from future DURING digests.
# `verify-complete` is the teardown gate for tasks first managed under this
# feature; tasks without a managed marker are grandfathered.
# `decision-create` scaffolds a private project-grouped JSON decision digest at
# `data/founder-brief-decisions/<digest-id>.json`.
# `decision-deliver` sends its decisions with one-use opaque inline buttons.
# `remind-decisions` sends one deduplicated project-grouped bundle of every
# still-open decision when the bounded local cadence is due.
# `ingest-update` claims only callback queries whose callback_data starts with
# `fmb1:`; an ordinary message or any foreign callback returns exit 3 without
# modifying the update, advancing an offset, or stealing it from another relay.
# `route-update` durably accepts one authenticated captain text/update or
# separately dispatches one owned callback.
# `relay-once` is the tracked replacement for the private getUpdates poll.
# It processes updates in numeric order, advances `state/telegram-relay.offset`
# only after each update is durably classified, and retains ordinary messages
# at `state/telegram-inbox/<update-id>.json` with update, message, chat, sender,
# edit, reply, and thread identifiers.
# Every accepted captain text or edit receives one prompt in-channel
# acknowledgment bound with `reply_parameters.message_id`.
# `reply-create` scaffolds `data/telegram-replies/<update-id>.md`.
# `reply` sends that substantive response back to the authenticated originating
# chat, binds every split part to the originating message, and durably records
# the response without consuming or reclassifying it as lifecycle content.
# `outcome-create` scaffolds the private handling record for one accepted
# message; `outcome` proves that its substantive reply produced a
# content-appropriate answer, work route, approval record, suggestion record,
# conversation answer, or correction steer.
# `regression-run` runs this owner's deterministic test through fm-test-run and
# publishes a bounded, code-hash-bound private pass receipt.
# `conversation-canary-create` scaffolds three private update-id bindings for a
# live question, work request, and correction.
# `conversation-canary-verify` requires accepted, acknowledged, substantively
# answered, and outcome-recorded evidence for all three plus a current
# deterministic regression receipt.
# `canary-delivery` and `canary-buttons` are explicit firstmate-owned post-merge
# live checks for the lifecycle and decision lanes.
# The button canary carries `authority=none` and can never create an approval
# receipt or authorize an action.
# Any failed live canary atomically opens a lane-scoped incident.
# A lifecycle failure disables only PRE/DURING/POST and a decision failure
# disables only decision automation; neither may disable or delay ordinary
# conversation ingest, prompt acknowledgment, substantive reply, or work
# routing.
# A conversation incident is highest priority and blocks both automation lanes,
# but conversation itself stays retryable through its durable inbox/outbox.
# Incident states are containment, diagnosis, repair, revalidation, resolved.
# Containment is never success.
# `incident-transition` reads bounded private diagnostics from
# `data/telegram-protocol-incidents/<lane>.md`.
# `incident-restore` requires a regression pass and all three live canaries
# newer than the incident before resolving it.
#
# The local opt-in schema is owned by `docs/configuration.md`.
# With no `config/founder-brief` file, `verify` is a silent compatibility no-op
# and every sending command refuses to send.
# `telegram-conversation` enables only the ordinary two-way lane.
# `telegram-mandatory` requests both lanes, but PRE/DURING/POST and decisions
# stay disabled until deterministic regression and the live conversation canary
# pass; an open lane incident keeps only its affected automation contained.
# Telegram credentials and the expected numeric chat identity come from the
# process environment first, then the active home's private `.env`.
# Token keys, in precedence order, are TELEGRAM_BOT_TOKEN,
# FM_TELEGRAM_BOT_TOKEN, and MARLOW_TELEGRAM_BOT_TOKEN.
# Chat keys, in precedence order, are TELEGRAM_CHAT_ID and
# FM_TELEGRAM_CHAT_ID.
# Callback user keys, in precedence order, are TELEGRAM_USER_ID and
# FM_TELEGRAM_USER_ID.
# Never place any of these values in tracked files.
# Ordinary Telegram conversation is additive to PRE/DURING/POST.
# Lifecycle renderers never claim, summarize, close, or replace chat messages.
#
# The brief is UTF-8 Markdown with these exact level-two headings, once each and
# in this order:
#   Project and customer context
#   Requirement and why now
#   Intended capability and outcome
#   Affected product surfaces
#   In scope
#   Out of scope
#   Risks and safety boundaries
#   Dependencies
#   Planned proof
# Every section must contain non-placeholder text.
# The owner command canonically renders those sections as Telegram HTML.
# Only fixed owner-generated `<b>` tags are emitted for the title, metadata
# labels, part label, and section headings.
# Every author-provided character is HTML-escaped, so literal `<`, `>`, `&`,
# markup-looking prose, bullets, and newlines remain content rather than markup.
# This owner conservatively caps every rendered message at 4096 UTF-8 bytes
# after entity decoding.
# A brief over that limit is split deterministically at line boundaries, then
# character boundaries for a single overlong line, with a repeated
# informational header and `Part: n/N` label.
# One brief may produce at most 20 messages.
# PRE, DURING, POST, and decision digests use the same compact mobile header,
# fixed bold grouping labels, escaped author content, and deterministic split
# mechanics.
#
# Task ids and phases are lowercase slugs.
# The canonical unsplit Telegram HTML is SHA-256 hashed as the exact content
# identity.
# The dedupe key is SHA-256 over canonical JSON containing the resolved home,
# task, phase, canonical rendered-content hash, rendering version, and
# expected-chat hash.
# Private outbox records live at
# `state/founder-brief-outbox/<dedupe-key>.json`.
# Private staged Telegram responses live at
# `state/founder-brief-responses/<dedupe-key>.<part-number>.json`.
# Private acknowledgment receipts live at
# `state/founder-brief-receipts/<dedupe-key>.json`.
# DURING latest-state records live at `state/founder-brief-active/<task>.json`.
# Managed-phase and acknowledged-POST markers live in private
# `state/founder-brief-managed/` and `state/founder-brief-posted/` directories.
# Decision button bindings live at
# `state/founder-brief-buttons/<opaque-id>.json`, current-decision pointers at
# `state/founder-brief-decision-current/<decision-identity>.json`, and atomic
# one-use selections at a hash of stable identity plus exact decision content in
# `state/founder-brief-approvals/`.
# Numeric reply maps are bound to the final acknowledged decision message at
# `state/founder-brief-number-replies/<message-id>.json`.
# Current decision pointers carry stable decision ids, explicit versions,
# recommendation/context, and explicit option numbers.
# Superseded versions are retained at
# `state/founder-brief-decision-history/<decision-identity>/<version>.json`.
# Every outbox record and receipt binds schema version, resolved home, task,
# phase, exact content hash, expected-chat hash, and dedupe key.
# A staged response is bound by its dedupe-key filename inside the private
# response directory and is never treated as an acknowledgment by itself.
# Receipts additionally bind the ordered positive numeric Telegram message ids,
# message count, first message id, and acknowledgment time.
#
# Record directories are real, owner-controlled mode-0700 directories.
# Briefs, outbox records, staged responses, receipts, and per-item lock files
# are regular mode-0600 files.
# Every publication writes a same-directory temporary file, fsyncs it, applies
# mode 0600, renames it atomically, and fsyncs the directory.
# A per-dedupe advisory lock serializes concurrent deliveries in one home.
#
# A valid acknowledgment is JSON with boolean `ok=true`, a `result.chat.id`
# exactly matching the configured chat identity, and a positive integer
# `result.message_id`.
# Captain replies, inbound relay state, silence, and approval are never read or
# inferred by this command.
# A matching valid receipt makes retries succeed without sending again.
# A part response staged before a crash is revalidated and recorded on the next
# retry without sending that part again.
# A receipt is published only after every rendered part is acknowledged.
# A validated Telegram `ok=false` is a definite failed attempt and may be
# retried.
# A malformed or wrong-chat response is rejected as delivery-unknown and is not
# resent automatically because it does not prove that Telegram delivered
# nothing.
# A timeout, transport exception, or crash with no complete staged response is
# delivery-unknown and is never resent automatically, because Telegram
# `sendMessage` has no idempotency key and resending could duplicate a delivered
# message.
# In that rare case, preserve the durable outbox and staged response evidence;
# recover a complete staged response if one exists, or change the brief content
# to create a new explicitly acknowledged item.
#
# Decision digests bind the exact canonical decision JSON hash, delivery hash,
# approved chat hash, approved user hash, task, project, decision key, option,
# expiry, and an opaque callback id whose `fmb1:<id>` callback_data is at most
# 64 UTF-8 bytes.
# Options are numbered once across the whole digest.
# The private digest schema requires a stable `decision_id`, positive `version`,
# `context`, `recommendation`, and an explicit positive `number` on every
# option; numbers must be unique across the bundle.
# Repeats preserve those ids and numbers.
# Changed decision content requires a higher version and may never bind an old
# number to a different option key or silently move an existing option key to a
# different number.
# Each one-use approval is keyed by stable decision identity plus the exact
# decision-content hash, so an answered old version can never close a changed
# decision version.
# An exact numeric captain message is accepted when it replies to the digest's
# final acknowledged Telegram message or when exactly one unexpired unused
# decision is open and its number resolves uniquely.
# An unavailable or ambiguous bare number receives a clarification prompt.
# Prose containing a number, replies to superseded digests, and already-used
# decisions remain conversation and never become approvals.
# Callback ingestion requires the matching acknowledged delivery receipt and
# final Telegram message id, the currently armed decision pointer, exact chat
# and user identities, an unexpired binding, and an unused decision identity.
# Stale, replayed, foreign, expired, or tampered callbacks never create a new
# approval.
# The one-use approval receipt is atomically and durably created before
# `answerCallbackQuery` is attempted and before any caller may act.
# A retry of the exact same callback only recovers callback acknowledgment and
# never creates a second action.
# This command records the captain's exact option; it never executes the
# downstream action.
# Existing merge, ask-user, destructive, irreversible, credential, and
# security-sensitive authority rules remain authoritative.
# Every DURING and POST renderer appends one compact project-grouped Pending
# approvals section while any current unexpired decision remains unanswered.
# `config/founder-brief-reminder-seconds` is optional private text containing
# one integer from 900 through 43200; absent means 21600 seconds.
# Reminder cycles use the current pending content hash and cadence window as
# their dedupe identity, batch all pending decisions, stop immediately when
# none remain, and never inspect or advance the ordinary conversation inbox.
# The common watcher invokes `remind-decisions` after ordinary relay checks, so
# every supported harness and runtime uses one restart-safe scheduler without
# letting reminder delivery outrank captain conversation.
# A reminder failure preserves its outbox, contains only decision automation,
# durably opens an incident, and surfaces one bounded deduplicated diagnostic.
#
# Validation rejects missing headings, empty or placeholder sections, invalid
# UTF-8, NUL/unsafe control characters, inputs above 65536 characters, and
# rendered output requiring more than 20 Telegram messages.
# It also rejects bounded credential signatures: private-key headers, common
# secret assignments, Telegram/GitHub/Slack/AWS token shapes, JWT-like bearer
# values, and URLs containing userinfo.
# This is deliberately not a general-purpose secret scanner.
# It reduces common accidental disclosure but cannot prove that prose is
# secret-free or founder-friendly; the author remains responsible for concise
# plain language and safe content.
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
  -h|--help) usage; exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "fm-founder-brief: python3 is required" >&2
  exit 1
}

export FM_ROOT FM_HOME
exec python3 - "$@" <<'PY'
import fcntl
import hashlib
import html
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCHEMA_VERSION = 1
RENDERING_VERSION = "telegram-html-v1"
CONFIG_CONVERSATION = "telegram-conversation"
CONFIG_MANDATORY = "telegram-mandatory"
CONVERSATION_PROTOCOL_VERSION = "telegram-dual-lane-v1"
MESSAGE_LIMIT = 4096
MAX_MESSAGE_CHUNKS = 20
MAX_INPUT_CHARS = 65536
MAX_RESPONSE_BYTES = 1024 * 1024
TASK_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
PHASE_RE = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
REQUIRED_SECTIONS = (
    "Project and customer context",
    "Requirement and why now",
    "Intended capability and outcome",
    "Affected product surfaces",
    "In scope",
    "Out of scope",
    "Risks and safety boundaries",
    "Dependencies",
    "Planned proof",
)
PLACEHOLDER_RE = re.compile(
    r"(?im)(?:\{[^{}\n]+\}|<[^<>\n]*(?:fill|replace|todo)[^<>\n]*>|\b(?:TODO|TBD|PLACEHOLDER)\b)"
)
SECRET_PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("secret-assignment", re.compile(
        r"(?i)\b(?:api[_-]?key|access[_-]?token|auth(?:orization)?|bot[_-]?token|"
        r"client[_-]?secret|password|private[_-]?key|secret)\b\s*[:=]\s*"
        r"[\"']?[A-Za-z0-9_./+=:@-]{8,}"
    )),
    ("telegram-token", re.compile(r"\b[0-9]{6,}:[A-Za-z0-9_-]{20,}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("url-userinfo", re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@")),
)
TOKEN_KEYS = (
    "TELEGRAM_BOT_TOKEN",
    "FM_TELEGRAM_BOT_TOKEN",
    "MARLOW_TELEGRAM_BOT_TOKEN",
)
CHAT_KEYS = ("TELEGRAM_CHAT_ID", "FM_TELEGRAM_CHAT_ID")
USER_KEYS = ("TELEGRAM_USER_ID", "FM_TELEGRAM_USER_ID")


class BriefError(Exception):
    pass


class DeliveryRejected(BriefError):
    pass


class CallbackRejected(BriefError):
    pass


def fail(message, code=1):
    print(f"fm-founder-brief: {message}", file=sys.stderr)
    raise SystemExit(code)


def now_epoch():
    override = os.environ.get("FM_FOUNDER_BRIEF_NOW")
    if override and re.fullmatch(r"[0-9]+", override):
        return int(override)
    return int(time.time())


def file_mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def ensure_private_dir(path):
    try:
        if path.is_symlink():
            raise BriefError(f"private directory cannot be a symlink: {path}")
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        st = path.stat()
    except OSError:
        raise BriefError(f"cannot prepare private directory: {path}") from None
    if not stat.S_ISDIR(st.st_mode):
        raise BriefError(f"private path is not a directory: {path}")
    if st.st_uid != os.geteuid():
        raise BriefError(f"private directory is not owned by the current user: {path}")
    try:
        os.chmod(path, 0o700)
    except OSError:
        raise BriefError(f"cannot set mode 0700 on private directory: {path}") from None
    if file_mode(path) != 0o700:
        raise BriefError(f"private directory is not mode 0700: {path}")


def check_private_file(path, label):
    try:
        st = path.lstat()
    except OSError:
        raise BriefError(f"cannot inspect {label}: {path}") from None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise BriefError(f"{label} must be a regular non-symlink file: {path}")
    if st.st_uid != os.geteuid():
        raise BriefError(f"{label} is not owned by the current user: {path}")
    if stat.S_IMODE(st.st_mode) != 0o600:
        raise BriefError(f"{label} must be mode 0600: {path}")


def atomic_write_bytes(path, payload):
    ensure_private_dir(path.parent)
    fd = None
    tmp_name = None
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as handle:
            fd = None
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
        tmp_name = None
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        raise BriefError(f"atomic publication failed: {path}") from None
    finally:
        if fd is not None:
            os.close(fd)
        if tmp_name is not None:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass


def atomic_write_json(path, value):
    payload = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    atomic_write_bytes(path, payload)


def read_json(path, label):
    check_private_file(path, label)
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise BriefError(f"{label} is not valid private JSON: {path}") from None
    if not isinstance(value, dict):
        raise BriefError(f"{label} must contain a JSON object: {path}")
    return value


def read_dotenv(home):
    values = {}
    path = home / ".env"
    if not path.exists():
        return values
    try:
        st = path.lstat()
    except OSError:
        raise BriefError("cannot inspect the private .env") from None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise BriefError("private .env must be a regular non-symlink file")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        raise BriefError("cannot read the private .env") from None
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in TOKEN_KEYS and key not in CHAT_KEYS and key not in USER_KEYS:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


def first_setting(keys, dotenv):
    for key in keys:
        value = os.environ.get(key)
        if value:
            return value
    for key in keys:
        value = dotenv.get(key)
        if value:
            return value
    return ""


def config_mode(home):
    path = home / "config" / "founder-brief"
    if not path.exists():
        return None
    try:
        st = path.lstat()
    except OSError:
        raise BriefError("cannot inspect config/founder-brief") from None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise BriefError("config/founder-brief must be a regular non-symlink file")
    try:
        value = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        raise BriefError("cannot read config/founder-brief") from None
    if value not in (CONFIG_CONVERSATION, CONFIG_MANDATORY):
        raise BriefError(
            "config/founder-brief must contain exactly telegram-conversation "
            "or telegram-mandatory"
        )
    return value


def config_enabled(home):
    return config_mode(home) is not None


def identity_hashes(home):
    dotenv = read_dotenv(home)
    chat_id = first_setting(CHAT_KEYS, dotenv)
    user_id = first_setting(USER_KEYS, dotenv)
    if not re.fullmatch(r"-?[0-9]+", chat_id or ""):
        return None
    if not re.fullmatch(r"[0-9]+", user_id or ""):
        return None
    return (
        hashlib.sha256(chat_id.encode("utf-8")).hexdigest(),
        hashlib.sha256(user_id.encode("utf-8")).hexdigest(),
    )


def file_sha256(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        raise BriefError(f"cannot hash tracked protocol owner: {path}") from None


def regression_receipt_valid(home, newer_than=0):
    path = home / "state" / "telegram-protocol-regression.json"
    if not path.exists():
        return False
    value = read_json(path, "Telegram protocol regression receipt")
    root = Path(os.environ["FM_ROOT"]).resolve(strict=True)
    expected = {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-protocol-regression",
        "status": "passed",
        "home": str(home),
        "owner_sha256": file_sha256(root / "bin" / "fm-founder-brief.sh"),
        "test_sha256": file_sha256(root / "tests" / "fm-founder-brief.test.sh"),
    }
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        return False
    verified_at = value.get("verified_at")
    return (
        isinstance(verified_at, int)
        and not isinstance(verified_at, bool)
        and verified_at > 0
        and verified_at > newer_than
    )


def incident_dir(home):
    path = home / "state" / "telegram-protocol-incidents"
    ensure_private_dir(path)
    return path


def incident_path(home, lane):
    return incident_dir(home) / f"{lane}.json"


def validate_lane(lane):
    if lane not in ("conversation", "lifecycle", "decision"):
        raise BriefError("incident lane must be conversation, lifecycle, or decision")


def open_incident(home, lane, canary, consequence=None):
    validate_lane(lane)
    path = incident_path(home, lane)
    now = now_epoch()
    if path.exists():
        current = read_json(path, "Telegram protocol incident")
        if current.get("status") != "resolved":
            current["last_failed_canary"] = canary
            current["last_failed_at"] = now
            current["next_action"] = "capture diagnostics, repair root cause, then revalidate every lane"
            atomic_write_json(path, current)
            return current
    incident_id = hashlib.sha256(
        f"{home}\0{lane}\0{canary}\0{now}".encode("utf-8")
    ).hexdigest()
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-protocol-incident",
        "protocol_version": CONVERSATION_PROTOCOL_VERSION,
        "home": str(home),
        "incident_id": incident_id,
        "lane": lane,
        "status": "containment",
        "failed_canary": canary,
        "consequence": consequence or (
            "conversation remains active; only the affected automation is disabled"
        ),
        "opened_at": now,
        "updated_at": now,
        "next_action": "capture diagnostics and identify the root cause",
    }
    atomic_write_json(path, value)
    data_dir = home / "data" / "telegram-protocol-incidents"
    ensure_private_dir(data_dir)
    diagnostics_path = data_dir / f"{lane}.md"
    if not diagnostics_path.exists():
        template = """# Telegram protocol incident

## Failed canary and consequence

{Name the failed canary and its bounded consequence without message content or credentials.}

## Bounded diagnostics

{Record only the minimum safe diagnostic evidence needed to reproduce the failure.}

## Root cause

{State the verified root cause.}

## Repair

{State the repair that was applied.}

## Next concrete action

{State the next concrete action.}
"""
        atomic_write_bytes(diagnostics_path, template.encode("utf-8"))
    if os.environ.get("FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_INCIDENT") == "1":
        os._exit(88)
    return value


def active_incident(home, lane):
    path = incident_path(home, lane)
    if not path.exists():
        return None
    value = read_json(path, "Telegram protocol incident")
    if value.get("lane") != lane or value.get("home") != str(home):
        raise BriefError("Telegram protocol incident binding is stale or tampered")
    return None if value.get("status") == "resolved" else value


def conversation_canary_valid(home, newer_than=0):
    if config_mode(home) != CONFIG_MANDATORY:
        return False
    path = home / "state" / "telegram-conversation-canary.json"
    if not path.exists():
        return False
    value = read_json(path, "Telegram conversation canary receipt")
    hashes = identity_hashes(home)
    if hashes is None:
        return False
    chat_hash, user_hash = hashes
    expected = {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-conversation-canary",
        "protocol_version": CONVERSATION_PROTOCOL_VERSION,
        "status": "passed",
        "home": str(home),
        "chat_identity_sha256": chat_hash,
        "user_identity_sha256": user_hash,
    }
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        return False
    evidence_hash = value.get("canary_evidence_sha256")
    verified_at = value.get("verified_at")
    if not isinstance(evidence_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", evidence_hash):
        return False
    if isinstance(verified_at, bool) or not isinstance(verified_at, int) or verified_at <= 0:
        return False
    return verified_at > newer_than


def protocol_ready(home):
    return (
        config_mode(home) == CONFIG_MANDATORY
        and regression_receipt_valid(home)
        and conversation_canary_valid(home)
        and active_incident(home, "conversation") is None
    )


def lifecycle_enabled(home):
    return protocol_ready(home) and active_incident(home, "lifecycle") is None


def decision_enabled(home):
    return protocol_ready(home) and active_incident(home, "decision") is None


def require_lifecycle(home):
    if not lifecycle_enabled(home):
        raise BriefError(
            "PRE/DURING/POST automation is contained; ordinary Telegram "
            "conversation remains active while regression, canary, or incident evidence is repaired"
        )


def require_decision(home):
    if not decision_enabled(home):
        raise BriefError(
            "decision automation is contained; ordinary Telegram conversation "
            "remains active while regression, canary, or incident evidence is repaired"
        )


def validate_slug(value, label, pattern):
    if not pattern.fullmatch(value):
        raise BriefError(f"invalid {label}; expected a lowercase slug")


def brief_path(home, task):
    return home / "data" / task / "founder-brief.md"


def scaffold(home, task, phase):
    path = brief_path(home, task)
    ensure_private_dir(path.parent)
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing founder brief: {path}")
    template = f"""# Founder pre-work brief

Task: {task}
Phase: {phase}

Write plain founder-language text or Markdown bullets.
Literal Telegram or HTML markup is escaped; section headings become bold automatically.

## Project and customer context

{{Describe the project, customer, and business context in plain language.}}

## Requirement and why now

{{Explain what is required and why this work is starting now.}}

## Intended capability and outcome

{{Describe the user or business outcome this work should create.}}

## Affected product surfaces

{{Name the product areas, workflows, or operational surfaces affected.}}

## In scope

{{State the bounded work included in this phase.}}

## Out of scope

{{State what this phase will not change or decide.}}

## Risks and safety boundaries

{{Explain material risks and the boundaries that keep the work safe.}}

## Dependencies

{{List required systems, people, prior work, or state, or say None.}}

## Planned proof

{{Explain how the outcome will be demonstrated or verified.}}
"""
    atomic_write_bytes(path, template.encode("utf-8"))
    print(f"scaffolded founder brief: {path}")


def render_line(text, bold=False):
    escaped = html.escape(text, quote=False)
    return f"<b>{escaped}</b>" if bold else escaped


def visible_bytes(rendered):
    without_owner_tags = rendered.replace("<b>", "").replace("</b>", "")
    return len(html.unescape(without_owner_tags).encode("utf-8"))


def rendered_header(title, subtitle, metadata, part=None, total=None):
    lines = [
        render_line(title, bold=True),
        html.escape(subtitle, quote=False),
    ]
    for label, value in metadata:
        lines.append(
            f"{render_line(label + ':', bold=True)} {html.escape(value, quote=False)}"
        )
    if part is not None and total is not None:
        lines.append(f"{render_line('Part:', bold=True)} {part}/{total}")
    return "\n".join(lines)


def take_prefix_by_bytes(text, budget):
    low = 0
    high = len(text)
    while low < high:
        middle = (low + high + 1) // 2
        if len(text[:middle].encode("utf-8")) <= budget:
            low = middle
        else:
            high = middle - 1
    return text[:low], text[low:]


def pack_rendered_parts(title, subtitle, metadata, body_lines, total_hint):
    chunks = []
    current = []
    index = 1

    def available_for(candidate):
        header = rendered_header(title, subtitle, metadata, index, total_hint)
        rendered_body = "\n".join(render_line(text, bold) for text, bold in candidate)
        separator = "\n\n" if rendered_body else ""
        return MESSAGE_LIMIT - visible_bytes(header + separator + rendered_body)

    for source_text, bold in body_lines:
        remaining = source_text
        while True:
            candidate = current + [(remaining, bold)]
            if available_for(candidate) >= 0:
                current = candidate
                break
            if current:
                chunks.append(current)
                if len(chunks) >= MAX_MESSAGE_CHUNKS:
                    raise BriefError(
                        f"founder brief requires more than {MAX_MESSAGE_CHUNKS} Telegram messages"
                    )
                current = []
                index += 1
                continue
            header = rendered_header(title, subtitle, metadata, index, total_hint)
            budget = MESSAGE_LIMIT - visible_bytes(header) - 2
            if budget <= 0:
                raise BriefError("founder brief Telegram header exceeds the message limit")
            if bold:
                raise BriefError("founder brief section heading exceeds the Telegram message limit")
            segment, remaining = take_prefix_by_bytes(remaining, budget)
            if not segment:
                raise BriefError("founder brief contains a character too large for Telegram")
            current = [(segment, False)]
            if not remaining:
                break
            chunks.append(current)
            if len(chunks) >= MAX_MESSAGE_CHUNKS:
                raise BriefError(
                    f"founder brief requires more than {MAX_MESSAGE_CHUNKS} Telegram messages"
                )
            current = []
            index += 1
    if current or not chunks:
        chunks.append(current)
    return chunks


def render_document(title, subtitle, metadata, body_lines):
    body_html = "\n".join(render_line(text, bold) for text, bold in body_lines)
    canonical = rendered_header(title, subtitle, metadata) + "\n\n" + body_html
    if visible_bytes(canonical) <= MESSAGE_LIMIT:
        return canonical, [canonical]
    total_hint = 2
    for _ in range(10):
        chunks = pack_rendered_parts(title, subtitle, metadata, body_lines, total_hint)
        actual_total = len(chunks)
        if actual_total == total_hint:
            break
        total_hint = actual_total
    else:
        raise BriefError("founder brief splitting did not converge")
    if actual_total > MAX_MESSAGE_CHUNKS:
        raise BriefError(
            f"founder brief requires more than {MAX_MESSAGE_CHUNKS} Telegram messages"
        )
    messages = []
    for part, chunk in enumerate(chunks, start=1):
        rendered_body = "\n".join(render_line(text, bold) for text, bold in chunk)
        message = (
            rendered_header(title, subtitle, metadata, part, actual_total)
            + "\n\n"
            + rendered_body
        )
        if visible_bytes(message) > MESSAGE_LIMIT:
            raise BriefError("founder brief splitting produced an oversized Telegram message")
        messages.append(message)
    return canonical, messages


def sections_to_lines(sections):
    body_lines = []
    for heading, body in sections:
        if body_lines:
            body_lines.append(("", False))
        body_lines.append((heading, True))
        for line in body.split("\n"):
            body_lines.append((line, False))
    return body_lines


def render_messages(task, phase, sections):
    return render_document(
        "PRE · Founder brief",
        "Informational · No reply or approval required",
        (("Task", task), ("Phase", phase)),
        sections_to_lines(sections),
    )


def validate_brief(home, task, phase):
    path = brief_path(home, task)
    if not path.exists():
        raise BriefError(f"missing founder brief: {path}")
    check_private_file(path, "founder brief")
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeError):
        raise BriefError("founder brief must be readable UTF-8") from None
    if not raw:
        raise BriefError("founder brief is empty")
    if len(text) > MAX_INPUT_CHARS:
        raise BriefError(
            f"founder brief input is oversized ({len(text)} characters; maximum is {MAX_INPUT_CHARS})"
        )
    for char in text:
        code = ord(char)
        if (code < 0x20 and char != "\n") or code == 0x7F:
            raise BriefError("founder brief contains an unsafe control character")
    positions = []
    for heading in REQUIRED_SECTIONS:
        marker = f"## {heading}"
        hits = [match.start() for match in re.finditer(rf"(?m)^{re.escape(marker)}\s*$", text)]
        if len(hits) != 1:
            raise BriefError(f"founder brief requires exactly one section: {heading}")
        positions.append(hits[0])
    if positions != sorted(positions):
        raise BriefError("founder brief sections are not in the required order")
    sections = []
    for index, heading in enumerate(REQUIRED_SECTIONS):
        start_line = text.find("\n", positions[index])
        if start_line < 0:
            body = ""
        else:
            end = positions[index + 1] if index + 1 < len(positions) else len(text)
            body = text[start_line + 1:end].strip()
        if not body:
            raise BriefError(f"founder brief section is empty: {heading}")
        if PLACEHOLDER_RE.search(body):
            raise BriefError(f"founder brief section still contains placeholder text: {heading}")
        sections.append((heading, body))
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            raise BriefError(f"founder brief rejected credential-like material ({label})")
    canonical_rendered, messages = render_messages(task, phase, sections)
    content_hash = hashlib.sha256(canonical_rendered.encode("utf-8")).hexdigest()
    return path, canonical_rendered, messages, content_hash


def identity(home, task, phase, content_hash, bindings=None):
    dotenv = read_dotenv(home)
    chat_id = first_setting(CHAT_KEYS, dotenv)
    if not re.fullmatch(r"-?[0-9]+", chat_id or ""):
        raise BriefError("expected Telegram chat identity is missing or not numeric")
    chat_hash = hashlib.sha256(chat_id.encode("utf-8")).hexdigest()
    material = {
        "chat_identity_sha256": chat_hash,
        "content_sha256": content_hash,
        "home": str(home),
        "phase": phase,
        "rendering_version": RENDERING_VERSION,
        "task": task,
    }
    if bindings:
        material.update(bindings)
    canonical = json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    dedupe_key = hashlib.sha256(canonical).hexdigest()
    return dotenv, chat_id, chat_hash, dedupe_key


def paths_for(home, dedupe_key):
    state = home / "state"
    outbox_dir = state / "founder-brief-outbox"
    response_dir = state / "founder-brief-responses"
    receipt_dir = state / "founder-brief-receipts"
    lock_dir = state / "founder-brief-locks"
    for directory in (state, outbox_dir, response_dir, receipt_dir, lock_dir):
        ensure_private_dir(directory)
    return {
        "outbox": outbox_dir / f"{dedupe_key}.json",
        "response_dir": response_dir,
        "receipt": receipt_dir / f"{dedupe_key}.json",
        "lock": lock_dir / f"{dedupe_key}.lock",
    }


def response_path(paths, dedupe_key, index):
    return paths["response_dir"] / f"{dedupe_key}.{index + 1:04d}.json"


def common_record(
    home,
    task,
    phase,
    content_hash,
    chat_hash,
    dedupe_key,
    message_count,
    bindings=None,
):
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": "founder-brief",
        "rendering_version": RENDERING_VERSION,
        "home": str(home),
        "task": task,
        "phase": phase,
        "content_sha256": content_hash,
        "chat_identity_sha256": chat_hash,
        "dedupe_key": dedupe_key,
        "message_count": message_count,
    }
    if bindings:
        value.update(bindings)
    return value


def receipt_valid(path, common):
    if not path.exists():
        return False
    value = read_json(path, "founder brief receipt")
    for key, expected in common.items():
        if value.get(key) != expected:
            raise BriefError(f"founder brief receipt binding mismatch: {key}")
    message_id = value.get("telegram_message_id")
    message_ids = value.get("telegram_message_ids")
    acknowledged_at = value.get("acknowledged_at")
    if not isinstance(message_ids, list) or len(message_ids) != common["message_count"]:
        raise BriefError("founder brief receipt has an invalid Telegram message id list")
    for item in message_ids:
        if isinstance(item, bool) or not isinstance(item, int) or item <= 0:
            raise BriefError("founder brief receipt has an invalid Telegram message id list")
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        raise BriefError("founder brief receipt has an invalid Telegram message id")
    if not message_ids or message_id != message_ids[0]:
        raise BriefError("founder brief receipt first message id does not match its ordered list")
    if isinstance(acknowledged_at, bool) or not isinstance(acknowledged_at, int) or acknowledged_at <= 0:
        raise BriefError("founder brief receipt has an invalid acknowledgment time")
    return True


def validate_response(response, expected_chat):
    if not isinstance(response, dict):
        raise BriefError("Telegram response is not a JSON object")
    if response.get("ok") is False:
        raise DeliveryRejected("Telegram rejected founder brief delivery with ok=false")
    if response.get("ok") is not True:
        raise BriefError("Telegram response did not acknowledge delivery with ok=true")
    result = response.get("result")
    if not isinstance(result, dict):
        raise BriefError("Telegram response is missing result")
    chat = result.get("chat")
    if not isinstance(chat, dict) or str(chat.get("id")) != expected_chat:
        raise BriefError("Telegram response chat identity does not match the configured captain chat")
    message_id = result.get("message_id")
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        raise BriefError("Telegram response has no positive numeric message id")
    return message_id


def publish_ack(paths, common, message_ids):
    if len(message_ids) != common["message_count"]:
        raise BriefError("cannot publish founder brief receipt before every part is acknowledged")
    receipt = dict(common)
    receipt.update({
        "telegram_message_id": message_ids[0],
        "telegram_message_ids": message_ids,
        "acknowledged_at": now_epoch(),
    })
    atomic_write_json(paths["receipt"], receipt)


def acquire_lock(path):
    ensure_private_dir(path.parent)
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        os.fchmod(fd, 0o600)
        handle = os.fdopen(fd, "a+", encoding="utf-8")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    except OSError:
        raise BriefError("cannot acquire founder brief delivery lock") from None
    return handle


def outbox_with_status(outbox, status, error_code=None):
    next_value = dict(outbox)
    next_value["status"] = status
    next_value["updated_at"] = now_epoch()
    if error_code:
        next_value["last_error_code"] = error_code
    else:
        next_value.pop("last_error_code", None)
    return next_value


def telegram_request(dotenv, method, payload):
    token = first_setting(TOKEN_KEYS, dotenv)
    if not token or any(ord(char) < 0x21 or ord(char) == 0x7F for char in token):
        raise BriefError("Telegram bot token is missing or malformed")
    base = os.environ.get("FM_FOUNDER_BRIEF_ENDPOINT", "https://api.telegram.org").rstrip("/")
    if not (base.startswith("https://") or base.startswith("http://127.0.0.1:") or base.startswith("http://localhost:")):
        raise BriefError("founder brief endpoint must use HTTPS, except loopback test endpoints")
    endpoint = f"{base}/bot{urllib.parse.quote(token, safe=':')}/{method}"
    request_body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=request_body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    timeout_raw = os.environ.get("FM_FOUNDER_BRIEF_TIMEOUT", "20")
    try:
        timeout = float(timeout_raw)
    except ValueError:
        timeout = 20.0
    if timeout <= 0 or timeout > 60:
        timeout = 20.0

    def read_response(response):
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise BriefError("Telegram delivery state is unknown after an oversized response")
        return body

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return read_response(response)
    except urllib.error.HTTPError as error:
        try:
            return read_response(error)
        except OSError:
            raise BriefError("Telegram transport failed without a complete response") from None
    except BriefError:
        raise
    except Exception:
        raise BriefError("Telegram delivery state is unknown after a transport failure") from None


def send_telegram(
    dotenv,
    chat_id,
    message,
    reply_markup=None,
    reply_to_message_id=None,
    message_thread_id=None,
):
    payload = {"chat_id": chat_id, "text": message, "parse_mode": "HTML"}
    if reply_markup is not None:
        payload["reply_markup"] = reply_markup
    if reply_to_message_id is not None:
        payload["reply_parameters"] = {
            "message_id": reply_to_message_id,
            "allow_sending_without_reply": False,
        }
    if message_thread_id is not None:
        payload["message_thread_id"] = message_thread_id
    return telegram_request(dotenv, "sendMessage", payload)


def answer_callback(dotenv, callback_query_id, text):
    return telegram_request(
        dotenv,
        "answerCallbackQuery",
        {
            "callback_query_id": callback_query_id,
            "text": text,
            "show_alert": False,
        },
    )


def discard_staged_response(path):
    try:
        path.unlink()
    except FileNotFoundError:
        return
    except OSError:
        raise BriefError("cannot discard a definitively rejected Telegram response") from None


def context(home, task, phase):
    _, canonical_rendered, messages, content_hash = validate_brief(home, task, phase)
    dotenv, chat_id, chat_hash, dedupe_key = identity(home, task, phase, content_hash)
    paths = paths_for(home, dedupe_key)
    common = common_record(
        home,
        task,
        phase,
        content_hash,
        chat_hash,
        dedupe_key,
        len(messages),
    )
    return canonical_rendered, messages, dotenv, chat_id, paths, common


def payload_context(home, task, phase, canonical_rendered, messages, bindings):
    content_hash = hashlib.sha256(canonical_rendered.encode("utf-8")).hexdigest()
    dotenv, chat_id, chat_hash, dedupe_key = identity(
        home,
        task,
        phase,
        content_hash,
        bindings,
    )
    paths = paths_for(home, dedupe_key)
    common = common_record(
        home,
        task,
        phase,
        content_hash,
        chat_hash,
        dedupe_key,
        len(messages),
        bindings,
    )
    return dotenv, chat_id, paths, common


def lifecycle_marker_dirs(home):
    managed = home / "state" / "founder-brief-managed"
    posted = home / "state" / "founder-brief-posted"
    ensure_private_dir(managed)
    ensure_private_dir(posted)
    return managed, posted


def mark_managed_phase(home, common):
    managed_dir, posted_dir = lifecycle_marker_dirs(home)
    path = managed_dir / f"{common['task']}.json"
    value = {
        "schema_version": SCHEMA_VERSION,
        "home": str(home),
        "task": common["task"],
        "phase": common["phase"],
        "pre_dedupe_key": common["dedupe_key"],
        "pre_content_sha256": common["content_sha256"],
        "managed_at": now_epoch(),
    }
    if path.exists():
        previous = read_json(path, "founder managed-phase marker")
        if previous.get("phase") != common["phase"]:
            durable_unlink(posted_dir / f"{common['task']}.json")
    atomic_write_json(path, value)


def verify(home, task, phase):
    if not lifecycle_enabled(home):
        return
    _, _, _, _, paths, common = context(home, task, phase)
    if not receipt_valid(paths["receipt"], common):
        raise BriefError(
            f"no acknowledged founder brief for task={task} phase={phase}; "
            f"run bin/fm-founder-brief.sh phase {task} {phase}"
        )
    mark_managed_phase(home, common)


def deliver_payload(
    home,
    canonical_rendered,
    messages,
    dotenv,
    chat_id,
    paths,
    common,
    reply_markup=None,
    after_ack=None,
    reply_to_message_id=None,
    message_thread_id=None,
    emit=True,
):
    with acquire_lock(paths["lock"]):
        if receipt_valid(paths["receipt"], common):
            if after_ack is not None:
                after_ack()
            if emit:
                print(
                    "founder communication already acknowledged: "
                    f"task={common['task']} phase={common['phase']}"
                )
            return
        if paths["outbox"].exists():
            outbox = read_json(paths["outbox"], "founder brief outbox")
            for key, expected in common.items():
                if outbox.get(key) != expected:
                    raise BriefError(f"founder brief outbox binding mismatch: {key}")
            if outbox.get("canonical_rendered_content") != canonical_rendered:
                raise BriefError("founder brief outbox canonical rendered content mismatch")
            if outbox.get("messages") != messages:
                raise BriefError("founder brief outbox rendered message list mismatch")
            if outbox.get("reply_markup") != reply_markup:
                raise BriefError("founder brief outbox reply markup mismatch")
            if outbox.get("reply_to_message_id") != reply_to_message_id:
                raise BriefError("founder brief outbox reply target mismatch")
            if outbox.get("message_thread_id") != message_thread_id:
                raise BriefError("founder brief outbox message thread mismatch")
        else:
            outbox = dict(common)
            outbox.update({
                "canonical_rendered_content": canonical_rendered,
                "messages": messages,
                "reply_markup": reply_markup,
                "reply_to_message_id": reply_to_message_id,
                "message_thread_id": message_thread_id,
                "telegram_message_ids": [],
                "status": "ready",
                "attempts": 0,
                "created_at": now_epoch(),
                "updated_at": now_epoch(),
            })
            atomic_write_json(paths["outbox"], outbox)
        message_ids = outbox.get("telegram_message_ids")
        if not isinstance(message_ids, list) or len(message_ids) > len(messages):
            raise BriefError("founder brief outbox has an invalid Telegram message id list")
        for message_id in message_ids:
            if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
                raise BriefError("founder brief outbox has an invalid Telegram message id list")

        recovered_any = False
        while len(message_ids) < len(messages):
            index = len(message_ids)
            staged = response_path(paths, common["dedupe_key"], index)
            if not staged.exists():
                break
            try:
                response = read_json(staged, "staged Telegram response")
                message_id = validate_response(response, chat_id)
            except DeliveryRejected:
                atomic_write_json(
                    paths["outbox"],
                    outbox_with_status(outbox, "failed", "telegram-rejected"),
                )
                discard_staged_response(staged)
                raise
            except BriefError:
                atomic_write_json(
                    paths["outbox"],
                    outbox_with_status(outbox, "unknown", "invalid-acknowledgment"),
                )
                raise
            message_ids.append(message_id)
            outbox["telegram_message_ids"] = message_ids
            outbox.pop("current_part", None)
            outbox = outbox_with_status(outbox, "ready")
            atomic_write_json(paths["outbox"], outbox)
            recovered_any = True

        if len(message_ids) == len(messages):
            publish_ack(paths, common, message_ids)
            atomic_write_json(paths["outbox"], outbox_with_status(outbox, "acknowledged"))
            if after_ack is not None:
                after_ack()
            outcome = "acknowledgment recovered" if recovered_any else "acknowledged"
            if emit:
                print(
                    f"founder communication {outcome}: "
                    f"task={common['task']} phase={common['phase']}"
                )
            return

        status = outbox.get("status")
        if status in ("sending", "unknown"):
            raise BriefError(
                "founder brief delivery state is unknown; refusing to resend the same item"
            )
        if status not in ("ready", "failed"):
            raise BriefError(f"founder brief outbox has invalid status: {status}")

        while len(message_ids) < len(messages):
            index = len(message_ids)
            staged = response_path(paths, common["dedupe_key"], index)
            outbox["attempts"] = int(outbox.get("attempts", 0)) + 1
            outbox["current_part"] = index + 1
            atomic_write_json(paths["outbox"], outbox_with_status(outbox, "sending"))
            try:
                markup = reply_markup if index == len(messages) - 1 else None
                raw_response = send_telegram(
                    dotenv,
                    chat_id,
                    messages[index],
                    markup,
                    reply_to_message_id,
                    message_thread_id,
                )
            except BriefError:
                atomic_write_json(
                    paths["outbox"],
                    outbox_with_status(outbox, "unknown", "transport-unknown"),
                )
                raise
            atomic_write_bytes(staged, raw_response)
            if os.environ.get("FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE") == "1":
                os._exit(86)
            try:
                response = read_json(staged, "staged Telegram response")
                message_id = validate_response(response, chat_id)
            except DeliveryRejected:
                atomic_write_json(
                    paths["outbox"],
                    outbox_with_status(outbox, "failed", "telegram-rejected"),
                )
                discard_staged_response(staged)
                raise
            except BriefError:
                atomic_write_json(
                    paths["outbox"],
                    outbox_with_status(outbox, "unknown", "invalid-acknowledgment"),
                )
                raise
            message_ids.append(message_id)
            outbox["telegram_message_ids"] = message_ids
            outbox.pop("current_part", None)
            outbox = outbox_with_status(outbox, "ready")
            atomic_write_json(paths["outbox"], outbox)

        publish_ack(paths, common, message_ids)
        atomic_write_json(paths["outbox"], outbox_with_status(outbox, "acknowledged"))
        if after_ack is not None:
            after_ack()
        if emit:
            print(
                "founder communication acknowledged: "
                f"task={common['task']} phase={common['phase']}"
            )


def deliver(home, task, phase):
    require_lifecycle(home)
    canonical_rendered, messages, dotenv, chat_id, paths, common = context(home, task, phase)
    deliver_payload(
        home,
        canonical_rendered,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        after_ack=lambda: mark_managed_phase(home, common),
    )


def validate_private_markdown(path, headings, label):
    if not path.exists():
        raise BriefError(f"missing {label}: {path}")
    check_private_file(path, label)
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeError):
        raise BriefError(f"{label} must be readable UTF-8") from None
    if not raw:
        raise BriefError(f"{label} is empty")
    if len(text) > MAX_INPUT_CHARS:
        raise BriefError(
            f"{label} input is oversized ({len(text)} characters; maximum is {MAX_INPUT_CHARS})"
        )
    for char in text:
        code = ord(char)
        if (code < 0x20 and char != "\n") or code == 0x7F:
            raise BriefError(f"{label} contains an unsafe control character")
    positions = []
    for heading in headings:
        marker = f"## {heading}"
        hits = [match.start() for match in re.finditer(rf"(?m)^{re.escape(marker)}\s*$", text)]
        if len(hits) != 1:
            raise BriefError(f"{label} requires exactly one section: {heading}")
        positions.append(hits[0])
    if positions != sorted(positions):
        raise BriefError(f"{label} sections are not in the required order")
    values = {}
    for index, heading in enumerate(headings):
        start_line = text.find("\n", positions[index])
        end = positions[index + 1] if index + 1 < len(positions) else len(text)
        body = "" if start_line < 0 else text[start_line + 1:end].strip()
        if not body:
            raise BriefError(f"{label} section is empty: {heading}")
        if PLACEHOLDER_RE.search(body):
            raise BriefError(f"{label} section still contains placeholder text: {heading}")
        values[heading] = body
    for secret_label, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            raise BriefError(f"{label} rejected credential-like material ({secret_label})")
    return values


def scaffold_lifecycle(home, task, phase, lifecycle):
    if lifecycle == "during":
        filename = "founder-during.md"
        description = "latest material transition"
        sections = (
            ("Project", "{Name the project in founder language.}"),
            ("Material transition", "{Name the milestone, risk, blocker, or proof change.}"),
            ("Latest material state", "{Explain the latest meaningful state and why it matters.}"),
            ("Risks or blockers", "{State current risk or blocker, or say None.}"),
            ("Proof", "{State the newest concrete proof, or say Pending.}"),
            ("Next step", "{State the immediate next step.}"),
        )
    else:
        filename = "founder-post.md"
        description = "completed phase or task outcome"
        sections = (
            ("Project", "{Name the project in founder language.}"),
            ("Outcome", "{State what completed and the founder-facing outcome.}"),
            ("Proof", "{State the concrete proof that supports the outcome.}"),
            ("Remaining limits", "{State remaining limits or risks, or say None.}"),
            ("Next step", "{State the next step, or say Complete.}"),
        )
    path = home / "data" / task / filename
    ensure_private_dir(path.parent)
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing founder communication: {path}")
    lines = [
        f"# Founder {lifecycle.upper()} communication",
        "",
        f"Task: {task}",
        f"Phase: {phase}",
        "",
        f"Write concise founder-language text for the {description}.",
        "Markdown bullets are preserved and all Telegram or HTML markup is escaped.",
        "",
    ]
    for heading, placeholder in sections:
        lines.extend((f"## {heading}", "", placeholder, ""))
    atomic_write_bytes(path, ("\n".join(lines).rstrip() + "\n").encode("utf-8"))
    print(f"scaffolded founder {lifecycle} communication: {path}")


def active_dir(home):
    path = home / "state" / "founder-brief-active"
    ensure_private_dir(path)
    return path


def load_active_records(home):
    records = []
    directory = active_dir(home)
    for path in sorted(directory.glob("*.json")):
        value = read_json(path, "founder active-state record")
        required = (
            "schema_version",
            "home",
            "task",
            "project",
            "phase",
            "transition",
            "latest_state",
            "risks",
            "proof",
            "next_step",
            "content_sha256",
        )
        if any(key not in value for key in required):
            raise BriefError(f"founder active-state record is incomplete: {path}")
        if value["schema_version"] != SCHEMA_VERSION or value["home"] != str(home):
            raise BriefError(f"founder active-state record binding mismatch: {path}")
        if path.name != f"{value['task']}.json":
            raise BriefError(f"founder active-state filename binding mismatch: {path}")
        records.append(value)
    return sorted(
        records,
        key=lambda item: (
            item["project"].casefold(),
            item["project"],
            item["task"],
        ),
    )


def load_pending_decisions(home):
    directories = decision_state_dirs(home)
    pending = []
    for path in sorted(directories["founder-brief-decision-current"].glob("*.json")):
        value = read_json(path, "current founder decision binding")
        identity_hash = value.get("decision_identity_sha256")
        expires_at = value.get("expires_at")
        if (
            value.get("home") != str(home)
            or not isinstance(identity_hash, str)
            or not re.fullmatch(r"[a-f0-9]{64}", identity_hash)
            or isinstance(expires_at, bool)
            or not isinstance(expires_at, int)
            or now_epoch() > expires_at
            or approval_path_for(
                directories,
                identity_hash,
                value.get("decision_sha256"),
            ).exists()
        ):
            continue
        required = (
            "project",
            "task",
            "decision_id",
            "version",
            "question",
            "context",
            "recommendation",
            "options",
            "requested_at",
        )
        if any(key not in value for key in required):
            raise BriefError(f"current founder decision is incomplete: {path}")
        pending.append(value)
    return sorted(
        pending,
        key=lambda item: (
            item["project"].casefold(),
            item["project"],
            item["task"],
            item["decision_id"],
        ),
    )


def decision_age(requested_at):
    age = max(0, now_epoch() - requested_at)
    if age < 3600:
        return "under 1h"
    hours = age // 3600
    if hours < 48:
        return f"{hours}h"
    return f"{hours // 24}d"


def pending_approval_lines(pending):
    if not pending:
        return []
    lines = [("", False), ("Pending approvals", True)]
    previous_project = None
    for decision in pending:
        if decision["project"] != previous_project:
            lines.append((f"Project · {decision['project']}", True))
            previous_project = decision["project"]
        lines.append(
            (
                f"{decision['decision_id']} v{decision['version']} · age {decision_age(decision['requested_at'])}",
                True,
            )
        )
        for line in decision["question"].split("\n"):
            lines.append((line, False))
        lines.append((f"Context · {decision['context']}", False))
        lines.append((f"Recommendation · {decision['recommendation']}", False))
        lines.append(
            (
                "Options · "
                + " · ".join(
                    f"{option['number']} {option['label']}"
                    for option in decision["options"]
                ),
                False,
            )
        )
    return lines


def pending_decisions_sha256(pending):
    material = [
        {
            "decision_identity_sha256": item["decision_identity_sha256"],
            "decision_sha256": item["decision_sha256"],
            "version": item["version"],
            "options": item["options"],
        }
        for item in pending
    ]
    return hashlib.sha256(
        json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def mark_decision_visibility(home, pending, source, dedupe_key):
    if not pending:
        return
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": "founder-pending-approval-visibility",
        "home": str(home),
        "source": source,
        "pending_sha256": pending_decisions_sha256(pending),
        "pending_count": len(pending),
        "delivery_dedupe_key": dedupe_key,
        "visible_at": now_epoch(),
    }
    atomic_write_json(
        home / "state" / "founder-brief-pending-visibility.json",
        value,
    )


def render_during_digest(records, pending):
    lines = []
    previous_project = None
    for record in records:
        if record["project"] != previous_project:
            if lines:
                lines.append(("", False))
            lines.append((f"Project · {record['project']}", True))
            previous_project = record["project"]
        lines.append((f"{record['task']} · {record['phase']}", True))
        lines.append((f"Change · {record['transition']}", False))
        for line in record["latest_state"].split("\n"):
            lines.append((line, False))
        lines.append((f"Risk · {record['risks']}", False))
        lines.append((f"Proof · {record['proof']}", False))
        lines.append((f"Next · {record['next_step']}", False))
    lines.extend(pending_approval_lines(pending))
    return render_document(
        "DURING · Active work digest",
        "Latest material state only · No reply required",
        (("Projects", str(len({record["project"] for record in records}))),),
        lines,
    )


def record_during(home, task, phase):
    require_lifecycle(home)
    path = home / "data" / task / "founder-during.md"
    values = validate_private_markdown(
        path,
        (
            "Project",
            "Material transition",
            "Latest material state",
            "Risks or blockers",
            "Proof",
            "Next step",
        ),
        "founder DURING communication",
    )
    record = {
        "schema_version": SCHEMA_VERSION,
        "home": str(home),
        "task": task,
        "project": values["Project"],
        "phase": phase,
        "transition": values["Material transition"],
        "latest_state": values["Latest material state"],
        "risks": values["Risks or blockers"],
        "proof": values["Proof"],
        "next_step": values["Next step"],
        "updated_at": now_epoch(),
    }
    content_material = json.dumps(
        {key: value for key, value in record.items() if key != "updated_at"},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    record["content_sha256"] = hashlib.sha256(content_material).hexdigest()
    atomic_write_json(active_dir(home) / f"{task}.json", record)
    records = load_active_records(home)
    pending = load_pending_decisions(home)
    canonical, messages = render_during_digest(records, pending)
    bindings = {
        "lifecycle": "during",
        "project_count": len({item["project"] for item in records}),
        "pending_decision_count": len(pending),
    }
    dotenv, chat_id, paths, common = payload_context(
        home,
        "active-projects",
        "during",
        canonical,
        messages,
        bindings,
    )
    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        after_ack=lambda: mark_decision_visibility(
            home,
            pending,
            "during",
            common["dedupe_key"],
        ),
    )


def durable_unlink(path):
    try:
        path.unlink()
    except FileNotFoundError:
        return
    except OSError:
        raise BriefError(f"cannot retire private founder state: {path}") from None
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def deliver_post(home, task, phase):
    require_lifecycle(home)
    path = home / "data" / task / "founder-post.md"
    values = validate_private_markdown(
        path,
        ("Project", "Outcome", "Proof", "Remaining limits", "Next step"),
        "founder POST communication",
    )
    sections = (
        ("Outcome", values["Outcome"]),
        ("Proof", values["Proof"]),
        ("Remaining limits", values["Remaining limits"]),
        ("Next step", values["Next step"]),
    )
    pending = load_pending_decisions(home)
    canonical, messages = render_document(
        "POST · Completion brief",
        "Outcome and proof · No reply required",
        (("Project", values["Project"]), ("Task", task), ("Phase", phase)),
        [*sections_to_lines(sections), *pending_approval_lines(pending)],
    )
    bindings = {
        "lifecycle": "post",
        "project": values["Project"],
        "pending_decision_count": len(pending),
    }
    dotenv, chat_id, paths, common = payload_context(
        home,
        task,
        phase,
        canonical,
        messages,
        bindings,
    )
    active_path = active_dir(home) / f"{task}.json"

    def finish_post():
        _, posted_dir = lifecycle_marker_dirs(home)
        marker = {
            "schema_version": SCHEMA_VERSION,
            "home": str(home),
            "task": task,
            "phase": phase,
            "project": values["Project"],
            "post_dedupe_key": common["dedupe_key"],
            "post_content_sha256": common["content_sha256"],
            "posted_at": now_epoch(),
        }
        atomic_write_json(posted_dir / f"{task}.json", marker)
        durable_unlink(active_path)
        mark_decision_visibility(home, pending, "post", common["dedupe_key"])

    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        after_ack=finish_post,
    )


def verify_complete(home, task):
    if not lifecycle_enabled(home):
        return
    managed_dir, posted_dir = lifecycle_marker_dirs(home)
    managed_path = managed_dir / f"{task}.json"
    if not managed_path.exists():
        return
    managed = read_json(managed_path, "founder managed-phase marker")
    posted_path = posted_dir / f"{task}.json"
    if not posted_path.exists():
        raise BriefError(
            f"no acknowledged POST communication for task={task} "
            f"phase={managed.get('phase', 'unknown')}; run "
            f"bin/fm-founder-brief.sh post {task} {managed.get('phase', '<phase>')}"
        )
    posted = read_json(posted_path, "founder POST marker")
    if (
        managed.get("home") != str(home)
        or posted.get("home") != str(home)
        or managed.get("task") != task
        or posted.get("task") != task
        or posted.get("phase") != managed.get("phase")
    ):
        raise BriefError("founder POST completion marker is stale or misbound")
    dedupe_key = posted.get("post_dedupe_key")
    if not isinstance(dedupe_key, str) or not re.fullmatch(r"[a-f0-9]{64}", dedupe_key):
        raise BriefError("founder POST completion marker has an invalid receipt binding")
    receipt = read_json(
        home / "state" / "founder-brief-receipts" / f"{dedupe_key}.json",
        "founder POST receipt",
    )
    if (
        receipt.get("dedupe_key") != dedupe_key
        or receipt.get("task") != task
        or receipt.get("phase") != managed.get("phase")
        or receipt.get("lifecycle") != "post"
        or receipt.get("content_sha256") != posted.get("post_content_sha256")
    ):
        raise BriefError("founder POST receipt binding is stale or tampered")


def atomic_create_json(path, value):
    payload = (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    ensure_private_dir(path.parent)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return False
    except OSError:
        raise BriefError(f"atomic first publication failed: {path}") from None
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as handle:
            fd = None
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError:
        try:
            path.unlink()
        except OSError:
            pass
        raise BriefError(f"atomic first publication failed: {path}") from None
    finally:
        if fd is not None:
            os.close(fd)
    return True


def decision_input_path(home, digest_id):
    return home / "data" / "founder-brief-decisions" / f"{digest_id}.json"


def scaffold_decision(home, digest_id):
    path = decision_input_path(home, digest_id)
    ensure_private_dir(path.parent)
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing founder decision digest: {path}")
    value = {
        "schema_version": SCHEMA_VERSION,
        "digest_id": digest_id,
        "expires_at": now_epoch() + 3600,
        "summary": "{Explain why these choices need the captain now.}",
        "decisions": [
            {
                "project": "{Project name}",
                "task": "{task-id}",
                "decision_id": "{stable-decision-id}",
                "version": 1,
                "decision_key": "{decision-key}",
                "question": "{State the exact decision in founder language.}",
                "context": "{State the durable context needed to decide.}",
                "why_now": "{Explain what is waiting on this choice.}",
                "recommendation": "{State Firstmate's recommended option and why.}",
                "authority_boundary": (
                    "{State the existing authority boundary; delivery alone never approves.}"
                ),
                "options": [
                    {
                        "number": 1,
                        "key": "option-a",
                        "label": "Option A",
                        "outcome": "{Explain the outcome of Option A.}",
                    },
                    {
                        "number": 2,
                        "key": "option-b",
                        "label": "Option B",
                        "outcome": "{Explain the outcome of Option B.}",
                    },
                ],
            }
        ],
    }
    atomic_write_json(path, value)
    print(f"scaffolded founder decision digest: {path}")


def bounded_text(value, label, maximum, allow_newlines=True):
    if not isinstance(value, str):
        raise BriefError(f"{label} must be text")
    value = value.strip()
    if not value:
        raise BriefError(f"{label} must not be empty")
    if len(value) > maximum:
        raise BriefError(f"{label} is too long")
    if not allow_newlines and ("\n" in value or "\r" in value):
        raise BriefError(f"{label} must be one line")
    for char in value:
        code = ord(char)
        if (code < 0x20 and char != "\n") or code == 0x7F:
            raise BriefError(f"{label} contains an unsafe control character")
    if PLACEHOLDER_RE.search(value):
        raise BriefError(f"{label} still contains placeholder text")
    return value


def validate_decision_digest(home, digest_id):
    path = decision_input_path(home, digest_id)
    value = read_json(path, "founder decision digest")
    try:
        serialized = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError):
        raise BriefError("founder decision digest is not canonical JSON") from None
    if len(serialized) > MAX_INPUT_CHARS:
        raise BriefError("founder decision digest input is oversized")
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(serialized):
            raise BriefError(f"founder decision digest rejected credential-like material ({label})")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise BriefError("founder decision digest schema_version is invalid")
    if value.get("digest_id") != digest_id:
        raise BriefError("founder decision digest id binding mismatch")
    expires_at = value.get("expires_at")
    if isinstance(expires_at, bool) or not isinstance(expires_at, int) or expires_at <= now_epoch():
        raise BriefError("founder decision digest expiry must be a future Unix timestamp")
    if expires_at > now_epoch() + 7 * 24 * 60 * 60:
        raise BriefError("founder decision digest expiry may be at most seven days away")
    summary = bounded_text(value.get("summary"), "decision digest summary", 800)
    raw_decisions = value.get("decisions")
    if not isinstance(raw_decisions, list) or not (1 <= len(raw_decisions) <= 10):
        raise BriefError("founder decision digest requires 1 to 10 decisions")
    decisions = []
    identities = set()
    decision_ids = set()
    option_numbers = set()
    for index, raw in enumerate(raw_decisions, start=1):
        if not isinstance(raw, dict):
            raise BriefError(f"decision {index} must be an object")
        project = bounded_text(raw.get("project"), f"decision {index} project", 120, False)
        task = bounded_text(raw.get("task"), f"decision {index} task", 64, False)
        decision_id = bounded_text(
            raw.get("decision_id"),
            f"decision {index} decision_id",
            48,
            False,
        )
        decision_key = bounded_text(
            raw.get("decision_key"),
            f"decision {index} decision_key",
            48,
            False,
        )
        validate_slug(task, f"decision {index} task", TASK_RE)
        validate_slug(decision_id, f"decision {index} decision id", PHASE_RE)
        validate_slug(decision_key, f"decision {index} decision key", PHASE_RE)
        version = raw.get("version")
        if isinstance(version, bool) or not isinstance(version, int) or version <= 0:
            raise BriefError(f"decision {index} version must be a positive integer")
        identity_tuple = (project, task, decision_id)
        if identity_tuple in identities:
            raise BriefError("founder decision digest contains a duplicate decision identity")
        if decision_id in decision_ids:
            raise BriefError("founder decision digest contains a duplicate stable decision id")
        identities.add(identity_tuple)
        decision_ids.add(decision_id)
        options = raw.get("options")
        if not isinstance(options, list) or not (2 <= len(options) <= 4):
            raise BriefError(f"decision {index} requires 2 to 4 options")
        normalized_options = []
        option_keys = set()
        for option_index, option in enumerate(options, start=1):
            if not isinstance(option, dict):
                raise BriefError(f"decision {index} option {option_index} must be an object")
            key = bounded_text(
                option.get("key"),
                f"decision {index} option {option_index} key",
                48,
                False,
            )
            validate_slug(key, f"decision {index} option key", PHASE_RE)
            number = option.get("number")
            if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
                raise BriefError(
                    f"decision {index} option {option_index} number must be a positive integer"
                )
            if number in option_numbers:
                raise BriefError("founder decision option numbers must be unique across the bundle")
            option_numbers.add(number)
            if key in option_keys:
                raise BriefError(f"decision {index} contains a duplicate option key")
            option_keys.add(key)
            label = bounded_text(
                option.get("label"),
                f"decision {index} option {option_index} label",
                40,
                False,
            )
            if len(label.encode("utf-8")) > 40:
                raise BriefError(f"decision {index} option label exceeds 40 UTF-8 bytes")
            normalized_options.append(
                {
                    "number": number,
                    "key": key,
                    "label": label,
                    "outcome": bounded_text(
                        option.get("outcome"),
                        f"decision {index} option {option_index} outcome",
                        600,
                    ),
                }
            )
        decision = {
            "project": project,
            "task": task,
            "decision_id": decision_id,
            "version": version,
            "decision_key": decision_key,
            "question": bounded_text(raw.get("question"), f"decision {index} question", 800),
            "context": bounded_text(raw.get("context"), f"decision {index} context", 800),
            "why_now": bounded_text(raw.get("why_now"), f"decision {index} why_now", 600),
            "recommendation": bounded_text(
                raw.get("recommendation"),
                f"decision {index} recommendation",
                600,
            ),
            "authority_boundary": bounded_text(
                raw.get("authority_boundary"),
                f"decision {index} authority boundary",
                600,
            ),
            "options": normalized_options,
        }
        decisions.append(decision)
    normalized = {
        "schema_version": SCHEMA_VERSION,
        "digest_id": digest_id,
        "expires_at": expires_at,
        "summary": summary,
        "decisions": sorted(
            decisions,
            key=lambda item: (
                item["project"].casefold(),
                item["project"],
                item["task"],
                item["decision_key"],
            ),
        ),
    }
    for decision in normalized["decisions"]:
        decision["options"] = sorted(decision["options"], key=lambda option: option["number"])
        decision["decision_sha256"] = hashlib.sha256(
            json.dumps(
                decision,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
    digest_hash = hashlib.sha256(
        json.dumps(
            normalized,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return normalized, digest_hash


def decision_identity_hash(home, decision):
    material = {
        "home": str(home),
        "project": decision["project"],
        "task": decision["task"],
        "decision_id": decision["decision_id"],
    }
    return hashlib.sha256(
        json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def decision_approval_hash(identity_hash, decision_hash):
    if not isinstance(identity_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", identity_hash):
        raise BriefError("founder decision identity hash is invalid")
    if not isinstance(decision_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", decision_hash):
        raise BriefError("founder decision content hash is invalid")
    return hashlib.sha256(
        json.dumps(
            {
                "decision_identity_sha256": identity_hash,
                "decision_sha256": decision_hash,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def approval_path_for(directories, identity_hash, decision_hash):
    approval_hash = decision_approval_hash(identity_hash, decision_hash)
    return directories["founder-brief-approvals"] / f"{approval_hash}.json"


def render_decision_digest(digest):
    lines = []
    previous_project = None
    for decision in digest["decisions"]:
        if decision["project"] != previous_project:
            if lines:
                lines.append(("", False))
            lines.append((f"Project · {decision['project']}", True))
            previous_project = decision["project"]
        lines.append(
            (
                f"{decision['task']} · {decision['decision_id']} v{decision['version']}",
                True,
            )
        )
        for line in decision["question"].split("\n"):
            lines.append((line, False))
        requested_at = decision.get("requested_at")
        if isinstance(requested_at, int) and not isinstance(requested_at, bool):
            lines.append((f"Age · {decision_age(requested_at)}", False))
        lines.append((f"Context · {decision['context']}", False))
        lines.append((f"Why now · {decision['why_now']}", False))
        lines.append((f"Recommendation · {decision['recommendation']}", False))
        for option in decision["options"]:
            lines.append(
                (f"{option['number']}. {option['label']} · {option['outcome']}", False)
            )
        lines.append((f"Boundary · {decision['authority_boundary']}", False))
    return render_document(
        "DECISIONS · Captain action",
        "A button click records only the exact selected option",
        (("Expires", time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(digest["expires_at"]))),),
        [("Summary", True), *[(line, False) for line in digest["summary"].split("\n")], ("", False), *lines],
    )


def decision_state_dirs(home):
    state = home / "state"
    names = (
        "founder-brief-decision-plans",
        "founder-brief-buttons",
        "founder-brief-decision-current",
        "founder-brief-decision-history",
        "founder-brief-number-replies",
        "founder-brief-approvals",
        "founder-brief-callback-acks",
        "founder-brief-canary-clicks",
    )
    result = {}
    for name in names:
        path = state / name
        ensure_private_dir(path)
        result[name] = path
    return result


def validate_decision_versions(home, digest, directories):
    current_by_id = {}
    for path in sorted(directories["founder-brief-decision-current"].glob("*.json")):
        current = read_json(path, "current founder decision binding")
        stable_id = current.get("decision_id")
        if isinstance(stable_id, str):
            current_by_id[stable_id] = current
    for decision in digest["decisions"]:
        identity_hash = decision_identity_hash(home, decision)
        current = current_by_id.get(decision["decision_id"])
        if current is None:
            continue
        if current.get("decision_identity_sha256") != identity_hash:
            raise BriefError(
                f"stable decision id {decision['decision_id']} cannot move to another project or task"
            )
        if current.get("decision_sha256") == decision["decision_sha256"]:
            continue
        old_version = current.get("version")
        if (
            isinstance(old_version, bool)
            or not isinstance(old_version, int)
            or decision["version"] <= old_version
        ):
            raise BriefError(
                f"changed decision {decision['decision_id']} requires a higher version"
            )
        old_by_number = {
            option["number"]: option["key"] for option in current.get("options", [])
        }
        old_by_key = {
            option["key"]: option["number"] for option in current.get("options", [])
        }
        for option in decision["options"]:
            number = option["number"]
            key = option["key"]
            if number in old_by_number and old_by_number[number] != key:
                raise BriefError(
                    f"decision {decision['decision_id']} may not remap option number {number}"
                )
            if key in old_by_key and old_by_key[key] != number:
                raise BriefError(
                    f"decision {decision['decision_id']} may not renumber option {key}"
                )


def build_decision_plan(home, digest, digest_hash, common, user_hash):
    buttons = []
    rows = []
    for decision in digest["decisions"]:
        row = []
        identity_hash = decision_identity_hash(home, decision)
        for option in decision["options"]:
            opaque = secrets.token_urlsafe(16)
            callback_data = f"fmb1:{opaque}"
            if len(callback_data.encode("utf-8")) > 64:
                raise BriefError("generated Telegram callback_data exceeds 64 bytes")
            row.append(
                {
                    "text": f"{option['number']} · {option['label']}",
                    "callback_data": callback_data,
                }
            )
            buttons.append(
                {
                    "schema_version": SCHEMA_VERSION,
                    "kind": "founder-approval-button",
                    "authority": "captain",
                    "opaque_id": opaque,
                    "callback_data": callback_data,
                    "home": str(home),
                    "task": decision["task"],
                    "project": decision["project"],
                    "decision_id": decision["decision_id"],
                    "decision_version": decision["version"],
                    "decision_key": decision["decision_key"],
                    "decision_identity_sha256": identity_hash,
                    "decision_sha256": decision["decision_sha256"],
                    "digest_sha256": digest_hash,
                    "delivery_dedupe_key": common["dedupe_key"],
                    "delivery_content_sha256": common["content_sha256"],
                    "chat_identity_sha256": common["chat_identity_sha256"],
                    "user_identity_sha256": user_hash,
                    "option": option,
                    "expires_at": digest["expires_at"],
                }
            )
        rows.append(row)
    return {
        "schema_version": SCHEMA_VERSION,
        "dedupe_key": common["dedupe_key"],
        "reply_markup": {"inline_keyboard": rows},
        "buttons": buttons,
    }


def publish_decision_plan(home, plan, directories):
    plan_path = directories["founder-brief-decision-plans"] / f"{plan['dedupe_key']}.json"
    if not atomic_create_json(plan_path, plan):
        plan = read_json(plan_path, "founder decision delivery plan")
    if plan.get("dedupe_key") != plan_path.stem:
        raise BriefError("founder decision plan binding mismatch")
    buttons = plan.get("buttons")
    if not isinstance(buttons, list) or not buttons:
        raise BriefError("founder decision plan has no button bindings")
    for button in buttons:
        opaque = button.get("opaque_id")
        if not isinstance(opaque, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,32}", opaque):
            raise BriefError("founder decision plan has an invalid opaque id")
        token_path = directories["founder-brief-buttons"] / f"{opaque}.json"
        if not atomic_create_json(token_path, button):
            existing = read_json(token_path, "founder decision button binding")
            if existing != button:
                raise BriefError("founder decision button binding collision")
    return plan


def validate_decision_plan(home, plan, digest, digest_hash, common, user_hash):
    expected = {}
    expected_callbacks = []
    for decision in digest["decisions"]:
        identity_hash = decision_identity_hash(home, decision)
        for option in decision["options"]:
            key = (
                decision["project"],
                decision["task"],
                decision["decision_key"],
                option["key"],
            )
            expected[key] = (decision, option, identity_hash)
    buttons = plan.get("buttons")
    markup = plan.get("reply_markup")
    if not isinstance(buttons, list) or len(buttons) != len(expected):
        raise BriefError("founder decision plan button count is invalid")
    if not isinstance(markup, dict) or not isinstance(markup.get("inline_keyboard"), list):
        raise BriefError("founder decision plan reply markup is invalid")
    seen = set()
    for button in buttons:
        option = button.get("option")
        if not isinstance(option, dict):
            raise BriefError("founder decision plan option binding is invalid")
        key = (
            button.get("project"),
            button.get("task"),
            button.get("decision_key"),
            option.get("key"),
        )
        if key not in expected or key in seen:
            raise BriefError("founder decision plan contains a stale or duplicate option")
        seen.add(key)
        decision, expected_option, identity_hash = expected[key]
        opaque = button.get("opaque_id")
        callback_data = button.get("callback_data")
        if (
            button.get("schema_version") != SCHEMA_VERSION
            or button.get("kind") != "founder-approval-button"
            or button.get("authority") != "captain"
            or button.get("home") != str(home)
            or button.get("decision_id") != decision["decision_id"]
            or button.get("decision_version") != decision["version"]
            or button.get("decision_identity_sha256") != identity_hash
            or button.get("decision_sha256") != decision["decision_sha256"]
            or button.get("digest_sha256") != digest_hash
            or button.get("delivery_dedupe_key") != common["dedupe_key"]
            or button.get("delivery_content_sha256") != common["content_sha256"]
            or button.get("chat_identity_sha256") != common["chat_identity_sha256"]
            or button.get("user_identity_sha256") != user_hash
            or button.get("expires_at") != digest["expires_at"]
            or option != expected_option
            or not isinstance(opaque, str)
            or callback_data != f"fmb1:{opaque}"
            or len(callback_data.encode("utf-8")) > 64
        ):
            raise BriefError("founder decision plan exact binding is stale or tampered")
        expected_callbacks.append(callback_data)
    actual_callbacks = []
    for row in markup["inline_keyboard"]:
        if not isinstance(row, list) or not row:
            raise BriefError("founder decision plan contains an invalid button row")
        for item in row:
            if not isinstance(item, dict) or set(item) != {"text", "callback_data"}:
                raise BriefError("founder decision plan contains invalid Telegram button markup")
            actual_callbacks.append(item["callback_data"])
    if actual_callbacks != expected_callbacks:
        raise BriefError("founder decision plan markup does not match its exact button bindings")


def arm_decision_pointers(home, digest, digest_hash, common, plan, directories):
    by_identity = {}
    for button in plan["buttons"]:
        by_identity.setdefault(button["decision_identity_sha256"], []).append(button["opaque_id"])
    for decision in digest["decisions"]:
        identity_hash = decision_identity_hash(home, decision)
        current_path = (
            directories["founder-brief-decision-current"] / f"{identity_hash}.json"
        )
        previous = None
        if current_path.exists():
            previous = read_json(current_path, "current founder decision binding")
        requested_at = now_epoch()
        if (
            previous is not None
            and previous.get("decision_sha256") == decision["decision_sha256"]
            and isinstance(previous.get("requested_at"), int)
        ):
            requested_at = previous["requested_at"]
        if (
            previous is not None
            and previous.get("decision_sha256") != decision["decision_sha256"]
        ):
            history_dir = (
                directories["founder-brief-decision-history"] / identity_hash
            )
            ensure_private_dir(history_dir)
            history = dict(previous)
            history["status"] = "superseded"
            history["superseded_at"] = now_epoch()
            history["superseded_by_decision_sha256"] = decision["decision_sha256"]
            atomic_write_json(history_dir / f"{previous['version']}.json", history)
        pointer = {
            "schema_version": SCHEMA_VERSION,
            "home": str(home),
            "task": decision["task"],
            "project": decision["project"],
            "decision_id": decision["decision_id"],
            "version": decision["version"],
            "decision_key": decision["decision_key"],
            "question": decision["question"],
            "context": decision["context"],
            "why_now": decision["why_now"],
            "recommendation": decision["recommendation"],
            "authority_boundary": decision["authority_boundary"],
            "options": decision["options"],
            "decision_identity_sha256": identity_hash,
            "decision_sha256": decision["decision_sha256"],
            "digest_sha256": digest_hash,
            "delivery_dedupe_key": common["dedupe_key"],
            "opaque_ids": by_identity[identity_hash],
            "expires_at": digest["expires_at"],
            "requested_at": requested_at,
            "armed_at": now_epoch(),
        }
        atomic_write_json(current_path, pointer)
    receipt = read_json(
        home / "state" / "founder-brief-receipts" / f"{common['dedupe_key']}.json",
        "founder decision delivery receipt",
    )
    message_id = receipt.get("telegram_message_ids", [None])[-1]
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        raise BriefError("founder decision numeric-reply message binding is invalid")
    number_bindings = {}
    for button in plan["buttons"]:
        number = button.get("option", {}).get("number")
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise BriefError("founder decision option number binding is invalid")
        number_bindings[str(number)] = button["opaque_id"]
    mapping = {
        "schema_version": SCHEMA_VERSION,
        "kind": "founder-numbered-options",
        "home": str(home),
        "message_id": message_id,
        "delivery_dedupe_key": common["dedupe_key"],
        "delivery_content_sha256": common["content_sha256"],
        "digest_sha256": digest_hash,
        "chat_identity_sha256": common["chat_identity_sha256"],
        "user_identity_sha256": common["user_identity_sha256"],
        "expires_at": digest["expires_at"],
        "numbers": number_bindings,
    }
    mapping_path = directories["founder-brief-number-replies"] / f"{message_id}.json"
    if not atomic_create_json(mapping_path, mapping):
        existing = read_json(mapping_path, "founder numbered-option mapping")
        if existing != mapping:
            raise BriefError("founder numbered-option message binding collision")


def deliver_decisions(home, digest_id):
    require_decision(home)
    digest, digest_hash = validate_decision_digest(home, digest_id)
    directories = decision_state_dirs(home)
    validate_decision_versions(home, digest, directories)
    canonical, messages = render_decision_digest(digest)
    private_settings = read_dotenv(home)
    user_id = first_setting(USER_KEYS, private_settings)
    if not re.fullmatch(r"[0-9]+", user_id or ""):
        raise BriefError("approved Telegram user identity is missing or not numeric")
    user_hash = hashlib.sha256(user_id.encode("utf-8")).hexdigest()
    bindings = {
        "lifecycle": "decision",
        "decision_digest_sha256": digest_hash,
        "decision_count": len(digest["decisions"]),
        "user_identity_sha256": user_hash,
    }
    dotenv, chat_id, paths, common = payload_context(
        home,
        digest_id,
        "decision",
        canonical,
        messages,
        bindings,
    )
    plan_path = directories["founder-brief-decision-plans"] / f"{common['dedupe_key']}.json"
    if plan_path.exists():
        plan = read_json(plan_path, "founder decision delivery plan")
    else:
        plan = build_decision_plan(home, digest, digest_hash, common, user_hash)
    plan = publish_decision_plan(home, plan, directories)
    validate_decision_plan(home, plan, digest, digest_hash, common, user_hash)
    reply_markup = plan.get("reply_markup")
    if not isinstance(reply_markup, dict):
        raise BriefError("founder decision plan reply markup is invalid")
    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        reply_markup=reply_markup,
        after_ack=lambda: arm_decision_pointers(
            home,
            digest,
            digest_hash,
            common,
            plan,
            directories,
        ),
    )


def reminder_cadence(home):
    path = home / "config" / "founder-brief-reminder-seconds"
    if not path.exists():
        return 21600
    try:
        st = path.lstat()
    except OSError:
        raise BriefError("cannot inspect config/founder-brief-reminder-seconds") from None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise BriefError(
            "config/founder-brief-reminder-seconds must be a regular non-symlink file"
        )
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        raise BriefError("cannot read config/founder-brief-reminder-seconds") from None
    if not re.fullmatch(r"[0-9]+", raw):
        raise BriefError("founder brief reminder cadence must be an integer")
    seconds = int(raw)
    if not 900 <= seconds <= 43200:
        raise BriefError("founder brief reminder cadence must be from 900 through 43200 seconds")
    return seconds


def reminder_decision(pointer):
    return {
        "project": pointer["project"],
        "task": pointer["task"],
        "decision_id": pointer["decision_id"],
        "version": pointer["version"],
        "decision_key": pointer["decision_key"],
        "question": pointer["question"],
        "context": pointer["context"],
        "why_now": pointer["why_now"],
        "recommendation": pointer["recommendation"],
        "authority_boundary": pointer["authority_boundary"],
        "options": pointer["options"],
        "decision_sha256": pointer["decision_sha256"],
        "requested_at": pointer["requested_at"],
    }


def remind_decisions(home):
    if not decision_enabled(home):
        return
    pending = load_pending_decisions(home)
    if not pending:
        return
    cadence = reminder_cadence(home)
    latest = max(item["armed_at"] for item in pending)
    visibility_path = home / "state" / "founder-brief-pending-visibility.json"
    if visibility_path.exists():
        visibility = read_json(
            visibility_path,
            "founder pending-approval visibility",
        )
        if (
            visibility.get("home") == str(home)
            and visibility.get("pending_sha256") == pending_decisions_sha256(pending)
            and isinstance(visibility.get("visible_at"), int)
        ):
            latest = max(latest, visibility["visible_at"])
    now = now_epoch()
    if now - latest < cadence:
        return
    cycle = now // cadence
    digest = {
        "schema_version": SCHEMA_VERSION,
        "digest_id": f"pending-{cycle}",
        "expires_at": min(item["expires_at"] for item in pending),
        "summary": (
            f"Pending approval bundle · reminder cycle {cycle} · "
            "ordinary conversation remains separate"
        ),
        "decisions": [reminder_decision(item) for item in pending],
    }
    digest_hash = hashlib.sha256(
        json.dumps(
            digest,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    canonical, messages = render_decision_digest(digest)
    private_settings = read_dotenv(home)
    user_id = first_setting(USER_KEYS, private_settings)
    if not re.fullmatch(r"[0-9]+", user_id or ""):
        raise BriefError("approved Telegram user identity is missing or not numeric")
    user_hash = hashlib.sha256(user_id.encode("utf-8")).hexdigest()
    bindings = {
        "lifecycle": "decision-reminder",
        "decision_digest_sha256": digest_hash,
        "decision_count": len(digest["decisions"]),
        "pending_sha256": pending_decisions_sha256(pending),
        "reminder_cycle": cycle,
        "user_identity_sha256": user_hash,
    }
    dotenv, chat_id, paths, common = payload_context(
        home,
        "pending-decisions",
        f"reminder-{cycle}",
        canonical,
        messages,
        bindings,
    )
    directories = decision_state_dirs(home)
    plan_path = (
        directories["founder-brief-decision-plans"] / f"{common['dedupe_key']}.json"
    )
    if plan_path.exists():
        plan = read_json(plan_path, "founder decision reminder plan")
    else:
        plan = build_decision_plan(home, digest, digest_hash, common, user_hash)
    plan = publish_decision_plan(home, plan, directories)
    validate_decision_plan(home, plan, digest, digest_hash, common, user_hash)
    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        reply_markup=plan["reply_markup"],
        after_ack=lambda: (
            arm_decision_pointers(
                home,
                digest,
                digest_hash,
                common,
                plan,
                directories,
            ),
            mark_decision_visibility(
                home,
                pending,
                "reminder",
                common["dedupe_key"],
            ),
        ),
        emit=False,
    )


def validate_callback_ack(response):
    if not isinstance(response, dict) or response.get("ok") is not True:
        raise BriefError("Telegram did not acknowledge the callback")
    if response.get("result") is not True:
        raise BriefError("Telegram callback acknowledgment result is malformed")


def acknowledge_callback(dotenv, callback_query_id, acknowledgment_path, text):
    if acknowledgment_path.exists():
        response = read_json(acknowledgment_path, "Telegram callback acknowledgment")
        if response.get("ok") is False:
            durable_unlink(acknowledgment_path)
        else:
            validate_callback_ack(response)
            return
    raw = answer_callback(dotenv, callback_query_id, text)
    atomic_write_bytes(acknowledgment_path, raw)
    response = read_json(acknowledgment_path, "Telegram callback acknowledgment")
    validate_callback_ack(response)


def reject_callback(dotenv, callback_query_id, directories, reason, code):
    digest = hashlib.sha256(callback_query_id.encode("utf-8")).hexdigest()
    ack_path = directories["founder-brief-callback-acks"] / f"rejected-{digest}.json"
    acknowledge_callback(dotenv, callback_query_id, ack_path, reason)
    raise CallbackRejected(code)


def callback_update(path):
    check_private_file(path, "Telegram update")
    try:
        raw = path.read_bytes()
        if len(raw) > MAX_RESPONSE_BYTES:
            raise BriefError("Telegram update is oversized")
        update = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise BriefError("Telegram update is not valid private JSON") from None
    if not isinstance(update, dict):
        raise BriefError("Telegram update must be a JSON object")
    query = update.get("callback_query")
    if not isinstance(query, dict):
        return None
    data = query.get("data")
    if not isinstance(data, str) or not data.startswith("fmb1:"):
        return None
    return query, data[5:]


def ingest_update(home, update_path, emit=True):
    claimed = callback_update(update_path)
    if claimed is None:
        return False
    require_decision(home)
    query, opaque = claimed
    callback_query_id = query.get("id")
    if not isinstance(callback_query_id, str) or not callback_query_id:
        raise BriefError("Telegram founder callback query id is missing")
    message = query.get("message")
    actor = query.get("from")
    if not isinstance(message, dict) or not isinstance(actor, dict):
        raise BriefError("Telegram founder callback has no bound message or actor")
    chat = message.get("chat")
    message_id = message.get("message_id")
    if not isinstance(chat, dict):
        raise BriefError("Telegram founder callback has no chat binding")
    callback_chat = str(chat.get("id"))
    callback_user = str(actor.get("id"))
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        raise BriefError("Telegram founder callback message id is invalid")
    dotenv = read_dotenv(home)
    expected_chat = first_setting(CHAT_KEYS, dotenv)
    expected_user = first_setting(USER_KEYS, dotenv)
    directories = decision_state_dirs(home)
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,32}", opaque):
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This control is malformed.",
            "Telegram founder callback opaque id is malformed",
        )
    if callback_chat != expected_chat or callback_user != expected_user:
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This control is not authorized for this account.",
            "Telegram founder callback identity is not authorized",
        )
    token_path = directories["founder-brief-buttons"] / f"{opaque}.json"
    if not token_path.exists():
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This control is invalid or no longer available.",
            "Telegram founder callback binding does not exist",
        )
    token = read_json(token_path, "founder decision button binding")
    if token.get("opaque_id") != opaque or token.get("callback_data") != f"fmb1:{opaque}":
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This control is invalid.",
            "Telegram founder callback binding is tampered",
        )
    expected_chat_hash = hashlib.sha256(expected_chat.encode("utf-8")).hexdigest()
    expected_user_hash = hashlib.sha256(expected_user.encode("utf-8")).hexdigest()
    if (
        token.get("home") != str(home)
        or token.get("chat_identity_sha256") != expected_chat_hash
        or token.get("user_identity_sha256") != expected_user_hash
    ):
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This control is not valid in this Firstmate home.",
            "Telegram founder callback home or identity binding is stale",
        )
    expires_at = token.get("expires_at")
    if isinstance(expires_at, bool) or not isinstance(expires_at, int) or now_epoch() > expires_at:
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This choice has expired.",
            "Telegram founder callback has expired",
        )
    delivery_key = token.get("delivery_dedupe_key")
    if not isinstance(delivery_key, str) or not re.fullmatch(r"[a-f0-9]{64}", delivery_key):
        raise BriefError("Telegram founder callback delivery binding is malformed")
    receipt_path = home / "state" / "founder-brief-receipts" / f"{delivery_key}.json"
    if not receipt_path.exists():
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This message has no verified delivery receipt.",
            "Telegram founder callback delivery is not acknowledged",
        )
    receipt = read_json(receipt_path, "founder communication receipt")
    if (
        receipt.get("dedupe_key") != delivery_key
        or receipt.get("content_sha256") != token.get("delivery_content_sha256")
        or receipt.get("chat_identity_sha256") != expected_chat_hash
        or receipt.get("user_identity_sha256", expected_user_hash) != expected_user_hash
        or receipt.get("telegram_message_ids", [None])[-1] != message_id
    ):
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This choice is not attached to the acknowledged message.",
            "Telegram founder callback delivery receipt binding is stale or tampered",
        )
    callback_hash = hashlib.sha256(callback_query_id.encode("utf-8")).hexdigest()
    authority = token.get("authority")
    if authority == "none":
        canary_path = directories["founder-brief-canary-clicks"] / f"{opaque}.json"
        canary = {
            "schema_version": SCHEMA_VERSION,
            "kind": "founder-button-canary",
            "authority": "none",
            "home": str(home),
            "opaque_id": opaque,
            "delivery_dedupe_key": delivery_key,
            "callback_query_id_sha256": callback_hash,
            "recorded_at": now_epoch(),
            "ready_to_act": False,
        }
        if not atomic_create_json(canary_path, canary):
            existing = read_json(canary_path, "founder button canary receipt")
            if existing.get("callback_query_id_sha256") != callback_hash:
                reject_callback(
                    dotenv,
                    callback_query_id,
                    directories,
                    "This canary was already used.",
                    "Telegram founder button canary replay was rejected",
                )
        ack_path = directories["founder-brief-callback-acks"] / f"canary-{opaque}.json"
        acknowledge_callback(dotenv, callback_query_id, ack_path, "Canary received; no authority granted.")
        canary["callback_acknowledged"] = True
        canary["acknowledged_at"] = now_epoch()
        atomic_write_json(canary_path, canary)
        if emit:
            print("founder button canary acknowledged; no authority granted")
        return True
    if authority != "captain":
        raise BriefError("Telegram founder callback authority binding is invalid")
    identity_hash = token.get("decision_identity_sha256")
    if not isinstance(identity_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", identity_hash):
        raise BriefError("Telegram founder callback decision identity is malformed")
    current_path = directories["founder-brief-decision-current"] / f"{identity_hash}.json"
    if not current_path.exists():
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This choice is not active.",
            "Telegram founder callback has no current decision binding",
        )
    current = read_json(current_path, "current founder decision binding")
    if (
        current.get("decision_identity_sha256") != identity_hash
        or current.get("decision_sha256") != token.get("decision_sha256")
        or current.get("digest_sha256") != token.get("digest_sha256")
        or current.get("delivery_dedupe_key") != delivery_key
        or opaque not in current.get("opaque_ids", [])
    ):
        reject_callback(
            dotenv,
            callback_query_id,
            directories,
            "This choice was superseded. Use the latest decision message.",
            "Telegram founder callback is stale",
        )
    approval_hash = decision_approval_hash(identity_hash, token.get("decision_sha256"))
    approval_path = directories["founder-brief-approvals"] / f"{approval_hash}.json"
    approval = {
        "schema_version": SCHEMA_VERSION,
        "kind": "founder-approval",
        "home": str(home),
        "task": token["task"],
        "project": token["project"],
        "decision_id": token["decision_id"],
        "decision_version": token["decision_version"],
        "decision_key": token["decision_key"],
        "decision_identity_sha256": identity_hash,
        "approval_sha256": approval_hash,
        "decision_sha256": token["decision_sha256"],
        "digest_sha256": token["digest_sha256"],
        "delivery_dedupe_key": delivery_key,
        "chat_identity_sha256": expected_chat_hash,
        "user_identity_sha256": expected_user_hash,
        "opaque_id": opaque,
        "option": token["option"],
        "callback_query_id_sha256": callback_hash,
        "recorded_at": now_epoch(),
        "callback_acknowledged": False,
        "ready_to_act": False,
    }
    if not atomic_create_json(approval_path, approval):
        existing = read_json(approval_path, "founder approval receipt")
        if (
            existing.get("opaque_id") != opaque
            or existing.get("callback_query_id_sha256") != callback_hash
        ):
            reject_callback(
                dotenv,
                callback_query_id,
                directories,
                "A choice was already recorded for this decision.",
                "Telegram founder callback replay was rejected",
            )
        approval = existing
    if os.environ.get("FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_APPROVAL") == "1":
        os._exit(87)
    ack_path = directories["founder-brief-callback-acks"] / f"{approval_hash}.json"
    acknowledge_callback(dotenv, callback_query_id, ack_path, "Choice recorded.")
    approval["callback_acknowledged"] = True
    approval["ready_to_act"] = True
    approval["acknowledged_at"] = now_epoch()
    atomic_write_json(approval_path, approval)
    if emit:
        print(
            "founder approval recorded: "
            f"task={approval['task']} project={approval['project']} "
            f"decision={approval['decision_key']} option={approval['option']['key']}"
        )
    return True


def deliver_canary(home, with_button):
    if not config_enabled(home):
        raise BriefError("founder communications are not enabled for this home")
    lane = "decision" if with_button else "lifecycle"
    attempted_at = now_epoch()
    lifecycle = "canary-button" if with_button else "canary-delivery"
    title = "CANARY · Button transport" if with_button else "CANARY · Delivery transport"
    subtitle = (
        "No authority · Safe callback plumbing only"
        if with_button
        else "Informational only · No reply required"
    )
    body = [
        ("Purpose", True),
        (
            "Verify live Telegram delivery without starting work or granting authority.",
            False,
        ),
        (f"Attempt · {attempted_at}", False),
    ]
    canonical, messages = render_document(title, subtitle, (), body)
    bindings = {"lifecycle": lifecycle}
    dotenv = read_dotenv(home)
    user_id = first_setting(USER_KEYS, dotenv)
    if with_button and not re.fullmatch(r"[0-9]+", user_id or ""):
        raise BriefError("approved Telegram user identity is missing or not numeric")
    if with_button:
        bindings["user_identity_sha256"] = hashlib.sha256(user_id.encode("utf-8")).hexdigest()
    dotenv, chat_id, paths, common = payload_context(
        home,
        lifecycle,
        "canary",
        canonical,
        messages,
        bindings,
    )
    if not with_button:
        try:
            deliver_payload(home, canonical, messages, dotenv, chat_id, paths, common)
        except BriefError:
            open_incident(home, lane, lifecycle)
            raise
        publish_live_canary_receipt(home, lane, common, attempted_at)
        return
    directories = decision_state_dirs(home)
    plan_path = directories["founder-brief-decision-plans"] / f"{common['dedupe_key']}.json"
    if plan_path.exists():
        plan = read_json(plan_path, "founder button canary plan")
    else:
        opaque = secrets.token_urlsafe(16)
        callback_data = f"fmb1:{opaque}"
        button = {
            "schema_version": SCHEMA_VERSION,
            "kind": "founder-button-canary",
            "authority": "none",
            "opaque_id": opaque,
            "callback_data": callback_data,
            "home": str(home),
            "delivery_dedupe_key": common["dedupe_key"],
            "delivery_content_sha256": common["content_sha256"],
            "chat_identity_sha256": common["chat_identity_sha256"],
            "user_identity_sha256": bindings["user_identity_sha256"],
            "expires_at": now_epoch() + 900,
        }
        plan = {
            "schema_version": SCHEMA_VERSION,
            "dedupe_key": common["dedupe_key"],
            "reply_markup": {
                "inline_keyboard": [
                    [{"text": "Canary only · no authority", "callback_data": callback_data}]
                ]
            },
            "buttons": [button],
        }
    plan = publish_decision_plan(home, plan, directories)
    try:
        deliver_payload(
            home,
            canonical,
            messages,
            dotenv,
            chat_id,
            paths,
            common,
            reply_markup=plan["reply_markup"],
        )
    except BriefError:
        open_incident(home, lane, lifecycle)
        raise
    publish_live_canary_receipt(home, lane, common, attempted_at)


def publish_live_canary_receipt(home, lane, common, verified_at):
    hashes = identity_hashes(home)
    if hashes is None:
        raise BriefError("live canary identities are unavailable")
    chat_hash, user_hash = hashes
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": f"telegram-{lane}-canary",
        "protocol_version": CONVERSATION_PROTOCOL_VERSION,
        "status": "passed",
        "home": str(home),
        "lane": lane,
        "chat_identity_sha256": chat_hash,
        "user_identity_sha256": user_hash,
        "delivery_dedupe_key": common["dedupe_key"],
        "delivery_content_sha256": common["content_sha256"],
        "verified_at": verified_at,
    }
    atomic_write_json(home / "state" / f"telegram-{lane}-canary.json", value)


def conversation_dirs(home):
    state = home / "state"
    result = {}
    for name in (
        "telegram-inbox",
        "telegram-callback-inbox",
        "founder-brief-update-inbox",
        "telegram-conversation-receipts",
        "telegram-conversation-outcomes",
    ):
        path = state / name
        ensure_private_dir(path)
        result[name] = path
    replies = home / "data" / "telegram-replies"
    ensure_private_dir(replies)
    result["telegram-replies"] = replies
    outcomes = home / "data" / "telegram-outcomes"
    ensure_private_dir(outcomes)
    result["telegram-outcomes"] = outcomes
    return result


def parse_update_bytes(raw):
    if len(raw) > MAX_RESPONSE_BYTES:
        raise BriefError("Telegram update is oversized")
    try:
        update = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise BriefError("Telegram update is not valid JSON") from None
    if not isinstance(update, dict):
        raise BriefError("Telegram update must be a JSON object")
    update_id = update.get("update_id")
    if isinstance(update_id, bool) or not isinstance(update_id, int) or update_id < 0:
        raise BriefError("Telegram update has no valid numeric update_id")
    return update


def load_private_update(path):
    check_private_file(path, "Telegram update")
    try:
        return parse_update_bytes(path.read_bytes())
    except OSError:
        raise BriefError("cannot read private Telegram update") from None


def authenticated_settings(home):
    dotenv = read_dotenv(home)
    chat_id = first_setting(CHAT_KEYS, dotenv)
    user_id = first_setting(USER_KEYS, dotenv)
    if not re.fullmatch(r"-?[0-9]+", chat_id or ""):
        raise BriefError("expected Telegram chat identity is missing or not numeric")
    if not re.fullmatch(r"[0-9]+", user_id or ""):
        raise BriefError("approved Telegram user identity is missing or not numeric")
    return dotenv, chat_id, user_id


def conversation_record(home, update, message_kind, message, chat_id, user_id):
    message_id = message.get("message_id")
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        raise BriefError("accepted Telegram message has no positive numeric message_id")
    text = message.get("text")
    if not isinstance(text, str) or not text:
        return None
    if len(text) > MAX_INPUT_CHARS:
        raise BriefError("accepted Telegram message text is oversized")
    for char in text:
        code = ord(char)
        if (code < 0x20 and char not in ("\n", "\t")) or code == 0x7F:
            raise BriefError("accepted Telegram message contains an unsafe control character")
    reply_to = message.get("reply_to_message")
    reply_to_message_id = None
    if isinstance(reply_to, dict):
        candidate = reply_to.get("message_id")
        if isinstance(candidate, int) and not isinstance(candidate, bool) and candidate > 0:
            reply_to_message_id = candidate
    thread_id = message.get("message_thread_id")
    if isinstance(thread_id, bool) or not isinstance(thread_id, int) or thread_id <= 0:
        thread_id = None
    sender_chat = message.get("sender_chat")
    sender_chat_id = None
    if isinstance(sender_chat, dict):
        candidate = sender_chat.get("id")
        if isinstance(candidate, int) and not isinstance(candidate, bool):
            sender_chat_id = candidate
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-conversation-message",
        "home": str(home),
        "update_id": update["update_id"],
        "message_kind": message_kind,
        "message_id": message_id,
        "chat_id": int(chat_id),
        "sender_user_id": int(user_id),
        "sender_chat_id": sender_chat_id,
        "message_thread_id": thread_id,
        "reply_to_message_id": reply_to_message_id,
        "date": message.get("date"),
        "edit_date": message.get("edit_date"),
        "text": text,
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "received_at": now_epoch(),
    }


def conversation_context(home, record, purpose, canonical, messages):
    bindings = {
        "channel": "telegram-conversation",
        "conversation_purpose": purpose,
        "origin_update_id": record["update_id"],
        "origin_message_id": record["message_id"],
        "origin_message_thread_id": record.get("message_thread_id"),
        "origin_reply_to_message_id": record.get("reply_to_message_id"),
        "origin_sender_identity_sha256": hashlib.sha256(
            str(record["sender_user_id"]).encode("utf-8")
        ).hexdigest(),
    }
    return payload_context(
        home,
        f"chat-{record['update_id']}",
        purpose,
        canonical,
        messages,
        bindings,
    )


def render_chat_reply(text, origin_message_id):
    canonical = html.escape(text, quote=False)
    if visible_bytes(canonical) <= MESSAGE_LIMIT:
        return canonical, [canonical]
    body_lines = [(line, False) for line in text.split("\n")]
    return render_document(
        "Reply · Conversation",
        "Continuation of one response",
        (("In reply to", str(origin_message_id)),),
        body_lines,
    )


def send_conversation_ack(home, record, text, emit=False):
    canonical = render_line(text)
    messages = [canonical]
    dotenv, chat_id, paths, common = conversation_context(
        home,
        record,
        "ack",
        canonical,
        messages,
    )

    def mark_acknowledged():
        record["acknowledgment_dedupe_key"] = common["dedupe_key"]
        record["acknowledged_at"] = now_epoch()
        record["routed_at"] = now_epoch()
        atomic_write_json(
            conversation_dirs(home)["telegram-inbox"] / f"{record['update_id']}.json",
            record,
        )

    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        after_ack=mark_acknowledged,
        reply_to_message_id=record["message_id"],
        message_thread_id=record.get("message_thread_id"),
        emit=emit,
    )


def token_for_numbered_reply(home, record):
    text = record["text"].strip()
    if not re.fullmatch(r"[1-9][0-9]*", text):
        return None, None
    reply_to = record.get("reply_to_message_id")
    directories = decision_state_dirs(home)
    if reply_to is not None:
        mapping_path = directories["founder-brief-number-replies"] / f"{reply_to}.json"
        if not mapping_path.exists():
            return "ambiguous", None
        mapping = read_json(mapping_path, "founder numbered-option mapping")
        opaque = mapping.get("numbers", {}).get(text)
        if not isinstance(opaque, str):
            return "ambiguous", None
        token_path = directories["founder-brief-buttons"] / f"{opaque}.json"
        token = read_json(token_path, "founder numbered-option binding")
        token["_numeric_message_id"] = reply_to
        return "bound", token
    open_pointers = []
    for pointer_path in sorted(directories["founder-brief-decision-current"].glob("*.json")):
        pointer = read_json(pointer_path, "current founder decision binding")
        identity_hash = pointer.get("decision_identity_sha256")
        expires_at = pointer.get("expires_at")
        if (
            pointer.get("home") != str(home)
            or not isinstance(identity_hash, str)
            or isinstance(expires_at, bool)
            or not isinstance(expires_at, int)
            or now_epoch() > expires_at
            or approval_path_for(
                directories,
                identity_hash,
                pointer.get("decision_sha256"),
            ).exists()
        ):
            continue
        open_pointers.append(pointer)
    if len(open_pointers) != 1:
        return "ambiguous", None
    matches = []
    for opaque in open_pointers[0].get("opaque_ids", []):
        token_path = directories["founder-brief-buttons"] / f"{opaque}.json"
        token = read_json(token_path, "founder numbered-option binding")
        if str(token.get("option", {}).get("number")) == text:
            matches.append(token)
    if len(matches) != 1:
        return "ambiguous", None
    token = matches[0]
    receipt = read_json(
        home / "state" / "founder-brief-receipts" / f"{token['delivery_dedupe_key']}.json",
        "founder decision delivery receipt",
    )
    message_id = receipt.get("telegram_message_ids", [None])[-1]
    if isinstance(message_id, bool) or not isinstance(message_id, int) or message_id <= 0:
        return "ambiguous", None
    token["_numeric_message_id"] = message_id
    return "bound", token


def record_numeric_approval(home, record, token):
    dotenv, expected_chat, expected_user = authenticated_settings(home)
    directories = decision_state_dirs(home)
    expected_chat_hash = hashlib.sha256(expected_chat.encode("utf-8")).hexdigest()
    expected_user_hash = hashlib.sha256(expected_user.encode("utf-8")).hexdigest()
    expires_at = token.get("expires_at")
    if (
        token.get("authority") != "captain"
        or token.get("home") != str(home)
        or token.get("chat_identity_sha256") != expected_chat_hash
        or token.get("user_identity_sha256") != expected_user_hash
        or record["chat_id"] != int(expected_chat)
        or record["sender_user_id"] != int(expected_user)
        or isinstance(expires_at, bool)
        or not isinstance(expires_at, int)
        or now_epoch() > expires_at
    ):
        return "stale", None
    delivery_key = token.get("delivery_dedupe_key")
    if not isinstance(delivery_key, str) or not re.fullmatch(r"[a-f0-9]{64}", delivery_key):
        return "stale", None
    receipt_path = home / "state" / "founder-brief-receipts" / f"{delivery_key}.json"
    if not receipt_path.exists():
        return "stale", None
    receipt = read_json(receipt_path, "founder decision delivery receipt")
    if (
        receipt.get("content_sha256") != token.get("delivery_content_sha256")
        or receipt.get("telegram_message_ids", [None])[-1]
        != token.get("_numeric_message_id")
    ):
        return "stale", None
    identity_hash = token.get("decision_identity_sha256")
    if not isinstance(identity_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", identity_hash):
        return "stale", None
    current_path = directories["founder-brief-decision-current"] / f"{identity_hash}.json"
    if not current_path.exists():
        return "stale", None
    current = read_json(current_path, "current founder decision binding")
    if (
        current.get("decision_sha256") != token.get("decision_sha256")
        or current.get("digest_sha256") != token.get("digest_sha256")
        or current.get("delivery_dedupe_key") != delivery_key
        or token.get("opaque_id") not in current.get("opaque_ids", [])
    ):
        return "stale", None
    approval_hash = decision_approval_hash(identity_hash, token.get("decision_sha256"))
    approval_path = directories["founder-brief-approvals"] / f"{approval_hash}.json"
    message_binding = {
        "update_id": record["update_id"],
        "message_id": record["message_id"],
        "reply_to_message_id": record["reply_to_message_id"],
        "decision_message_id": token["_numeric_message_id"],
        "text_sha256": record["text_sha256"],
    }
    source_hash = hashlib.sha256(
        json.dumps(message_binding, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    approval = {
        "schema_version": SCHEMA_VERSION,
        "kind": "founder-approval",
        "source": "numbered-reply",
        "home": str(home),
        "task": token["task"],
        "project": token["project"],
        "decision_id": token["decision_id"],
        "decision_version": token["decision_version"],
        "decision_key": token["decision_key"],
        "decision_identity_sha256": identity_hash,
        "approval_sha256": approval_hash,
        "decision_sha256": token["decision_sha256"],
        "digest_sha256": token["digest_sha256"],
        "delivery_dedupe_key": delivery_key,
        "chat_identity_sha256": expected_chat_hash,
        "user_identity_sha256": expected_user_hash,
        "opaque_id": token["opaque_id"],
        "option": token["option"],
        "telegram_message_binding": message_binding,
        "source_sha256": source_hash,
        "recorded_at": now_epoch(),
        "callback_acknowledged": False,
        "ready_to_act": False,
    }
    if not atomic_create_json(approval_path, approval):
        existing = read_json(approval_path, "founder approval receipt")
        if existing.get("source_sha256") == source_hash:
            return "idempotent", existing
        return "replay", existing
    return "recorded", approval


def finish_numeric_approval(home, approval):
    directories = decision_state_dirs(home)
    approval_path = approval_path_for(
        directories,
        approval["decision_identity_sha256"],
        approval["decision_sha256"],
    )
    approval["callback_acknowledged"] = True
    approval["conversation_acknowledged"] = True
    approval["ready_to_act"] = True
    approval["acknowledged_at"] = now_epoch()
    atomic_write_json(approval_path, approval)


def route_update_value(home, update, emit=True):
    if not config_enabled(home):
        raise BriefError("founder brief delivery is not enabled for this home")
    directories = conversation_dirs(home)
    callback = update.get("callback_query")
    if isinstance(callback, dict):
        callback_data = callback.get("data")
        target_dir = (
            directories["founder-brief-update-inbox"]
            if isinstance(callback_data, str) and callback_data.startswith("fmb1:")
            else directories["telegram-callback-inbox"]
        )
        update_path = target_dir / f"{update['update_id']}.json"
        atomic_write_json(update_path, update)
        if target_dir == directories["founder-brief-update-inbox"]:
            if not decision_enabled(home):
                return "callback-contained"
            try:
                ingest_update(home, update_path, emit=False)
                return "callback"
            except CallbackRejected:
                return "callback-rejected"
        return "foreign-callback"
    message_kind = None
    message = update.get("message")
    if isinstance(message, dict):
        message_kind = "message"
    else:
        message = update.get("edited_message")
        if isinstance(message, dict):
            message_kind = "edited_message"
    if message_kind is None:
        return "ignored"
    dotenv, expected_chat, expected_user = authenticated_settings(home)
    del dotenv
    chat = message.get("chat")
    sender = message.get("from")
    if (
        not isinstance(chat, dict)
        or not isinstance(sender, dict)
        or str(chat.get("id")) != expected_chat
        or str(sender.get("id")) != expected_user
    ):
        return "ignored"
    record = conversation_record(
        home,
        update,
        message_kind,
        message,
        expected_chat,
        expected_user,
    )
    if record is None:
        return "ignored"
    inbox_path = directories["telegram-inbox"] / f"{record['update_id']}.json"
    if inbox_path.exists():
        existing = read_json(inbox_path, "Telegram conversation message")
        immutable_keys = (
            "update_id",
            "message_kind",
            "message_id",
            "chat_id",
            "sender_user_id",
            "message_thread_id",
            "reply_to_message_id",
            "text",
            "text_sha256",
        )
        if any(existing.get(key) != record.get(key) for key in immutable_keys):
            raise BriefError("Telegram update id replay changed its bound message content")
        record = existing
    else:
        atomic_write_json(inbox_path, record)
    if re.fullmatch(r"[1-9][0-9]*", record["text"].strip()) and not decision_enabled(home):
        numeric_state, token = "ambiguous", None
    else:
        numeric_state, token = token_for_numbered_reply(home, record)
    if numeric_state == "bound":
        approval_state, approval = record_numeric_approval(home, record, token)
        if approval_state in ("recorded", "idempotent"):
            number = token["option"]["number"]
            send_conversation_ack(
                home,
                record,
                f"Choice {number} recorded for {token['decision_key']}.",
                emit=False,
            )
            finish_numeric_approval(home, approval)
            record["handled_as"] = "numbered-approval"
            record["approval_state"] = approval_state
            atomic_write_json(inbox_path, record)
        elif approval_state == "replay":
            send_conversation_ack(
                home,
                record,
                "That decision already has a recorded choice; this reply was not applied.",
                emit=False,
            )
            record["handled_as"] = "numbered-replay"
            atomic_write_json(inbox_path, record)
        else:
            send_conversation_ack(
                home,
                record,
                "That numbered choice is stale; use the latest decision message.",
                emit=False,
            )
            record["handled_as"] = "numbered-stale"
            atomic_write_json(inbox_path, record)
    elif numeric_state == "ambiguous":
        send_conversation_ack(
            home,
            record,
            "That option number is unavailable or ambiguous; reply to the exact current decision or clarify which decision you mean.",
            emit=False,
        )
        record["handled_as"] = "numbered-invalid"
        atomic_write_json(inbox_path, record)
    else:
        acknowledgment = (
            "Update received. I’m following the latest version and will reply here."
            if message_kind == "edited_message"
            else "Received. I’m on it and will reply here."
        )
        send_conversation_ack(home, record, acknowledgment, emit=False)
    if emit:
        print(
            f"telegram conversation accepted: update={record['update_id']} "
            f"message={record['message_id']}"
        )
    return "message"


def route_update_file(home, path):
    return route_update_value(home, load_private_update(path))


def relay_once(home):
    if not config_enabled(home):
        raise BriefError("founder brief delivery is not enabled for this home")
    dotenv, _, _ = authenticated_settings(home)
    offset_path = home / "state" / "telegram-relay.offset"
    if offset_path.exists():
        check_private_file(offset_path, "Telegram relay offset")
        try:
            offset = int(offset_path.read_text(encoding="utf-8").strip())
        except (OSError, UnicodeError, ValueError):
            raise BriefError("Telegram relay offset is invalid") from None
    else:
        offset = 0
    raw = telegram_request(
        dotenv,
        "getUpdates",
        {
            "offset": offset,
            "timeout": 0,
            "limit": 100,
            "allowed_updates": ["message", "edited_message", "callback_query"],
        },
    )
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise BriefError("Telegram getUpdates response is malformed") from None
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        raise BriefError("Telegram getUpdates did not return ok=true")
    updates = payload.get("result")
    if not isinstance(updates, list):
        raise BriefError("Telegram getUpdates result is not a list")
    ordered = []
    for raw_update in updates:
        try:
            encoded = json.dumps(
                raw_update,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
        except (TypeError, ValueError):
            raise BriefError("Telegram getUpdates contains a malformed update") from None
        ordered.append(parse_update_bytes(encoded))
    ordered.sort(key=lambda item: item["update_id"])
    accepted = []
    for update in ordered:
        if update["update_id"] < offset:
            continue
        outcome = route_update_value(home, update, emit=False)
        offset = update["update_id"] + 1
        atomic_write_bytes(offset_path, f"{offset}\n".encode("utf-8"))
        if outcome in (
            "message",
            "callback",
            "callback-contained",
            "callback-rejected",
            "foreign-callback",
        ):
            accepted.append(update["update_id"])
    if accepted:
        print(f"telegram updates {min(accepted)}-{max(accepted)}")


def scaffold_reply(home, update_id):
    directories = conversation_dirs(home)
    inbox_path = directories["telegram-inbox"] / f"{update_id}.json"
    if not inbox_path.exists():
        raise BriefError(f"no accepted Telegram conversation update={update_id}")
    path = directories["telegram-replies"] / f"{update_id}.md"
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing Telegram reply: {path}")
    template = (
        "{Write the substantive founder-language response here.}\n"
        "{It will be sent in reply to the exact originating Telegram message.}\n"
    )
    atomic_write_bytes(path, template.encode("utf-8"))
    print(f"scaffolded Telegram conversation reply: {path}")


def validate_reply_text(path):
    check_private_file(path, "Telegram conversation reply")
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        raise BriefError("Telegram conversation reply must be readable UTF-8") from None
    if not text:
        raise BriefError("Telegram conversation reply is empty")
    if len(text) > MAX_INPUT_CHARS:
        raise BriefError("Telegram conversation reply is oversized")
    if PLACEHOLDER_RE.search(text):
        raise BriefError("Telegram conversation reply still contains placeholder text")
    for char in text:
        code = ord(char)
        if (code < 0x20 and char not in ("\n", "\t")) or code == 0x7F:
            raise BriefError("Telegram conversation reply contains an unsafe control character")
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            raise BriefError(f"Telegram conversation reply rejected credential-like material ({label})")
    return text


def deliver_reply(home, update_id):
    if not config_enabled(home):
        raise BriefError("founder brief delivery is not enabled for this home")
    directories = conversation_dirs(home)
    record = read_json(
        directories["telegram-inbox"] / f"{update_id}.json",
        "Telegram conversation message",
    )
    _, expected_chat, expected_user = authenticated_settings(home)
    if (
        record.get("home") != str(home)
        or record.get("update_id") != update_id
        or str(record.get("chat_id")) != expected_chat
        or str(record.get("sender_user_id")) != expected_user
    ):
        raise BriefError("Telegram conversation reply origin binding is stale or tampered")
    text = validate_reply_text(directories["telegram-replies"] / f"{update_id}.md")
    canonical, messages = render_chat_reply(text, record["message_id"])
    dotenv, chat_id, paths, common = conversation_context(
        home,
        record,
        "reply",
        canonical,
        messages,
    )

    def publish_conversation_receipt():
        delivery_receipt = read_json(paths["receipt"], "Telegram conversation delivery receipt")
        value = {
            "schema_version": SCHEMA_VERSION,
            "kind": "telegram-conversation-response",
            "home": str(home),
            "origin_update_id": update_id,
            "origin_message_id": record["message_id"],
            "origin_chat_id": record["chat_id"],
            "origin_sender_user_id": record["sender_user_id"],
            "origin_text_sha256": record["text_sha256"],
            "response_content_sha256": common["content_sha256"],
            "response_dedupe_key": common["dedupe_key"],
            "telegram_message_ids": delivery_receipt["telegram_message_ids"],
            "responded_at": now_epoch(),
        }
        atomic_write_json(
            directories["telegram-conversation-receipts"] / f"{update_id}.json",
            value,
        )

    deliver_payload(
        home,
        canonical,
        messages,
        dotenv,
        chat_id,
        paths,
        common,
        after_ack=publish_conversation_receipt,
        reply_to_message_id=record["message_id"],
        message_thread_id=record.get("message_thread_id"),
    )


def validate_safe_value(value, label, maximum=4096):
    if not isinstance(value, str):
        raise BriefError(f"{label} must be text")
    value = value.strip()
    if not value:
        raise BriefError(f"{label} is empty")
    if len(value) > maximum:
        raise BriefError(f"{label} is oversized")
    if PLACEHOLDER_RE.search(value):
        raise BriefError(f"{label} still contains placeholder text")
    for char in value:
        code = ord(char)
        if (code < 0x20 and char not in ("\n", "\t")) or code == 0x7F:
            raise BriefError(f"{label} contains an unsafe control character")
    for secret_label, pattern in SECRET_PATTERNS:
        if pattern.search(value):
            raise BriefError(f"{label} rejected credential-like material ({secret_label})")
    return value


def scaffold_outcome(home, update_id):
    directories = conversation_dirs(home)
    if not (directories["telegram-inbox"] / f"{update_id}.json").exists():
        raise BriefError(f"no accepted Telegram conversation update={update_id}")
    path = directories["telegram-outcomes"] / f"{update_id}.json"
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing Telegram outcome: {path}")
    value = {
        "schema_version": SCHEMA_VERSION,
        "update_id": update_id,
        "classification": "{question|work-request|approval|suggestion|conversation|correction}",
        "outcome": "{answered|work-routed|work-completed|approval-recorded|approval-acted|suggestion-recorded|conversation-answered|correction-steered}",
        "project": "{Project name, or None.}",
        "task_id": "{Task id, or None.}",
        "decision_key": "{Decision key, or None.}",
        "proof": "{Concrete evidence that the message was answered and acted on appropriately.}",
        "next_step": "{Next concrete action, or Complete.}",
    }
    atomic_write_json(path, value)
    print(f"scaffolded Telegram conversation outcome: {path}")


def record_outcome(home, update_id):
    directories = conversation_dirs(home)
    record = read_json(
        directories["telegram-inbox"] / f"{update_id}.json",
        "Telegram conversation message",
    )
    response = read_json(
        directories["telegram-conversation-receipts"] / f"{update_id}.json",
        "Telegram conversation response",
    )
    source = read_json(
        directories["telegram-outcomes"] / f"{update_id}.json",
        "Telegram conversation outcome input",
    )
    if source.get("schema_version") != SCHEMA_VERSION or source.get("update_id") != update_id:
        raise BriefError("Telegram conversation outcome input binding is stale or tampered")
    classification = source.get("classification")
    outcome = source.get("outcome")
    allowed = {
        "question": {"answered"},
        "work-request": {"work-routed", "work-completed"},
        "approval": {"approval-recorded", "approval-acted"},
        "suggestion": {"suggestion-recorded", "answered"},
        "conversation": {"conversation-answered"},
        "correction": {"correction-steered"},
    }
    if classification not in allowed or outcome not in allowed[classification]:
        raise BriefError("Telegram conversation classification and outcome do not match")
    project = validate_safe_value(source.get("project"), "conversation project")
    task_id = validate_safe_value(source.get("task_id"), "conversation task id")
    decision_key = validate_safe_value(source.get("decision_key"), "conversation decision key")
    proof = validate_safe_value(source.get("proof"), "conversation outcome proof")
    next_step = validate_safe_value(source.get("next_step"), "conversation next step")
    if classification in ("work-request", "correction"):
        validate_slug(task_id, "conversation task id", TASK_RE)
    if classification == "approval":
        validate_slug(decision_key, "conversation decision key", PHASE_RE)
    if (
        response.get("origin_update_id") != update_id
        or response.get("origin_message_id") != record.get("message_id")
        or response.get("origin_text_sha256") != record.get("text_sha256")
        or not response.get("telegram_message_ids")
    ):
        raise BriefError("Telegram conversation outcome has no exact substantive response binding")
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-conversation-outcome",
        "home": str(home),
        "update_id": update_id,
        "origin_message_id": record["message_id"],
        "origin_text_sha256": record["text_sha256"],
        "response_content_sha256": response["response_content_sha256"],
        "classification": classification,
        "outcome": outcome,
        "project": project,
        "task_id": task_id,
        "decision_key": decision_key,
        "proof": proof,
        "next_step": next_step,
        "recorded_at": now_epoch(),
    }
    binding = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    value["outcome_sha256"] = hashlib.sha256(binding).hexdigest()
    atomic_write_json(
        directories["telegram-conversation-outcomes"] / f"{update_id}.json",
        value,
    )
    print(f"telegram conversation outcome recorded: update={update_id} outcome={outcome}")


def run_regression(home):
    root = Path(os.environ["FM_ROOT"]).resolve(strict=True)
    command = [
        str(root / "bin" / "fm-test-run.sh"),
        str(root / "tests" / "fm-founder-brief.test.sh"),
    ]
    result = subprocess.run(
        command,
        cwd=str(root),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    output = result.stdout[-16384:]
    for _, pattern in SECRET_PATTERNS:
        output = pattern.sub("[REDACTED]", output)
    diagnostics = home / "state" / "telegram-protocol-regression.log"
    atomic_write_bytes(diagnostics, output.encode("utf-8", errors="replace"))
    if result.returncode != 0:
        raise BriefError(
            "deterministic Telegram regression failed; bounded diagnostics were retained privately"
        )
    value = {
        "schema_version": SCHEMA_VERSION,
        "kind": "telegram-protocol-regression",
        "status": "passed",
        "home": str(home),
        "owner_sha256": file_sha256(root / "bin" / "fm-founder-brief.sh"),
        "test_sha256": file_sha256(root / "tests" / "fm-founder-brief.test.sh"),
        "verified_at": now_epoch(),
    }
    atomic_write_json(home / "state" / "telegram-protocol-regression.json", value)
    print("deterministic Telegram regression passed")


def scaffold_conversation_canary(home):
    if not config_enabled(home):
        raise BriefError("founder communications are not enabled for this home")
    path = home / "data" / "telegram-conversation-canary.json"
    ensure_private_dir(path.parent)
    if path.exists() or path.is_symlink():
        raise BriefError(f"refusing to overwrite existing conversation canary: {path}")
    atomic_write_json(
        path,
        {
            "schema_version": SCHEMA_VERSION,
            "question_update_id": 0,
            "work_request_update_id": 0,
            "correction_update_id": 0,
        },
    )
    print(f"scaffolded Telegram conversation canary: {path}")


def verify_conversation_canary(home):
    if config_mode(home) != CONFIG_MANDATORY:
        raise BriefError("conversation canary requires telegram-mandatory mode")
    path = home / "data" / "telegram-conversation-canary.json"
    try:
        source = read_json(path, "Telegram conversation canary input")
        ids = [
            source.get("question_update_id"),
            source.get("work_request_update_id"),
            source.get("correction_update_id"),
        ]
        if (
            source.get("schema_version") != SCHEMA_VERSION
            or any(isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in ids)
            or ids != sorted(set(ids))
        ):
            raise BriefError("conversation canary update ids must be distinct positive ordered integers")
        if not regression_receipt_valid(home):
            raise BriefError("conversation canary requires a current deterministic regression receipt")
        expected = (
            ("question", "answered"),
            ("work-request", "work-routed"),
            ("correction", "correction-steered"),
        )
        evidence = []
        directories = conversation_dirs(home)
        for update_id, (classification, outcome) in zip(ids, expected):
            inbox = read_json(
                directories["telegram-inbox"] / f"{update_id}.json",
                "Telegram conversation canary message",
            )
            response = read_json(
                directories["telegram-conversation-receipts"] / f"{update_id}.json",
                "Telegram conversation canary response",
            )
            handled = read_json(
                directories["telegram-conversation-outcomes"] / f"{update_id}.json",
                "Telegram conversation canary outcome",
            )
            if (
                not inbox.get("acknowledgment_dedupe_key")
                or response.get("origin_update_id") != update_id
                or handled.get("classification") != classification
                or handled.get("outcome") not in ({outcome, "work-completed"} if classification == "work-request" else {outcome})
            ):
                raise BriefError("conversation canary evidence is incomplete or content-inappropriate")
            evidence.append(
                {
                    "update_id": update_id,
                    "origin_text_sha256": inbox["text_sha256"],
                    "response_content_sha256": response["response_content_sha256"],
                    "outcome_sha256": handled["outcome_sha256"],
                }
            )
        hashes = identity_hashes(home)
        if hashes is None:
            raise BriefError("conversation canary identities are unavailable")
        evidence_hash = hashlib.sha256(
            json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        value = {
            "schema_version": SCHEMA_VERSION,
            "kind": "telegram-conversation-canary",
            "protocol_version": CONVERSATION_PROTOCOL_VERSION,
            "status": "passed",
            "home": str(home),
            "chat_identity_sha256": hashes[0],
            "user_identity_sha256": hashes[1],
            "canary_evidence_sha256": evidence_hash,
            "update_ids": ids,
            "verified_at": now_epoch(),
        }
        atomic_write_json(home / "state" / "telegram-conversation-canary.json", value)
        print("Telegram conversation question/work-request/correction canary passed")
    except BriefError:
        open_incident(
            home,
            "conversation",
            "question-work-request-correction",
            "conversation retries remain durable; lifecycle and decision automation are contained",
        )
        raise


def incident_mark(home, lane, state):
    validate_lane(lane)
    allowed_next = {
        "containment": "diagnosis",
        "diagnosis": "repair",
        "repair": "revalidation",
    }
    path = incident_path(home, lane)
    value = read_json(path, "Telegram protocol incident")
    current = value.get("status")
    if allowed_next.get(current) != state:
        raise BriefError(f"incident transition must move {current} to {allowed_next.get(current)}")
    diagnostics_path = home / "data" / "telegram-protocol-incidents" / f"{lane}.md"
    sections = validate_private_markdown(
        diagnostics_path,
        (
            "Failed canary and consequence",
            "Bounded diagnostics",
            "Root cause",
            "Repair",
            "Next concrete action",
        ),
        "Telegram protocol incident diagnostics",
    )
    diagnostics_hash = hashlib.sha256(
        json.dumps(sections, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    value["status"] = state
    value["diagnostics_sha256"] = diagnostics_hash
    value["updated_at"] = now_epoch()
    value["next_action"] = {
        "diagnosis": "apply and record the verified repair",
        "repair": "rerun deterministic regression and every live canary",
        "revalidation": "restore only after every fresh proof is green",
    }[state]
    atomic_write_json(path, value)
    print(f"Telegram protocol incident {lane}: {state}")


def live_canary_valid(home, lane, newer_than):
    path = home / "state" / f"telegram-{lane}-canary.json"
    if not path.exists():
        return False
    value = read_json(path, f"Telegram {lane} canary receipt")
    hashes = identity_hashes(home)
    if hashes is None:
        return False
    return (
        value.get("schema_version") == SCHEMA_VERSION
        and value.get("kind") == f"telegram-{lane}-canary"
        and value.get("protocol_version") == CONVERSATION_PROTOCOL_VERSION
        and value.get("status") == "passed"
        and value.get("home") == str(home)
        and value.get("chat_identity_sha256") == hashes[0]
        and value.get("user_identity_sha256") == hashes[1]
        and isinstance(value.get("verified_at"), int)
        and not isinstance(value.get("verified_at"), bool)
        and value["verified_at"] > newer_than
    )


def restore_incident(home, lane):
    validate_lane(lane)
    path = incident_path(home, lane)
    value = read_json(path, "Telegram protocol incident")
    if value.get("status") != "revalidation":
        raise BriefError("incident restore requires revalidation state")
    opened_at = value.get("opened_at")
    if (
        not regression_receipt_valid(home, opened_at)
        or not conversation_canary_valid(home, opened_at)
        or not live_canary_valid(home, "lifecycle", opened_at)
        or not live_canary_valid(home, "decision", opened_at)
    ):
        raise BriefError(
            "incident remains contained until regression and conversation, lifecycle, and decision canaries are all fresh and green"
        )
    value["status"] = "resolved"
    value["resolved_at"] = now_epoch()
    value["updated_at"] = now_epoch()
    value["next_action"] = "monitor ordinary conversation and restored automation"
    atomic_write_json(path, value)
    print(f"Telegram protocol incident {lane}: resolved; lane eligible for restoration")


def show_incident(home, lane):
    validate_lane(lane)
    path = incident_path(home, lane)
    if not path.exists():
        print(f"Telegram protocol incident {lane}: none")
        return
    value = read_json(path, "Telegram protocol incident")
    print(
        f"Telegram protocol incident {lane}: status={value.get('status')} "
        f"next={value.get('next_action')}"
    )


def main():
    if len(sys.argv) < 2:
        fail("run fm-founder-brief.sh --help for commands", 2)
    command = sys.argv[1]
    try:
        home = Path(os.environ["FM_HOME"]).expanduser().resolve(strict=True)
    except (KeyError, OSError):
        fail("active FM_HOME does not resolve to an existing directory")
    try:
        if command in (
            "create",
            "deliver",
            "verify",
            "phase",
            "during-create",
            "during",
            "post-create",
            "post",
        ):
            if len(sys.argv) != 4:
                raise BriefError(f"{command} requires <task-id> <phase>")
            task, phase = sys.argv[2:]
            validate_slug(task, "task id", TASK_RE)
            validate_slug(phase, "phase", PHASE_RE)
            if command == "create":
                scaffold(home, task, phase)
            elif command == "verify":
                verify(home, task, phase)
            elif command in ("deliver", "phase"):
                deliver(home, task, phase)
            elif command == "during-create":
                scaffold_lifecycle(home, task, phase, "during")
            elif command == "during":
                record_during(home, task, phase)
            elif command == "post-create":
                scaffold_lifecycle(home, task, phase, "post")
            else:
                deliver_post(home, task, phase)
        elif command in ("decision-create", "decision-deliver"):
            if len(sys.argv) != 3:
                raise BriefError(f"{command} requires <digest-id>")
            digest_id = sys.argv[2]
            validate_slug(digest_id, "digest id", TASK_RE)
            if command == "decision-create":
                scaffold_decision(home, digest_id)
            else:
                deliver_decisions(home, digest_id)
        elif command == "remind-decisions":
            if len(sys.argv) != 2:
                raise BriefError("remind-decisions takes no arguments")
            try:
                remind_decisions(home)
            except BriefError:
                open_incident(
                    home,
                    "decision",
                    "pending-approval-reminder",
                    "ordinary conversation remains active; decision reminders and authority automation are contained",
                )
                raise
        elif command == "verify-complete":
            if len(sys.argv) != 3:
                raise BriefError("verify-complete requires <task-id>")
            task = sys.argv[2]
            validate_slug(task, "task id", TASK_RE)
            verify_complete(home, task)
        elif command in ("ingest-update", "route-update"):
            if len(sys.argv) != 3:
                raise BriefError(f"{command} requires <private-update.json>")
            try:
                update_path = Path(sys.argv[2]).expanduser().resolve(strict=True)
            except OSError:
                raise BriefError("Telegram update path does not resolve") from None
            state_root = (home / "state").resolve(strict=True)
            if state_root not in update_path.parents:
                raise BriefError("Telegram update must be a private file under this home's state")
            if command == "ingest-update":
                if not ingest_update(home, update_path):
                    raise SystemExit(3)
            else:
                route_update_file(home, update_path)
        elif command in ("reply-create", "reply"):
            if len(sys.argv) != 3:
                raise BriefError(f"{command} requires <update-id>")
            if not re.fullmatch(r"[0-9]+", sys.argv[2]):
                raise BriefError("Telegram update id must be numeric")
            update_id = int(sys.argv[2])
            if command == "reply-create":
                scaffold_reply(home, update_id)
            else:
                deliver_reply(home, update_id)
        elif command in ("outcome-create", "outcome"):
            if len(sys.argv) != 3:
                raise BriefError(f"{command} requires <update-id>")
            if not re.fullmatch(r"[0-9]+", sys.argv[2]):
                raise BriefError("Telegram update id must be numeric")
            update_id = int(sys.argv[2])
            if command == "outcome-create":
                scaffold_outcome(home, update_id)
            else:
                record_outcome(home, update_id)
        elif command == "regression-run":
            if len(sys.argv) != 2:
                raise BriefError("regression-run takes no arguments")
            run_regression(home)
        elif command in ("conversation-canary-create", "conversation-canary-verify"):
            if len(sys.argv) != 2:
                raise BriefError(f"{command} takes no arguments")
            if command == "conversation-canary-create":
                scaffold_conversation_canary(home)
            else:
                verify_conversation_canary(home)
        elif command == "relay-once":
            if len(sys.argv) != 2:
                raise BriefError("relay-once takes no arguments")
            try:
                relay_once(home)
            except BriefError:
                if config_enabled(home):
                    open_incident(
                        home,
                        "conversation",
                        "relay-once",
                        "durable inbound and outbound retries remain; lifecycle and decision automation are contained",
                    )
                raise
        elif command in ("canary-delivery", "canary-buttons"):
            if len(sys.argv) != 2:
                raise BriefError(f"{command} takes no arguments")
            try:
                deliver_canary(home, command == "canary-buttons")
            except BriefError:
                open_incident(
                    home,
                    "decision" if command == "canary-buttons" else "lifecycle",
                    command,
                )
                raise
        elif command == "incident-create":
            if len(sys.argv) != 4:
                raise BriefError("incident-create requires <lane> <canary>")
            lane, canary = sys.argv[2:]
            validate_lane(lane)
            validate_slug(canary, "canary", PHASE_RE)
            value = open_incident(home, lane, canary)
            print(
                f"Telegram protocol incident {lane}: status={value['status']} "
                f"next={value['next_action']}"
            )
        elif command == "incident-transition":
            if len(sys.argv) != 4:
                raise BriefError("incident-transition requires <lane> <state>")
            incident_mark(home, sys.argv[2], sys.argv[3])
        elif command == "incident-restore":
            if len(sys.argv) != 3:
                raise BriefError("incident-restore requires <lane>")
            restore_incident(home, sys.argv[2])
        elif command == "incident-status":
            if len(sys.argv) != 3:
                raise BriefError("incident-status requires <lane>")
            show_incident(home, sys.argv[2])
        else:
            raise BriefError("unknown command; run fm-founder-brief.sh --help")
    except BriefError as error:
        fail(str(error))


main()
PY
