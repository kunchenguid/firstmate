#!/usr/bin/env python3
"""Validate the retained outcome evidence that authorizes verified delivery cleanup."""

from __future__ import annotations

import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import NoReturn


SHA = re.compile(r"^[0-9a-f]{40}$")


def refuse(message: str) -> NoReturn:
    raise ValueError(message)


def object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            refuse(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def required_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        refuse(f"{field} must be a non-empty string")
    return value


def required_object(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        refuse(f"{field} must be an object")
    return value


def read_meta(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def validate(_task_id: str, meta_path: Path, evidence_path: Path) -> None:
    evidence_stat = os.lstat(evidence_path)
    if stat.S_ISLNK(evidence_stat.st_mode) or not stat.S_ISREG(evidence_stat.st_mode):
        refuse("outcome evidence must be one regular file, not a link")
    if evidence_stat.st_size > 1024 * 1024:
        refuse("outcome evidence exceeds the 1 MiB structural-validation limit")

    meta = read_meta(meta_path)
    expected_pr = required_string(meta.get("pr"), "task metadata pr")
    expected_head = required_string(meta.get("pr_head"), "task metadata pr_head")
    if not SHA.fullmatch(expected_head):
        refuse("task metadata pr_head must be a lowercase 40-character revision")

    evidence = json.loads(
        evidence_path.read_text(encoding="utf-8"),
        object_pairs_hook=object_without_duplicate_keys,
    )
    root = required_object(evidence, "outcome evidence")
    if type(root.get("schema_version")) is not int or root.get("schema_version") != 1:
        refuse("schema_version must be integer 1")
    if root.get("verdict") != "VERIFIED":
        refuse("verdict must be VERIFIED")

    required_string(root.get("issue"), "issue")
    required_string(root.get("acceptance"), "acceptance")
    required_string(root.get("evidence_ref"), "evidence_ref")
    required_string(root.get("created_at"), "created_at")

    release = required_object(root.get("release"), "release")
    if release.get("pr_url") != expected_pr:
        refuse("release.pr_url does not match the task PR")
    if release.get("pr_head_revision") != expected_head:
        refuse("release.pr_head_revision does not match the task PR head")
    merge_revision = required_string(release.get("merge_revision"), "release.merge_revision")
    if not SHA.fullmatch(merge_revision):
        refuse("release.merge_revision must be a lowercase 40-character revision")

    tested_source = required_object(root.get("tested_source"), "tested_source")
    if tested_source.get("revision") != merge_revision:
        refuse("tested_source.revision does not match release.merge_revision")
    if not isinstance(tested_source.get("worktree_fingerprint"), (str, type(None))):
        refuse("tested_source.worktree_fingerprint must be a string or null")

    target = required_object(root.get("target"), "target")
    if target.get("environment") != "production":
        refuse("target.environment must be production")
    required_string(target.get("identity"), "target.identity")
    required_string(target.get("runtime_revision"), "target.runtime_revision")
    runtime_evidence = target.get("runtime_revision_evidence")
    if not isinstance(runtime_evidence, (str, list, dict)) or not runtime_evidence:
        refuse("target.runtime_revision_evidence must identify retained deployment proof")
    if not isinstance(target.get("database_identity"), (str, type(None))):
        refuse("target.database_identity must be a string or null")

    boundaries = root.get("boundaries")
    if not isinstance(boundaries, list) or not boundaries:
        refuse("boundaries must be a non-empty list")
    for index, boundary_value in enumerate(boundaries):
        boundary = required_object(boundary_value, f"boundaries[{index}]")
        required_string(boundary.get("name"), f"boundaries[{index}].name")
        if not isinstance(boundary.get("actions"), list) or not boundary.get("actions"):
            refuse(f"boundaries[{index}].actions must be a non-empty list")
        required_string(boundary.get("expected"), f"boundaries[{index}].expected")
        required_string(boundary.get("actual"), f"boundaries[{index}].actual")
        if not isinstance(boundary.get("artifacts"), list) or not boundary.get("artifacts"):
            refuse(f"boundaries[{index}].artifacts must be a non-empty list")

    cleanup = required_object(root.get("cleanup"), "cleanup")
    for name in ("run_owned_resources", "removed", "residuals"):
        if not isinstance(cleanup.get(name), list):
            refuse(f"cleanup.{name} must be a list")
    if root.get("unverified_paths") != []:
        refuse("unverified_paths must be empty for VERIFIED evidence")


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: fm-outcome-evidence.py <task-id> <task-meta> <outcome-evidence.json>", file=sys.stderr)
        return 2
    try:
        validate(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"REFUSED: invalid verified-production outcome evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
