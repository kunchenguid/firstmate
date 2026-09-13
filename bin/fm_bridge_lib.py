"""fm_bridge_lib.py - pure, Textual-free logic for the bridge terminal console.

Every function here is plain stdlib: formatting, thresholds, snapshot parsing,
key-to-command mapping, and the small quota-axi adapter used by the console's
"q" key. Kept free of any Textual import so tests/fm-bridge-console-lib.test.py
can exercise it in CI without Textual installed. bin/fm-bridge-console.py is
the only caller and owns everything that touches the terminal or a subprocess
result beyond the wrapper in run_command().

Contract owner: the fm-bridge-snapshot.v1 schema is defined once, in the
launch brief for this task pair; this module only consumes it defensively.
"""

from __future__ import annotations

import csv
import datetime as _dt
import json
import subprocess
import sys
from typing import Any

SCHEMA = "fm-bridge-snapshot.v1"

CONTEXT_AMBER_AT = 50.0
CONTEXT_RED_AT = 70.0

# Direct keys run immediately and never write anywhere.
DIRECT_KEYS: dict[str, str] = {
    "r": "refresh",
    "q": "refresh_quota",
    "u": "check_upstream",
    "p": "peek",
    "o": "open_links",
}

# Queued keys always confirm, then queue a note for firstmate; never act directly.
QUEUED_KEYS: dict[str, str] = {
    "s": "ask_firstmate",
    "/": "route",
    "f": "propose_restart",
    "U": "take_upstream",
}


class SnapshotError(ValueError):
    """Raised when snapshot text is not valid fm-bridge-snapshot.v1 JSON."""


