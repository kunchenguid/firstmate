#!/usr/bin/env python3
"""Slack Socket Mode exposure of the crosscheck gate for team engineers (R10).

An engineer tags the crosscheck bot in an allowlisted Slack channel with a
GitHub pull-request link; the bot runs the crosscheck CLI for that PR and
posts the findings as a thread reply on the engineer's own message, naming
the lane that produced the review. The listener uses Socket Mode, so no
public inbound endpoint is added to the private lane posture.

Posture, in one place:

- Slack text and PR content are DATA, never instructions. The only thing
  this process ever takes from a mention is one pull-request URL, which is
  validated against the repository allowlist before any credentialed tool
  sees it. Nothing from Slack or from the PR is ever executed.
- Credential sources and service startup requirements are owned by
  docs/crosscheck-slack.md.
  Tokens are never stored in the config, never written to state, never placed
  in a child process environment (except the GitHub read credential, whose
  entire job is to be the crosscheck subprocess's read credential), and
  every log line passes through a redactor that knows every secret value.
- Authorship comes only from an HMAC-signed Firstmate/no-mistakes
  attestation bound to the exact repository, pull request, and head SHA.
  Slack text, the submitter, branch names, and caller-supplied model text
  carry no authorship authority. Missing, conflicting, or unverifiable
  provenance is a visible fail-closed refusal.
- Every Slack event id is claimed durably before any work starts, so a
  retried delivery of the same event never starts a second review.
- Team usage is metered per submitter per UTC day in a durable JSON ledger
  (the C3 hook). Two bounds exist and both reply in thread instead of
  silently dropping: `daily_request_cap` counts started reviews and is the
  BINDING control today; `daily_budget_usd` remains a forward contract and
  does not consume the new observational telemetry because this change does
  not add a spend cap.
  Null for either means that bound is off; requests are still ledgered.

The review itself belongs to bin/fm-crosscheck.sh; this file never
reimplements or weakens any part of that gate. The websocket client below
is a deliberately minimal RFC 6455 implementation over the standard
library, because the repo carries no third-party Python dependencies and a
Socket Mode listener needs exactly one client-side websocket.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import fcntl
import functools
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import secrets
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, NoReturn
import urllib.error
import urllib.parse
import urllib.request

BIN_DIR = Path(__file__).resolve().parent
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))

from fm_bounded_io import BoundedIOError, read_bounded_json, run_bounded


TOOL = "fm-crosscheck-slack"
METER_SCHEMA = "firstmate.crosscheck-slack-meter.v1"

REQUIRED_CONFIG_KEYS = {
    "app_token_env",
    "bot_token_env",
    "channel_allowlist",
    "repo_allowlist",
    "github_token_env",
    "daily_budget_usd",
    "daily_request_cap",
    "provenance_key_file",
    "state_dir",
}
OPTIONAL_CONFIG_KEYS = {"keychain_services"}
CONFIG_KEYS = REQUIRED_CONFIG_KEYS | OPTIONAL_CONFIG_KEYS
ENV_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
CHANNEL_RE = re.compile(r"^[A-Z0-9]{1,32}$")
EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
REQUEST_DAY_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
REQUEST_ID_RE = re.compile(r"^req-([0-9]{4}-[0-9]{2}-[0-9]{2})-[0-9a-f]{12}$")
# The trailing lookahead makes the PR number strictly bounded: an 11+ digit
# run never truncates into a shorter, DIFFERENT PR id inside an allowlisted
# repository; the link simply does not match and the mention is refused as
# link-less rather than reviewed as the wrong PR.
PR_LINK_RE = re.compile(
    r"https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/"
    r"([A-Za-z0-9._-]{1,100})/pull/([0-9]{1,10})(?![0-9])"
)

MAX_CONFIG_BYTES = 64 * 1024
MAX_METER_BYTES = 8 * 1024 * 1024
MAX_LEDGER_BYTES = 16 * 1024 * 1024
MAX_REVIEW_OUTPUT_BYTES = 4 * 1024 * 1024
DEFAULT_REVIEW_TIMEOUT_SECONDS = 5400.0
MAX_REPLY_CHARS = 3500
MAX_SUMMARY_CHARS = 900
MAX_LISTED_FINDINGS = 10
WS_MAX_PAYLOAD = 4 * 1024 * 1024
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WEB_API_TIMEOUT_SECONDS = 30
REVIEW_QUEUE_LIMIT = 8
REVIEW_WORKERS = 4
RECONNECT_BACKOFF_CAP_SECONDS = 60.0
LAUNCH_PROVENANCE_SCHEMA = "firstmate.crosscheck-author-launch.v1"
PROVENANCE_SCHEMA = "firstmate.crosscheck-authorship.v2"
PROVENANCE_SIGNATURE_ALGORITHM = "hmac-sha256"
MAX_PROVENANCE_BYTES = 64 * 1024
MAX_TASK_META_BYTES = 64 * 1024
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class SlackExposureError(RuntimeError):
    """A validated refusal with a message safe to show and to log."""


def refuse(message: str) -> NoReturn:
    print(f"{TOOL} REFUSED: {redact(message)}", file=sys.stderr, flush=True)
    raise SystemExit(3)


# --- secret redaction --------------------------------------------------------
#
# Every token this process resolves is registered here, and every line the
# process emits goes through redact(). Belt and braces: no call site is ever
# handed a token to log in the first place, and the redactor catches the
# mistake if one is.

_SECRETS: list[str] = []


def register_secret(value: str) -> None:
    if value and value not in _SECRETS:
        _SECRETS.append(value)


def redact(text: str) -> str:
    for secret in _SECRETS:
        text = text.replace(secret, "[redacted]")
    return text


def log(message: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{stamp} {TOOL}: {redact(message)}", flush=True)


# --- configuration ------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Config:
    path: Path
    app_token_env: str
    bot_token_env: str
    github_token_env: str
    keychain_services: dict[str, str]
    channel_allowlist: tuple[str, ...]
    repo_allowlist: tuple[str, ...]
    daily_budget_usd: float | None
    daily_request_cap: int | None
    provenance_key_file: Path
    state_dir: Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SlackExposureError(message)


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value.strip() != "", f"{label} must be a nonempty string")
    return value.strip()


def default_config_path() -> Path:
    override = os.environ.get("FM_CROSSCHECK_SLACK_CONFIG", "")
    if override:
        return Path(override)
    home = os.environ.get("FM_HOME", "")
    if not home:
        raise SlackExposureError(
            "FM_HOME is required to locate config/crosscheck-slack.json "
            "(or set FM_CROSSCHECK_SLACK_CONFIG to an explicit path)"
        )
    return Path(home) / "config" / "crosscheck-slack.json"


def expand_host_path(raw: str, label: str) -> Path:
    if raw == "$FM_HOME" or raw.startswith("$FM_HOME/"):
        home = os.environ.get("FM_HOME", "")
        require(
            home != "",
            f"{label} references $FM_HOME but FM_HOME is not set in the environment",
        )
        raw = home + raw[len("$FM_HOME"):]
    require(
        "$" not in raw,
        f"{label} supports only a literal leading $FM_HOME reference; "
        f"other substitutions are refused: {raw!r}",
    )
    path = Path(raw)
    require(path.is_absolute(), f"{label} must resolve to an absolute path, got {raw!r}")
    return path


def load_config(path: Path) -> Config:
    try:
        value = read_bounded_json(path, maximum_bytes=MAX_CONFIG_BYTES)
    except BoundedIOError as exc:
        raise SlackExposureError(f"configuration at {path} is unreadable: {exc}") from exc
    require(isinstance(value, dict), f"configuration at {path} must be a JSON object")
    unexpected = sorted(set(value) - CONFIG_KEYS)
    missing = sorted(REQUIRED_CONFIG_KEYS - set(value))
    require(not unexpected, f"configuration at {path} has unexpected keys: {', '.join(unexpected)}")
    require(not missing, f"configuration at {path} is missing keys: {', '.join(missing)}")

    env_names: dict[str, str] = {}
    for key in ("app_token_env", "bot_token_env", "github_token_env"):
        name = require_string(value.get(key), f"configuration {key}")
        require(
            ENV_NAME_RE.fullmatch(name) is not None,
            f"configuration {key} must name an environment variable "
            f"(uppercase letters, digits, underscores), got {name!r}",
        )
        env_names[key] = name
    require(
        len(set(env_names.values())) == 3,
        "configuration app_token_env, bot_token_env, and github_token_env "
        "must name three distinct environment variables",
    )
    keychain_raw = value.get("keychain_services", {})
    require(
        isinstance(keychain_raw, dict),
        "configuration keychain_services must be an object when present",
    )
    require(
        set(keychain_raw) <= {"app_token", "bot_token", "github_token"},
        "configuration keychain_services has an unknown credential role",
    )
    keychain_services: dict[str, str] = {}
    for role, service in keychain_raw.items():
        service = require_string(service, f"configuration keychain_services.{role}")
        require(
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", service) is not None,
            f"configuration keychain_services.{role} is not a safe service name",
        )
        keychain_services[role] = service
    require(
        len(set(keychain_services.values())) == len(keychain_services),
        "configuration keychain_services must name distinct services",
    )

    channels_raw = value.get("channel_allowlist")
    require(
        isinstance(channels_raw, list) and channels_raw,
        "configuration channel_allowlist must be a nonempty array of Slack channel ids",
    )
    channels: list[str] = []
    for index, channel in enumerate(channels_raw):
        channel = require_string(channel, f"configuration channel_allowlist[{index}]")
        require(
            CHANNEL_RE.fullmatch(channel) is not None,
            f"configuration channel_allowlist[{index}] must be a Slack channel id "
            f"(e.g. C0123ABCDEF), got {channel!r}",
        )
        channels.append(channel)

    repos_raw = value.get("repo_allowlist")
    require(
        isinstance(repos_raw, list) and repos_raw,
        "configuration repo_allowlist must be a nonempty array of owner/name repositories",
    )
    repos: list[str] = []
    for index, repo in enumerate(repos_raw):
        repo = require_string(repo, f"configuration repo_allowlist[{index}]")
        require(
            REPO_RE.fullmatch(repo) is not None,
            f"configuration repo_allowlist[{index}] must be owner/name, got {repo!r}",
        )
        repos.append(repo.lower())

    budget_raw = value.get("daily_budget_usd")
    budget: float | None
    if budget_raw is None:
        budget = None
    else:
        require(
            isinstance(budget_raw, (int, float)) and not isinstance(budget_raw, bool),
            "configuration daily_budget_usd must be null or a positive number",
        )
        budget = float(budget_raw)
        require(budget > 0, "configuration daily_budget_usd must be null or a positive number")

    cap_raw = value.get("daily_request_cap")
    cap: int | None
    if cap_raw is None:
        cap = None
    else:
        require(
            isinstance(cap_raw, int) and not isinstance(cap_raw, bool) and cap_raw > 0,
            "configuration daily_request_cap must be null or a positive integer",
        )
        cap = cap_raw

    state_dir = expand_host_path(
        require_string(value.get("state_dir"), "configuration state_dir"),
        "state_dir",
    )
    provenance_key_file = expand_host_path(
        require_string(
            value.get("provenance_key_file"),
            "configuration provenance_key_file",
        ),
        "provenance_key_file",
    )

    return Config(
        path=path,
        app_token_env=env_names["app_token_env"],
        bot_token_env=env_names["bot_token_env"],
        github_token_env=env_names["github_token_env"],
        keychain_services=keychain_services,
        channel_allowlist=tuple(channels),
        repo_allowlist=tuple(repos),
        daily_budget_usd=budget,
        daily_request_cap=cap,
        provenance_key_file=provenance_key_file,
        state_dir=state_dir,
    )


def required_token(
    env_name: str,
    role: str,
    keychain_service: str | None = None,
) -> str:
    value = os.environ.get(env_name)
    if (value is None or value == "") and keychain_service:
        security = Path("/usr/bin/security")
        if security.is_file():
            try:
                result = subprocess.run(
                    [
                        str(security),
                        "find-generic-password",
                        "-s",
                        keychain_service,
                        "-w",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                result = None
            if result is not None and result.returncode == 0:
                try:
                    value = result.stdout.decode("utf-8", "strict").rstrip("\r\n")
                except UnicodeDecodeError:
                    value = None
    if value is None or value == "":
        fallback = (
            f" or install it in macOS Keychain service {keychain_service}"
            if keychain_service
            else ""
        )
        refuse(
            f"cannot start: the {role} environment variable {env_name} is not set. "
            f"Export {env_name} with the credential{fallback} and start again; the token is "
            "never stored in the config file"
        )
    register_secret(value)
    return value


def load_provenance_key(path: Path) -> bytes:
    """Load the coordinator-only HMAC key without following links."""

    try:
        stat_result = path.lstat()
    except FileNotFoundError as exc:
        raise SlackExposureError(
            f"provenance signing key is missing at {path}"
        ) from exc
    except OSError as exc:
        raise SlackExposureError(
            f"provenance signing key inspection failed at {path}: {exc}"
        ) from exc
    require(not path.is_symlink(), f"provenance signing key must not be a symlink: {path}")
    require(
        (stat_result.st_mode & 0o077) == 0,
        f"provenance signing key permissions must be owner-only at {path}",
    )
    try:
        raw = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        raise SlackExposureError(
            f"provenance signing key is unreadable at {path}: {exc}"
        ) from exc
    require(
        re.fullmatch(r"[0-9a-f]{64}", raw) is not None,
        f"provenance signing key at {path} must contain exactly 32 bytes as lowercase hex",
    )
    register_secret(raw)
    return bytes.fromhex(raw)


def provenance_key_id(key: bytes) -> str:
    return hashlib.sha256(key).hexdigest()[:16]


def configured_credentials(config: Config) -> tuple[str, str, str]:
    app_token = required_token(
        config.app_token_env,
        "Slack app-level (Socket Mode) token",
        config.keychain_services.get("app_token"),
    )
    bot_token = required_token(
        config.bot_token_env,
        "Slack bot token",
        config.keychain_services.get("bot_token"),
    )
    github_token = required_token(
        config.github_token_env,
        "GitHub read credential",
        config.keychain_services.get("github_token"),
    )
    return app_token, bot_token, github_token


# --- durable event dedupe -----------------------------------------------------


class EventDeduper:
    """Durable first-claim-wins registry of processed Slack event ids.

    Besides the claim marker, it stores the rendered final reply BEFORE it is
    posted and a delivered marker AFTER the post succeeds, so a redelivered
    event whose verdict was produced but never delivered can be answered by
    re-posting the stored reply instead of being silently deduped (and never
    by running a second review).
    """

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)

    def _validated(self, event_id: str) -> str:
        require(
            EVENT_ID_RE.fullmatch(event_id) is not None,
            f"event id validation rejected {event_id!r}",
        )
        return event_id

    def claim(self, event_id: str) -> bool:
        path = self.directory / f"{self._validated(event_id)}.claimed"
        try:
            descriptor = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            return False
        try:
            os.write(
                descriptor,
                json.dumps({"claimed_at": utc_now()}).encode("utf-8") + b"\n",
            )
        finally:
            os.close(descriptor)
        return True

    def store_reply(self, event_id: str, text: str) -> None:
        path = self.directory / f"{self._validated(event_id)}.reply"
        descriptor, temp_name = tempfile.mkstemp(prefix=".reply.", dir=str(self.directory))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.chmod(temp_name, 0o600)
            os.replace(temp_name, path)
        except BaseException:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise

    def mark_delivered(self, event_id: str) -> None:
        path = self.directory / f"{self._validated(event_id)}.delivered"
        path.write_text(json.dumps({"delivered_at": utc_now()}) + "\n", encoding="utf-8")
        os.chmod(path, 0o600)

    def undelivered_reply(self, event_id: str) -> str | None:
        """Return the stored final reply if it was never delivered, else None."""

        event_id = self._validated(event_id)
        if (self.directory / f"{event_id}.delivered").exists():
            return None
        reply_path = self.directory / f"{event_id}.reply"
        if not reply_path.is_file():
            return None
        try:
            return reply_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return None


CLAIM_RETENTION_DAYS = 14
METER_RETENTION_DAYS = 90


def sweep_state(
    state_dir: Path,
    now: float | None = None,
    claim_days: int = CLAIM_RETENTION_DAYS,
    meter_days: int = METER_RETENTION_DAYS,
) -> list[str]:
    """Bounded retention sweep; returns the removed paths (for logging/tests).

    Event artifacts (claim, reply, delivered markers) age out by mtime after
    `claim_days`; meter day-files age out by the day their FILENAME names
    after `meter_days` (mtime as fallback for unparseable names). Fresh
    files are never touched.
    """

    removed: list[str] = []
    current = time.time() if now is None else now
    events = state_dir / "events"
    if events.is_dir():
        cutoff = current - claim_days * 86400
        for path in sorted(events.iterdir()):
            if not path.is_file():
                continue
            try:
                if path.stat().st_mtime < cutoff:
                    path.unlink()
                    removed.append(str(path))
            except OSError:
                continue
    meter = state_dir / "meter"
    if meter.is_dir():
        cutoff = current - meter_days * 86400
        for path in sorted(meter.glob("*.json")):
            day = path.name[: -len(".json")]
            try:
                if REQUEST_DAY_RE.fullmatch(day):
                    stamp = dt.datetime.strptime(day, "%Y-%m-%d").replace(
                        tzinfo=dt.timezone.utc
                    ).timestamp()
                else:
                    stamp = path.stat().st_mtime
                if stamp < cutoff:
                    path.unlink()
                    removed.append(str(path))
            except (OSError, ValueError):
                continue
    return removed


# --- per-submitter daily meter --------------------------------------------------


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_day() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


class DailyMeter:
    """Durable per-UTC-day, per-submitter request ledger (the C3 hook).

    Each request lands as one record: submitter, PR, timestamps, outcome,
    token usage when the crosscheck output exposes it, and estimated USD when
    derivable (else null). Writes are atomic (temp file + rename) under one
    advisory lock so a crash never leaves a torn ledger.

    Day binding: a request is metered against the UTC day it STARTED. The
    request id encodes that origin day, and finish() finalizes the record in
    the origin day's file, so a review crossing midnight UTC neither orphans
    its started record nor lands a misattributed completion in the next
    day's ledger (which would let a submitter evade the bound once costs
    exist). `day_fn` is injectable so tests can prove the rollover.
    """

    def __init__(self, directory: Path, day_fn: Callable[[], str] = utc_day) -> None:
        self.directory = directory
        self._day_fn = day_fn
        directory.mkdir(parents=True, exist_ok=True)

    def _day_path(self, day: str) -> Path:
        return self.directory / f"{day}.json"

    def _load(self, day: str) -> dict[str, Any]:
        path = self._day_path(day)
        if not path.exists():
            return {"schema": METER_SCHEMA, "day": day, "requests": []}
        value = read_bounded_json(path, maximum_bytes=MAX_METER_BYTES)
        require(
            isinstance(value, dict)
            and value.get("schema") == METER_SCHEMA
            and isinstance(value.get("requests"), list),
            f"meter ledger at {path} is not a {METER_SCHEMA} document",
        )
        return value

    def _write(self, day: str, value: dict[str, Any]) -> None:
        path = self._day_path(day)
        encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
        descriptor, temp_name = tempfile.mkstemp(prefix=".meter.", dir=str(self.directory))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(encoded)
            os.chmod(temp_name, 0o600)
            os.replace(temp_name, path)
        except BaseException:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise

    def _locked(self) -> Any:
        lock_path = self.directory / ".lock"
        handle = lock_path.open("a+", encoding="utf-8")
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle

    def begin(
        self,
        submitter: str,
        pr_url: str,
        event_id: str,
        *,
        request_cap: int | None = None,
        budget_usd: float | None = None,
    ) -> tuple[str | None, str | None, float]:
        """Atomically enforce both bounds and record one admitted request.

        Returns (request_id, refusal, observed), where refusal is `cap` or
        `budget` and observed is the count or spend that reached the bound.
        The check and append share one lock so concurrent listener workers
        cannot overrun a per-engineer cap.
        """

        day = self._day_fn()
        require(
            REQUEST_DAY_RE.fullmatch(day) is not None,
            f"meter day function returned a non-day value: {day!r}",
        )
        with self._locked():
            ledger = self._load(day)
            submitter_rows = [
                record
                for record in ledger["requests"]
                if record.get("submitter") == submitter
            ]
            count = len(submitter_rows)
            if request_cap is not None and count >= request_cap:
                return None, "cap", float(count)
            spent = sum(
                float(cost)
                for record in submitter_rows
                for cost in [record.get("estimated_usd")]
                if isinstance(cost, (int, float)) and not isinstance(cost, bool)
            )
            if budget_usd is not None and spent >= budget_usd:
                return None, "budget", spent
            request_id = f"req-{day}-{secrets.token_hex(6)}"
            ledger["requests"].append(
                {
                    "id": request_id,
                    "day": day,
                    "submitter": submitter,
                    "pr_url": pr_url,
                    "event_id": event_id,
                    "started_at": utc_now(),
                    "finished_at": None,
                    "status": "started",
                    "lane": None,
                    "tokens": None,
                    "estimated_usd": None,
                }
            )
            self._write(day, ledger)
        return request_id, None, 0.0

    def finish(
        self,
        request_id: str,
        status: str,
        lane: str | None,
        tokens: dict[str, int] | None,
        estimated_usd: float | None,
    ) -> None:
        # Finalize in the ORIGIN day's file, recovered from the request id,
        # never in whatever day it happens to be at completion time.
        match = REQUEST_ID_RE.fullmatch(request_id)
        require(match is not None, f"meter request id validation rejected {request_id!r}")
        day = match.group(1)
        with self._locked():
            ledger = self._load(day)
            for record in ledger["requests"]:
                if record.get("id") == request_id:
                    record["finished_at"] = utc_now()
                    record["status"] = status
                    record["lane"] = lane
                    record["tokens"] = tokens
                    record["estimated_usd"] = estimated_usd
                    break
            else:
                # The started record should always exist in the origin file;
                # if it was lost, the completion still lands THERE, keeping
                # the day's accounting in one place.
                ledger["requests"].append(
                    {
                        "id": request_id,
                        "day": day,
                        "submitter": "unknown",
                        "pr_url": "unknown",
                        "event_id": "unknown",
                        "started_at": None,
                        "finished_at": utc_now(),
                        "status": status,
                        "lane": lane,
                        "tokens": tokens,
                        "estimated_usd": estimated_usd,
                    }
                )
            self._write(day, ledger)

    def submitter_day_usd(self, submitter: str) -> float:
        with self._locked():
            ledger = self._load(self._day_fn())
        total = 0.0
        for record in ledger["requests"]:
            if record.get("submitter") != submitter:
                continue
            cost = record.get("estimated_usd")
            if isinstance(cost, (int, float)) and not isinstance(cost, bool):
                total += float(cost)
        return total

    def submitter_day_count(self, submitter: str) -> int:
        with self._locked():
            ledger = self._load(self._day_fn())
        return sum(1 for record in ledger["requests"] if record.get("submitter") == submitter)


# --- pull-request link handling -------------------------------------------------


def extract_pr_links(text: str) -> list[str]:
    """Return unique canonical GitHub PR URLs from Slack message text.

    Slack wraps links as <url> or <url|label>; the regex matches the URL body
    directly because '|' and '>' cannot appear inside it. Order is preserved
    and duplicates (case-insensitive owner/repo) collapse to one entry.
    """

    links: list[str] = []
    seen: set[str] = set()
    for match in PR_LINK_RE.finditer(text or ""):
        owner, repo, number = match.group(1), match.group(2), match.group(3)
        if repo.lower().endswith(".git"):
            repo = repo[: -len(".git")]
        key = f"{owner.lower()}/{repo.lower()}#{number}"
        if key in seen:
            continue
        seen.add(key)
        links.append(f"https://github.com/{owner}/{repo}/pull/{number}")
    return links


def repo_of(pr_url: str) -> str:
    match = PR_LINK_RE.fullmatch(pr_url)
    require(match is not None, f"internal error: unparseable PR URL {pr_url!r}")
    return f"{match.group(1)}/{match.group(2)}".lower()


@dataclasses.dataclass(frozen=True)
class PrSnapshot:
    pr_url: str
    repository: str
    number: int
    head_sha: str


@dataclasses.dataclass(frozen=True)
class AuthorshipProvenance:
    harness: str
    model: str
    model_family: str
    task_id: str
    task_generation: str
    author_kind: str
    author_account_identity: str | None
    launch_attestation_path: Path
    launch_attestation_sha256: str
    attestation_path: Path
    attestation_sha256: str


@dataclasses.dataclass(frozen=True)
class LaunchProvenance:
    harness: str
    model: str
    model_family: str
    task_id: str
    task_generation: str
    author_account_identity: str | None
    worktree: Path
    git_dir_identity: str
    launch_head: str
    launch_ref: str
    attestation_path: Path
    attestation_sha256: str


def fetch_pr_snapshot(pr_url: str, github_token: str) -> PrSnapshot:
    """Return the allowlisted PR's exact current head, fail closed."""

    match = PR_LINK_RE.fullmatch(pr_url)
    require(match is not None, f"internal error: unparseable PR URL {pr_url!r}")
    owner, repo, number = match.group(1), match.group(2), match.group(3)
    request = urllib.request.Request(
        f"https://api.github.com/repos/{owner}/{repo}/pulls/{number}",
        headers={
            "Authorization": f"Bearer {github_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=WEB_API_TIMEOUT_SECONDS) as response:
            body = response.read(1024 * 1024)
    except (urllib.error.URLError, OSError) as exc:
        raise SlackExposureError(f"PR head lookup failed for {pr_url}: {exc}") from exc
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SlackExposureError(
            f"PR head lookup returned malformed JSON for {pr_url}"
        ) from exc
    head = value.get("head") if isinstance(value, dict) else None
    sha = head.get("sha") if isinstance(head, dict) else None
    if not isinstance(sha, str) or SHA_RE.fullmatch(sha) is None:
        raise SlackExposureError(f"PR head lookup returned no exact SHA for {pr_url}")
    return PrSnapshot(
        pr_url=pr_url,
        repository=repo_of(pr_url),
        number=int(match.group(3)),
        head_sha=sha,
    )


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


@functools.lru_cache(maxsize=1)
def crosscheck_core() -> Any:
    module_path = BIN_DIR / "fm-crosscheck.py"
    spec = importlib.util.spec_from_file_location("fm_crosscheck_core_identity", module_path)
    require(spec is not None and spec.loader is not None, "Crosscheck model-family owner is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@functools.lru_cache(maxsize=128)
def crosscheck_model_family(model: str) -> str:
    """Use the core gate's exact family classifier, never a Slack-local guess."""

    module = crosscheck_core()
    family = module.model_family(model)
    require(isinstance(family, str) and family != "", "Crosscheck model family is empty")
    return family


def attestation_path(state_dir: Path, snapshot: PrSnapshot) -> Path:
    identity = f"{snapshot.repository}#{snapshot.number}@{snapshot.head_sha}"
    name = hashlib.sha256(identity.encode("utf-8")).hexdigest() + ".json"
    return state_dir / "provenance" / name


def launch_attestation_path(
    state_dir: Path, task_id: str, task_generation: str
) -> Path:
    identity = f"{task_id}@{task_generation}"
    name = hashlib.sha256(identity.encode("utf-8")).hexdigest() + ".json"
    return state_dir / "launch-provenance" / name


def git_inspect_worktree(worktree: Path) -> dict[str, str]:
    """Return the exact physical Git identity of one clean task worktree."""

    require(worktree.is_absolute(), f"task worktree must be absolute: {worktree}")
    try:
        metadata = worktree.lstat()
    except OSError as exc:
        raise SlackExposureError(f"task worktree is unavailable at {worktree}: {exc}") from exc
    require(
        stat.S_ISDIR(metadata.st_mode) and not worktree.is_symlink(),
        f"task worktree must be a real directory at {worktree}",
    )
    resolved = worktree.resolve()

    def git(*arguments: str) -> str:
        try:
            result = run_bounded(
                ["git", "-C", str(resolved), *arguments],
                timeout_seconds=30,
                maximum_output_bytes=1024 * 1024,
                env={
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "HOME": os.environ.get("HOME", "/var/empty"),
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_ASKPASS": "/usr/bin/false",
                    "SSH_ASKPASS": "/usr/bin/false",
                },
            )
        except BoundedIOError as exc:
            raise SlackExposureError(
                f"task worktree Git inspection exceeded its bounds at {resolved}: {exc}"
            ) from exc
        diagnostic = result.stderr.decode("utf-8", "replace").strip()
        require(
            result.returncode == 0,
            f"task worktree Git inspection failed at {resolved}: "
            f"{clamp(redact(diagnostic or 'no diagnostic'), 300)}",
        )
        return result.stdout.decode("utf-8", "strict").strip()

    top = Path(git("rev-parse", "--show-toplevel")).resolve()
    require(top == resolved, f"task worktree top differs from its recorded path: {top}")
    head = git("rev-parse", "HEAD")
    require(SHA_RE.fullmatch(head) is not None, f"task worktree has no exact HEAD at {resolved}")
    git_dir_raw = Path(git("rev-parse", "--git-dir"))
    git_dir = git_dir_raw if git_dir_raw.is_absolute() else resolved / git_dir_raw
    git_dir = git_dir.resolve()
    try:
        git_dir_stat = git_dir.stat()
    except OSError as exc:
        raise SlackExposureError(
            f"task worktree Git directory is unavailable at {git_dir}: {exc}"
        ) from exc
    require(stat.S_ISDIR(git_dir_stat.st_mode), f"task Git directory is not a directory at {git_dir}")
    ref_result = git("rev-parse", "--symbolic-full-name", "HEAD")
    return {
        "worktree": str(resolved),
        "head": head,
        "ref": ref_result if ref_result != "HEAD" else "DETACHED",
        "git_dir_identity": f"{git_dir_stat.st_dev}:{git_dir_stat.st_ino}",
        "tracked_status": git("status", "--porcelain=v1", "--untracked-files=no"),
    }


def git_head_descends_from(worktree: Path, ancestor: str) -> bool:
    """Prove the current task head retains the commit it launched from."""

    require(SHA_RE.fullmatch(ancestor) is not None, "launch head is not an exact SHA")
    try:
        result = run_bounded(
            ["git", "-C", str(worktree.resolve()), "merge-base", "--is-ancestor", ancestor, "HEAD"],
            timeout_seconds=30,
            maximum_output_bytes=1024 * 1024,
            env={
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": os.environ.get("HOME", "/var/empty"),
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
            },
        )
    except BoundedIOError as exc:
        raise SlackExposureError(
            f"task worktree ancestry inspection exceeded its bounds at {worktree}: {exc}"
        ) from exc
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    diagnostic = result.stderr.decode("utf-8", "replace").strip()
    raise SlackExposureError(
        f"task worktree ancestry inspection failed at {worktree}: "
        f"{clamp(redact(diagnostic or 'no diagnostic'), 300)}"
    )


def launch_account_identity(harness: str, account_home: Path) -> str:
    """Derive the author account through Crosscheck's identity owner."""

    core = crosscheck_core()
    if harness == "codex":
        return core.account_identity(harness, account_home)
    require(harness == "pi", f"unsupported OpenAI author harness {harness!r}")
    credential_path = account_home.resolve() / "auth.json"
    try:
        credential = read_bounded_json(credential_path, maximum_bytes=1024 * 1024)
    except BoundedIOError as exc:
        raise SlackExposureError(
            f"Pi author credential is unreadable at {credential_path}: {exc}"
        ) from exc
    require(
        isinstance(credential, dict) and len(credential) == 1,
        f"Pi author credential at {credential_path} must contain exactly one profile",
    )
    entry = next(iter(credential.values()))
    return core.account_identity_from_credential(
        "pi", {"openai-codex": entry}, str(credential_path)
    )


def parse_task_identity(meta_path: Path) -> dict[str, str]:
    try:
        metadata_stat = meta_path.lstat()
        require(
            stat.S_ISREG(metadata_stat.st_mode),
            f"task metadata is not a regular file at {meta_path}",
        )
        require(
            0 < metadata_stat.st_size <= MAX_TASK_META_BYTES,
            f"task metadata at {meta_path} exceeds its byte bound",
        )
        lines = meta_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise SlackExposureError(f"task metadata is unreadable at {meta_path}: {exc}") from exc
    values: dict[str, list[str]] = {}
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {
            "harness",
            "model",
            "generation_id",
            "worktree",
            "pr",
            "pr_head",
        }:
            values.setdefault(key, []).append(value)
    result: dict[str, str] = {}
    for key in ("harness", "model", "generation_id", "worktree", "pr"):
        found = values.get(key, [])
        require(
            len(found) == 1 and found[0] != "",
            f"task metadata at {meta_path} must contain exactly one nonempty {key}",
        )
        result[key] = found[0]
    heads = values.get("pr_head", [])
    require(heads and SHA_RE.fullmatch(heads[-1]) is not None, f"task metadata at {meta_path} has no exact PR head")
    result["pr_head"] = heads[-1]
    return result


def require_provenance_string(value: Any, label: str, maximum: int = 512) -> str:
    require(
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and all(character.isprintable() for character in value),
        f"{label} must be a bounded printable string",
    )
    return value


def signed_attestation(
    payload: dict[str, Any], key: bytes, *, schema: str = PROVENANCE_SCHEMA
) -> dict[str, Any]:
    signed_body = {"schema": schema, "payload": payload}
    signature = hmac.new(key, canonical_json(signed_body), hashlib.sha256).hexdigest()
    return {
        "schema": schema,
        "payload": payload,
        "signature": {
            "algorithm": PROVENANCE_SIGNATURE_ALGORITHM,
            "key_id": provenance_key_id(key),
            "value": signature,
        },
    }


def write_new_attestation(destination: Path, document: dict[str, Any]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    try:
        descriptor = os.open(
            str(destination), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
        )
    except FileExistsError:
        raise
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(encoded)
    except BaseException:
        try:
            destination.unlink()
        except OSError:
            pass
        raise


def issue_launch_attestation(
    config: Config,
    key: bytes,
    task_id: str,
    task_generation: str,
    worktree: Path,
    harness: str,
    model: str,
    account_home: Path | None,
) -> Path:
    """Capture the author identity before the task's agent process starts."""

    require(TASK_ID_RE.fullmatch(task_id) is not None, f"task id validation rejected {task_id!r}")
    for value, label in (
        (task_generation, "task generation"),
        (harness, "author harness"),
        (model, "author model"),
    ):
        require_provenance_string(value, label)
    require(
        harness != "human" and model != "human-authored",
        "Firstmate task launch provenance cannot classify human authorship",
    )
    require(model != "default", "author model is unresolved at task launch")
    worktree_identity = git_inspect_worktree(worktree)
    family = crosscheck_model_family(model)
    account_identity: str | None = None
    if family == "openai":
        require(
            harness in {"pi", "codex"},
            f"codex-family author model {model!r} has unsupported harness {harness!r}",
        )
        require(account_home is not None, "codex-family author has no launch-bound account home")
        try:
            account_identity = launch_account_identity(harness, account_home)
        except Exception as exc:
            raise SlackExposureError(
                f"codex-family author account identity is unverifiable: {exc}"
            ) from exc
        require_provenance_string(account_identity, "author account identity")
    destination = launch_attestation_path(config.state_dir, task_id, task_generation)
    payload: dict[str, Any] = {
        "issued_at": utc_now(),
        "issuer": "firstmate-spawn",
        "task": {
            "task_id": task_id,
            "task_generation": task_generation,
        },
        "author": {
            "harness": harness,
            "model": model,
            "model_family": family,
            "account_identity": account_identity,
        },
        "launch": {
            "worktree": worktree_identity["worktree"],
            "git_dir_identity": worktree_identity["git_dir_identity"],
            "head_sha": worktree_identity["head"],
            "ref": worktree_identity["ref"],
        },
    }
    document = signed_attestation(payload, key, schema=LAUNCH_PROVENANCE_SCHEMA)
    if destination.exists():
        existing = verify_launch_attestation(config, key, task_id, task_generation)
        require(
            existing.harness == harness
            and existing.model == model
            and existing.author_account_identity == account_identity
            and existing.worktree == Path(worktree_identity["worktree"])
            and existing.git_dir_identity == worktree_identity["git_dir_identity"]
            and existing.launch_head == worktree_identity["head"]
            and existing.launch_ref == worktree_identity["ref"],
            f"conflicting launch provenance already exists at {destination}",
        )
        return destination
    try:
        write_new_attestation(destination, document)
    except FileExistsError:
        existing = verify_launch_attestation(config, key, task_id, task_generation)
        require(
            existing.harness == harness
            and existing.model == model
            and existing.author_account_identity == account_identity
            and existing.worktree == Path(worktree_identity["worktree"])
            and existing.git_dir_identity == worktree_identity["git_dir_identity"]
            and existing.launch_head == worktree_identity["head"]
            and existing.launch_ref == worktree_identity["ref"],
            f"conflicting launch provenance won a concurrent issue at {destination}",
        )
    return destination


def verify_launch_attestation(
    config: Config,
    key: bytes,
    task_id: str,
    task_generation: str,
) -> LaunchProvenance:
    path = launch_attestation_path(config.state_dir, task_id, task_generation)
    try:
        raw_document = path.read_bytes()
    except OSError as exc:
        raise SlackExposureError(
            f"no launch-bound Firstmate authorship attestation exists for task "
            f"{task_id} generation {task_generation}: {exc}"
        ) from exc
    require(len(raw_document) <= MAX_PROVENANCE_BYTES, f"launch attestation at {path} exceeds its byte bound")
    try:
        document = read_bounded_json(path, maximum_bytes=MAX_PROVENANCE_BYTES)
        raw_value = json.loads(raw_document.decode("utf-8"))
    except (BoundedIOError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise SlackExposureError(f"launch attestation is malformed at {path}: {exc}") from exc
    require(raw_value == document, f"launch attestation changed while it was verified at {path}")
    require(isinstance(document, dict), f"launch attestation at {path} must be an object")
    require(set(document) == {"schema", "payload", "signature"}, f"launch attestation at {path} has an unknown shape")
    require(document.get("schema") == LAUNCH_PROVENANCE_SCHEMA, f"launch attestation at {path} has an unknown schema")
    payload = document.get("payload")
    signature = document.get("signature")
    require(isinstance(payload, dict) and isinstance(signature, dict), f"launch attestation at {path} is incomplete")
    require(
        set(payload) == {"issued_at", "issuer", "task", "author", "launch"}
        and payload.get("issuer") == "firstmate-spawn"
        and isinstance(payload.get("issued_at"), str),
        f"launch attestation at {path} has unknown issuer metadata",
    )
    require(
        signature.get("algorithm") == PROVENANCE_SIGNATURE_ALGORITHM
        and signature.get("key_id") == provenance_key_id(key)
        and isinstance(signature.get("value"), str),
        f"launch attestation at {path} has untrusted signature metadata",
    )
    expected = hmac.new(
        key,
        canonical_json({"schema": LAUNCH_PROVENANCE_SCHEMA, "payload": payload}),
        hashlib.sha256,
    ).hexdigest()
    require(hmac.compare_digest(signature["value"], expected), f"launch attestation signature verification failed at {path}")
    task = payload.get("task")
    author = payload.get("author")
    launch = payload.get("launch")
    require(
        task == {"task_id": task_id, "task_generation": task_generation},
        f"launch attestation at {path} conflicts with the requested task generation",
    )
    require(isinstance(author, dict) and set(author) == {"harness", "model", "model_family", "account_identity"}, f"launch attestation at {path} has an unknown author shape")
    require(isinstance(launch, dict) and set(launch) == {"worktree", "git_dir_identity", "head_sha", "ref"}, f"launch attestation at {path} has an unknown worktree shape")
    for field in ("harness", "model", "model_family"):
        require_provenance_string(author.get(field), f"launch attestation at {path} field {field}")
    require(
        author["harness"] != "human" and author["model"] != "human-authored",
        f"launch attestation at {path} cannot establish human authorship",
    )
    require(author["model_family"] == crosscheck_model_family(author["model"]), f"launch attestation at {path} conflicts on model family")
    account = author.get("account_identity")
    if author["model_family"] == "openai":
        require_provenance_string(account, f"launch attestation at {path} account identity")
    else:
        require(account is None or isinstance(account, str), f"launch attestation at {path} has malformed account identity")
    worktree = Path(require_provenance_string(launch.get("worktree"), f"launch attestation at {path} worktree", 4096))
    require(worktree.is_absolute(), f"launch attestation at {path} has a relative worktree")
    git_dir_identity = require_provenance_string(launch.get("git_dir_identity"), f"launch attestation at {path} Git identity")
    launch_head = require_provenance_string(launch.get("head_sha"), f"launch attestation at {path} head")
    require(SHA_RE.fullmatch(launch_head) is not None, f"launch attestation at {path} has no exact launch head")
    launch_ref = require_provenance_string(launch.get("ref"), f"launch attestation at {path} ref")
    return LaunchProvenance(
        harness=author["harness"],
        model=author["model"],
        model_family=author["model_family"],
        task_id=task_id,
        task_generation=task_generation,
        author_account_identity=account,
        worktree=worktree,
        git_dir_identity=git_dir_identity,
        launch_head=launch_head,
        launch_ref=launch_ref,
        attestation_path=path,
        attestation_sha256=hashlib.sha256(raw_document).hexdigest(),
    )


def issue_task_attestation(
    config: Config,
    key: bytes,
    task_id: str,
    pr_url: str,
    head_sha: str,
) -> Path:
    """Mint exact-head provenance from a launch-bound Firstmate task record."""

    require(TASK_ID_RE.fullmatch(task_id) is not None, f"task id validation rejected {task_id!r}")
    require(PR_LINK_RE.fullmatch(pr_url) is not None, f"PR URL validation rejected {pr_url!r}")
    require(SHA_RE.fullmatch(head_sha) is not None, f"PR head validation rejected {head_sha!r}")
    fm_home = Path(os.environ.get("FM_HOME", ""))
    require(fm_home.is_absolute(), "FM_HOME is required to issue task provenance")
    meta_path = Path(os.environ.get("FM_STATE_OVERRIDE") or fm_home / "state") / f"{task_id}.meta"
    identity = parse_task_identity(meta_path)
    require(identity["pr"].rstrip("/") == pr_url.rstrip("/"), "task metadata PR does not match the attestation subject")
    require(identity["pr_head"] == head_sha, "task metadata head does not match the attestation subject")
    require(
        identity["harness"] != "human" and identity["model"] != "human-authored",
        "Firstmate task metadata cannot establish human authorship; a trusted upstream producer is required",
    )
    launch = verify_launch_attestation(
        config, key, task_id, identity["generation_id"]
    )
    require(
        launch.harness == identity["harness"]
        and launch.model == identity["model"],
        "task metadata conflicts with launch-bound author identity",
    )
    current = git_inspect_worktree(Path(identity["worktree"]))
    require(
        Path(current["worktree"]) == launch.worktree,
        "task metadata worktree conflicts with launch-bound provenance",
    )
    require(
        current["git_dir_identity"] == launch.git_dir_identity,
        "task worktree Git identity changed after author launch",
    )
    require(
        git_head_descends_from(Path(current["worktree"]), launch.launch_head),
        "task worktree HEAD does not descend from its launch-bound head",
    )
    require(
        current["tracked_status"] == "",
        "task worktree has uncommitted tracked changes; exact-head authorship is not attestable",
    )
    require(
        current["head"] == head_sha,
        "task worktree HEAD does not equal the live PR head; another worktree or later author produced it",
    )
    snapshot = PrSnapshot(pr_url, repo_of(pr_url), int(PR_LINK_RE.fullmatch(pr_url).group(3)), head_sha)  # type: ignore[union-attr]
    destination = attestation_path(config.state_dir, snapshot)
    if destination.exists():
        existing = verify_attestation(config, key, snapshot)
        require(
            existing.harness == launch.harness
            and existing.model == launch.model
            and existing.task_id == task_id
            and existing.task_generation == identity["generation_id"]
            and existing.author_account_identity == launch.author_account_identity
            and existing.launch_attestation_sha256 == launch.attestation_sha256,
            f"conflicting provenance already exists at {destination}",
        )
        return destination
    payload: dict[str, Any] = {
        "issued_at": utc_now(),
        "issuer": "firstmate-pr-check",
        "subject": {
            "repository": snapshot.repository,
            "pull_request": snapshot.number,
            "pr_url": snapshot.pr_url.rstrip("/"),
            "head_sha": snapshot.head_sha,
        },
        "author": {
            "kind": "agent",
            "harness": launch.harness,
            "model": launch.model,
            "model_family": launch.model_family,
            "task_id": task_id,
            "task_generation": identity["generation_id"],
            "account_identity": launch.author_account_identity,
        },
        "origin": {
            "schema": LAUNCH_PROVENANCE_SCHEMA,
            "sha256": launch.attestation_sha256,
        },
    }
    document = signed_attestation(payload, key)
    try:
        write_new_attestation(destination, document)
    except FileExistsError:
        existing = verify_attestation(config, key, snapshot)
        require(
            existing.harness == launch.harness
            and existing.model == launch.model
            and existing.task_id == task_id
            and existing.task_generation == identity["generation_id"]
            and existing.author_account_identity == launch.author_account_identity
            and existing.launch_attestation_sha256 == launch.attestation_sha256,
            f"conflicting provenance won a concurrent issue at {destination}",
        )
        return destination
    return destination


def verify_attestation(config: Config, key: bytes, snapshot: PrSnapshot) -> AuthorshipProvenance:
    path = attestation_path(config.state_dir, snapshot)
    try:
        raw_document = path.read_bytes()
    except OSError as exc:
        raise SlackExposureError(
            f"no verifiable authorship attestation exists for this exact PR head: {exc}"
        ) from exc
    require(
        len(raw_document) <= MAX_PROVENANCE_BYTES,
        f"authorship attestation at {path} exceeds its byte bound",
    )
    try:
        document = read_bounded_json(path, maximum_bytes=MAX_PROVENANCE_BYTES)
    except BoundedIOError as exc:
        raise SlackExposureError(f"no verifiable authorship attestation exists for this exact PR head: {exc}") from exc
    try:
        raw_value = json.loads(raw_document.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise SlackExposureError(
            f"authorship attestation changed or became malformed at {path}: {exc}"
        ) from exc
    require(
        raw_value == document,
        f"authorship attestation changed while it was being verified at {path}",
    )
    require(isinstance(document, dict), f"authorship attestation at {path} must be an object")
    require(set(document) == {"schema", "payload", "signature"}, f"authorship attestation at {path} has an unknown shape")
    require(document.get("schema") == PROVENANCE_SCHEMA, f"authorship attestation at {path} has an unknown schema")
    payload = document.get("payload")
    signature = document.get("signature")
    require(isinstance(payload, dict) and isinstance(signature, dict), f"authorship attestation at {path} is incomplete")
    require(
        set(payload) == {"issued_at", "issuer", "subject", "author", "origin"}
        and payload.get("issuer") == "firstmate-pr-check"
        and isinstance(payload.get("issued_at"), str),
        f"authorship attestation at {path} has unknown issuer metadata",
    )
    require(
        signature.get("algorithm") == PROVENANCE_SIGNATURE_ALGORITHM
        and signature.get("key_id") == provenance_key_id(key)
        and isinstance(signature.get("value"), str),
        f"authorship attestation at {path} has untrusted signature metadata",
    )
    expected = hmac.new(
        key,
        canonical_json({"schema": PROVENANCE_SCHEMA, "payload": payload}),
        hashlib.sha256,
    ).hexdigest()
    require(hmac.compare_digest(signature["value"], expected), f"authorship attestation signature verification failed at {path}")
    subject = payload.get("subject")
    author = payload.get("author")
    origin = payload.get("origin")
    require(isinstance(subject, dict) and isinstance(author, dict) and isinstance(origin, dict), f"authorship attestation at {path} has no subject, author, or origin")
    expected_subject = {
        "repository": snapshot.repository,
        "pull_request": snapshot.number,
        "pr_url": snapshot.pr_url.rstrip("/"),
        "head_sha": snapshot.head_sha,
    }
    require(subject == expected_subject, f"authorship attestation at {path} conflicts with the live PR head")
    required_author = {"kind", "harness", "model", "model_family", "task_id", "task_generation", "account_identity"}
    require(set(author) == required_author, f"authorship attestation at {path} has an unknown author shape")
    for field in ("kind", "harness", "model", "model_family", "task_id", "task_generation"):
        require_provenance_string(
            author[field], f"authorship attestation at {path} field {field}"
        )
    require(author["kind"] in {"agent", "human"}, f"authorship attestation at {path} has unknown author kind")
    expected_kind = "human" if author["harness"] == "human" and author["model"] == "human-authored" else "agent"
    require(author["kind"] == expected_kind, f"authorship attestation at {path} conflicts on author kind")
    require(author["model_family"] == crosscheck_model_family(author["model"]), f"authorship attestation at {path} conflicts on model family")
    account = author["account_identity"]
    if author["model_family"] == "openai" or account is not None:
        require_provenance_string(
            account, f"authorship attestation at {path} account identity"
        )
    require(
        TASK_ID_RE.fullmatch(author["task_id"]) is not None,
        f"authorship attestation at {path} has malformed task identity",
    )
    require(
        origin.get("schema") == LAUNCH_PROVENANCE_SCHEMA
        and set(origin) == {"schema", "sha256"}
        and isinstance(origin.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", origin["sha256"]) is not None,
        f"authorship attestation at {path} has untrusted launch provenance",
    )
    launch = verify_launch_attestation(
        config, key, author["task_id"], author["task_generation"]
    )
    require(
        launch.attestation_sha256 == origin["sha256"]
        and launch.harness == author["harness"]
        and launch.model == author["model"]
        and launch.model_family == author["model_family"]
        and launch.author_account_identity == account,
        f"authorship attestation at {path} conflicts with launch-bound provenance",
    )
    return AuthorshipProvenance(
        harness=author["harness"],
        model=author["model"],
        model_family=author["model_family"],
        task_id=author["task_id"],
        task_generation=author["task_generation"],
        author_kind=author["kind"],
        author_account_identity=account,
        launch_attestation_path=launch.attestation_path,
        launch_attestation_sha256=launch.attestation_sha256,
        attestation_path=path,
        attestation_sha256=hashlib.sha256(raw_document).hexdigest(),
    )


# --- lane naming -----------------------------------------------------------------


def lane_name(reviewer: Any) -> str:
    """Name the lane that produced a ledger run, for the R6/R10 visibility rule.

    Prefers an explicit lane marker recorded by the crosscheck ledger, then
    the durable `review_family_mode` provenance the crosscheck gate records on
    every run; when the run predates both, the lane is derived from the
    reviewer profile that ran: a GLM model is the primary lane of that era and
    the retained pi/codex roster is the recorded degraded fallback.
    """

    if not isinstance(reviewer, dict):
        return "unknown lane"
    marker = reviewer.get("lane")
    if isinstance(marker, str) and marker.strip():
        name = marker.strip()
        if reviewer.get("degraded") is True and "degraded" not in name.lower():
            name += " (degraded)"
        return name
    model = str(reviewer.get("model") or "")
    harness = str(reviewer.get("harness") or "")
    family = reviewer.get("review_family_mode")
    # The crosscheck gate binds this marker to the reviewer model in both
    # directions, so it names the lane without guessing from the model string.
    if family in {"cross-family-primary", "glm-primary"}:
        return f"{model.rsplit('/', 1)[-1]} primary" if model else "cross-family primary"
    if family == "codex-fallback":
        return "pi-codex fallback (degraded)"
    lowered = model.lower()
    if "glm" in lowered:
        return "GLM-5.2 primary" if "5.2" in lowered else f"{model} primary"
    if harness in {"pi", "codex"}:
        return "pi-codex fallback (degraded)"
    if harness or model:
        return f"{harness} {model}".strip() + " lane"
    return "unknown lane"


# --- reply rendering ---------------------------------------------------------------


def escape_slack(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def clamp(text: str, limit: int) -> str:
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    if len(text) <= limit:
        return text
    return text[: limit - 12].rstrip() + " [truncated]"


@dataclasses.dataclass
class ReviewOutcome:
    ok: bool
    state: str
    lane: str | None
    reply_text: str
    tokens: dict[str, int] | None
    estimated_usd: float | None
    task_id: str


def usage_from_run(run: dict[str, Any]) -> tuple[dict[str, int] | None, float | None]:
    """Read only the legacy Slack budget contract, not economics telemetry.

    Crosscheck telemetry is observational and must not silently activate this
    lane's existing `daily_budget_usd` cap. Absent or malformed legacy usage
    is null, never guessed.
    """

    usage = run.get("usage")
    if not isinstance(usage, dict):
        return None, None
    tokens: dict[str, int] = {}
    for key in (
        "input_tokens",
        "output_tokens",
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
    ):
        raw = usage.get(key)
        if isinstance(raw, int) and not isinstance(raw, bool) and raw >= 0:
            tokens[key] = raw
    estimated: float | None = None
    for key in ("estimated_usd", "cost_usd"):
        raw = usage.get(key)
        if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw >= 0:
            estimated = float(raw)
            break
    return (tokens or None), estimated


def render_verdict_reply(
    pr_url: str,
    run: dict[str, Any],
    ledger: dict[str, Any],
    lane: str,
    report_path: Path,
    task_id: str,
) -> str:
    # Every ledger-derived value is escaped uniformly: state, lane, head,
    # summary, severities, and titles all pass through escape_slack, so no
    # reviewer- or PR-influenced string can smuggle Slack control sequences.
    state = escape_slack(clamp(str(run.get("state") or "unknown"), 40).upper())
    lines = [
        f"Crosscheck {state} for {pr_url}",
        f"Lane: {escape_slack(clamp(lane, 120))}",
        f"Task ID: {escape_slack(task_id)}",
    ]
    head = run.get("head_sha")
    require(
        isinstance(head, str) and SHA_RE.fullmatch(head) is not None,
        "the Crosscheck run has no exact reviewed head",
    )
    lines.append(f"Reviewed head: {head}")
    summary = run.get("summary")
    if isinstance(summary, str) and summary.strip():
        lines.append(f"Summary: {escape_slack(clamp(summary.strip(), MAX_SUMMARY_CHARS))}")
    findings = ledger.get("findings")
    if isinstance(findings, list) and findings:
        active = [
            finding
            for finding in findings
            if isinstance(finding, dict)
            and finding.get("lifecycle") in {"open", "claimed-fixed"}
        ]
        if active:
            lines.append(f"Active findings ({len(active)}):")
            for finding in active[:MAX_LISTED_FINDINGS]:
                title = escape_slack(clamp(str(finding.get("title") or "(untitled)"), 200))
                severity = escape_slack(clamp(str(finding.get("severity") or "unrated"), 40))
                lines.append(f"- [{severity}] {title}")
            if len(active) > MAX_LISTED_FINDINGS:
                lines.append(f"- ... and {len(active) - MAX_LISTED_FINDINGS} more in the report")
        else:
            lines.append("No active findings for this head.")
    else:
        lines.append("No active findings for this head.")
    # The report is a file on the listener's host, not a link anyone remote
    # can open; label it so nobody reads it as one.
    lines.append(f"Durable artifact: {report_path}")
    return clamp("\n".join(lines), MAX_REPLY_CHARS)


def render_stale_reply(
    pr_url: str,
    reviewed_head: str,
    current_head: str,
    lane: str,
    task_id: str,
    report_path: Path,
) -> str:
    return clamp(
        "\n".join(
            [
                f"Crosscheck STALE for {pr_url}",
                f"Lane: {escape_slack(clamp(lane, 120))}",
                f"Task ID: {escape_slack(task_id)}",
                f"Reviewed head: {reviewed_head}",
                f"Current head: {current_head}",
                f"Durable artifact: {report_path}",
                "The PR head changed during review, so the earlier verdict does not apply. Request a new review for the current head.",
            ]
        ),
        MAX_REPLY_CHARS,
    )


def render_nonverdict_reply(
    pr_url: str,
    state: str,
    reviewed_head: str,
    lane: str,
    task_id: str,
    report_path: Path,
    summary: Any,
) -> str:
    lines = [
        f"Crosscheck {escape_slack(clamp(state.upper(), 40))} for {pr_url}",
        f"Lane: {escape_slack(clamp(lane, 120))}",
        f"Task ID: {escape_slack(task_id)}",
        f"Reviewed head: {reviewed_head}",
        f"Durable artifact: {report_path}",
    ]
    if isinstance(summary, str) and summary.strip():
        lines.append(
            f"Diagnostic: {escape_slack(clamp(summary.strip(), MAX_SUMMARY_CHARS))}"
        )
    lines.append(
        "No admitted verdict was produced; this is a review or infrastructure failure, not CLEAR."
    )
    return clamp("\n".join(lines), MAX_REPLY_CHARS)


def render_failure_reply(pr_url: str, reason: str) -> str:
    body = escape_slack(clamp(redact(reason), MAX_SUMMARY_CHARS))
    return clamp(
        f"Crosscheck TOOL FAILURE for {pr_url}: {body}\n"
        "No verdict was produced; this is an infrastructure failure, not a "
        "review outcome. Retry after the failure is addressed.",
        MAX_REPLY_CHARS,
    )


# --- running the crosscheck CLI ------------------------------------------------------


def review_timeout_seconds() -> float:
    raw = os.environ.get("FM_CROSSCHECK_SLACK_REVIEW_TIMEOUT_SECONDS", "")
    if not raw:
        return DEFAULT_REVIEW_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        raise SlackExposureError(
            f"FM_CROSSCHECK_SLACK_REVIEW_TIMEOUT_SECONDS is not a number: {raw!r}"
        )
    require(0 < value <= 24 * 3600, "review timeout must be between 0 and 86400 seconds")
    return value


def crosscheck_argv(task_id: str, pr_url: str) -> list[str]:
    override = os.environ.get("FM_CROSSCHECK_SLACK_CROSSCHECK_BIN", "")
    binary = override or str(BIN_DIR / "fm-crosscheck.sh")
    return [binary, "run", task_id, pr_url]


def scrubbed_child_environment(config: Config, github_token: str) -> dict[str, str]:
    """Build the crosscheck subprocess environment.

    Only the process-neutral basics and FM_* configuration pass through; the
    Slack tokens never do, and neither does any variable whose value matches
    a registered secret other than the GitHub read credential, which is
    exported both under its configured name and as GH_TOKEN because being the
    subprocess's repository read credential is its entire purpose.
    """

    excluded = {config.app_token_env, config.bot_token_env}
    child: dict[str, str] = {}
    for key, value in os.environ.items():
        if key in excluded:
            continue
        keep = key in {"PATH", "HOME", "TMPDIR", "LANG", "USER", "SHELL"}
        keep = keep or key.startswith("LC_") or key.startswith("FM_")
        if not keep:
            continue
        if value in _SECRETS and value != github_token:
            continue
        child[key] = value
    child[config.github_token_env] = github_token
    child["GH_TOKEN"] = github_token
    return child


def make_run_review(
    config: Config,
    github_token: str,
    current_snapshot: Callable[[str], PrSnapshot] | None = None,
) -> Callable[[str, PrSnapshot, AuthorshipProvenance], ReviewOutcome]:
    fm_home_raw = os.environ.get("FM_HOME", "")
    if not fm_home_raw:
        raise SlackExposureError("FM_HOME is required to run crosscheck reviews")
    fm_home = Path(fm_home_raw).resolve()
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or fm_home / "state")
    data = Path(os.environ.get("FM_DATA_OVERRIDE") or fm_home / "data")
    resolve_current_snapshot = current_snapshot or (
        lambda pr_url: fetch_pr_snapshot(pr_url, github_token)
    )

    def run_review(
        pr_url: str,
        snapshot: PrSnapshot,
        provenance: AuthorshipProvenance,
    ) -> ReviewOutcome:
        task_id = f"slack-{secrets.token_hex(6)}"
        state.mkdir(parents=True, exist_ok=True)
        meta_lines = [
            f"harness={provenance.harness}",
            f"model={provenance.model}",
            f"author_model_family={provenance.model_family}",
            f"author_task_id={provenance.task_id}",
            f"author_task_generation={provenance.task_generation}",
            f"author_attestation_sha256={provenance.attestation_sha256}",
            f"author_launch_attestation_sha256={provenance.launch_attestation_sha256}",
        ]
        if provenance.author_account_identity:
            meta_lines.append(
                f"author_account_identity={provenance.author_account_identity}"
            )
        (state / f"{task_id}.meta").write_text(
            "\n".join(meta_lines) + "\n",
            encoding="utf-8",
        )
        task_data = data / task_id
        task_data.mkdir(parents=True, exist_ok=True)
        attestation_copy = task_data / "authorship-attestation.json"
        attestation_bytes = provenance.attestation_path.read_bytes()
        require(
            hashlib.sha256(attestation_bytes).hexdigest()
            == provenance.attestation_sha256,
            "authorship attestation changed after verification",
        )
        attestation_copy.write_bytes(attestation_bytes)
        os.chmod(attestation_copy, 0o600)
        launch_copy = task_data / "author-launch-attestation.json"
        launch_bytes = provenance.launch_attestation_path.read_bytes()
        require(
            hashlib.sha256(launch_bytes).hexdigest()
            == provenance.launch_attestation_sha256,
            "author launch attestation changed after verification",
        )
        launch_copy.write_bytes(launch_bytes)
        os.chmod(launch_copy, 0o600)
        argv = crosscheck_argv(task_id, pr_url)
        try:
            result = run_bounded(
                argv,
                timeout_seconds=review_timeout_seconds(),
                maximum_output_bytes=MAX_REVIEW_OUTPUT_BYTES,
                env=scrubbed_child_environment(config, github_token),
            )
        except BoundedIOError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, f"the crosscheck run exceeded its bounds: {exc}"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        ledger_path = data / task_id / "crosscheck-ledger.json"
        report_path = task_data / "crosscheck.md"
        if not ledger_path.is_file():
            stderr_tail = result.stderr.decode("utf-8", "replace")[-800:].strip()
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(
                    pr_url,
                    f"the crosscheck CLI exited {result.returncode} without a ledger: "
                    f"{stderr_tail or 'no diagnostic'}",
                ),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        try:
            ledger = read_bounded_json(ledger_path, maximum_bytes=MAX_LEDGER_BYTES)
        except BoundedIOError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, f"the crosscheck ledger is unreadable: {exc}"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        runs = ledger.get("runs") if isinstance(ledger, dict) else None
        if not isinstance(runs, list) or not runs or not isinstance(runs[-1], dict):
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, "the crosscheck ledger recorded no runs"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        run = runs[-1]
        lane = lane_name(run.get("reviewer"))
        tokens, estimated = usage_from_run(run)
        reviewed_head = run.get("head_sha")
        if not isinstance(reviewed_head, str) or SHA_RE.fullmatch(reviewed_head) is None:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=lane,
                reply_text=render_failure_reply(
                    pr_url, "the Crosscheck ledger recorded no exact reviewed head"
                ),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        if reviewed_head != snapshot.head_sha:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=lane,
                reply_text=render_failure_reply(
                    pr_url,
                    "the Crosscheck ledger head conflicts with the exact head admitted from Slack",
                ),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        try:
            current = resolve_current_snapshot(pr_url)
        except SlackExposureError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=lane,
                reply_text=render_failure_reply(
                    pr_url, f"post-review head verification failed: {exc}"
                ),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        if current.head_sha != reviewed_head:
            return ReviewOutcome(
                ok=False,
                state="stale",
                lane=lane,
                reply_text=render_stale_reply(
                    pr_url,
                    reviewed_head,
                    current.head_sha,
                    lane,
                    task_id,
                    report_path,
                ),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        run_state = str(run.get("state") or "unknown")
        if run_state not in {"clear", "blocking"}:
            return ReviewOutcome(
                ok=False,
                state=run_state,
                lane=lane,
                reply_text=render_nonverdict_reply(
                    pr_url,
                    run_state,
                    reviewed_head,
                    lane,
                    task_id,
                    report_path,
                    run.get("summary"),
                ),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        try:
            reply = render_verdict_reply(
                pr_url, run, ledger, lane, report_path, task_id
            )
        except SlackExposureError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=lane,
                reply_text=render_failure_reply(pr_url, str(exc)),
                tokens=tokens,
                estimated_usd=estimated,
                task_id=task_id,
            )
        return ReviewOutcome(
            ok=run_state in {"clear", "blocking"},
            state=run_state,
            lane=lane,
            reply_text=reply,
            tokens=tokens,
            estimated_usd=estimated,
            task_id=task_id,
        )

    return run_review


# --- the event-handling core (driven directly by the tests) -------------------------


def _unwired_pr_snapshot(pr_url: str) -> PrSnapshot:
    raise SlackExposureError(f"PR head resolver is not wired; refusing to review {pr_url}")


def _unwired_provenance(snapshot: PrSnapshot) -> AuthorshipProvenance:
    raise SlackExposureError(
        f"authorship provenance resolver is not wired for {snapshot.pr_url}"
    )


@dataclasses.dataclass
class MentionContext:
    config: Config
    meter: DailyMeter
    deduper: EventDeduper
    post: Callable[[str, str, str], None]  # channel, thread_ts, text
    react: Callable[[str, str, str], None]  # channel, ts, emoji name
    run_review: Callable[[str, PrSnapshot, AuthorshipProvenance], ReviewOutcome]
    pr_snapshot: Callable[[str], PrSnapshot] = _unwired_pr_snapshot
    provenance: Callable[[PrSnapshot], AuthorshipProvenance] = _unwired_provenance
    log: Callable[[str], None] = log


def usage_reply() -> str:
    return (
        "Tag me with one GitHub pull-request link to get a crosscheck review, "
        "for example: @crosscheck https://github.com/ORG/REPO/pull/123"
    )


def handle_mention(event_id: str, event: dict[str, Any], ctx: MentionContext) -> str:
    """Process one app_mention event. Returns the action taken (for tests/logs).

    Slack text is data: the only value this function extracts from it is a
    pull-request URL validated against the repository allowlist. Nothing in
    the message is executed or interpolated into a command line beyond that
    single validated URL.
    """

    channel = str(event.get("channel") or "")
    user = str(event.get("user") or "unknown")
    ts = str(event.get("ts") or "")
    thread_ts = str(event.get("thread_ts") or ts)
    text = str(event.get("text") or "")
    if not channel or not ts:
        ctx.log(f"ignoring malformed mention event {event_id}: missing channel or ts")
        return "malformed"

    if not ctx.deduper.claim(event_id):
        # A produced-but-undelivered verdict is re-posted from the stored
        # reply on redelivery; a second review is never started.
        stored = ctx.deduper.undelivered_reply(event_id)
        if stored is not None:
            return _deliver_final_reply(
                ctx, event_id, channel, thread_ts, stored, "redelivered"
            )
        ctx.log(f"duplicate delivery of event {event_id}; not starting a second review")
        return "duplicate"

    def terminal_reply(action: str, reply: str) -> str:
        return _deliver_final_reply(
            ctx, event_id, channel, thread_ts, reply, action
        )

    if channel not in ctx.config.channel_allowlist:
        return terminal_reply(
            "channel-refused",
            "This channel is not enabled for crosscheck reviews. "
            "Ask the owner to add it to the channel allowlist.",
        )

    links = extract_pr_links(text)
    if not links:
        return terminal_reply("no-link", usage_reply())
    if len(links) > 1:
        return terminal_reply(
            "multiple-links",
            "One pull-request link per request, please; I received "
            f"{len(links)}. Mention me once per PR.",
        )
    pr_url = links[0]

    repo = repo_of(pr_url)
    if repo not in ctx.config.repo_allowlist:
        allowed = ", ".join(ctx.config.repo_allowlist)
        return terminal_reply(
            "repo-refused",
            f"Refusing to review {pr_url}: repository {repo} is not in the "
            f"crosscheck repository allowlist ({allowed}). The bot's read "
            "credential is never pointed at repositories outside the allowlist.",
        )

    try:
        snapshot = ctx.pr_snapshot(pr_url)
    except Exception as exc:
        return terminal_reply(
            "head-refused",
            f"Refusing to review {pr_url}: its exact current head could not be "
            f"verified ({escape_slack(clamp(redact(str(exc)), 300))}). No review started.",
        )
    try:
        provenance = ctx.provenance(snapshot)
    except Exception as exc:
        return terminal_reply(
            "provenance-refused",
            f"Refusing to review {pr_url} at {snapshot.head_sha}: no trustworthy "
            "Firstmate/no-mistakes authorship attestation matches this exact head "
            f"({escape_slack(clamp(redact(str(exc)), 300))}). Branch names, Slack "
            "identity, and message text cannot assert the author model.",
        )

    # The request-count cap is the bound that actually binds today. The USD
    # bound remains a forward contract; observational Crosscheck telemetry
    # does not activate a spend cap in this change.
    request_id, refusal, observed = ctx.meter.begin(
        user,
        pr_url,
        event_id,
        request_cap=ctx.config.daily_request_cap,
        budget_usd=ctx.config.daily_budget_usd,
    )
    if refusal == "cap":
        return terminal_reply(
            "cap-refused",
            f"Daily crosscheck request cap reached: {int(observed)} of "
            f"{ctx.config.daily_request_cap} requests recorded for you today, "
            "so this review is not starting. The bound resets at midnight UTC.",
        )
    if refusal == "budget":
        return terminal_reply(
            "budget-refused",
            f"Daily crosscheck budget reached: ${observed:.2f} of "
            f"${ctx.config.daily_budget_usd:.2f} recorded for you today, so this "
            "review is not starting. The bound resets at midnight UTC.",
        )
    assert request_id is not None

    try:
        ctx.react(channel, ts, "hourglass_flowing_sand")
    except Exception as exc:  # a failed reaction never blocks the review
        ctx.log(f"reaction failed for event {event_id}: {exc}")
    try:
        ctx.post(
            channel,
            thread_ts,
            f"Review started for {pr_url} at {snapshot.head_sha}. Authorship was "
            f"verified from task {provenance.task_id}; findings will land in this thread.",
        )
    except Exception as exc:
        ctx.log(
            f"start acknowledgement failed for event {event_id} "
            f"({type(exc).__name__}: {exc}); review continues"
        )
    try:
        outcome = ctx.run_review(pr_url, snapshot, provenance)
    except Exception as exc:
        ctx.meter.finish(request_id, "tool-failure", None, None, None)
        reply = render_failure_reply(pr_url, f"unexpected {type(exc).__name__}: {exc}")
        return _deliver_final_reply(ctx, event_id, channel, thread_ts, reply, "failed")
    ctx.meter.finish(
        request_id,
        outcome.state,
        outcome.lane,
        outcome.tokens,
        outcome.estimated_usd,
    )
    action = f"completed:{outcome.state}" if outcome.ok else "failed"
    return _deliver_final_reply(
        ctx, event_id, channel, thread_ts, outcome.reply_text, action
    )


def revalidate_reply(ctx: MentionContext, reply: str) -> str:
    lines = reply.splitlines()
    if len(lines) < 4 or not lines[0].startswith("Crosscheck "):
        return reply
    if lines[0].startswith("Crosscheck STALE for "):
        return reply
    if not lines[3].startswith("Reviewed head: "):
        return reply
    links = extract_pr_links(lines[0])
    if len(links) != 1 or repo_of(links[0]) not in ctx.config.repo_allowlist:
        return render_failure_reply("", "Stored verdict has no allowlisted PR subject")
    pr_url = links[0]
    reviewed_head = lines[3].removeprefix("Reviewed head: ")
    try:
        require(SHA_RE.fullmatch(reviewed_head) is not None, "Stored verdict has no exact reviewed head")
        current = ctx.pr_snapshot(pr_url)
        require(SHA_RE.fullmatch(current.head_sha) is not None, "Live PR lookup returned no exact head")
    except Exception as exc:
        return render_failure_reply(pr_url, f"Cannot validate verdict head before delivery: {exc}")
    if current.head_sha != reviewed_head:
        lines[0] = f"Crosscheck STALE for {pr_url}"
        lines.insert(4, f"Current head at delivery: {current.head_sha}")
        lines.insert(5, "The reviewed verdict does not apply to the current head. Request a new review.")
        return clamp("\n".join(lines), MAX_REPLY_CHARS)
    return reply


def _deliver_final_reply(
    ctx: MentionContext,
    event_id: str,
    channel: str,
    thread_ts: str,
    reply: str,
    action: str,
) -> str:
    """Store the final reply durably, post it, and mark it delivered.

    The store happens BEFORE the post: if the post fails, the verdict is not
    lost; a redelivery of the same event re-posts the stored reply instead
    of silently deduping (and never runs a second review).
    """

    reply = revalidate_reply(ctx, reply)
    ctx.deduper.store_reply(event_id, reply)
    try:
        ctx.post(channel, thread_ts, reply)
    except Exception as exc:
        ctx.log(
            f"final reply for event {event_id} was produced but not delivered "
            f"({type(exc).__name__}: {exc}); a redelivery will re-post it"
        )
        return f"undelivered:{action}"
    ctx.deduper.mark_delivered(event_id)
    return action


# --- Slack Web API client ---------------------------------------------------------


class SlackWebClient:
    def __init__(self, bot_token: str, app_token: str) -> None:
        self._bot_token = bot_token
        self._app_token = app_token

    def _call(self, method: str, payload: dict[str, Any], token: str) -> dict[str, Any]:
        request = urllib.request.Request(
            f"https://slack.com/api/{method}",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=WEB_API_TIMEOUT_SECONDS) as response:
                body = response.read(1024 * 1024)
        except (urllib.error.URLError, OSError) as exc:
            raise SlackExposureError(f"Slack API {method} failed: {exc}") from exc
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SlackExposureError(f"Slack API {method} returned malformed JSON") from exc
        if not isinstance(value, dict) or value.get("ok") is not True:
            error = value.get("error") if isinstance(value, dict) else "unknown"
            raise SlackExposureError(f"Slack API {method} refused: {error}")
        return value

    def connections_open(self) -> str:
        value = self._call("apps.connections.open", {}, self._app_token)
        url = value.get("url")
        if not isinstance(url, str) or not url.startswith("wss://"):
            raise SlackExposureError("apps.connections.open returned no wss URL")
        return url

    def post_message(self, channel: str, thread_ts: str, text: str) -> None:
        # mrkdwn stays off so hostile finding text cannot render fake
        # emphasis, code, or links; replies are uniform plain text.
        self._call(
            "chat.postMessage",
            {
                "channel": channel,
                "thread_ts": thread_ts,
                "text": redact(text),
                "mrkdwn": False,
            },
            self._bot_token,
        )

    def add_reaction(self, channel: str, ts: str, name: str) -> None:
        self._call(
            "reactions.add",
            {"channel": channel, "timestamp": ts, "name": name},
            self._bot_token,
        )


# --- minimal RFC 6455 websocket client (client side only, TLS, masked frames) -------


class WebSocketError(RuntimeError):
    pass


class WebSocketClient:
    """The smallest websocket client that can hold a Socket Mode session.

    Text, ping/pong, and close frames only; client frames are masked as the
    RFC requires; payloads are bounded; fragmented messages are reassembled
    up to the same bound. No extensions, no subprotocols, no third-party
    dependency.
    """

    def __init__(self, url: str, timeout: float = 90.0) -> None:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "wss" or not parsed.hostname:
            raise WebSocketError(f"unsupported websocket URL scheme in {parsed.scheme!r}")
        self._host = parsed.hostname
        self._port = parsed.port or 443
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        self._resource = path
        self._timeout = timeout
        self._sock: ssl.SSLSocket | None = None
        self._buffer = b""
        # Reassembly state survives across recv_message calls so a control
        # frame interleaved into a fragmented data message never discards the
        # fragments already received.
        self._assembled = b""
        self._assembled_opcode: int | None = None

    def connect(self) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        expected_accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        raw = socket.create_connection((self._host, self._port), timeout=self._timeout)
        context = ssl.create_default_context()
        sock = context.wrap_socket(raw, server_hostname=self._host)
        handshake = (
            f"GET {self._resource} HTTP/1.1\r\n"
            f"Host: {self._host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        sock.sendall(handshake.encode("ascii"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                raise WebSocketError("connection closed during websocket handshake")
            response += chunk
            if len(response) > 64 * 1024:
                raise WebSocketError("oversized websocket handshake response")
        head, _, rest = response.partition(b"\r\n\r\n")
        status_line = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line + b" ":
            raise WebSocketError(f"websocket upgrade refused: {status_line[:200]!r}")
        accept = ""
        for line in head.split(b"\r\n")[1:]:
            name, _, value = line.partition(b":")
            if name.strip().lower() == b"sec-websocket-accept":
                accept = value.strip().decode("ascii", "replace")
        if accept != expected_accept:
            raise WebSocketError("websocket accept key mismatch")
        self._sock = sock
        self._buffer = rest

    def _read_exact(self, count: int) -> bytes:
        assert self._sock is not None
        while len(self._buffer) < count:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise WebSocketError("websocket connection closed")
            self._buffer += chunk
        value, self._buffer = self._buffer[:count], self._buffer[count:]
        return value

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        assert self._sock is not None
        mask = os.urandom(4)
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._sock.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def pong(self, payload: bytes) -> None:
        self._send_frame(0xA, payload)

    def recv_message(self) -> tuple[int, bytes]:
        """Return the next complete (opcode, payload) message."""

        while True:
            first, second = self._read_exact(2)
            fin = bool(first & 0x80)
            opcode = first & 0x0F
            if first & 0x70:
                raise WebSocketError("websocket reserved bits set without an extension")
            length = second & 0x7F
            if second & 0x80:
                raise WebSocketError("server-to-client websocket frames must be unmasked")
            if length == 126:
                (length,) = struct.unpack(">H", self._read_exact(2))
            elif length == 127:
                (length,) = struct.unpack(">Q", self._read_exact(8))
            if length > WS_MAX_PAYLOAD:
                raise WebSocketError(f"websocket frame exceeds the {WS_MAX_PAYLOAD}-byte bound")
            payload = self._read_exact(length)
            if opcode in (0x8, 0x9, 0xA):  # control frames may interleave
                if not fin:
                    raise WebSocketError("fragmented websocket control frame")
                return opcode, payload
            if opcode == 0x0:
                if self._assembled_opcode is None:
                    raise WebSocketError("websocket continuation without a first frame")
            else:
                if self._assembled_opcode is not None:
                    raise WebSocketError("interleaved websocket data messages")
                self._assembled_opcode = opcode
            self._assembled += payload
            if len(self._assembled) > WS_MAX_PAYLOAD:
                raise WebSocketError(f"websocket message exceeds the {WS_MAX_PAYLOAD}-byte bound")
            if fin:
                message_opcode = self._assembled_opcode
                message = self._assembled
                self._assembled = b""
                self._assembled_opcode = None
                return message_opcode, message

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._send_frame(0x8, struct.pack(">H", 1000))
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# --- the Socket Mode service loop ----------------------------------------------------


class SocketModeService:
    def __init__(self, config: Config) -> None:
        self.config = config
        app_token, bot_token, github_token = configured_credentials(config)
        provenance_key = load_provenance_key(config.provenance_key_file)
        self.web = SlackWebClient(bot_token=bot_token, app_token=app_token)
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        self.meter = DailyMeter(config.state_dir / "meter")
        self.deduper = EventDeduper(config.state_dir / "events")
        self.run_review = make_run_review(config, github_token)
        self._github_token = github_token
        self._provenance_key = provenance_key
        removed = sweep_state(config.state_dir)
        if removed:
            log(f"retention sweep removed {len(removed)} aged state file(s) at startup")
        self._sweeper = threading.Thread(
            target=self._sweep_loop, name="crosscheck-slack-sweeper", daemon=True
        )
        self.queue: queue.Queue[tuple[str, dict[str, Any]]] = queue.Queue(
            maxsize=REVIEW_QUEUE_LIMIT
        )
        self.workers = tuple(
            threading.Thread(
                target=self._drain,
                name=f"crosscheck-slack-worker-{index + 1}",
                daemon=True,
            )
            for index in range(REVIEW_WORKERS)
        )

    def _sweep_loop(self) -> None:
        # One retention pass per day (checked every 6 hours), plus the pass
        # already taken at startup.
        while True:
            time.sleep(6 * 3600)
            try:
                removed = sweep_state(self.config.state_dir)
                if removed:
                    log(f"retention sweep removed {len(removed)} aged state file(s)")
            except OSError as exc:
                log(f"retention sweep failed: {exc}")

    def _context(self) -> MentionContext:
        return MentionContext(
            config=self.config,
            meter=self.meter,
            deduper=self.deduper,
            post=self.web.post_message,
            react=self.web.add_reaction,
            run_review=self.run_review,
            pr_snapshot=lambda pr_url: fetch_pr_snapshot(pr_url, self._github_token),
            provenance=lambda snapshot: verify_attestation(
                self.config, self._provenance_key, snapshot
            ),
        )

    def _drain(self) -> None:
        while True:
            event_id, event = self.queue.get()
            try:
                action = handle_mention(event_id, event, self._context())
                log(f"event {event_id}: {action}")
            except Exception as exc:
                log(f"event {event_id} failed: {type(exc).__name__}: {exc}")

    def _enqueue(self, event_id: str, event: dict[str, Any]) -> None:
        try:
            self.queue.put_nowait((event_id, event))
        except queue.Full:
            channel = str(event.get("channel") or "")
            thread_ts = str(event.get("thread_ts") or event.get("ts") or "")
            log(f"review queue full; refusing event {event_id}")
            if channel and thread_ts:
                try:
                    self.web.post_message(
                        channel,
                        thread_ts,
                        f"The review queue is full ({REVIEW_QUEUE_LIMIT} pending); "
                        "try again once the current reviews finish.",
                    )
                except SlackExposureError as exc:
                    log(f"could not post queue-full refusal: {exc}")

    def _handle_envelope(self, ws: WebSocketClient, raw: bytes) -> None:
        try:
            envelope = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            log("ignoring undecodable Socket Mode payload")
            return
        if not isinstance(envelope, dict):
            return
        kind = envelope.get("type")
        if kind == "hello":
            log("Socket Mode session established")
            return
        if kind == "disconnect":
            raise WebSocketError(f"server asked to reconnect: {envelope.get('reason')}")
        envelope_id = envelope.get("envelope_id")
        if isinstance(envelope_id, str) and envelope_id:
            ws.send_text(json.dumps({"envelope_id": envelope_id}))
        if kind != "events_api":
            return
        payload = envelope.get("payload")
        if not isinstance(payload, dict):
            return
        event = payload.get("event")
        event_id = payload.get("event_id")
        if (
            isinstance(event, dict)
            and event.get("type") == "app_mention"
            and isinstance(event_id, str)
            and EVENT_ID_RE.fullmatch(event_id)
        ):
            self._enqueue(event_id, event)

    def serve_forever(self) -> NoReturn:
        for worker in self.workers:
            worker.start()
        self._sweeper.start()
        backoff = 1.0
        while True:
            try:
                url = self.web.connections_open()
                ws = WebSocketClient(url)
                ws.connect()
                backoff = 1.0
                try:
                    while True:
                        opcode, payload = ws.recv_message()
                        if opcode == 0x9:
                            ws.pong(payload)
                        elif opcode == 0x8:
                            raise WebSocketError("server closed the websocket")
                        elif opcode == 0x1:
                            self._handle_envelope(ws, payload)
                finally:
                    ws.close()
            except (WebSocketError, SlackExposureError, OSError) as exc:
                log(f"Socket Mode connection ended: {exc}; reconnecting in {backoff:.0f}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, RECONNECT_BACKOFF_CAP_SECONDS)


# --- selftest and entry ----------------------------------------------------------------


def selftest(config_path: Path) -> int:
    config = load_config(config_path)
    key = load_provenance_key(config.provenance_key_file)
    lines = [
        f"config: {config.path}",
        "schema: valid",
        f"app_token_env: {config.app_token_env} "
        f"({'set' if os.environ.get(config.app_token_env) else 'UNSET'})",
        f"bot_token_env: {config.bot_token_env} "
        f"({'set' if os.environ.get(config.bot_token_env) else 'UNSET'})",
        f"github_token_env: {config.github_token_env} "
        f"({'set' if os.environ.get(config.github_token_env) else 'UNSET'})",
        f"channel_allowlist: {len(config.channel_allowlist)} channel(s)",
        f"repo_allowlist: {', '.join(config.repo_allowlist)}",
        f"provenance_key_file: {config.provenance_key_file} (valid, key id {provenance_key_id(key)})",
        f"review_workers: {REVIEW_WORKERS} (shared core FIFO lanes)",
        "daily_request_cap: "
        + (
            f"{config.daily_request_cap} (the binding control today)"
            if config.daily_request_cap is not None
            else "null (uncapped; requests still ledgered)"
        ),
        "daily_budget_usd: "
        + (
            f"{config.daily_budget_usd:.2f} (forward contract; economics telemetry does not activate it)"
            if config.daily_budget_usd is not None
            else "null (unmetered pass-through, still ledgered)"
        ),
        f"state_dir: {config.state_dir}",
    ]
    print("\n".join(lines))
    return 0


def assert_supported_interpreter() -> None:
    """Mirror the crosscheck gate's interpreter floor.

    This process parses hostile JSON (Slack payloads, config, ledgers) through
    the same bounded-read layer as the gate, whose hostile-integer rejection
    relies on the CPython conversion limit introduced in 3.11.
    """

    minimum = (3, 11)
    if sys.version_info[:2] < minimum:
        running = ".".join(str(part) for part in sys.version_info[:3])
        refuse(
            f"interpreter inspection found Python {running}, but this listener "
            "requires 3.11 or newer because its hostile-JSON defense does not "
            "exist on older interpreters"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=TOOL, description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="start the Socket Mode listener")
    run.add_argument("--config", default="", help="config path (default: $FM_HOME/config/crosscheck-slack.json)")
    run.add_argument("--keychain-only", action="store_true", help="require service-accessible Keychain credentials; ignore token environment")
    check = subparsers.add_parser("selftest", help="validate config shape and exit")
    check.add_argument("config", nargs="?", default="", help="config path override")
    preflight = subparsers.add_parser(
        "preflight",
        help="validate config, provenance key, and central credentials",
    )
    preflight.add_argument("--config", default="", help="config path override")
    preflight.add_argument("--keychain-only", action="store_true", help="require service-accessible Keychain credentials; ignore token environment")
    attest = subparsers.add_parser(
        "attest-task",
        help="sign exact-head authorship from a Firstmate task record",
    )
    attest.add_argument("task_id")
    attest.add_argument("pr_url")
    attest.add_argument("head_sha")
    attest.add_argument("--config", default="", help="config path override")
    launch = subparsers.add_parser(
        "attest-launch",
        help="capture a task's author identity before its agent starts",
    )
    launch.add_argument("task_id")
    launch.add_argument("task_generation")
    launch.add_argument("worktree")
    launch.add_argument("harness")
    launch.add_argument("model")
    launch.add_argument("--account-home", default="")
    launch.add_argument("--config", default="", help="config path override")
    return parser


def main() -> int:
    assert_supported_interpreter()
    args = build_parser().parse_args()
    try:
        if getattr(args, "keychain_only", False):
            path = Path(args.config) if args.config else default_config_path()
            config = load_config(path)
            require(
                set(config.keychain_services) == {"app_token", "bot_token", "github_token"},
                "service requires Keychain services for all three credentials",
            )
            for name in (config.app_token_env, config.bot_token_env, config.github_token_env):
                os.environ.pop(name, None)
        if args.command == "attest-launch":
            path = Path(args.config) if args.config else default_config_path()
            config = load_config(path)
            key = load_provenance_key(config.provenance_key_file)
            account_home = Path(args.account_home) if args.account_home else None
            destination = issue_launch_attestation(
                config,
                key,
                args.task_id,
                args.task_generation,
                Path(args.worktree),
                args.harness,
                args.model,
                account_home,
            )
            print(f"launch-attested: {destination}")
            return 0
        if args.command == "attest-task":
            path = Path(args.config) if args.config else default_config_path()
            config = load_config(path)
            key = load_provenance_key(config.provenance_key_file)
            destination = issue_task_attestation(
                config, key, args.task_id, args.pr_url, args.head_sha
            )
            print(f"attested: {destination}")
            return 0
        if args.command == "preflight":
            path = Path(args.config) if args.config else default_config_path()
            config = load_config(path)
            load_provenance_key(config.provenance_key_file)
            configured_credentials(config)
            print("preflight: config, provenance key, and central credentials are ready")
            return 0
        if args.command == "selftest":
            path = Path(args.config) if args.config else default_config_path()
            return selftest(path)
        path = Path(args.config) if args.config else default_config_path()
        config = load_config(path)
        service = SocketModeService(config)
        log(
            f"starting Socket Mode listener; repos: {', '.join(config.repo_allowlist)}; "
            f"channels: {len(config.channel_allowlist)}; workers: {REVIEW_WORKERS}; request cap: "
            + (
                f"{config.daily_request_cap}/submitter/day"
                if config.daily_request_cap is not None
                else "uncapped (null)"
            )
            + "; budget: "
            + (
                f"${config.daily_budget_usd:.2f}/submitter/day "
                "(forward contract; economics telemetry does not activate it)"
                if config.daily_budget_usd is not None
                else "unmetered (null)"
            )
        )
        service.serve_forever()
    except SlackExposureError as exc:
        refuse(str(exc))
    except KeyboardInterrupt:
        log("interrupted; shutting down")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
