#!/usr/bin/env python3
"""Read-only Git inventory backed by the shared PR-stack SQLite catalog.

The stable public command is:

    bin/fm-pr-stack.py inventory [--base <revision>] [--json]

Git owns refs, worktrees, ancestry, upstreams, and cleanliness.  This command
observes those facts without fetching or changing Git state, then replaces the
catalog's current observation tables in one transaction.  The catalog owns only
orchestrator declarations, operations, and append-only reconciliation evidence.
See docs/pr-stack-orchestrator.md for the operator contract.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn, Sequence


SCHEMA_VERSION = 1
CATALOG_RELATIVE_PATH = Path("pr-stack") / "orchestrator.sqlite"
DEFAULT_LOCK_TIMEOUT_MS = 2_000


class InventoryError(Exception):
    """A deterministic, user-actionable inventory failure."""


class CatalogBusyError(InventoryError):
    """The bounded catalog writer wait expired."""


@dataclass(frozen=True)
class GitResult:
    stdout: bytes
    stderr: bytes
    returncode: int


def now_utc() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def decode(raw: bytes) -> str:
    return os.fsdecode(raw)


def run_git(repo: Path, args: Sequence[str], *, check: bool = True) -> GitResult:
    environment = os.environ.copy()
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["LC_ALL"] = "C"
    process = subprocess.run(
        ["git", "-C", os.fspath(repo), *args],
        check=False,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    result = GitResult(process.stdout, process.stderr, process.returncode)
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        command = "git " + " ".join(args)
        raise InventoryError(
            f"{command} failed: {detail or f'exit {result.returncode}'}"
        )
    return result


def one_line(result: GitResult) -> str:
    return decode(result.stdout.rstrip(b"\n"))


def repository_root() -> Path:
    result = run_git(
        Path.cwd(), ["rev-parse", "--path-format=absolute", "--show-toplevel"]
    )
    return Path(one_line(result))


def common_git_dir(repo: Path) -> Path:
    result = run_git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    return Path(one_line(result))


def resolve_commit(repo: Path, revision: str, label: str) -> str:
    result = run_git(
        repo,
        ["rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"],
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise InventoryError(
            f"{label} {revision!r} does not resolve to one commit: {detail or 'not found'}"
        )
    return one_line(result)


def short_ref_name(ref: str) -> str:
    for prefix in ("refs/heads/", "refs/remotes/", "refs/tags/"):
        if ref.startswith(prefix):
            return ref[len(prefix) :]
    return ref


def canonical_ref(repo: Path, revision: str) -> str | None:
    result = run_git(
        repo,
        ["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", revision],
        check=False,
    )
    if result.returncode != 0:
        return None
    value = one_line(result)
    return value or None


def select_base(repo: Path, override: str | None) -> dict[str, Any]:
    if override is not None:
        if not override:
            raise InventoryError("--base requires a non-empty revision")
        oid = resolve_commit(repo, override, "explicit integration base")
        ref = canonical_ref(repo, override)
        return {
            "source": "explicit",
            "input": override,
            "ref": ref,
            "name": short_ref_name(ref) if ref else override,
            "oid": oid,
        }

    remote_head = run_git(
        repo,
        ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
        check=False,
    )
    if remote_head.returncode == 0:
        ref = one_line(remote_head)
        oid = resolve_commit(repo, ref, "default integration base")
        return {
            "source": "origin_head",
            "input": None,
            "ref": ref,
            "name": short_ref_name(ref),
            "oid": oid,
        }
    if remote_head.returncode not in (1, 128):
        detail = remote_head.stderr.decode("utf-8", "replace").strip()
        raise InventoryError(
            f"could not inspect refs/remotes/origin/HEAD: {detail or 'unknown error'}"
        )

    candidates: list[str] = []
    for name in ("main", "master"):
        ref = f"refs/heads/{name}"
        exists = run_git(repo, ["show-ref", "--verify", "--quiet", ref], check=False)
        if exists.returncode == 0:
            candidates.append(ref)
        elif exists.returncode != 1:
            raise InventoryError(f"could not inspect default-base candidate {ref}")
    if not candidates:
        raise InventoryError(
            "no default integration base: origin/HEAD is unset and neither local main nor master exists; "
            "pass --base <revision>"
        )
    if len(candidates) > 1:
        names = ", ".join(short_ref_name(ref) for ref in candidates)
        raise InventoryError(
            f"ambiguous default integration base: origin/HEAD is unset and local {names} both exist; "
            "pass --base <revision>"
        )
    ref = candidates[0]
    return {
        "source": "local_convention",
        "input": None,
        "ref": ref,
        "name": short_ref_name(ref),
        "oid": resolve_commit(repo, ref, "default integration base"),
    }


def parse_worktree_porcelain(raw: bytes) -> list[dict[str, bytes]]:
    records: list[dict[str, bytes]] = []
    current: dict[str, bytes] = {}
    for field in raw.split(b"\0"):
        if not field:
            if current:
                records.append(current)
                current = {}
            continue
        key, separator, value = field.partition(b" ")
        current[key.decode("ascii")] = value if separator else b""
    if current:
        records.append(current)
    return records


def worktree_cleanliness(
    path: str, *, bare: bool
) -> tuple[bool | None, str, str | None]:
    if bare:
        return None, "not_applicable", "bare worktree record"
    worktree = Path(path)
    if not worktree.is_dir():
        return None, "unavailable", "worktree path is missing"
    result = run_git(
        worktree,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=normal",
            "--ignore-submodules=none",
        ],
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise InventoryError(
            f"could not inspect cleanliness for worktree {path!r}: {detail or 'git status failed'}"
        )
    clean = result.stdout == b""
    return clean, "clean" if clean else "dirty", None


def scan_worktrees(repo: Path) -> list[dict[str, Any]]:
    result = run_git(repo, ["worktree", "list", "--porcelain", "-z"])
    worktrees: list[dict[str, Any]] = []
    for record in parse_worktree_porcelain(result.stdout):
        if "worktree" not in record or "HEAD" not in record:
            raise InventoryError(
                "git worktree list returned an incomplete porcelain record"
            )
        path = decode(record["worktree"])
        bare = "bare" in record
        branch_ref = decode(record["branch"]) if "branch" in record else None
        clean, cleanliness, cleanliness_reason = worktree_cleanliness(path, bare=bare)
        worktrees.append(
            {
                "path": path,
                "head_oid": decode(record["HEAD"]),
                "branch_ref": branch_ref,
                "detached": "detached" in record or (branch_ref is None and not bare),
                "bare": bare,
                "clean": clean,
                "cleanliness": cleanliness,
                "cleanliness_reason": cleanliness_reason,
                "locked_reason": decode(record["locked"])
                if "locked" in record
                else None,
                "prunable_reason": decode(record["prunable"])
                if "prunable" in record
                else None,
            }
        )
    return sorted(worktrees, key=lambda item: item["path"])


def parse_branch_refs(raw: bytes) -> list[tuple[str, str, str | None, str | None]]:
    branches: list[tuple[str, str, str | None, str | None]] = []
    for line in raw.splitlines():
        if not line:
            continue
        fields = line.split(b"\0")
        if len(fields) < 4:
            raise InventoryError(
                "git for-each-ref returned an incomplete branch record"
            )
        ref, oid, upstream_ref, upstream_name = (decode(value) for value in fields[:4])
        branches.append((ref, oid, upstream_ref or None, upstream_name or None))
    return sorted(branches, key=lambda item: item[0])


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    result = run_git(
        repo, ["merge-base", "--is-ancestor", ancestor, descendant], check=False
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    detail = result.stderr.decode("utf-8", "replace").strip()
    raise InventoryError(
        f"could not compare commits {ancestor} and {descendant}: {detail or 'git merge-base failed'}"
    )


def unique_commit_count(repo: Path, base_oid: str, head_oid: str) -> int:
    result = run_git(repo, ["rev-list", "--count", f"{base_oid}..{head_oid}"])
    value = one_line(result)
    try:
        return int(value)
    except ValueError as exc:
        raise InventoryError(
            f"git rev-list returned a non-integer count: {value!r}"
        ) from exc


def aggregate_cleanliness(checkouts: list[dict[str, Any]]) -> bool | None:
    if not checkouts:
        return None
    values = [checkout["clean"] for checkout in checkouts]
    if any(value is False for value in values):
        return False
    if all(value is True for value in values):
        return True
    return None


def scan_branches(
    repo: Path, base: dict[str, Any], worktrees: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    result = run_git(
        repo,
        [
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:short)%00",
            "refs/heads",
        ],
    )
    by_branch: dict[str, list[dict[str, Any]]] = {}
    for worktree in worktrees:
        if worktree["branch_ref"]:
            by_branch.setdefault(worktree["branch_ref"], []).append(worktree)

    branches: list[dict[str, Any]] = []
    for ref, oid, upstream_ref, upstream_name in parse_branch_refs(result.stdout):
        checkouts = sorted(by_branch.get(ref, []), key=lambda item: item["path"])
        unique_count = unique_commit_count(repo, base["oid"], oid)
        branches.append(
            {
                "ref": ref,
                "name": short_ref_name(ref),
                "head_oid": oid,
                "upstream_ref": upstream_ref,
                "upstream": upstream_name,
                "checked_out_worktree": checkouts[0]["path"] if checkouts else None,
                "checked_out_worktrees": [
                    {
                        "path": checkout["path"],
                        "clean": checkout["clean"],
                        "cleanliness": checkout["cleanliness"],
                        "cleanliness_reason": checkout["cleanliness_reason"],
                    }
                    for checkout in checkouts
                ],
                "worktree_clean": aggregate_cleanliness(checkouts),
                "reachable_from_base": is_ancestor(repo, oid, base["oid"]),
                "unique_commit_count": unique_count,
                "unique_commit_proof": {
                    "revision_range": f"{base['oid']}..{oid}",
                    "count": unique_count,
                },
            }
        )
    return branches


SCHEMA_STATEMENTS = (
    """
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE repositories (
      id INTEGER PRIMARY KEY,
      common_git_dir TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE reconciliations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      observed_at TEXT NOT NULL,
      base_source TEXT NOT NULL,
      base_ref TEXT,
      base_oid TEXT NOT NULL,
      invoking_head_oid TEXT NOT NULL,
      worktree_count INTEGER NOT NULL,
      branch_count INTEGER NOT NULL,
      journal_mode TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE branch_declarations (
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      branch_ref TEXT NOT NULL,
      disposition TEXT NOT NULL CHECK (disposition IN ('registered', 'ignored')),
      reason TEXT,
      owner_id TEXT,
      intent TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (repository_id, branch_ref),
      CHECK (disposition <> 'ignored' OR reason IS NOT NULL)
    )
    """,
    """
    CREATE TABLE worktree_observations (
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      path TEXT NOT NULL,
      reconciliation_id INTEGER NOT NULL REFERENCES reconciliations(id),
      head_oid TEXT NOT NULL,
      branch_ref TEXT,
      detached INTEGER NOT NULL CHECK (detached IN (0, 1)),
      bare INTEGER NOT NULL CHECK (bare IN (0, 1)),
      clean INTEGER CHECK (clean IN (0, 1)),
      cleanliness TEXT NOT NULL,
      cleanliness_reason TEXT,
      locked_reason TEXT,
      prunable_reason TEXT,
      observed_at TEXT NOT NULL,
      PRIMARY KEY (repository_id, path)
    )
    """,
    """
    CREATE TABLE branch_observations (
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      branch_ref TEXT NOT NULL,
      reconciliation_id INTEGER NOT NULL REFERENCES reconciliations(id),
      name TEXT NOT NULL,
      head_oid TEXT NOT NULL,
      upstream_ref TEXT,
      checked_out_worktree TEXT,
      worktree_clean INTEGER CHECK (worktree_clean IN (0, 1)),
      reachable_from_base INTEGER NOT NULL CHECK (reachable_from_base IN (0, 1)),
      unique_commit_count INTEGER NOT NULL CHECK (unique_commit_count >= 0),
      disposition TEXT NOT NULL CHECK (disposition IN ('registered', 'unregistered', 'ignored')),
      disposition_reason TEXT,
      observed_at TEXT NOT NULL,
      PRIMARY KEY (repository_id, branch_ref)
    )
    """,
    """
    CREATE TABLE operations (
      id TEXT PRIMARY KEY,
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      idempotency_key TEXT NOT NULL UNIQUE,
      action TEXT NOT NULL,
      state TEXT NOT NULL,
      preconditions_json TEXT NOT NULL,
      plan_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT
    )
    """,
    """
    CREATE TABLE events (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      repository_id INTEGER NOT NULL REFERENCES repositories(id),
      reconciliation_id INTEGER REFERENCES reconciliations(id),
      operation_id TEXT REFERENCES operations(id),
      occurred_at TEXT NOT NULL,
      actor TEXT NOT NULL,
      action TEXT NOT NULL,
      detail_json TEXT NOT NULL
    )
    """,
    "CREATE INDEX events_reconciliation_idx ON events (reconciliation_id, seq)",
    "CREATE INDEX branch_observations_disposition_idx ON branch_observations (repository_id, disposition, branch_ref)",
)


def sqlite_bool(value: bool | None) -> int | None:
    if value is None:
        return None
    return int(value)


def is_busy_error(error: sqlite3.Error) -> bool:
    return "locked" in str(error).lower() or "busy" in str(error).lower()


def migrate(connection: sqlite3.Connection, observed_at: str) -> None:
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version > SCHEMA_VERSION:
        raise InventoryError(
            f"catalog schema version {version} is newer than supported version {SCHEMA_VERSION}"
        )
    if version == 0:
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        connection.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
            (SCHEMA_VERSION, observed_at),
        )
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    elif version != SCHEMA_VERSION:
        raise InventoryError(
            f"no deterministic migration path from catalog schema version {version}"
        )


def disposition_for(
    branch: dict[str, Any], declaration: sqlite3.Row | None
) -> tuple[str, str | None]:
    if declaration is not None:
        return declaration["disposition"], declaration["reason"]
    if branch["unique_commit_count"] > 0:
        return "unregistered", "no orchestrator declaration exists"
    return "ignored", "no commits unique to the selected integration base"


def reconcile_catalog(
    catalog: Path,
    common_dir: Path,
    observed_at: str,
    base: dict[str, Any],
    invoking_head_oid: str,
    worktrees: list[dict[str, Any]],
    branches: list[dict[str, Any]],
    lock_timeout_ms: int,
) -> tuple[int, str]:
    try:
        catalog.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise InventoryError(f"could not create catalog directory: {error}") from error
    try:
        connection = sqlite3.connect(
            catalog,
            timeout=lock_timeout_ms / 1_000,
            isolation_level=None,
        )
    except sqlite3.Error as error:
        raise InventoryError(f"could not open catalog: {error}") from error
    connection.row_factory = sqlite3.Row
    try:
        connection.execute(f"PRAGMA busy_timeout = {lock_timeout_ms}")
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            journal_mode = str(
                connection.execute("PRAGMA journal_mode = WAL").fetchone()[0]
            ).lower()
            connection.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as error:
            if is_busy_error(error):
                raise CatalogBusyError(
                    f"catalog writer remained busy for {lock_timeout_ms} ms; retry inventory after the other refresh finishes"
                ) from error
            raise
        try:
            migrate(connection, observed_at)
            connection.execute(
                """
                INSERT INTO repositories(id, common_git_dir, created_at, updated_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  common_git_dir = excluded.common_git_dir,
                  updated_at = excluded.updated_at
                """,
                (os.fspath(common_dir), observed_at, observed_at),
            )
            cursor = connection.execute(
                """
                INSERT INTO reconciliations(
                  repository_id, observed_at, base_source, base_ref, base_oid,
                  invoking_head_oid, worktree_count, branch_count, journal_mode
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    observed_at,
                    base["source"],
                    base["ref"],
                    base["oid"],
                    invoking_head_oid,
                    len(worktrees),
                    len(branches),
                    journal_mode,
                ),
            )
            reconciliation_id = int(cursor.lastrowid)
            declarations = {
                row["branch_ref"]: row
                for row in connection.execute(
                    "SELECT branch_ref, disposition, reason FROM branch_declarations WHERE repository_id = 1"
                )
            }
            connection.execute(
                "DELETE FROM worktree_observations WHERE repository_id = 1"
            )
            connection.execute(
                "DELETE FROM branch_observations WHERE repository_id = 1"
            )
            for worktree in worktrees:
                connection.execute(
                    """
                    INSERT INTO worktree_observations(
                      repository_id, path, reconciliation_id, head_oid, branch_ref,
                      detached, bare, clean, cleanliness, cleanliness_reason,
                      locked_reason, prunable_reason, observed_at
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        worktree["path"],
                        reconciliation_id,
                        worktree["head_oid"],
                        worktree["branch_ref"],
                        int(worktree["detached"]),
                        int(worktree["bare"]),
                        sqlite_bool(worktree["clean"]),
                        worktree["cleanliness"],
                        worktree["cleanliness_reason"],
                        worktree["locked_reason"],
                        worktree["prunable_reason"],
                        observed_at,
                    ),
                )
            for branch in branches:
                disposition, reason = disposition_for(
                    branch, declarations.get(branch["ref"])
                )
                branch["disposition"] = disposition
                branch["disposition_reason"] = reason
                connection.execute(
                    """
                    INSERT INTO branch_observations(
                      repository_id, branch_ref, reconciliation_id, name, head_oid,
                      upstream_ref, checked_out_worktree, worktree_clean,
                      reachable_from_base, unique_commit_count, disposition,
                      disposition_reason, observed_at
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        branch["ref"],
                        reconciliation_id,
                        branch["name"],
                        branch["head_oid"],
                        branch["upstream_ref"],
                        branch["checked_out_worktree"],
                        sqlite_bool(branch["worktree_clean"]),
                        int(branch["reachable_from_base"]),
                        branch["unique_commit_count"],
                        disposition,
                        reason,
                        observed_at,
                    ),
                )
            event_detail = json.dumps(
                {
                    "base_oid": base["oid"],
                    "base_ref": base["ref"],
                    "branch_count": len(branches),
                    "worktree_count": len(worktrees),
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            connection.execute(
                """
                INSERT INTO events(
                  repository_id, reconciliation_id, operation_id, occurred_at,
                  actor, action, detail_json
                ) VALUES (1, ?, NULL, ?, 'fm-pr-stack', 'inventory.reconciled', ?)
                """,
                (reconciliation_id, observed_at, event_detail),
            )
            connection.commit()
            return reconciliation_id, journal_mode
        except Exception:
            connection.rollback()
            raise
    except sqlite3.OperationalError as error:
        if is_busy_error(error):
            raise CatalogBusyError(
                f"catalog writer remained busy for {lock_timeout_ms} ms; retry inventory after the other refresh finishes"
            ) from error
        raise InventoryError(f"could not update catalog: {error}") from error
    except sqlite3.DatabaseError as error:
        raise InventoryError(f"could not update catalog: {error}") from error
    finally:
        connection.close()


def inventory(
    repo: Path, base_override: str | None, lock_timeout_ms: int
) -> dict[str, Any]:
    observed_at = now_utc()
    common_dir = common_git_dir(repo)
    base = select_base(repo, base_override)
    invoking_head_oid = resolve_commit(repo, "HEAD", "repository HEAD")
    worktrees = scan_worktrees(repo)
    branches = scan_branches(repo, base, worktrees)
    catalog = common_dir / CATALOG_RELATIVE_PATH
    reconciliation_id, journal_mode = reconcile_catalog(
        catalog,
        common_dir,
        observed_at,
        base,
        invoking_head_oid,
        worktrees,
        branches,
        lock_timeout_ms,
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "observed_at": observed_at,
        "query": "inventory",
        "repository_head": invoking_head_oid,
        "selected_base": base,
        "catalog": {
            "path": os.fspath(catalog),
            "schema_version": SCHEMA_VERSION,
            "reconciliation_id": reconciliation_id,
            "journal_mode": journal_mode,
        },
        "worktrees": worktrees,
        "items": branches,
    }


def render_human(snapshot: dict[str, Any]) -> None:
    base = snapshot["selected_base"]
    worktrees = snapshot["worktrees"]
    branches = snapshot["items"]
    dirty = sum(worktree["clean"] is False for worktree in worktrees)
    detached = sum(worktree["detached"] for worktree in worktrees)
    print(f"PR-stack inventory observed {snapshot['observed_at']}")
    print(f"Base: {base['name']} @ {base['oid'][:12]} ({base['source']})")
    print(f"Worktrees: {len(worktrees)} ({dirty} dirty, {detached} detached)")
    print("Branches:")
    for branch in branches:
        clean = "-"
        if branch["worktree_clean"] is True:
            clean = "clean"
        elif branch["worktree_clean"] is False:
            clean = "dirty"
        location = ""
        if branch["checked_out_worktree"]:
            location = (
                f" @ {json.dumps(branch['checked_out_worktree'], ensure_ascii=False)}"
            )
        upstream = f" -> {branch['upstream']}" if branch["upstream"] else ""
        print(
            f"  {branch['disposition']:<12} unique={branch['unique_commit_count']:<4} "
            f"{clean:<5} {branch['name']}{upstream}{location}"
        )
    catalog = snapshot["catalog"]
    print(
        f"Catalog: {catalog['path']} "
        f"(schema {catalog['schema_version']}, reconciliation {catalog['reconciliation_id']})"
    )


def positive_timeout(value: str) -> int:
    try:
        timeout = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "must be an integer number of milliseconds"
        ) from exc
    if timeout < 1 or timeout > 60_000:
        raise argparse.ArgumentTypeError("must be between 1 and 60000 milliseconds")
    return timeout


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="fm-pr-stack.py",
        description="Reconcile read-only Git branch/worktree inventory into the shared PR-stack catalog.",
    )
    subcommands = command.add_subparsers(dest="command", required=True)
    inventory_parser = subcommands.add_parser(
        "inventory",
        help="observe all linked worktrees and local branches",
    )
    inventory_parser.add_argument(
        "--base",
        metavar="REVISION",
        help="explicit integration base (otherwise origin/HEAD, then an unambiguous local main or master)",
    )
    inventory_parser.add_argument(
        "--json",
        action="store_true",
        help="print the stable agent-readable JSON object",
    )
    inventory_parser.add_argument(
        "--lock-timeout-ms",
        type=positive_timeout,
        default=positive_timeout(
            os.environ.get("FM_PR_STACK_LOCK_TIMEOUT_MS", str(DEFAULT_LOCK_TIMEOUT_MS))
        ),
        help=argparse.SUPPRESS,
    )
    return command


def fail(message: str, code: int = 1) -> NoReturn:
    print(f"fm-pr-stack: {message}", file=sys.stderr)
    raise SystemExit(code)


def main() -> int:
    arguments = parser().parse_args()
    try:
        repo = repository_root()
        if arguments.command == "inventory":
            snapshot = inventory(repo, arguments.base, arguments.lock_timeout_ms)
            if arguments.json:
                print(json.dumps(snapshot, indent=2, sort_keys=True, ensure_ascii=True))
            else:
                render_human(snapshot)
            return 0
        raise AssertionError(f"unhandled command {arguments.command}")
    except CatalogBusyError as error:
        fail(str(error), 3)
    except InventoryError as error:
        fail(str(error), 2)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