def parse_snapshot(text: str) -> dict[str, Any]:
    """Parse and minimally validate a fm-bridge-snapshot.v1 document.

    Raises SnapshotError with a plain-English reason on any problem; never
    raises a bare JSONDecodeError or KeyError out of this function.
    """
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SnapshotError(f"snapshot is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SnapshotError("snapshot JSON must be an object")
    schema = data.get("schema")
    if schema != SCHEMA:
        raise SnapshotError(
            f"unexpected snapshot schema {schema!r}, expected {SCHEMA!r}"
        )
    return data


def context_band(percent: float | None) -> str:
    """Classify a context percent into normal/amber/red/unknown.

    unknown covers None only; a measured 0% is still "normal", never treated
    as unmeasured.
    """
    if percent is None:
        return "unknown"
    if percent >= CONTEXT_RED_AT:
        return "red"
    if percent >= CONTEXT_AMBER_AT:
        return "amber"
    return "normal"


def format_tokens(n: int | None) -> str:
    if n is None:
        return "?"
    return f"{n:,}"


def format_percent(p: float | None, digits: int = 0) -> str:
    if p is None:
        return "not measured"
    return f"{p:.{digits}f}%"


def format_context(context: dict[str, Any] | None) -> tuple[str, str]:
    """Render one agent's context cell. Returns (text, band)."""
    if not context:
        return ("not measured", "unknown")
    tokens = context.get("current_tokens")
    window = context.get("window_tokens")
    percent = context.get("percent")
    if tokens is None:
        return ("not measured", "unknown")
    band = context_band(percent)
    if window is None or percent is None:
        return (f"{format_tokens(tokens)} / ? tokens", band)
    return (
        f"{format_tokens(tokens)} / {format_tokens(window)} ({format_percent(percent)})",
        band,
    )


def format_elapsed(seconds: int | None) -> str:
    if seconds is None:
        return "?"
    seconds = int(seconds)
    if seconds < 0:
        return "?"
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def _parse_iso8601(value: str) -> _dt.datetime:
    v = value.replace("Z", "+00:00")
    return _dt.datetime.fromisoformat(v)


def format_age(generated: str | None, now: _dt.datetime | None = None) -> str:
    """Render "Ns ago" / "Nm ago" for a UTC ISO8601 timestamp.

    Returns "unknown" when generated is missing or unparsable, never "0s ago".
    """
    if not generated:
        return "unknown"
    try:
        then = _parse_iso8601(generated)
    except ValueError:
        return "unknown"
    if then.tzinfo is None:
        then = then.replace(tzinfo=_dt.timezone.utc)
    now = now or _dt.datetime.now(_dt.timezone.utc)
    delta = int((now - then).total_seconds())
    if delta < 0:
        delta = 0
    if delta < 60:
        return f"{delta}s ago"
    if delta < 3600:
        return f"{delta // 60}m ago"
    return f"{delta // 3600}h {(delta % 3600) // 60}m ago"


def format_quota_provider(entry: dict[str, Any]) -> str:
    """One quota-strip line: provider, percent left, window, reset/run-out."""
    provider = entry.get("provider", "?")
    scope = entry.get("scope")
    pct = format_percent(entry.get("percent_remaining"))
    limited_by = entry.get("limited_by") or "?"
    runway = entry.get("runway") or "unknown"
    when = entry.get("resets_at") or entry.get("projected_exhausted_at")
    when_label = "reset" if entry.get("resets_at") else "runs out"
    scope_part = f" [{scope}]" if scope and scope != "all_models" else ""
    when_part = f", {when_label} {when}" if when else ""
    return f"{provider}{scope_part}: {pct} left ({limited_by}, {runway}{when_part})"


def warnings_for_unrecorded(unrecorded_agents: list[dict[str, Any]] | None) -> list[str]:
    """One warning line per process the collector could not attribute to an agent."""
    out = []
    for row in unrecorded_agents or []:
        pid = row.get("pid", "?")
        command = row.get("command", "?")
        elapsed = format_elapsed(row.get("elapsed_seconds"))
        out.append(f"unrecorded: pid {pid} running {elapsed} - {command}")
    return out


def classify_key(key: str) -> tuple[str | None, str | None]:
    """Map a pressed key to ("direct"|"queued", action) or (None, None)."""
    if key in DIRECT_KEYS:
        return ("direct", DIRECT_KEYS[key])
    if key in QUEUED_KEYS:
        return ("queued", QUEUED_KEYS[key])
    return (None, None)


def queue_note_text(action: str, *, target: str | None = None, text: str | None = None) -> str:
    """Build the exact text handed to `fm-inbox.sh note` for one queued action.

    The console never sends this itself past the confirm step; it only builds
    the string that will be queued.
    """
    if action == "ask_firstmate":
        body = (text or "").strip()
        return f"fm-bridge: ask firstmate: {body}"
    if action == "route":
        body = (text or "").strip()
        dest = target or "main"
        return f"fm-bridge: route to {dest}: {body}"
    if action == "propose_restart":
        return f"fm-bridge: propose a fresh restart of {target} on its current work"
    if action == "take_upstream":
        return "fm-bridge: take upstream (sync branch, run tests, PR to fork)"
    raise ValueError(f"unknown queued action {action!r}")


def quota_from_quota_axi_json(raw: dict[str, Any]) -> dict[str, Any]:
    """Best-effort adapter from `quota-axi --json` shape to the snapshot's
    quota sub-object shape (providers[]/attention[]), for the console's
    standalone "q" refresh only. The collector (fm-bridge-snapshot.sh) owns
    the authoritative normalization used by the full snapshot; this exists
    only so pressing "q" does not need a full snapshot round trip.
    """
    providers_out: list[dict[str, Any]] = []
    attention_out: list[dict[str, Any]] = []
    for prov in raw.get("providers", []) or []:
        name = prov.get("provider", "?")
        state = prov.get("state") or {}
        if state.get("status") not in (None, "fresh") or state.get("stale"):
            attention_out.append(
                {
                    "provider": name,
                    "kind": state.get("status") or "stale",
                    "detail": f"quota state is {state.get('status')!r}",
                }
            )
        windows_by_id = {w.get("id"): w for w in prov.get("windows", []) or []}
        semantics = prov.get("quotaSemantics") or {}
        if semantics.get("status") not in (None, "known"):
            attention_out.append(
                {
                    "provider": name,
                    "kind": semantics.get("status") or "unknown",
                    "detail": "quota semantics not known (auth or config issue)",
                }
            )
        for avail in semantics.get("effectiveAvailability", []) or []:
            limiting = avail.get("limitingWindowIds") or []
            limited_by = limiting[0] if limiting else None
            reset = None
            if limited_by and limited_by in windows_by_id:
                reset = windows_by_id[limited_by].get("resetsAt")
            providers_out.append(
                {
                    "provider": name,
                    "scope": avail.get("scope"),
                    "percent_remaining": avail.get("effectivePercentRemaining"),
                    "spend_priority": (avail.get("selection") or {}).get("spendPriority"),
                    "runway": (avail.get("runway") or {}).get("status", "unknown"),
                    "limited_by": limited_by,
                    "resets_at": reset,
                    "projected_exhausted_at": None,
                }
            )
    return {
        "ok": True,
        "error": None,
        "observed_at": raw.get("generatedAt"),
        "providers": providers_out,
        "attention": attention_out,
    }


def parse_lavish_sessions(raw: str) -> list[dict[str, str]]:
    """Extract the sessions[N]{file,status,url,pending_prompts} rows lavish-axi
    prints when run with no arguments. Returns [] when the section is absent
    or unparsable, never raises, since this only feeds the "o" open key.
    """
    out: list[dict[str, str]] = []
    in_section = False
    for line in raw.splitlines():
        if not in_section:
            if line.startswith("sessions[") and line.rstrip().endswith(":"):
                in_section = True
            continue
        if not line.startswith("  "):
            break
        try:
            row = next(csv.reader([line.strip()]))
        except csv.Error:
            continue
        if len(row) < 4:
            continue
        out.append(
            {
                "file": row[0],
                "status": row[1],
                "url": row[2],
                "pending_prompts": row[3],
            }
        )
    return out


def run_command(
    argv: list[str], timeout: float | None = 20.0
) -> tuple[int, str, str]:
    """Run argv, returning (returncode, stdout, stderr).

    A missing executable or a timeout is reported as a synthetic non-zero
    return with the reason in stderr, never an uncaught exception, so a
    caller can always show it plainly instead of crashing.
    """
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return (proc.returncode, proc.stdout, proc.stderr)
    except FileNotFoundError as exc:
        return (127, "", f"command not found: {exc}")
    except subprocess.TimeoutExpired:
        return (124, "", f"timed out after {timeout}s: {' '.join(argv)}")


if __name__ == "__main__":  # pragma: no cover - manual smoke aid only
    print(f"fm_bridge_lib loaded from {__file__}", file=sys.stderr)
