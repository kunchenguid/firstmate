#!/usr/bin/env python3
"""Bounded runtime-incident triage and lifecycle ledger.

The triage command is read-only with respect to repositories, workers,
deployments, providers, and managed services.  Its only write is an atomic
incident record under state/incidents so status views can expose progress.

Usage:
  fm-runtime-incident.py triage --incident ID --repo PATH --summary TEXT
      [--evidence FILE] [--scan-root PATH]... [--term WORD]... [--json]
  fm-runtime-incident.py approve --incident ID --kind KIND --note TEXT [--json]
  fm-runtime-incident.py repair --incident ID --note TEXT [--json]
  fm-runtime-incident.py verify --incident ID --evidence FILE [--json]
  fm-runtime-incident.py status [--incident ID] [--json] [--compact]

Evidence is a JSON object.  Supported observations are:
  production: {origin, commit, proposed_hotfix_commit, routing_mismatch,
               proposed_hotfix_present, deployment_failed, health}
  runtime: {errors:[{source,name,kind,status,code}], defect_proven,
            defect_evidence:[...], reproduction, proven_path}
  external_providers: [{name,status,code}]
  local_services: [{name,status}]
  diagnosis: {classification, probable_root_cause, supporting_evidence,
              code_change_required}
  approval: {required,kind,request}
  verification: {runtime_path_ok, companion_connectivity_required,
                 checks:[{scope,name,status,evidence}]}

The diagnosis is agent-adjudicated input, not a script inference from raw
observations.  Omit it, or use unknown/not yet proven, while evidence remains
ambiguous.  The script validates that an actionable diagnosis has the exact
proof, authority, and approval mechanics required by its selected workflow.

The command never executes a repair.  When the adjudicated workflow requires
captain approval, obtain and record that exact approval before performing the
narrow provider or service operation.  Use `repair` to record either that
completed operation or a code fix completed through the normal release process,
then use `verify` with fresh end-to-end evidence.  A code-change workflow is
ready only when triage returns `code_change_required: yes`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Callable, Iterable
from urllib.parse import unquote, urlparse


SCHEMA = "fm-runtime-incident.v1"
STATUS_SCHEMA = "fm-runtime-incidents.v1"
FLOW = ["triage", "diagnosis", "approval", "repair", "verification"]
INCIDENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MAX_EVIDENCE_BYTES = 1024 * 1024
MAX_COPIES = 64
DEFAULT_STATUS_LIMIT = 20
MAX_BRANCHES_PER_COPY = 100
MAX_AGGREGATE_ITEMS = 256
MAX_SCAN_DEPTH = 3
MAX_SCAN_ENTRIES_TOTAL = 4096
GIT_TIMEOUT = 4
CREW_STATE_TIMEOUT = 12
STATE_READ_LIMIT = 1024 * 1024
TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,}")
STOP_WORDS = {
    "about", "after", "again", "against", "being", "build", "change",
    "current", "during", "error", "failure", "firstmate", "from", "have",
    "incident", "into", "project", "production", "runtime", "should",
    "that", "their", "then", "there", "these", "this", "through", "using",
    "when", "where", "which", "with", "worker", "worktree",
}
VERIFICATION_PASS = {"healthy", "ok", "pass", "passing"}
VERIFICATION_REQUIRED_SCOPES = {
    "production_identity",
    "repaired_component_health",
    "user_visible_path",
}
VERIFICATION_OPTIONAL_SCOPES = {"companion_connectivity"}
DIAGNOSIS_CATEGORIES = {
    "application code defect",
    "deployment/routing defect",
    "external dependency, quota, billing, credential, or configuration failure",
    "local background-service failure",
    "unknown",
}
CODE_CHANGE_DECISIONS = {"yes", "no", "not yet proven"}


class IncidentError(RuntimeError):
    """Expected refusal or invalid input."""


def utc_now() -> str:
    override = os.environ.get("FM_INCIDENT_NOW")
    if override:
        try:
            parsed = dt.datetime.fromisoformat(override.replace("Z", "+00:00"))
        except ValueError as exc:
            raise IncidentError("FM_INCIDENT_NOW must be an ISO-8601 timestamp") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def paths() -> dict[str, Path]:
    script_root = Path(__file__).resolve().parent.parent
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", script_root)).resolve()
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", root))).resolve()
    return {
        "root": root,
        "home": home,
        "state": Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")).resolve(),
        "data": Path(os.environ.get("FM_DATA_OVERRIDE", home / "data")).resolve(),
        "projects": Path(os.environ.get("FM_PROJECTS_OVERRIDE", home / "projects")).resolve(),
    }


def validate_incident_id(value: str) -> str:
    if not INCIDENT_RE.fullmatch(value):
        raise IncidentError("incident id must use only letters, numbers, dot, underscore, or dash")
    return value


def run_git(repo: Path, *args: str, check: bool = False) -> str | None:
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=GIT_TIMEOUT,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        if check:
            raise IncidentError(f"git inspection timed out or failed for {repo}")
        return None
    if result.returncode != 0:
        if check:
            raise IncidentError(f"not a readable Git repository: {repo}")
        return None
    return result.stdout.rstrip("\n")


def canonical_repo(path: Path) -> Path:
    value = run_git(path, "rev-parse", "--show-toplevel", check=True)
    assert value is not None
    return Path(value).resolve()


def commit_is_ancestor(repo: Path, ancestor: str | None, descendant: str | None) -> bool:
    if not ancestor or not descendant:
        return False
    return run_git(repo, "merge-base", "--is-ancestor", ancestor, descendant) is not None


def forge_origin_key(host: str, path: str, port: int | None = None) -> str | None:
    normalized_host = host.lower().strip("[]").rstrip(".")
    normalized_path = re.sub(r"/+", "/", unquote(path)).strip("/").removesuffix(".git")
    if not normalized_host or not normalized_path:
        return None
    host_key = f"[{normalized_host}]" if ":" in normalized_host else normalized_host
    authority = f"{host_key}:{port}" if port is not None else host_key
    return f"forge://{authority}/{normalized_path}"


def normalize_origin(value: str | None, checkout: Path | None = None) -> str | None:
    if not value:
        return None
    value = value.strip()
    if value.lower().startswith("file:"):
        parsed = urlparse(value)
        path_value = unquote(parsed.path)
        if parsed.netloc and parsed.netloc.lower() != "localhost":
            path_value = f"//{parsed.netloc}{path_value}"
        path = Path(path_value).expanduser()
        if not path.is_absolute():
            if checkout is None:
                return None
            path = checkout / path
        return "file://" + str(path.resolve())
    if "://" in value:
        parsed = urlparse(value)
        try:
            port = parsed.port
        except ValueError:
            return None
        default_port = {
            "git": 9418,
            "http": 80,
            "https": 443,
            "ssh": 22,
        }.get(parsed.scheme.lower())
        if port == default_port:
            port = None
        return forge_origin_key(parsed.hostname or "", parsed.path, port)
    match = re.match(r"^(?:(?P<user>[^@/:]+)@)?(?P<host>[^:]+):(?P<path>.+)$", value)
    if match:
        return forge_origin_key(match.group("host"), match.group("path"))
    path = Path(value).expanduser()
    if not path.is_absolute():
        if checkout is None:
            return None
        path = checkout / path
    return "file://" + str(path.resolve())


def git_default_branch(repo: Path) -> str | None:
    ref = run_git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if ref and ref.startswith("origin/"):
        return ref.removeprefix("origin/")
    for name in ("main", "master"):
        if run_git(repo, "show-ref", "--verify", "--quiet", f"refs/remotes/origin/{name}") is not None:
            return name
    return None


def commit_epoch(repo: Path, ref: str | None) -> int | None:
    if not ref:
        return None
    value = run_git(repo, "show", "-s", "--format=%ct", ref)
    if value and value.isdigit():
        return int(value)
    return None


def repo_record(path: Path, *, include_branches: bool = False) -> dict[str, Any] | None:
    top_value = run_git(path, "rev-parse", "--show-toplevel")
    if not top_value:
        return None
    top = Path(top_value).resolve()
    origin_raw = run_git(top, "remote", "get-url", "origin")
    origin = normalize_origin(origin_raw, top)
    branch = run_git(top, "symbolic-ref", "--quiet", "--short", "HEAD")
    head = run_git(top, "rev-parse", "HEAD")
    common_dir_raw = run_git(top, "rev-parse", "--git-common-dir")
    common_dir = None
    if common_dir_raw:
        candidate = Path(common_dir_raw)
        common_dir = str((top / candidate).resolve() if not candidate.is_absolute() else candidate.resolve())
    default_branch = git_default_branch(top)
    remote_ref = f"refs/remotes/origin/{default_branch}" if default_branch else None
    remote_head = run_git(top, "rev-parse", remote_ref) if remote_ref else None
    status = run_git(top, "status", "--porcelain", "--untracked-files=normal")
    branches_value = None
    if include_branches:
        branches_value = run_git(
            top,
            "for-each-ref",
            f"--count={MAX_BRANCHES_PER_COPY + 1}",
            "--format=%(refname:short)\t%(objectname)",
            "refs/heads",
        )
    branches: list[dict[str, str]] = []
    branch_lines = (branches_value or "").splitlines()
    branches_omitted_at_least = max(0, len(branch_lines) - MAX_BRANCHES_PER_COPY)
    for line in branch_lines[:MAX_BRANCHES_PER_COPY]:
        name, _, sha = line.partition("\t")
        if name and sha:
            branches.append({"name": name, "commit": sha})
    return {
        "path": str(top),
        "common_dir": common_dir,
        "origin": origin,
        "branch": branch,
        "detached": branch is None,
        "head": head,
        "head_epoch": commit_epoch(top, head),
        "default_branch": default_branch,
        "remote_default_head": remote_head,
        "remote_default_epoch": commit_epoch(top, remote_head),
        "clean": status == "",
        "branches": branches,
        "branches_omitted_at_least": branches_omitted_at_least,
    }


def parse_worktree_rows(repo: Path) -> list[dict[str, Any]]:
    value = run_git(repo, "worktree", "list", "--porcelain") or ""
    rows: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in value.splitlines() + [""]:
        if not line:
            if current:
                path = Path(current["path"])
                rows.append({
                    "path": str(path.resolve()),
                    "head": current.get("head"),
                    "branch": current.get("branch"),
                    "detached": current.get("detached", False),
                    "present": path.exists(),
                })
                current = {}
            continue
        key, _, val = line.partition(" ")
        if key == "worktree":
            current["path"] = val
        elif key == "HEAD":
            current["head"] = val
        elif key == "branch":
            current["branch"] = val.removeprefix("refs/heads/")
        elif key == "detached":
            current["detached"] = True
    return rows


def bounded_worktrees(
    repo: Path,
    rows: list[dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], int]:
    parsed = rows if rows is not None else parse_worktree_rows(repo)
    shown: list[dict[str, Any]] = []
    for row in parsed[:MAX_COPIES]:
        record = repo_record(Path(row["path"])) if row["present"] else None
        shown.append({**row, "clean": record.get("clean") if record else None})
    return shown, max(0, len(parsed) - MAX_COPIES)


def meta_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        if path.stat().st_size > STATE_READ_LIMIT:
            return values
        for line in path.read_text(errors="replace").splitlines():
            key, sep, value = line.partition("=")
            if sep and key and key not in values:
                values[key] = value
    except OSError:
        pass
    return values


def registered_paths(state: Path) -> tuple[set[Path], int]:
    result: set[Path] = set()
    if not state.is_dir():
        return result, 0
    meta_paths = sorted(state.glob("*.meta"))
    for meta in meta_paths[:MAX_COPIES]:
        values = meta_values(meta)
        if values.get("remote_host"):
            continue
        for key in ("worktree", "project", "home"):
            value = values.get(key)
            if value and value.startswith("/"):
                result.add(Path(value))
    return result, max(0, len(meta_paths) - MAX_COPIES)


def scan_for_repos(
    root: Path,
    entry_budget: int,
    max_depth: int = MAX_SCAN_DEPTH,
) -> tuple[list[Path], int, int, bool]:
    if not root.is_dir():
        return [], 0, 0, False
    repositories: list[Path] = []
    omitted_at_least = 0
    entries_visited = 0
    stack: list[tuple[Path, int]] = [(root, 0)]
    while stack:
        current, depth = stack.pop()
        children: list[Path] = []
        is_repository = False
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    if entries_visited >= entry_budget:
                        return repositories, omitted_at_least, entries_visited, True
                    entries_visited += 1
                    try:
                        if entry.name == ".git" and (
                            entry.is_file(follow_symlinks=False)
                            or entry.is_dir(follow_symlinks=False)
                        ):
                            is_repository = True
                        elif (
                            depth < max_depth
                            and entry.name not in {".cache", "node_modules", "vendor"}
                            and entry.is_dir(follow_symlinks=False)
                        ):
                            children.append(Path(entry.path))
                    except OSError:
                        continue
        except OSError:
            continue
        if is_repository:
            if len(repositories) >= MAX_COPIES:
                omitted_at_least += 1
                return repositories, omitted_at_least, entries_visited, False
            repositories.append(current)
            continue
        stack.extend((child, depth + 1) for child in reversed(sorted(children, key=str)))
    return repositories, omitted_at_least, entries_visited, False


def collect_repositories(repo: Path, state: Path, projects: Path, scan_roots: list[Path]) -> dict[str, Any]:
    canonical = canonical_repo(repo)
    primary = repo_record(canonical, include_branches=True)
    if not primary or not primary["origin"]:
        raise IncidentError(f"canonical repository has no readable origin remote: {canonical}")
    candidates: set[Path] = {canonical}
    registered, registered_omitted = registered_paths(state)
    candidates.update(registered)
    candidate_worktree_rows = parse_worktree_rows(canonical)
    candidate_worktrees_shown = candidate_worktree_rows[:MAX_COPIES]
    candidate_worktrees_omitted = max(0, len(candidate_worktree_rows) - MAX_COPIES)
    candidates.update(Path(row["path"]) for row in candidate_worktrees_shown)
    project_paths: list[Path] = []
    project_omitted = 0
    if projects.is_dir():
        project_paths = sorted((path for path in projects.iterdir() if path.is_dir()), key=str)
        candidates.update(project_paths[:MAX_COPIES])
        project_omitted = max(0, len(project_paths) - MAX_COPIES)
    scan_omitted_at_least = 0
    scan_entries_visited = 0
    scan_truncated_roots = 0
    for index, root in enumerate(scan_roots):
        remaining_entry_budget = MAX_SCAN_ENTRIES_TOTAL - scan_entries_visited
        if remaining_entry_budget <= 0:
            scan_truncated_roots += len(scan_roots) - index
            break
        scanned, omitted, entries_visited, truncated = scan_for_repos(
            root,
            remaining_entry_budget,
        )
        scan_omitted_at_least += omitted
        scan_entries_visited += entries_visited
        for candidate in scanned:
            candidates.add(candidate)
        if truncated:
            scan_truncated_roots += len(scan_roots) - index
            break

    ordered_candidates = [canonical] + sorted((path for path in candidates if path != canonical), key=str)
    candidate_omitted = max(0, len(ordered_candidates) - MAX_COPIES)
    ordered_candidates = ordered_candidates[:MAX_COPIES]

    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for candidate in ordered_candidates:
        record = repo_record(candidate, include_branches=True)
        if not record or record["path"] in seen:
            continue
        seen.add(record["path"])
        if record["origin"] == primary["origin"]:
            records.append(record)

    if not records:
        records = [primary]
    for row in records:
        row["stale_remote"] = any(
            other["remote_default_head"] != row["remote_default_head"]
            and commit_is_ancestor(
                Path(other["path"]),
                row["remote_default_head"],
                other["remote_default_head"],
            )
            for other in records
        )
    surviving_heads = sorted({
        row["remote_default_head"]
        for row in records
        if not row["stale_remote"] and row["remote_default_head"]
    })
    remote_default_conflict = len(surviving_heads) > 1
    for row in records:
        row["current_main"] = bool(
            row["remote_default_head"]
            and row["head"] == row["remote_default_head"]
            and row["branch"] == row["default_branch"]
            and row["clean"]
            and not row["stale_remote"]
            and not remote_default_conflict
        )
    current_main = [row for row in records if row["current_main"]]
    fallback_candidates = [row for row in records if not row["stale_remote"]]
    if current_main:
        authoritative = sorted(current_main, key=lambda row: (row["path"] != str(canonical), row["path"]))[0]
        authoritative_worktree: str | None = authoritative["path"]
    elif not remote_default_conflict:
        authoritative = sorted(
            fallback_candidates,
            key=lambda row: (
                -(row["remote_default_epoch"] or -1),
                row["path"] != str(canonical),
                row["path"],
            ),
        )[0]
        authoritative_worktree = None
    else:
        authoritative = next(
            (row for row in fallback_candidates if row["path"] == str(canonical)),
            fallback_candidates[0],
        )
        authoritative_worktree = None

    authority_path = Path(authoritative["path"])
    authority_worktree_rows = (
        candidate_worktree_rows
        if authority_path == canonical
        else parse_worktree_rows(authority_path)
    )
    worktrees_shown, worktrees_omitted = bounded_worktrees(authority_path, authority_worktree_rows)

    common_dirs = {row["common_dir"] for row in records if row["common_dir"]}
    detached = [row["path"] for row in records if row["detached"]]
    superseded = [row["path"] for row in records if row["stale_remote"]]
    branch_budget = MAX_AGGREGATE_ITEMS
    for row in records:
        branches = row["branches"]
        shown = branches[:branch_budget]
        row["branches"] = shown
        row["branches_omitted_at_least"] += len(branches) - len(shown)
        branch_budget -= len(shown)
    all_branches = [
        {"repository": row["path"], **branch}
        for row in records
        for branch in row["branches"]
    ]
    branch_omitted_at_least = sum(row["branches_omitted_at_least"] for row in records)
    return {
        "canonical_repository": str(canonical),
        "canonical_remote": primary["origin"],
        "authoritative_repository": authoritative["path"],
        "authoritative_worktree": authoritative_worktree,
        "authoritative_default_branch": authoritative["default_branch"],
        "authoritative_remote_head": authoritative["remote_default_head"] if not remote_default_conflict else None,
        "remote_default_candidates": surviving_heads,
        "remote_default_conflict": remote_default_conflict,
        "copies": records,
        "worktrees": worktrees_shown,
        "branches": all_branches,
        "multiple_copies_same_origin": len(common_dirs) > 1,
        "detached_checkouts": detached,
        "superseded_continuations": superseded,
        "inventory": {
            "registered_worker_metadata": {
                "shown": min(MAX_COPIES, len(list(state.glob("*.meta")))) if state.is_dir() else 0,
                "omitted": registered_omitted,
            },
            "candidate_worktrees": {
                "repository": str(canonical),
                "shown": len(candidate_worktrees_shown),
                "omitted": candidate_worktrees_omitted,
            },
            "worktrees": {
                "repository": authoritative["path"],
                "shown": len(worktrees_shown),
                "omitted": worktrees_omitted,
            },
            "project_directories": {
                "shown": min(MAX_COPIES, len(project_paths)) if projects.is_dir() else 0,
                "omitted": project_omitted,
            },
            "scan_repositories": {"omitted_at_least": scan_omitted_at_least},
            "scan_entries": {
                "visited": scan_entries_visited,
                "truncated_roots": scan_truncated_roots,
            },
            "candidate_paths": {"shown": len(ordered_candidates), "omitted": candidate_omitted},
            "copies": {
                "shown": len(records),
                "complete": not any(
                    (
                        candidate_omitted,
                        candidate_worktrees_omitted,
                        registered_omitted,
                        worktrees_omitted,
                        project_omitted,
                        scan_omitted_at_least,
                        scan_truncated_roots,
                    )
                ),
            },
            "branches": {"shown": len(all_branches), "omitted_at_least": branch_omitted_at_least},
        },
    }


def backlog_objectives(data: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    path = data / "backlog.md"
    try:
        if path.stat().st_size > STATE_READ_LIMIT:
            return result
        for line in path.read_text(errors="replace").splitlines():
            match = re.match(r"^- \[[ xX]\] ([A-Za-z0-9._-]+) - (.*?)(?: \([^)]*:|$)", line)
            if match:
                result[match.group(1)] = match.group(2).strip()
    except OSError:
        pass
    return result


def brief_objective(data: Path, task_id: str) -> str | None:
    path = data / task_id / "brief.md"
    try:
        if path.stat().st_size > STATE_READ_LIMIT:
            return None
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    in_task = False
    for line in lines:
        if line.strip() == "# Task":
            in_task = True
            continue
        if in_task and line.startswith("#"):
            break
        if in_task and line.strip():
            return line.strip()[:240]
    return None


def latest_reported_event(state: Path, task_id: str) -> dict[str, Any]:
    path = state / f"{task_id}.status"
    try:
        if path.stat().st_size > STATE_READ_LIMIT:
            return {"line": None, "historical": True, "available": False, "reason": "status record too large"}
        lines = [line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
    except OSError:
        return {"line": None, "historical": True, "available": False, "reason": "no status event"}
    if not lines:
        return {"line": None, "historical": True, "available": False, "reason": "no status event"}
    return {"line": lines[-1][:240], "historical": True, "available": True, "reason": None}


def current_worker_state(state: Path, task_id: str) -> dict[str, Any]:
    executable = os.environ.get("FM_CREW_STATE_BIN") or str(Path(__file__).with_name("fm-crew-state.sh"))
    env = os.environ.copy()
    env["FM_STATE_OVERRIDE"] = str(state)
    try:
        result = subprocess.run(
            [executable, task_id],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=CREW_STATE_TIMEOUT,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"state": "unknown", "source": "none", "detail": "current-state authority unavailable"}
    line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
    match = re.fullmatch(r"state: ([a-z-]+) · source: ([a-z-]+)(?: · (.*))?", line)
    if result.returncode != 0 or not match:
        return {"state": "unknown", "source": "none", "detail": "current-state authority unreadable"}
    return {"state": match.group(1), "source": match.group(2), "detail": match.group(3) or None}


def terms(value: str) -> set[str]:
    return {
        token.lower()
        for token in TOKEN_RE.findall(value)
        if len(token) >= 4 and token.lower() not in STOP_WORDS
    }


def worker_age(meta: Path, values: dict[str, str], now: str) -> int | None:
    epoch: int | None = None
    match = re.match(r"^s([0-9]+)\.", values.get("spawn_gen", ""))
    if match:
        epoch = int(match.group(1))
    if epoch is None:
        try:
            epoch = int(meta.stat().st_mtime)
        except OSError:
            return None
    return max(0, int(parse_time(now).timestamp()) - epoch)


def collect_workers(
    state: Path,
    data: Path,
    repo_info: dict[str, Any],
    incident_summary: str,
    supplied_terms: list[str],
) -> dict[str, Any]:
    objectives = backlog_objectives(data)
    incident_terms = terms(incident_summary + " " + " ".join(supplied_terms))
    copy_by_path = {row["path"]: row for row in repo_info["copies"]}
    authoritative_path = repo_info["authoritative_worktree"] or repo_info["authoritative_repository"]
    now = utc_now()
    registry: list[dict[str, Any]] = []
    active: list[dict[str, Any]] = []
    stale: list[dict[str, str]] = []
    wrong: list[dict[str, str]] = []
    drifted: list[dict[str, str]] = []
    if not state.is_dir():
        return {
            "registry_entries": [], "active": [], "stale_registry_entries": [],
            "wrong_worktree": [], "scope_drifted": [],
            "inventory": {"shown": 0, "omitted": 0},
        }

    meta_paths = sorted(state.glob("*.meta"))
    for meta in meta_paths[:MAX_COPIES]:
        task_id = meta.stem
        values = meta_values(meta)
        cwd_value = values.get("worktree") or values.get("home") or values.get("project")
        remote_host = values.get("remote_host") or None
        remote_directory = f"{remote_host}:{cwd_value}" if remote_host and cwd_value else None
        cwd = (
            Path(cwd_value).resolve()
            if not remote_host and cwd_value and cwd_value.startswith("/")
            else None
        )
        cwd_exists = bool(cwd and cwd.exists())
        cwd_record = repo_record(cwd) if cwd_exists else None
        objective = objectives.get(task_id) or brief_objective(data, task_id) or "objective unavailable"
        reported_event = latest_reported_event(state, task_id)
        current_state = current_worker_state(state, task_id)
        is_active = current_state["state"] in {"working", "parked", "blocked", "paused"}
        active_value: bool | None = None if current_state["state"] == "unknown" else is_active
        objective_terms = terms(objective + " " + (current_state["detail"] or ""))
        match_value: bool | None
        match_reason: str
        repository_match: bool | None = None
        wrong_worktree: bool | None = None
        if remote_host and (not cwd_value or not cwd_value.startswith("/")):
            repository_match = False
            match_value = False
            match_reason = "registered remote working directory is absent"
            wrong_worktree = True
        elif not remote_host and (not cwd or not cwd_exists):
            repository_match = False
            match_value = False
            match_reason = "registered working directory is absent"
            wrong_worktree = True
        elif not remote_host and (
            not cwd_record or cwd_record["origin"] != repo_info["canonical_remote"]
        ):
            repository_match = False
            match_value = False
            match_reason = "worker is operating in a different repository"
            wrong_worktree = True
        elif incident_terms and objective_terms:
            if not remote_host:
                repository_match = True
                wrong_worktree = False
            overlap = sorted(incident_terms & objective_terms)
            match_value = True if overlap else None
            match_reason = (
                f"matching terms: {', '.join(overlap)}"
                if overlap
                else "no lexical overlap; semantic relevance is unknown"
            )
        else:
            if not remote_host:
                repository_match = True
                wrong_worktree = False
            match_value = None
            match_reason = "insufficient objective terms to prove relevance"

        registered_copy = copy_by_path.get(str(cwd)) if cwd and not remote_host else None
        stale_path = bool(registered_copy and registered_copy["stale_remote"])
        if cwd_record and not remote_host and registered_copy is None:
            worker_remote_head = cwd_record.get("remote_default_head")
            authoritative_remote_head = repo_info.get("authoritative_remote_head")
            if worker_remote_head and authoritative_remote_head:
                stale_path = bool(
                    worker_remote_head != authoritative_remote_head
                    and commit_is_ancestor(
                        Path(repo_info["authoritative_repository"]),
                        worker_remote_head,
                        authoritative_remote_head,
                    )
                )
                if not stale_path and worker_remote_head != authoritative_remote_head:
                    wrong_worktree = None
            else:
                wrong_worktree = None
        if stale_path:
            repository_match = False
            wrong_worktree = True
            match_value = False
            match_reason = "registered path is a superseded repository copy"
        entry = {
            "id": task_id,
            "working_directory": remote_directory if remote_host else str(cwd) if cwd else cwd_value,
            "objective": objective,
            "current_state": current_state,
            "latest_reported_event": reported_event,
            "age_seconds": worker_age(meta, values, now),
            "active": active_value,
            "activity_matches_incident": match_value,
            "match_reason": match_reason,
            "repository_match": repository_match,
            "wrong_worktree": wrong_worktree,
            "authoritative_worktree": authoritative_path,
            "backend": values.get("backend", "tmux"),
            "kind": values.get("kind", "ship"),
        }
        if remote_host:
            entry["remote_host"] = remote_host
        registry.append(entry)
        if is_active:
            active.append(entry)
        if remote_host and (not cwd_value or not cwd_value.startswith("/")):
            stale.append({
                "id": task_id,
                "path": remote_directory or remote_host,
                "reason": "remote path is absent",
            })
        elif not remote_host and (not cwd or not cwd_exists):
            stale.append({"id": task_id, "path": cwd_value or "", "reason": "path is absent"})
        elif stale_path:
            stale.append({"id": task_id, "path": str(cwd), "reason": "path is superseded by newer origin/main evidence"})
        if is_active and wrong_worktree is True:
            wrong.append({
                "id": task_id,
                "path": entry["working_directory"] or "",
                "reason": match_reason,
            })
        if is_active and match_value is False:
            drifted.append({"id": task_id, "activity": current_state["state"], "reason": match_reason})
    return {
        "registry_entries": registry,
        "active": active,
        "stale_registry_entries": stale,
        "wrong_worktree": wrong,
        "scope_drifted": drifted,
        "inventory": {
            "shown": min(len(meta_paths), MAX_COPIES),
            "omitted": max(0, len(meta_paths) - MAX_COPIES),
        },
    }


def load_evidence(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        if path.stat().st_size > MAX_EVIDENCE_BYTES:
            raise IncidentError(f"evidence exceeds {MAX_EVIDENCE_BYTES} bytes")
        value = json.loads(path.read_text())
    except OSError as exc:
        raise IncidentError(f"cannot read evidence: {path}") from exc
    except json.JSONDecodeError as exc:
        raise IncidentError(f"evidence is not valid JSON: {path}") from exc
    if not isinstance(value, dict):
        raise IncidentError("evidence must be a JSON object")
    return value


def list_of_objects(value: Any) -> list[dict[str, Any]]:
    return [row for row in value if isinstance(row, dict)] if isinstance(value, list) else []


def bounded_items(values: list[Any]) -> tuple[list[Any], int]:
    return values[:MAX_AGGREGATE_ITEMS], max(0, len(values) - MAX_AGGREGATE_ITEMS)


def compact(value: Any, maximum: int = 160) -> str:
    text = re.sub(r"\s+", " ", str(value)).strip()
    return text[:maximum]


def unique_strings(values: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value and value not in seen:
            result.append(value)
            seen.add(value)
    return result


def record_agent_diagnosis(evidence: dict[str, Any], repo_info: dict[str, Any]) -> dict[str, Any]:
    production = evidence.get("production") if isinstance(evidence.get("production"), dict) else {}
    runtime = evidence.get("runtime") if isinstance(evidence.get("runtime"), dict) else {}
    runtime_errors = list_of_objects(runtime.get("errors"))
    providers = list_of_objects(evidence.get("external_providers"))
    services = list_of_objects(evidence.get("local_services"))
    diagnosis_input = evidence.get("diagnosis") if isinstance(evidence.get("diagnosis"), dict) else None
    approval_input = evidence.get("approval") if isinstance(evidence.get("approval"), dict) else {}

    production_origin = normalize_origin(production.get("origin")) if isinstance(production.get("origin"), str) else None

    deployed = production.get("commit") if isinstance(production.get("commit"), str) else None
    proposed = production.get("proposed_hotfix_commit") if isinstance(production.get("proposed_hotfix_commit"), str) else None
    authoritative = Path(repo_info["authoritative_repository"])
    hotfix_already_deployed = bool(
        production.get("proposed_hotfix_present") is True
        or commit_is_ancestor(authoritative, proposed, deployed)
    )

    if diagnosis_input is None:
        category = "unknown"
        code_required = "not yet proven"
        probable = "agent diagnosis is pending; raw observations do not authorize a workflow"
        supporting_values = ["raw observations were recorded for agent adjudication"]
    else:
        category_input = diagnosis_input.get("classification")
        probable_input = diagnosis_input.get("probable_root_cause")
        code_required_input = diagnosis_input.get("code_change_required")
        supporting_input = diagnosis_input.get("supporting_evidence")
        if not isinstance(category_input, str) or category_input not in DIAGNOSIS_CATEGORIES:
            raise IncidentError("diagnosis.classification must be one supported incident category")
        if not isinstance(probable_input, str) or not probable_input.strip():
            raise IncidentError("diagnosis.probable_root_cause must be a non-empty string")
        if not isinstance(supporting_input, list) or not supporting_input:
            raise IncidentError("diagnosis.supporting_evidence must be a non-empty list of strings")
        if any(not isinstance(item, str) or not item.strip() for item in supporting_input):
            raise IncidentError("diagnosis.supporting_evidence must contain only non-empty strings")
        if not isinstance(code_required_input, str) or code_required_input not in CODE_CHANGE_DECISIONS:
            raise IncidentError(
                "diagnosis.code_change_required must be yes, no, or not yet proven"
            )
        category = category_input
        code_required = code_required_input
        probable = compact(probable_input, 300)
        supporting_values = unique_strings(compact(item, 300) for item in supporting_input)

    if code_required == "yes":
        defect_evidence = [item for item in runtime.get("defect_evidence", []) if isinstance(item, str) and item.strip()]
        proof_complete = bool(
            runtime.get("defect_proven") is True
            and defect_evidence
            and isinstance(runtime.get("reproduction"), str)
            and runtime["reproduction"].strip()
            and isinstance(runtime.get("proven_path"), str)
            and runtime["proven_path"].strip()
        )
        if not proof_complete:
            raise IncidentError(
                "a code-change diagnosis requires defect_proven, defect_evidence, reproduction, and proven_path"
            )
        if hotfix_already_deployed:
            raise IncidentError(
                "the code-change diagnosis conflicts with an already-deployed proposed hotfix; continue agent diagnosis"
            )
        if repo_info.get("remote_default_conflict") or not repo_info.get("authoritative_remote_head"):
            raise IncidentError("a code-change diagnosis requires one verified authoritative remote default head")

    operational_repair_ready = code_required == "no"
    approval_required_input = approval_input.get("required")
    if diagnosis_input is not None and operational_repair_ready:
        if type(approval_required_input) is not bool:
            raise IncidentError("a no-code diagnosis requires boolean approval.required")
        approval_required = approval_required_input
    else:
        if "required" in approval_input and type(approval_required_input) is not bool:
            raise IncidentError("approval.required must be boolean")
        approval_required = False
    if operational_repair_ready and approval_required:
        approval_kind_input = approval_input.get("kind")
        approval_request_input = approval_input.get("request")
        if not isinstance(approval_kind_input, str) or not approval_kind_input.strip():
            raise IncidentError("an operational diagnosis requires a non-empty approval.kind")
        if not isinstance(approval_request_input, str) or not approval_request_input.strip():
            raise IncidentError("an operational diagnosis requires a non-empty approval.request")
        approval_kind = compact(approval_kind_input, 80)
        approval_request = compact(approval_request_input, 300)
    else:
        approval_kind = "none"
        approval_request = (
            "No captain approval is required for the adjudicated operational repair."
            if operational_repair_ready
            else "No operational mutation is authorized by the current diagnosis."
        )

    if code_required == "yes":
        next_action = "Start one current-main continuation and transfer only incident-related changes through the repository's normal validation and release process."
    elif hotfix_already_deployed:
        next_action = "Continue runtime diagnosis; production already contains the proposed hotfix, so do not repeat that code change."
    elif code_required == "no" and approval_required:
        next_action = approval_request
    elif code_required == "no":
        next_action = "Perform only the diagnosed operational repair, then verify the complete runtime path."
    else:
        next_action = "Gather the missing runtime or provider evidence; do not create a code branch or run validation yet."

    supporting_shown, supporting_omitted = bounded_items(supporting_values)
    runtime_observations, runtime_omitted = bounded_items([
        {
            "source": compact(row.get("source", "unknown"), 80),
            "kind": compact(row.get("kind", "unknown"), 80),
            "code": compact(row.get("code", "unknown"), 120),
        }
        for row in runtime_errors
    ])
    provider_observations, providers_omitted = bounded_items([
        {
            "name": compact(row.get("name", "unknown"), 80),
            "status": compact(row.get("status", "unknown"), 80),
            "code": compact(row.get("code", ""), 120) or None,
        }
        for row in providers
    ])
    service_observations, services_omitted = bounded_items([
        {
            "name": compact(row.get("name", "unknown"), 80),
            "status": compact(row.get("status", "unknown"), 80),
        }
        for row in services
    ])

    return {
        "classification": category,
        "probable_root_cause": probable,
        "supporting_evidence": supporting_shown,
        "code_change_required": code_required,
        "hotfix_already_deployed": hotfix_already_deployed,
        "operational_repair_ready": operational_repair_ready,
        "observations": {
            "production": {
                "origin": production_origin,
                "commit": compact(production.get("commit", ""), 80) or None,
                "health": compact(production.get("health", ""), 40) or None,
                "routing_mismatch": production.get("routing_mismatch") is True,
                "deployment_failed": production.get("deployment_failed") is True,
            },
            "runtime_errors": runtime_observations,
            "external_providers": provider_observations,
            "local_services": service_observations,
            "reproduction": compact(runtime.get("reproduction", ""), 240) or None,
            "proven_path": compact(runtime.get("proven_path", ""), 240) or None,
            "inventory": {
                "supporting_evidence": {
                    "shown": len(supporting_shown),
                    "omitted": supporting_omitted,
                },
                "runtime_errors": {
                    "shown": len(runtime_observations),
                    "omitted": runtime_omitted,
                },
                "external_providers": {
                    "shown": len(provider_observations),
                    "omitted": providers_omitted,
                },
                "local_services": {
                    "shown": len(service_observations),
                    "omitted": services_omitted,
                },
            },
        },
        "approval": {
            "required": approval_required,
            "kind": approval_kind,
            "request": approval_request,
            "status": "pending" if approval_required else "not_required",
        },
        "safest_next_action": next_action,
    }


def flow_state(current: str, *, code_required: str, approval_required: bool) -> list[dict[str, str]]:
    if code_required == "yes":
        return [
            {"name": "triage", "status": "complete"},
            {"name": "diagnosis", "status": "complete"},
            {"name": "approval", "status": "not_applicable"},
            {
                "name": "repair",
                "status": "complete" if current == "verification" else "pending_after_release",
            },
            {
                "name": "verification",
                "status": "current" if current == "verification" else "pending_after_release",
            },
        ]
    current_index = FLOW.index(current)
    result: list[dict[str, str]] = []
    for index, name in enumerate(FLOW):
        if index < current_index:
            status = "complete"
        elif index == current_index:
            status = "current"
        else:
            status = "pending"
        if name == "approval" and not approval_required:
            status = "not_required"
        result.append({"name": name, "status": status})
    return result


def incident_path(base: dict[str, Path], incident_id: str) -> Path:
    return base["state"] / "incidents" / f"{incident_id}.json"


def read_incident(base: dict[str, Path], incident_id: str) -> dict[str, Any]:
    path = incident_path(base, incident_id)
    try:
        if path.stat().st_size > STATE_READ_LIMIT:
            raise IncidentError(f"incident record is too large: {incident_id}")
        value = json.loads(path.read_text())
    except OSError as exc:
        raise IncidentError(f"incident record not found: {incident_id}") from exc
    except json.JSONDecodeError as exc:
        raise IncidentError(f"incident record is malformed: {incident_id}") from exc
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("id") != incident_id:
        raise IncidentError(f"incident record has the wrong schema or id: {incident_id}")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if len(payload) > STATE_READ_LIMIT:
        raise IncidentError(f"incident record exceeds {STATE_READ_LIMIT} bytes: {value.get('id', path.stem)}")
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def update_incident(
    base: dict[str, Path],
    incident_id: str,
    transition: Callable[[dict[str, Any]], None],
) -> dict[str, Any]:
    path = incident_path(base, incident_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        record = read_incident(base, incident_id)
        transition(record)
        write_json(path, record)
    return record


def lifecycle_advanced(record: dict[str, Any]) -> bool:
    return bool(
        record.get("phase") in {"approval", "repair", "verification"}
        or record.get("diagnosis", {}).get("code_change_required") == "yes"
        or record.get("approval", {}).get("status") == "approved"
        or record.get("repair", {}).get("status") != "pending"
        or record.get("verification", {}).get("status") != "pending"
    )


def write_triage(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if path.exists():
            try:
                existing = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                raise IncidentError(f"existing incident record is unreadable: {record['id']}") from exc
            if (
                not isinstance(existing, dict)
                or existing.get("schema") != SCHEMA
                or existing.get("id") != record["id"]
            ):
                raise IncidentError(f"existing incident record has the wrong schema or id: {record['id']}")
            if lifecycle_advanced(existing):
                raise IncidentError(
                    "incident lifecycle has advanced; retriage would regress recorded escalation, approval, repair, or verification"
                )
            record["created_at"] = existing.get("created_at", record["created_at"])
        write_json(path, record)


def output_record(record: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(record, indent=2, sort_keys=True))
        return
    print(f"Incident: {record['id']} - {record['summary']}")
    print("Flow: triage → diagnosis → approval → repair → verification")
    print(f"Current: {record['phase']}")
    print(f"Classification: {record['diagnosis']['classification']}")
    print(f"Probable root cause: {record['diagnosis']['probable_root_cause']}")
    print(f"Authoritative repository: {record['repository']['authoritative_repository']}")
    worktree = record["repository"].get("authoritative_worktree") or "no verified current-main checkout"
    print(f"Authoritative working copy: {worktree}")
    print(f"Code change required: {record['diagnosis']['code_change_required']}")
    print(f"Unrelated or scope-drifted workers: {len(record['workers']['scope_drifted'])}")
    print(f"Workers omitted by bound: {record['workers'].get('inventory', {}).get('omitted', 0)}")
    inventory = record["repository"].get("inventory", {})
    registered_omitted = inventory.get("registered_worker_metadata", {}).get("omitted", 0)
    print(f"Registered worker metadata omitted by repository scan: {registered_omitted}")
    candidate_worktrees_omitted = inventory.get("candidate_worktrees", {}).get("omitted", 0)
    print(f"Candidate worktrees omitted by repository scan: {candidate_worktrees_omitted}")
    print(f"Worktrees omitted by repository scan: {inventory.get('worktrees', {}).get('omitted', 0)}")
    project_omitted = inventory.get("project_directories", {}).get("omitted", 0)
    print(f"Project directories omitted by repository scan: {project_omitted}")
    scanned_omitted = inventory.get("scan_repositories", {}).get("omitted_at_least", 0)
    print(f"Scanned repositories omitted: at least {scanned_omitted}")
    scan_entries = inventory.get("scan_entries", {})
    print(f"Scan entries visited: {scan_entries.get('visited', 0)}")
    print(f"Scan roots truncated by entry bound: {scan_entries.get('truncated_roots', 0)}")
    print(f"Repository candidates omitted by bound: {inventory.get('candidate_paths', {}).get('omitted', 0)}")
    print(f"Branches omitted by bound: at least {inventory.get('branches', {}).get('omitted_at_least', 0)}")
    evidence_inventory = record["diagnosis"].get("observations", {}).get("inventory", {})
    evidence_omitted = sum(item.get("omitted", 0) for item in evidence_inventory.values())
    print(f"Evidence items omitted by aggregate bounds: {evidence_omitted}")
    verification_inventory = record.get("verification", {}).get("inventory", {})
    verification_omitted = sum(item.get("omitted", 0) for item in verification_inventory.values())
    print(f"Verification checks omitted by aggregate bounds: {verification_omitted}")
    print(f"Safest next action: {record['safest_next_action']}")
    approval = record["approval"]
    print(f"Approval required: {approval['kind'] if approval['required'] else 'no'}")


def compact_status_error(incident_id: str, field: str) -> IncidentError:
    return IncidentError(f"incident record has invalid compact status field {field}: {incident_id}")


def compact_status_mapping(
    value: Any,
    incident_id: str,
    field: str,
    expected_keys: set[str],
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise compact_status_error(incident_id, field)
    return value


def compact_status_string(value: Any, incident_id: str, field: str) -> None:
    if type(value) is not str:
        raise compact_status_error(incident_id, field)


def compact_status_bool(value: Any, incident_id: str, field: str) -> None:
    if type(value) is not bool:
        raise compact_status_error(incident_id, field)


def compact_status_count(value: Any, incident_id: str, field: str) -> None:
    if type(value) is not int or value < 0:
        raise compact_status_error(incident_id, field)


def compact_status_count_pair(value: Any, incident_id: str, field: str) -> dict[str, Any]:
    row = compact_status_mapping(value, incident_id, field, {"shown", "omitted"})
    compact_status_count(row["shown"], incident_id, f"{field}.shown")
    compact_status_count(row["omitted"], incident_id, f"{field}.omitted")
    return row


def validate_compact_status(record: dict[str, Any]) -> None:
    incident_id = record.get("id") if isinstance(record.get("id"), str) else "unknown"
    compact_status_mapping(
        record,
        incident_id,
        "record",
        {
            "schema", "id", "summary", "updated_at", "phase", "flow", "outcome",
            "diagnosis", "approval", "inventory", "safest_next_action",
        },
    )
    for field in (
        "schema", "id", "summary", "updated_at", "phase", "outcome", "safest_next_action",
    ):
        compact_status_string(record[field], incident_id, field)
    if record["schema"] != SCHEMA or not INCIDENT_RE.fullmatch(record["id"]):
        raise compact_status_error(incident_id, "schema or id")
    try:
        updated_at = parse_time(record["updated_at"])
    except ValueError as exc:
        raise compact_status_error(incident_id, "updated_at") from exc
    if updated_at.tzinfo is None:
        raise compact_status_error(incident_id, "updated_at")

    flow = record["flow"]
    if not isinstance(flow, list) or len(flow) != len(FLOW):
        raise compact_status_error(incident_id, "flow")
    for index, expected_name in enumerate(FLOW):
        row = compact_status_mapping(flow[index], incident_id, f"flow[{index}]", {"name", "status"})
        compact_status_string(row["name"], incident_id, f"flow[{index}].name")
        compact_status_string(row["status"], incident_id, f"flow[{index}].status")
        if row["name"] != expected_name:
            raise compact_status_error(incident_id, f"flow[{index}].name")

    diagnosis = compact_status_mapping(
        record["diagnosis"],
        incident_id,
        "diagnosis",
        {
            "classification", "probable_root_cause", "code_change_required",
            "hotfix_already_deployed", "operational_repair_ready",
        },
    )
    for field in ("classification", "probable_root_cause", "code_change_required"):
        compact_status_string(diagnosis[field], incident_id, f"diagnosis.{field}")
    for field in ("hotfix_already_deployed", "operational_repair_ready"):
        compact_status_bool(diagnosis[field], incident_id, f"diagnosis.{field}")

    approval = compact_status_mapping(
        record["approval"],
        incident_id,
        "approval",
        {"required", "kind", "request", "status"},
    )
    compact_status_bool(approval["required"], incident_id, "approval.required")
    for field in ("kind", "request", "status"):
        compact_status_string(approval[field], incident_id, f"approval.{field}")
        if not approval[field].strip():
            raise compact_status_error(incident_id, f"approval.{field}")

    inventory = compact_status_mapping(
        record["inventory"],
        incident_id,
        "inventory",
        {"workers", "repository", "evidence", "verification"},
    )
    compact_status_count_pair(inventory["workers"], incident_id, "inventory.workers")
    repository = compact_status_mapping(
        inventory["repository"],
        incident_id,
        "inventory.repository",
        {
            "registered_worker_metadata", "candidate_worktrees", "worktrees",
            "project_directories", "scan_repositories", "scan_entries",
            "candidate_paths", "copies", "branches",
        },
    )
    compact_status_count_pair(
        repository["registered_worker_metadata"],
        incident_id,
        "inventory.repository.registered_worker_metadata",
    )
    for field in ("candidate_worktrees", "worktrees"):
        row = compact_status_mapping(
            repository[field],
            incident_id,
            f"inventory.repository.{field}",
            {"repository", "shown", "omitted"},
        )
        compact_status_string(
            row["repository"],
            incident_id,
            f"inventory.repository.{field}.repository",
        )
        compact_status_count(row["shown"], incident_id, f"inventory.repository.{field}.shown")
        compact_status_count(row["omitted"], incident_id, f"inventory.repository.{field}.omitted")
    compact_status_count_pair(
        repository["project_directories"],
        incident_id,
        "inventory.repository.project_directories",
    )
    scan_repositories = compact_status_mapping(
        repository["scan_repositories"],
        incident_id,
        "inventory.repository.scan_repositories",
        {"omitted_at_least"},
    )
    compact_status_count(
        scan_repositories["omitted_at_least"],
        incident_id,
        "inventory.repository.scan_repositories.omitted_at_least",
    )
    scan_entries = compact_status_mapping(
        repository["scan_entries"],
        incident_id,
        "inventory.repository.scan_entries",
        {"visited", "truncated_roots"},
    )
    compact_status_count(
        scan_entries["visited"],
        incident_id,
        "inventory.repository.scan_entries.visited",
    )
    compact_status_count(
        scan_entries["truncated_roots"],
        incident_id,
        "inventory.repository.scan_entries.truncated_roots",
    )
    compact_status_count_pair(
        repository["candidate_paths"],
        incident_id,
        "inventory.repository.candidate_paths",
    )
    copies = compact_status_mapping(
        repository["copies"],
        incident_id,
        "inventory.repository.copies",
        {"shown", "complete"},
    )
    compact_status_count(copies["shown"], incident_id, "inventory.repository.copies.shown")
    compact_status_bool(copies["complete"], incident_id, "inventory.repository.copies.complete")
    branches = compact_status_mapping(
        repository["branches"],
        incident_id,
        "inventory.repository.branches",
        {"shown", "omitted_at_least"},
    )
    compact_status_count(branches["shown"], incident_id, "inventory.repository.branches.shown")
    compact_status_count(
        branches["omitted_at_least"],
        incident_id,
        "inventory.repository.branches.omitted_at_least",
    )

    evidence = compact_status_mapping(
        inventory["evidence"],
        incident_id,
        "inventory.evidence",
        {"supporting_evidence", "runtime_errors", "external_providers", "local_services"},
    )
    for field, value in evidence.items():
        compact_status_count_pair(value, incident_id, f"inventory.evidence.{field}")

    verification = inventory["verification"]
    if not isinstance(verification, dict) or set(verification) not in (set(), {"checks"}):
        raise compact_status_error(incident_id, "inventory.verification")
    if "checks" in verification:
        compact_status_count_pair(
            verification["checks"],
            incident_id,
            "inventory.verification.checks",
        )


def status_projection(record: dict[str, Any]) -> dict[str, Any]:
    incident_id = record.get("id") if isinstance(record.get("id"), str) else "unknown"
    mapping_fields = ("diagnosis", "approval", "workers", "repository", "verification")
    if any(not isinstance(record.get(key), dict) for key in mapping_fields):
        raise compact_status_error(incident_id, "record")
    diagnosis = record["diagnosis"]
    observations = diagnosis.get("observations")
    if not isinstance(observations, dict):
        raise compact_status_error(incident_id, "diagnosis.observations")
    approval = record["approval"]
    projection = {
        "schema": record.get("schema"),
        "id": record.get("id"),
        "summary": record.get("summary"),
        "updated_at": record.get("updated_at"),
        "phase": record.get("phase"),
        "flow": record.get("flow"),
        "outcome": record.get("outcome"),
        "diagnosis": {
            key: diagnosis.get(key)
            for key in (
                "classification", "probable_root_cause", "code_change_required",
                "hotfix_already_deployed", "operational_repair_ready",
            )
        },
        "approval": {
            key: approval.get(key)
            for key in ("required", "kind", "request", "status")
        },
        "inventory": {
            "workers": record.get("workers", {}).get("inventory", {"shown": 0, "omitted": 0}),
            "repository": record.get("repository", {}).get("inventory", {}),
            "evidence": record.get("diagnosis", {}).get("observations", {}).get("inventory", {}),
            "verification": record.get("verification", {}).get("inventory", {}),
        },
        "safest_next_action": record.get("safest_next_action"),
    }
    validate_compact_status(projection)
    return projection


def triage(args: argparse.Namespace) -> int:
    base = paths()
    incident_id = validate_incident_id(args.incident)
    now = utc_now()
    repo_info = collect_repositories(
        Path(args.repo),
        base["state"],
        base["projects"],
        [Path(path).resolve() for path in args.scan_root],
    )
    evidence = load_evidence(Path(args.evidence).resolve() if args.evidence else None)
    workers = collect_workers(base["state"], base["data"], repo_info, args.summary, args.term)
    diagnosis = record_agent_diagnosis(evidence, repo_info)
    if diagnosis["code_change_required"] == "yes":
        phase = "diagnosis"
        outcome = "escalate_to_code_change"
    elif not diagnosis["operational_repair_ready"]:
        phase = "diagnosis"
        outcome = "more_evidence_required"
    elif diagnosis["operational_repair_ready"]:
        phase = "approval" if diagnosis["approval"]["required"] else "repair"
        outcome = "operational_repair"
    else:
        phase = "diagnosis"
        outcome = "more_evidence_required"
    path = incident_path(base, incident_id)
    record = {
        "schema": SCHEMA,
        "id": incident_id,
        "summary": compact(args.summary, 300),
        "created_at": now,
        "updated_at": now,
        "phase": phase,
        "flow": flow_state(
            phase,
            code_required=diagnosis["code_change_required"],
            approval_required=diagnosis["approval"]["required"],
        ),
        "outcome": outcome,
        "diagnosis": {
            key: diagnosis[key]
            for key in (
                "classification", "probable_root_cause", "supporting_evidence",
                "code_change_required", "hotfix_already_deployed",
                "operational_repair_ready", "observations",
            )
        },
        "repository": repo_info,
        "workers": workers,
        "approval": diagnosis["approval"],
        "repair": {"status": "pending", "note": None, "recorded_at": None},
        "verification": {"status": "pending", "checks": [], "recorded_at": None},
        "safest_next_action": diagnosis["safest_next_action"],
        "guardrails": {
            "project_code_edited_during_triage": False,
            "new_worktree_allowed": diagnosis["code_change_required"] == "yes",
            "code_validation_allowed": diagnosis["code_change_required"] == "yes",
            "other_worker_mutation_authorized": False,
        },
    }
    write_triage(path, record)
    output_record(record, args.json)
    return 0


def approve(args: argparse.Namespace) -> int:
    base = paths()
    incident_id = validate_incident_id(args.incident)
    now = utc_now()

    def transition(record: dict[str, Any]) -> None:
        approval = record["approval"]
        approval_kind = approval.get("kind")
        approval_request = approval.get("request")
        if (
            not isinstance(approval_kind, str)
            or not approval_kind.strip()
            or not isinstance(approval_request, str)
            or not approval_request.strip()
        ):
            raise IncidentError("incident has no valid operational approval request")
        if (
            record.get("phase") != "approval"
            or not approval.get("required")
            or approval.get("status") != "pending"
            or record.get("repair", {}).get("status") != "pending"
            or record.get("verification", {}).get("status") != "pending"
        ):
            raise IncidentError("incident has no pending operational approval")
        if args.kind != approval_kind:
            raise IncidentError(f"approval kind must exactly match {approval_kind}")
        approval.update({"status": "approved", "note": compact(args.note, 300), "approved_at": now})
        record["phase"] = "repair"
        record["updated_at"] = now
        record["flow"] = flow_state("repair", code_required="no", approval_required=True)
        record["safest_next_action"] = (
            "Perform only the approved operational repair, then record it and verify the complete runtime path."
        )

    record = update_incident(base, incident_id, transition)
    output_record(record, args.json)
    return 0


def repair(args: argparse.Namespace) -> int:
    base = paths()
    incident_id = validate_incident_id(args.incident)
    now = utc_now()

    def transition(record: dict[str, Any]) -> None:
        code_required = record["diagnosis"]["code_change_required"]
        expected_phase = "diagnosis" if code_required == "yes" else "repair"
        if record.get("phase") != expected_phase:
            raise IncidentError("the diagnosed repair is not ready to be recorded")
        if record.get("repair", {}).get("status") != "pending":
            raise IncidentError("the diagnosed repair is no longer pending")
        if record.get("verification", {}).get("status") != "pending":
            raise IncidentError("verification has already started or completed")
        approval = record["approval"]
        if code_required == "no":
            if not record["diagnosis"].get("operational_repair_ready"):
                raise IncidentError("the diagnosis has not identified an operational repair")
            if approval.get("required") and approval.get("status") != "approved":
                raise IncidentError("the exact operational approval is still pending")
            if not approval.get("required") and approval.get("status") != "not_required":
                raise IncidentError("the operational approval state is invalid")
        elif code_required == "yes":
            if record.get("outcome") != "escalate_to_code_change":
                raise IncidentError("the code repair has not been escalated through the normal workflow")
            if approval.get("required") or approval.get("status") != "not_required":
                raise IncidentError("a code repair has an invalid operational approval state")
        else:
            raise IncidentError("the diagnosis has not selected a repair workflow")
        record["repair"] = {"status": "complete", "note": compact(args.note, 300), "recorded_at": now}
        record["phase"] = "verification"
        record["updated_at"] = now
        record["flow"] = flow_state(
            "verification",
            code_required=code_required,
            approval_required=bool(approval.get("required")),
        )
        record["safest_next_action"] = (
            "Verify production identity, repaired component health, companion connectivity, and the complete user-visible runtime path."
        )

    record = update_incident(base, incident_id, transition)
    output_record(record, args.json)
    return 0


def verify(args: argparse.Namespace) -> int:
    base = paths()
    incident_id = validate_incident_id(args.incident)
    evidence = load_evidence(Path(args.evidence).resolve())
    verification = evidence.get("verification") if isinstance(evidence.get("verification"), dict) else {}
    checks = list_of_objects(verification.get("checks"))
    companion_required = verification.get("companion_connectivity_required")
    observed_scopes = {
        row.get("scope")
        for row in checks
        if isinstance(row.get("scope"), str)
    }
    required_scopes = set(VERIFICATION_REQUIRED_SCOPES)
    if companion_required is True:
        required_scopes.update(VERIFICATION_OPTIONAL_SCOPES)
    scopes_complete = bool(
        type(companion_required) is bool
        and observed_scopes <= VERIFICATION_REQUIRED_SCOPES | VERIFICATION_OPTIONAL_SCOPES
        and required_scopes <= observed_scopes
    )
    complete = bool(
        verification.get("runtime_path_ok") is True
        and checks
        and scopes_complete
        and all(compact(row.get("status", "")).lower() in VERIFICATION_PASS for row in checks)
    )
    safe_checks, checks_omitted = bounded_items([
        {
            "scope": compact(row.get("scope", "unscoped"), 40),
            "name": compact(row.get("name", "unnamed check"), 120),
            "status": compact(row.get("status", "unknown"), 40),
            "evidence": compact(row.get("evidence", ""), 200),
        }
        for row in checks
    ])
    now = utc_now()

    def transition(record: dict[str, Any]) -> None:
        if record.get("phase") != "verification" or record["repair"].get("status") != "complete":
            raise IncidentError("record the completed operational repair or released code fix before verification")
        if record.get("verification", {}).get("status") not in {"pending", "failed"}:
            raise IncidentError("incident verification is already complete")
        record["verification"] = {
            "status": "complete" if complete else "failed",
            "checks": safe_checks,
            "recorded_at": now,
            "inventory": {
                "checks": {
                    "shown": len(safe_checks),
                    "omitted": checks_omitted,
                }
            },
        }
        record["phase"] = "verification"
        record["updated_at"] = now
        record["flow"] = [
            {"name": name, "status": "complete" if complete or name != "verification" else "current"}
            for name in FLOW
        ]
        code_required = record["diagnosis"]["code_change_required"]
        if code_required == "yes":
            record["flow"][2]["status"] = "not_applicable"
        elif not record["approval"].get("required"):
            record["flow"][2]["status"] = "not_required"
        record["safest_next_action"] = (
            (
                "Incident verification is complete; close the incident without unrelated cleanup."
                if code_required == "yes"
                else "Incident verification is complete; close the incident without code, release, or unrelated cleanup."
            )
            if complete
            else "Verification did not prove the complete runtime path; keep the incident open and gather the failed check evidence."
        )

    record = update_incident(base, incident_id, transition)
    output_record(record, args.json)
    return 0 if complete else 1


def status(args: argparse.Namespace) -> int:
    base = paths()
    if args.compact and not args.json:
        raise IncidentError("--compact requires --json")
    if args.incident:
        record = read_incident(base, validate_incident_id(args.incident))
        compact_record = status_projection(record)
        if args.compact:
            record = compact_record
        output_record(record, args.json)
        return 0
    incident_dir = base["state"] / "incidents"
    candidates: list[tuple[dict[str, Any], dict[str, Any]]] = []
    invalid: list[dict[str, str]] = []
    if incident_dir.is_dir():
        for path in sorted(incident_dir.glob("*.json")):
            try:
                record = read_incident(base, path.stem)
                compact_record = status_projection(record)
            except IncidentError as exc:
                invalid.append({"path": str(path), "reason": str(exc)})
                continue
            candidates.append((record, compact_record))
    candidates.sort(
        key=lambda row: (parse_time(row[0]["updated_at"]), row[0]["id"]),
        reverse=True,
    )
    input_inventory = {
        "shown": min(len(candidates), MAX_COPIES),
        "omitted": max(0, len(candidates) - MAX_COPIES),
    }
    candidates = candidates[:MAX_COPIES]
    limit_value = os.environ.get("FM_INCIDENT_STATUS_LIMIT", str(DEFAULT_STATUS_LIMIT))
    if not limit_value.isdigit() or int(limit_value) < 1:
        raise IncidentError("FM_INCIDENT_STATUS_LIMIT must be a positive integer")
    limit = int(limit_value)
    truncated = max(0, len(candidates) - limit)
    candidates = candidates[:limit]
    records = [compact_record if args.compact else record for record, compact_record in candidates]
    result = {
        "schema": STATUS_SCHEMA,
        "records": records,
        "invalid": invalid,
        "truncated": truncated,
        "input": input_inventory,
    }
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        if not records:
            print("No readable runtime incidents recorded." if invalid else "No runtime incidents recorded.")
        else:
            for index, record in enumerate(records):
                if index:
                    print()
                output_record(record, False)
        if invalid:
            if records:
                print()
            print(f"Warning: {len(invalid)} invalid incident record(s) could not be read.")
            for row in invalid:
                print(f"Invalid incident record: {row['path']}: {row['reason']}")
        if input_inventory["omitted"]:
            print()
            print(f"Warning: {input_inventory['omitted']} incident record(s) omitted by the input bound.")
        if truncated:
            print(f"Warning: {truncated} readable incident record(s) omitted by the display limit.")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Bounded FirstMate runtime-incident fast path")
    sub = root.add_subparsers(dest="command", required=True)

    triage_parser = sub.add_parser(
        "triage",
        help="collect read-only inventory and record an agent-adjudicated diagnosis",
    )
    triage_parser.add_argument("--incident", required=True)
    triage_parser.add_argument("--repo", required=True)
    triage_parser.add_argument("--summary", required=True)
    triage_parser.add_argument("--evidence")
    triage_parser.add_argument("--scan-root", action="append", default=[])
    triage_parser.add_argument("--term", action="append", default=[])
    triage_parser.add_argument("--json", action="store_true")
    triage_parser.set_defaults(func=triage)

    approve_parser = sub.add_parser("approve", help="record the captain's exact operational approval")
    approve_parser.add_argument("--incident", required=True)
    approve_parser.add_argument("--kind", required=True)
    approve_parser.add_argument("--note", required=True)
    approve_parser.add_argument("--json", action="store_true")
    approve_parser.set_defaults(func=approve)

    repair_parser = sub.add_parser(
        "repair",
        help="record a completed narrow operation or normally released code fix",
    )
    repair_parser.add_argument("--incident", required=True)
    repair_parser.add_argument("--note", required=True)
    repair_parser.add_argument("--json", action="store_true")
    repair_parser.set_defaults(func=repair)

    verify_parser = sub.add_parser("verify", help="record fresh complete-runtime verification evidence")
    verify_parser.add_argument("--incident", required=True)
    verify_parser.add_argument("--evidence", required=True)
    verify_parser.add_argument("--json", action="store_true")
    verify_parser.set_defaults(func=verify)

    status_parser = sub.add_parser("status", help="show one or all incident records")
    status_parser.add_argument("--incident")
    status_parser.add_argument("--json", action="store_true")
    status_parser.add_argument("--compact", action="store_true")
    status_parser.set_defaults(func=status)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except IncidentError as exc:
        print(f"fm-runtime-incident: refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
