#!/usr/bin/env python3
"""Read-only pre-acquisition inventory for fm_treehouse_preacquire_guard.

Usage: fm-treehouse-inventory.py PROJECT STATE-DIR...
Runs while the caller holds the canonical project lock. Never invokes Treehouse:
even `status` may rewrite its state. Reads Treehouse v2's configured pool and
linked-worktree pools, retained task records, and claims. Unknown configuration,
malformed inventory, orphan ownership, or an unreserved retained copy refuses.
No PID liveness observation can authorize reuse. Configured TOML requires the
Python standard-library tomllib; absence refuses rather than guessing a pool.
This cannot serialize an external allocator that ignores Firstmate's lock.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def git(path, *args):
    return subprocess.check_output(
        ["git", "-C", str(path), *args], stderr=subprocess.DEVNULL
    ).decode().strip()


def regular(path):
    require(path.is_file() and not path.is_symlink(), f"unsafe inventory file: {path}")


def fields(path):
    regular(path)
    result = {}
    for line in path.read_text().splitlines():
        require("\0" not in line, f"NUL in inventory: {path}")
        key, sep, value = line.partition("=")
        if sep:
            require(key not in result, f"duplicate {key} in {path}")
            result[key] = value
    return result


def common(path):
    return Path(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve(strict=True)


def configured_pool(project):
    configs = [project / "treehouse.toml", Path.home() / ".config/treehouse/config.toml"]
    values = []
    for path in configs:
        if path.exists() or path.is_symlink():
            regular(path)
            try:
                import tomllib
            except ImportError as exc:
                raise ValueError("configured Treehouse pools require Python tomllib for safe inspection") from exc
            with path.open("rb") as stream:
                values.append(tomllib.load(stream))
        else:
            values.append(None)
    # Treehouse's repository configuration owns root when present; otherwise
    # the user configuration supplies it. Hooks do not affect pool selection.
    config = values[0] if values[0] is not None else values[1] or {}
    root = config.get("root", "")
    require(isinstance(root, str), "Treehouse root is not a string")
    if root:
        root = re.sub(r"\$(?:\{([^}]+)\}|([A-Za-z_][A-Za-z_0-9]*))",
                      lambda m: os.environ.get(m[1] or m[2], ""), root)
        base = Path(root)
        if not base.is_absolute():
            base = project / base
    else:
        base = Path.home()
    try:
        identity = git(project, "remote", "get-url", "origin")
    except subprocess.CalledProcessError:
        identity = str(project)
    return base / ".treehouse" / (project.name + "-" + hashlib.sha256(identity.encode()).hexdigest()[:6])


def inventory(project, state_dirs):
    repo = common(project)
    require(repo.name == ".git" and (repo.parent / ".git").is_dir(), "unsupported Git common-directory layout")
    primary = repo.parent
    require(common(primary) == repo, "cannot verify primary repository identity")
    pools = {configured_pool(primary).resolve()}
    # Existing pools reached through linked roots may use an older key. They
    # remain protected; changing the launch path never silently migrates them.
    paths = subprocess.check_output(["git", "-C", str(primary), "worktree", "list", "--porcelain", "-z"])
    for entry in paths.split(b"\0"):
        if entry.startswith(b"worktree "):
            path = Path(os.fsdecode(entry[9:])).resolve()
            if ((path.parent.parent / "treehouse-state.json").exists()
                    or (path.parent / ".fm-slot-owner").exists()
                    or (path.parent / ".fm-slot-owner").is_symlink()):
                pools.add(path.parent.parent)
    records = {}
    for state in state_dirs:
        require(state.is_dir() and not state.is_symlink(), f"cannot inspect registered state directory: {state}")
        for meta in state.glob("*.meta"):
            record = fields(meta)
            for value in set(filter(None, [record.get("worktree"), record.get("home")])):
                path = Path(value).resolve()
                if path.parent.parent in pools:
                    require(path not in records, f"multiple retained task records name pool slot {path}")
                    records[path] = (meta.stem, state.parent.resolve(), record)
    seen = set()
    for pool in pools:
        if not pool.exists():
            continue
        require(pool.is_dir() and not pool.is_symlink(), f"unsafe pool directory: {pool}")
        state_file = pool / "treehouse-state.json"
        if not state_file.exists():
            require(not any(pool.iterdir()), f"pool has files but no readable state: {pool}")
            continue
        regular(state_file)
        state_data = json.loads(state_file.read_text())
        require(isinstance(state_data, dict), f"malformed pool inventory: {state_file}")
        entries = state_data.get("worktrees")
        require(isinstance(entries, list), f"malformed pool inventory: {state_file}")
        slots = set()
        for entry in entries:
            require(isinstance(entry, dict) and isinstance(entry.get("path"), str), f"malformed slot: {state_file}")
            path = Path(entry["path"])
            require(path.is_absolute() and path.is_dir() and not path.is_symlink(), f"uninspectable slot: {path}")
            path = path.resolve(strict=True)
            require(path.parent.parent == pool and path.parent.name == entry.get("name"), f"foreign slot path: {path}")
            require(path not in seen, f"duplicate pool entry: {path}")
            seen.add(path)
            slots.add(path.parent)
            require(common(path) == repo, f"foreign repository in pool: {path}")
            require(not entry.get("destroying"), f"slot destruction is in progress: {path}")
            marker = path.parent / ".fm-slot-owner"
            owner = records.get(path)
            if owner:
                task, home, record = owner
                require(marker.exists() or marker.is_symlink(), f"task {task}'s slot has no owner claim: {path}")
                claim = fields(marker)
                require(claim.get("task") == task, f"slot claimed by {claim.get('task', 'unknown')} in another task: {path}")
                claim_home = Path(claim.get("home", ""))
                require(claim_home.is_absolute() and claim_home.is_dir(),
                        f"slot claimed by {task} in an unreadable or relative home: {path}")
                require(claim_home.resolve(strict=True) == home, f"slot claimed by {task} in another home: {path}")
                token = record.get("allocation_id")
                require(token and entry.get("leased") is True and entry.get("lease_holder") == token
                        and claim.get("allocation_id") == token,
                        f"task {task}'s slot has no durable allocation reservation matching its claim: {path}")
            else:
                require(not marker.exists() and not marker.is_symlink(), f"orphan owner claim: {marker}")
                require(not entry.get("leased") and not entry.get("lease_holder")
                        and not entry.get("owner_pid") and not entry.get("owner_started_at"),
                        f"unreconciled external or legacy reservation: {path}")
        for child in pool.iterdir():
            if child.is_dir() or child.is_symlink():
                require(child in slots, f"orphan pool directory: {child}")
    require(set(records).issubset(seen), "retained pool path is absent from allocator inventory")


if __name__ == "__main__":
    try:
        require(len(sys.argv) >= 3, "usage: fm-treehouse-inventory.py PROJECT STATE-DIR...")
        inventory(Path(sys.argv[1]).resolve(strict=True), [Path(p) for p in sys.argv[2:]])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Treehouse allocation refused: {error}", file=sys.stderr)
        sys.exit(1)
