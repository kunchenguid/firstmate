#!/usr/bin/env python3
"""Report whether one local account profile's provider credential is usable.

This module is the single owner of firstmate's provider-credential expiry
question. It answers exactly one thing for one local account profile
directory: can that credential still authenticate, and until when. It never
logs in, never refreshes, never mutates a profile, and never emits, returns,
or persists token material - only the profile path, harness, credential file
name, classified state, and expiry instants.

Why this exists: staging a dead credential onto a cloud compartment costs a
real VM and returns a tool failure instead of a verdict. Every path that
stages a credential is expected to call this first and refuse before it
provisions anything.

Credential shapes, read exactly as the providers write them:

  codex   <profile>/auth.json        tokens.access_token (JWT `exp`, seconds),
                                     tokens.refresh_token, or a non-expiring
                                     OPENAI_API_KEY
  pi      <profile>/auth.json        openai-codex.expires (milliseconds),
                                     openai-codex.refresh
  claude  <profile>/.credentials.json
                                     claudeAiOauth.expiresAt (milliseconds),
                                     claudeAiOauth.refreshToken,
                                     claudeAiOauth.refreshTokenExpiresAt

States, most usable first:

  usable       the credential authenticates now and still will after the
               caller's margin; an API-key credential declares no expiry and
               is usable until the provider revokes it
  refreshable  the access token is expired or expires inside the margin, but
               refresh material is present and is not provably dead. A refresh
               needs the provider's auth host, so a caller whose network
               allowlist excludes that host must NOT accept this state
  expired      the access token is dead and no refresh can revive it: refresh
               material is absent, or its own declared expiry has passed
  unusable     no credential to classify: absent, a symlink, not a regular
               file, over the byte bound, malformed, or carrying no token
               material at all

`refreshable` is deliberately distinct from `usable`, and stays distinct even
where a refresher exists. `bin/fm-pi-refresh.py` renews Pi profiles on the
host, so a `refreshable` Pi profile can become `usable` there; nothing renews
a codex or claude profile, and no caller whose network excludes the provider's
auth host can turn a `refreshable` profile of any harness into a usable one
where it runs. Reporting `refreshable` therefore still means "not usable
here", and a caller that needs a live credential asks for `usable`.

Usage:
  fm-credential-expiry.py report [--json] [--margin-seconds N]
                                 [--pool-root DIR] [<profile>...]
  fm-credential-expiry.py check [--harness H] [--margin-seconds N]
                                [--min-state usable|refreshable] <profile>

`report` with no profile arguments walks the Agent Fleet account pool
(`~/.local/share/agent-fleet/accounts/<vendor>/<name>`) and prints one row per
profile. `check` exits 0 when the named profile meets `--min-state` (default
`usable`) and 1 with an operator message when it does not.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import json
import os
from pathlib import Path
import stat
import sys
import time
from typing import Any


# One provider credential is small; anything larger is not a credential we
# know how to read and is refused rather than parsed.
MAX_CREDENTIAL_BYTES = 1024 * 1024

# Default headroom a credential must still hold to count as usable. Callers
# that know their own deadline should pass it instead: a token that outlives
# the preflight but not the run is the failure this module exists to stop.
DEFAULT_MARGIN_SECONDS = 900

HARNESS_CREDENTIAL_FILE = {
    "codex": "auth.json",
    "pi": "auth.json",
    "claude": ".credentials.json",
}

POOL_VENDORS = ("codex", "pi", "claude")

STATE_RANK = {"unusable": 0, "expired": 1, "refreshable": 2, "usable": 3}
STATE_ORDER = ("unusable", "expired", "refreshable", "usable")

DEFAULT_POOL_ROOT = "~/.local/share/agent-fleet/accounts"


class CredentialExpiryError(RuntimeError):
    """One profile's credential does not meet the caller's required state."""


def _utc(seconds: float | None) -> str | None:
    if seconds is None:
        return None
    moment = datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc)
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _epoch_seconds(value: Any, *, milliseconds: bool) -> float | None:
    """Return a positive epoch instant, or None when the field is unusable.

    A zero or negative stamp is not an instant. Claude writes `expiresAt: 0`
    for a profile whose access token was cleared, so zero must read as
    "no live access token", never as "expired in 1970" and never as absent.
    """

    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    seconds = float(value) / 1000.0 if milliseconds else float(value)
    if seconds <= 0:
        return None
    return seconds


def _jwt_expiry(token: Any) -> float | None:
    """Read the `exp` claim of a JWT without verifying or retaining it."""

    if not isinstance(token, str):
        return None
    parts = token.split(".")
    if len(parts) != 3:
        return None
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(claims, dict):
        return None
    return _epoch_seconds(claims.get("exp"), milliseconds=False)


def _present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def detect_harness(profile: Path) -> str | None:
    """Name the harness that owns this profile from its credential shape."""

    claude = profile / HARNESS_CREDENTIAL_FILE["claude"]
    if claude.is_file() and not claude.is_symlink():
        return "claude"
    auth = profile / "auth.json"
    if not auth.is_file() or auth.is_symlink():
        return None
    try:
        value = json.loads(auth.read_bytes()[:MAX_CREDENTIAL_BYTES])
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict):
        return None
    if isinstance(value.get("openai-codex"), dict):
        return "pi"
    if "tokens" in value or "OPENAI_API_KEY" in value or "auth_mode" in value:
        return "codex"
    return None


def _read_credential(path: Path) -> tuple[dict[str, Any] | None, str]:
    try:
        metadata = path.lstat()
    except OSError as exc:
        return None, f"credential is unreadable at {path}: {exc.strerror or exc}"
    if not stat.S_ISREG(metadata.st_mode):
        return None, f"credential is not a regular non-symlink file at {path}"
    if metadata.st_size > MAX_CREDENTIAL_BYTES:
        return None, f"credential exceeds its {MAX_CREDENTIAL_BYTES}-byte bound at {path}"
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return None, f"credential is unreadable at {path}: {exc.strerror or exc}"
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None, f"credential is malformed JSON at {path}"
    if not isinstance(value, dict):
        return None, f"credential is not a JSON object at {path}"
    return value, ""


def _codex_facts(value: dict[str, Any]) -> dict[str, Any]:
    tokens = value.get("tokens") if isinstance(value.get("tokens"), dict) else {}
    access = tokens.get("access_token")
    refresh = tokens.get("refresh_token")
    api_key = value.get("OPENAI_API_KEY")
    return {
        "never_expires": _present(api_key) and not _present(access),
        "has_access": _present(access),
        "access_expires_at": _jwt_expiry(access),
        "has_refresh": _present(refresh),
        "refresh_expires_at": None,
    }


def _pi_facts(value: dict[str, Any]) -> dict[str, Any]:
    entry = value.get("openai-codex")
    entry = entry if isinstance(entry, dict) else {}
    access = entry.get("access")
    return {
        "never_expires": False,
        "has_access": _present(access),
        "access_expires_at": (
            _epoch_seconds(entry.get("expires"), milliseconds=True)
            or _jwt_expiry(access)
        ),
        "has_refresh": _present(entry.get("refresh")),
        "refresh_expires_at": None,
    }


def _claude_facts(value: dict[str, Any]) -> dict[str, Any]:
    oauth = value.get("claudeAiOauth")
    oauth = oauth if isinstance(oauth, dict) else {}
    return {
        "never_expires": False,
        "has_access": _present(oauth.get("accessToken")),
        "access_expires_at": _epoch_seconds(oauth.get("expiresAt"), milliseconds=True),
        "has_refresh": _present(oauth.get("refreshToken")),
        "refresh_expires_at": _epoch_seconds(
            oauth.get("refreshTokenExpiresAt"), milliseconds=True
        ),
    }


_FACT_READERS = {"codex": _codex_facts, "pi": _pi_facts, "claude": _claude_facts}


def credential_usable_through(
    value: dict[str, Any],
    *,
    harness: str,
    deadline: float,
) -> bool:
    """Whether one already-read credential remains usable past a deadline.

    Stagers that select one entry from a pooled credential call this before
    writing a snapshot.  Credential interpretation stays here with the expiry
    owner, while token material stays in the caller's already-private memory.
    """

    reader = _FACT_READERS.get(harness)
    if reader is None or not isinstance(value, dict):
        return False
    facts = reader(value)
    if facts["never_expires"]:
        return True
    return bool(
        facts["has_access"]
        and facts["access_expires_at"] is not None
        and facts["access_expires_at"] > float(deadline)
    )


def inspect_profile(
    profile: str | os.PathLike[str],
    *,
    harness: str | None = None,
    now: float | None = None,
    margin_seconds: float = DEFAULT_MARGIN_SECONDS,
) -> dict[str, Any]:
    """Classify one profile's provider credential without touching a network.

    The returned record carries the profile path, harness, credential file
    name, state, both expiry instants, and a human detail line. It never
    carries token material, and no field is derived from one.
    """

    moment = time.time() if now is None else float(now)
    path = Path(profile).expanduser()
    try:
        path = path.resolve()
    except OSError:
        path = path.absolute()
    resolved_harness = harness or detect_harness(path)
    record: dict[str, Any] = {
        "profile": str(path),
        "harness": resolved_harness or "",
        "credential": "",
        "state": "unusable",
        "expires_at": None,
        "expires_in_seconds": None,
        "refresh_expires_at": None,
        "detail": "",
    }
    if resolved_harness is None:
        record["detail"] = f"no recognizable provider credential in {path}"
        return record
    if resolved_harness not in HARNESS_CREDENTIAL_FILE:
        record["detail"] = f"no credential reader for harness {resolved_harness!r}"
        return record
    name = HARNESS_CREDENTIAL_FILE[resolved_harness]
    record["credential"] = name
    value, problem = _read_credential(path / name)
    if value is None:
        record["detail"] = problem
        return record

    facts = _FACT_READERS[resolved_harness](value)
    record["expires_at"] = _utc(facts["access_expires_at"])
    record["refresh_expires_at"] = _utc(facts["refresh_expires_at"])
    if facts["access_expires_at"] is not None:
        record["expires_in_seconds"] = int(facts["access_expires_at"] - moment)

    if facts["never_expires"]:
        record["state"] = "usable"
        record["detail"] = (
            f"{resolved_harness} api-key credential declares no expiry"
        )
        return record
    if not facts["has_access"] and not facts["has_refresh"]:
        record["detail"] = (
            f"{resolved_harness} credential at {path / name} carries no token material"
        )
        return record

    deadline = moment + max(0.0, float(margin_seconds))
    access_live = credential_usable_through(
        value, harness=resolved_harness, deadline=deadline
    )
    if access_live:
        record["state"] = "usable"
        record["detail"] = (
            f"{resolved_harness} access token is valid through {record['expires_at']}"
        )
        return record

    # An access token with no declared expiry cannot be proved dead. Refusing
    # it would be a false refusal, so it is reported as refreshable with the
    # missing expiry named rather than silently promoted to usable.
    if facts["has_access"] and facts["access_expires_at"] is None:
        record["state"] = "refreshable"
        record["detail"] = (
            f"{resolved_harness} access token declares no expiry; its liveness "
            "cannot be proved from the profile"
        )
        return record

    refresh_dead = facts["refresh_expires_at"] is not None and (
        facts["refresh_expires_at"] <= moment
    )
    if facts["has_refresh"] and not refresh_dead:
        record["state"] = "refreshable"
        expiry = record["expires_at"] or "an unrecorded instant"
        # Distinguish the two ways a credential lands here. A token that is
        # alive now but dies inside the margin is not expired, and calling it
        # expired contradicts `report`, which shows the same profile as usable
        # with a future expiry.
        if facts.get("access_expires_at") is not None and facts["access_expires_at"] > moment:
            record["detail"] = (
                f"{resolved_harness} access token expires at {expiry}, inside the "
                "window this caller needs it for; refresh material is present, "
                "which this caller cannot use where it runs"
            )
        else:
            record["detail"] = (
                f"{resolved_harness} access token expired at {expiry}; refresh "
                "material is present, which this caller cannot use where it runs"
            )
        return record

    record["state"] = "expired"
    if not facts["has_refresh"]:
        record["detail"] = (
            f"{resolved_harness} access token expired at "
            f"{record['expires_at'] or 'an unrecorded instant'} and the profile "
            "holds no refresh material"
        )
    else:
        record["detail"] = (
            f"{resolved_harness} access token expired at "
            f"{record['expires_at'] or 'an unrecorded instant'} and its refresh "
            f"material expired at {record['refresh_expires_at']}"
        )
    return record


def state_meets(state: str, minimum: str) -> bool:
    return STATE_RANK.get(state, 0) >= STATE_RANK[minimum]


def require_state(
    record: dict[str, Any], minimum: str, label: str
) -> dict[str, Any]:
    """Raise unless one inspected profile meets the caller's minimum state.

    The message names the profile, the state, and the expiry, so an operator
    reads what to re-authenticate without opening the credential.
    """

    if minimum not in STATE_RANK:
        raise CredentialExpiryError(f"unknown minimum credential state {minimum!r}")
    if state_meets(record["state"], minimum):
        return record
    raise CredentialExpiryError(
        f"{label} credential preflight refused: profile {record['profile']} is "
        f"{record['state']} (required {minimum} or better): {record['detail']}"
    )


def pool_profiles(pool_root: str | os.PathLike[str]) -> list[Path]:
    root = Path(pool_root).expanduser()
    found: list[Path] = []
    for vendor in POOL_VENDORS:
        directory = root / vendor
        if not directory.is_dir():
            continue
        for entry in sorted(directory.iterdir()):
            if entry.is_dir() and not entry.is_symlink():
                found.append(entry)
    return found


def _render_table(records: list[dict[str, Any]]) -> str:
    header = ("STATE", "HARNESS", "EXPIRES", "PROFILE")
    rows = [
        (
            record["state"],
            record["harness"] or "-",
            record["expires_at"] or "-",
            record["profile"],
        )
        for record in records
    ]
    widths = [
        max(len(header[index]), *(len(row[index]) for row in rows))
        if rows
        else len(header[index])
        for index in range(len(header))
    ]
    lines = ["  ".join(header[i].ljust(widths[i]) for i in range(len(header))).rstrip()]
    for row in rows:
        lines.append(
            "  ".join(row[i].ljust(widths[i]) for i in range(len(row))).rstrip()
        )
    return "\n".join(lines)


def _command_report(args: argparse.Namespace) -> int:
    profiles = [Path(value) for value in args.profile] or pool_profiles(args.pool_root)
    records = [
        inspect_profile(profile, margin_seconds=args.margin_seconds)
        for profile in profiles
    ]
    if args.json:
        print(json.dumps({"profiles": records}, indent=2, sort_keys=True))
    elif not records:
        print("no account profiles found", file=sys.stderr)
    else:
        print(_render_table(records))
    return 0


def _command_check(args: argparse.Namespace) -> int:
    record = inspect_profile(
        args.profile,
        harness=args.harness,
        margin_seconds=args.margin_seconds,
    )
    try:
        require_state(record, args.min_state, "account profile")
    except CredentialExpiryError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"{record['state']}: {record['detail']}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-credential-expiry.py",
        description="Classify local provider credentials by expiry, never printing token material.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    report = commands.add_parser("report", help="report every named or pooled profile")
    report.add_argument("profile", nargs="*", help="account profile directories")
    report.add_argument("--json", action="store_true", help="emit a JSON record set")
    report.add_argument(
        "--margin-seconds",
        type=float,
        default=DEFAULT_MARGIN_SECONDS,
        help="headroom a credential must hold to count as usable",
    )
    report.add_argument(
        "--pool-root",
        default=DEFAULT_POOL_ROOT,
        help="Agent Fleet account pool scanned when no profile is named",
    )
    report.set_defaults(handler=_command_report)

    check = commands.add_parser("check", help="refuse one profile below a minimum state")
    check.add_argument("profile", help="account profile directory")
    check.add_argument("--harness", choices=sorted(HARNESS_CREDENTIAL_FILE))
    check.add_argument(
        "--margin-seconds", type=float, default=DEFAULT_MARGIN_SECONDS
    )
    # Deliberately not the full STATE_ORDER: `check --min-state unusable` is a
    # gate that cannot refuse anything, which is worse than no gate because it
    # reads like one.
    check.add_argument(
        "--min-state", choices=["usable", "refreshable"], default="usable"
    )
    check.set_defaults(handler=_command_check)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
