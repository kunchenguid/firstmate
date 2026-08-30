#!/usr/bin/env python3
"""Byte-identified deterministic claude-obsidian transaction fixture for CI."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def file_hash(path):
    if not path.exists():
        return None
    return digest(path.read_bytes())


def load(bundle_path):
    return json.loads(Path(bundle_path).read_text(encoding="utf-8"))


def plan(bundle, vault):
    info = vault.stat()
    bundle_sha = digest(canonical(bundle))
    changed = [item["path"] for item in bundle["writes"]]
    hashes = {item["path"]: digest(item["content"].encode()) for item in bundle["writes"]}
    identity = {"device": info.st_dev, "inode": info.st_ino, "path": str(vault)}
    approval = digest(canonical({"bundle": bundle, "vault_identity": identity}))
    return {
        "schema": "claude-obsidian.transaction-plan.v1",
        "operation_id": bundle["operation_id"],
        "operation_type": bundle["operation_type"],
        "valid": True,
        "changed_paths": changed,
        "hashes": hashes,
        "modes": {item["path"]: 0o644 for item in bundle["writes"]},
        "input_bundle_sha256": bundle_sha,
        "expanded_bundle_sha256": bundle_sha,
        "vault_identity": identity,
        "approval_sha256": approval,
    }


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(canonical(value) + b"\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def inspect(bundle_path, vault):
    bundle = load(bundle_path)
    if bundle.get("schema") != "claude-obsidian.transaction.v1" or bundle.get("operation_type") != "save":
        raise ValueError("invalid bundle")
    for item in bundle.get("writes", []):
        relative = item.get("path")
        if not isinstance(relative, str) or relative.startswith("/") or ".." in Path(relative).parts or not relative.startswith("wiki/"):
            raise ValueError("unsafe path")
        expected = bundle["expected_hashes"].get(relative, "missing")
        if item.get("mode") == "create" and expected is not None:
            raise ValueError("create expected hash")
        if item.get("mode") == "replace" and not isinstance(expected, str):
            raise ValueError("replace expected hash")
    return plan(bundle, vault)


def apply(bundle_path, vault, approval):
    bundle = load(bundle_path)
    reviewed = inspect(bundle_path, vault)
    if reviewed["approval_sha256"] != approval:
        raise ValueError("PLAN_CHANGED")
    meta = vault / ".vault-meta"
    operation = meta / "transactions" / bundle["operation_id"]
    result_path = operation / "changed-paths.json"
    bundle_sha = reviewed["input_bundle_sha256"]
    if result_path.is_file():
        result = json.loads(result_path.read_text(encoding="utf-8"))
        if result.get("bundle_sha256") != bundle_sha:
            raise Conflict("OPERATION_ID_REUSED")
        return result
    lock = meta / "mutation.lock"
    meta.mkdir(parents=True, exist_ok=True)
    try:
        lock_fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise Conflict("LOCK_TIMEOUT") from exc
    os.close(lock_fd)
    before = {}
    written = []
    try:
        for item in bundle["writes"]:
            target = vault / item["path"]
            expected = bundle["expected_hashes"][item["path"]]
            if file_hash(target) != expected:
                raise Conflict("EXPECTED_HASH_MISMATCH")
        operation.mkdir(parents=True, exist_ok=True)
        journal = {
            "schema": "claude-obsidian.transaction-journal.v1",
            "operation_id": bundle["operation_id"],
            "operation_type": "save",
            "input_bundle_sha256": bundle_sha,
            "expanded_bundle_sha256": bundle_sha,
            "approval_sha256": approval,
            "state": "applying",
            "writes": [],
            "applied": [],
        }
        for item in bundle["writes"]:
            target = vault / item["path"]
            before[item["path"]] = target.read_bytes() if target.exists() else None
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(item["content"], encoding="utf-8")
            written.append(item["path"])
            journal["writes"].append({"path": item["path"]})
            journal["applied"].append(item["path"])
            write_private(operation / "journal.json", journal)
            if os.environ.get("FM_FIXTURE_FAIL_AFTER") == str(len(written)):
                raise RuntimeError("injected crash")
        result = {
            "schema": "claude-obsidian.transaction-result.v1",
            "operation_id": bundle["operation_id"],
            "operation_type": "save",
            "bundle_sha256": bundle_sha,
            "expanded_bundle_sha256": bundle_sha,
            "approval_sha256": approval,
            "status": "complete",
            "changed_paths": [item["path"] for item in bundle["writes"]],
            "hashes": reviewed["hashes"],
            "modes": reviewed["modes"],
        }
        write_private(result_path, result)
        journal["state"] = "complete"
        write_private(operation / "journal.json", journal)
        return result
    except BaseException:
        for relative in reversed(written):
            target = vault / relative
            old = before[relative]
            if old is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(old)
        if operation.exists():
            journal_path = operation / "journal.json"
            if journal_path.exists():
                journal = json.loads(journal_path.read_text(encoding="utf-8"))
                journal["state"] = "rolled-back"
                write_private(journal_path, journal)
        raise
    finally:
        lock.unlink(missing_ok=True)


class Conflict(RuntimeError):
    pass


def main():
    args = sys.argv[1:]
    if len(args) < 5 or args[0:2] not in (["transaction", "inspect"], ["transaction", "apply"]):
        raise SystemExit(2)
    bundle_path = args[2]
    try:
        vault = Path(args[args.index("--vault") + 1]).resolve(strict=True)
        if args[1] == "inspect":
            result = inspect(bundle_path, vault)
        else:
            approval = args[args.index("--approved-plan-sha256") + 1]
            result = apply(bundle_path, vault, approval)
    except Conflict:
        raise SystemExit(75)
    except BaseException:
        raise SystemExit(2)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
