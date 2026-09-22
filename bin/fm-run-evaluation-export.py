#!/usr/bin/env python3
"""Validate, redact, and atomically publish the neutral Cockpit run-evaluation snapshot."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from types import ModuleType
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
CONTRACT_DIR = SCRIPT_DIR / "contracts" / "run-evaluation-v1"
VALIDATOR_PATH = CONTRACT_DIR / "validate_run_evaluation.py"
POLICY_PATH = CONTRACT_DIR / "cockpit-redaction-policy-v1.json"
VENDORED_VALIDATOR_SHA256 = "5f9ef989ed02260ff61328c7ca91f84529ab1a61f28abd01ba162780b6bbefc7"
PRODUCER_ADAPTER = "firstmate-run-evaluation-export"
PRODUCER_ADAPTER_VERSION = "1"
OUTPUT_NAME = "cockpit-run-evaluation.json"
SOURCE_DIRECTORY_NAME = "run-evaluations"
COMMON_CREDENTIAL_SHAPE = re.compile(
    r"(?:"
    r"github_pat_[A-Za-z0-9_]{20,}|"
    r"gh[pousr]_[A-Za-z0-9]{20,}|"
    r"glpat-[A-Za-z0-9_-]{20,}|"
    r"(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|"
    r"sk-(?:ant-|proj-|svcacct-)?[A-Za-z0-9_-]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]{20,}|"
    r"AIza[0-9A-Za-z_-]{35}|"
    r"(?:AKIA|ASIA)[A-Z0-9]{16}"
    r")"
)


class ExportError(RuntimeError):
    """A safe operator-facing export failure."""


def load_contract_validator() -> Any:
    try:
        source = VALIDATOR_PATH.read_bytes()
    except OSError as exc:
        raise ExportError(f"the vendored governance validator is unavailable: {exc}") from exc
    actual = hashlib.sha256(source).hexdigest()
    if actual != VENDORED_VALIDATOR_SHA256:
        raise ExportError("the vendored governance validator does not match its pinned digest")
    module = ModuleType("fm_governance_run_evaluation_v1")
    module.__file__ = str(VALIDATOR_PATH)
    try:
        code = compile(source.decode("utf-8"), str(VALIDATOR_PATH), "exec")
        exec(code, module.__dict__)
    except (SyntaxError, UnicodeDecodeError) as exc:
        raise ExportError("the vendored governance validator could not be loaded") from exc
    return module


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def reject_nonstandard_number(value: str) -> None:
    raise ValueError(f"non-standard JSON number: {value}")


def load_json_bytes(raw: bytes) -> Any:
    return json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_nonstandard_number,
    )


def load_policy(validator: Any) -> tuple[dict[str, Any], str]:
    try:
        policy = load_json_bytes(POLICY_PATH.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise ExportError(f"the Cockpit redaction policy is invalid: {exc}") from exc
    expected = {
        "id",
        "version",
        "sourceContract",
        "consumerContract",
        "validatorOrigin",
        "allowedDataClasses",
        "allowedEvidenceVisibility",
        "prohibitedContent",
        "withheldReasonCodes",
        "projectionOnly",
    }
    if not isinstance(policy, dict) or set(policy) != expected:
        raise ExportError("the Cockpit redaction policy has an unexpected shape")
    if policy["sourceContract"] != validator.EVALUATION_SCHEMA_VERSION:
        raise ExportError("the Cockpit redaction policy references the wrong source contract")
    if policy["consumerContract"] != validator.EXPORT_SCHEMA_VERSION:
        raise ExportError("the Cockpit redaction policy references the wrong consumer contract")
    if policy["id"] != "firstmate.cockpit-surface-labelled" or policy["version"] != 1:
        raise ExportError("the Cockpit redaction policy identity is unexpected")
    origin = policy["validatorOrigin"]
    expected_origin = {
        "repository": "00_Architektur",
        "branch": "codex/run-evaluation-contract-v1",
        "commit": "b5f4104f93d075cd9140c4dcb6cf06fbeb1501ac",
        "path": "scripts/validate_run_evaluation.py",
        "sha256": VENDORED_VALIDATOR_SHA256,
        "canonicalMainAtCopy": False,
    }
    if origin != expected_origin:
        raise ExportError("the vendored governance validator provenance is inconsistent")
    if set(policy["allowedDataClasses"]) != validator.EXPORT_DATA_CLASSES:
        raise ExportError("the Cockpit redaction policy has the wrong data-class allowlist")
    if policy["allowedEvidenceVisibility"] != "surface_labelled" or policy["projectionOnly"] is not True:
        raise ExportError("the Cockpit redaction policy weakens the projection boundary")
    if policy["prohibitedContent"] != [
        "free_text",
        "private_path",
        "prompt",
        "secret",
        "transcript",
    ]:
        raise ExportError("the Cockpit redaction policy has the wrong prohibited-content boundary")
    if policy["withheldReasonCodes"] != [
        "byte_limit",
        "classification_blocked",
        "duplicate_source",
        "evaluation_identity_conflict",
        "record_limit",
        "redaction_blocked",
        "revision_conflict",
        "revision_superseded",
        "source_invalid",
        "source_read_failed",
        "source_symlink_blocked",
    ]:
        raise ExportError("the Cockpit redaction policy has the wrong withheld-reason vocabulary")
    digest = validator.canonical_digest("redaction-policy.v1", policy)
    return policy, digest


def primary_validation_reason(findings: list[dict[str, str]]) -> str:
    codes = {item.get("code") for item in findings}
    if "credential_shaped_value" in codes:
        return "redaction_blocked"
    if codes & {
        "evaluation_data_class_too_low",
        "evidence_class_exceeds_evaluation",
    }:
        return "classification_blocked"
    return "source_invalid"


def evidence_is_exportable(document: dict[str, Any], allowed_data_classes: set[str]) -> bool:
    dimensions = document.get("dimensions")
    if not isinstance(dimensions, dict):
        return False
    for dimension in dimensions.values():
        if not isinstance(dimension, dict):
            return False
        evidence_refs = dimension.get("evidenceRefs")
        if not isinstance(evidence_refs, list):
            return False
        for evidence in evidence_refs:
            if (
                not isinstance(evidence, dict)
                or evidence.get("visibility") != "surface_labelled"
                or evidence.get("dataClass") not in allowed_data_classes
            ):
                return False
    return True


def contains_credential_shaped_value(document: dict[str, Any], validator: Any) -> bool:
    serialized = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return bool(
        validator.CREDENTIAL_SHAPE.search(serialized)
        or COMMON_CREDENTIAL_SHAPE.search(serialized)
    )


def source_record(document: dict[str, Any], source_digest: str) -> dict[str, Any]:
    return {
        "sourceEvaluationId": document["evaluationId"],
        "sourceEvaluationDigest": source_digest,
        "runId": document["derivedFrom"]["agentRunRecord"]["runId"],
        "evaluatedAt": document["evaluatedAt"],
        "taskClass": document["contextAxes"]["taskClass"],
        "dataClass": document["dataClass"],
        "state": deepcopy(document["state"]),
        "scoringProfile": {
            "id": document["scoringProfile"]["id"],
            "version": document["scoringProfile"]["version"],
            "digest": document["scoringProfile"]["digest"],
        },
        "subject": {
            "model": deepcopy(document["subject"]["model"]),
            "executionHarness": deepcopy(document["subject"]["executionHarness"]),
            "route": {"routeRef": document["subject"]["route"]["routeRef"]},
        },
        "identityKeys": deepcopy(document["identityKeys"]),
        "dimensions": deepcopy(document["dimensions"]),
        "comparisons": deepcopy(document["comparisons"]),
    }


def regular_source_files(source_dir: Path) -> list[Path]:
    try:
        if source_dir.is_symlink():
            raise ExportError("the run-evaluation source directory must not be a symlink")
        if not source_dir.exists():
            raise ExportError("the run-evaluation source directory does not exist")
        if not source_dir.is_dir():
            raise ExportError("the run-evaluation source path is not a directory")
        return sorted(source_dir.glob("*.json"), key=lambda path: path.name)
    except OSError as exc:
        raise ExportError(f"the run-evaluation source directory is unreadable: {exc}") from exc


def read_candidates(
    source_dir: Path,
    validator: Any,
    policy: dict[str, Any],
) -> tuple[list[dict[str, Any]], Counter[str]]:
    candidates: list[dict[str, Any]] = []
    withheld: Counter[str] = Counter()
    allowed_data_classes = set(policy["allowedDataClasses"])
    for path in regular_source_files(source_dir):
        try:
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                withheld["source_symlink_blocked"] += 1
                continue
            if not stat.S_ISREG(metadata.st_mode):
                withheld["source_read_failed"] += 1
                continue
            raw = path.read_bytes()
        except OSError:
            withheld["source_read_failed"] += 1
            continue
        try:
            document = load_json_bytes(raw)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            withheld["source_invalid"] += 1
            continue
        declared_classification_block = (
            isinstance(document, dict)
            and document.get("kind") == validator.EVALUATION_KIND
            and isinstance(document.get("dataClass"), str)
            and document["dataClass"] in validator.DATA_CLASS_ORDER
            and document["dataClass"] not in allowed_data_classes
        )
        declared_credential_block = (
            isinstance(document, dict)
            and contains_credential_shaped_value(document, validator)
        )
        try:
            findings = validator.validate_evaluation(document)
        except Exception:
            withheld["source_invalid"] += 1
            continue
        if findings:
            reason = (
                "classification_blocked"
                if declared_classification_block
                else "redaction_blocked"
                if declared_credential_block
                else primary_validation_reason(findings)
            )
            withheld[reason] += 1
            continue
        block_reason = None
        if declared_classification_block:
            block_reason = "classification_blocked"
        elif document["state"]["status"] == "invalid":
            block_reason = "source_invalid"
        elif declared_credential_block:
            block_reason = "redaction_blocked"
        elif not evidence_is_exportable(document, allowed_data_classes):
            block_reason = "redaction_blocked"
        candidates.append(
            {
                "document": document,
                "sourceRevision": document["freshness"]["sourceRevision"],
                "evaluatedAt": document["evaluatedAt"],
                "evaluationId": document["evaluationId"],
                "runId": document["derivedFrom"]["agentRunRecord"]["runId"],
                "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
                "blockReason": block_reason,
            }
        )
    return candidates, withheld


def select_current_revisions(
    candidates: list[dict[str, Any]],
    withheld: Counter[str],
) -> list[dict[str, Any]]:
    by_evaluation: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for candidate in candidates:
        by_evaluation[candidate["evaluationId"]].append(candidate)
    identity_safe: list[dict[str, Any]] = []
    for group in by_evaluation.values():
        if len({item["runId"] for item in group}) > 1:
            withheld["evaluation_identity_conflict"] += len(group)
        else:
            identity_safe.extend(group)

    by_run: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for candidate in identity_safe:
        by_run[candidate["runId"]].append(candidate)
    selected: list[dict[str, Any]] = []
    for group in by_run.values():
        max_revision = max(item["sourceRevision"] for item in group)
        newest = [item for item in group if item["sourceRevision"] == max_revision]
        older = [item for item in group if item["sourceRevision"] != max_revision]
        withheld["revision_superseded"] += len(older)
        unique: dict[tuple[str, str], dict[str, Any]] = {}
        for item in newest:
            key = (item["evaluationId"], item["digest"])
            if key in unique:
                withheld["duplicate_source"] += 1
            else:
                unique[key] = item
        if len(unique) != 1:
            withheld["revision_conflict"] += len(unique)
            continue
        current = next(iter(unique.values()))
        if current["blockReason"] is not None:
            withheld[current["blockReason"]] += 1
        else:
            current["record"] = source_record(current["document"], current["digest"])
            selected.append(current)
    return selected


def parse_evaluated_at(value: str) -> datetime:
    return datetime.fromisoformat(value[:-1] + "+00:00")


def make_document(
    records: list[dict[str, Any]],
    withheld: Counter[str],
    policy: dict[str, Any],
    policy_digest: str,
    generated_at: str,
    validator: Any,
) -> dict[str, Any]:
    unknown_reasons = set(withheld) - set(policy["withheldReasonCodes"])
    if unknown_reasons:
        raise ExportError("the exporter produced a withheld reason outside its pinned policy")
    return {
        "schemaVersion": validator.EXPORT_SCHEMA_VERSION,
        "kind": validator.EXPORT_KIND,
        "generatedAt": generated_at,
        "source": {
            "producerAdapter": PRODUCER_ADAPTER,
            "producerAdapterVersion": PRODUCER_ADAPTER_VERSION,
            "evaluationSchemaVersion": validator.EVALUATION_SCHEMA_VERSION,
            "redactionPolicy": {
                "id": policy["id"],
                "version": policy["version"],
                "digest": policy_digest,
            },
        },
        "freshness": {"staleAfterSeconds": validator.EXPORT_STALE_AFTER_SECONDS},
        "retention": {
            "mode": "rolling_snapshot",
            "maxRecords": validator.EXPORT_MAX_RECORDS,
            "maxBytes": validator.EXPORT_MAX_BYTES,
        },
        "records": [item["record"] for item in records],
        "withheld": {
            "count": sum(withheld.values()),
            "reasonCounts": [
                {"code": code, "count": count}
                for code, count in sorted(withheld.items())
                if count > 0
            ],
        },
    }


def serialize(document: dict[str, Any]) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def bounded_document(
    selected: list[dict[str, Any]],
    withheld: Counter[str],
    policy: dict[str, Any],
    policy_digest: str,
    generated_at: str,
    validator: Any,
) -> tuple[dict[str, Any], bytes]:
    selected.sort(
        key=lambda item: (
            parse_evaluated_at(item["evaluatedAt"]),
            item["evaluationId"],
        ),
        reverse=True,
    )
    if len(selected) > validator.EXPORT_MAX_RECORDS:
        withheld["record_limit"] += len(selected) - validator.EXPORT_MAX_RECORDS
        selected = selected[: validator.EXPORT_MAX_RECORDS]
    while True:
        document = make_document(
            selected,
            withheld,
            policy,
            policy_digest,
            generated_at,
            validator,
        )
        payload = serialize(document)
        if len(payload) <= validator.EXPORT_MAX_BYTES:
            return document, payload
        if not selected:
            raise ExportError("the empty run-evaluation export exceeds its byte limit")
        selected.pop()
        withheld["byte_limit"] += 1


def ensure_output_directory(state_dir: Path) -> None:
    if state_dir.is_symlink():
        raise ExportError("the FirstMate state directory must not be a symlink")
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not state_dir.is_dir() or state_dir.is_symlink():
        raise ExportError("the FirstMate state path is not a safe directory")


def validate_existing_output(output: Path) -> None:
    try:
        metadata = output.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ExportError("the Cockpit run-evaluation destination is not a regular file")


def atomic_publish(output: Path, payload: bytes) -> None:
    ensure_output_directory(output.parent)
    validate_existing_output(output)
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{OUTPUT_NAME}.",
            dir=output.parent,
        )
        temporary = Path(raw_path)
        fchmod = getattr(os, "fchmod", None)
        if fchmod is not None:
            fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        validate_existing_output(output)
        os.replace(temporary, output)
        temporary = None
        try:
            directory_descriptor = os.open(output.parent, os.O_RDONLY)
        except OSError:
            directory_descriptor = -1
        if directory_descriptor >= 0:
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
    except OSError as exc:
        raise ExportError(f"atomic Cockpit run-evaluation publication failed: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Publish FirstMate's neutral, redacted Cockpit run-evaluation snapshot."
    )
    return parser.parse_args(argv)


def environment_path(name: str, fallback: Path) -> Path:
    return Path(os.environ.get(name) or fallback)


def main(argv: list[str] | None = None) -> int:
    parse_args(argv)
    root = environment_path("FM_ROOT_OVERRIDE", SCRIPT_DIR.parent)
    home = environment_path("FM_HOME", root)
    data_dir = environment_path("FM_DATA_OVERRIDE", home / "data")
    state_dir = environment_path("FM_STATE_OVERRIDE", home / "state")
    source_dir = data_dir / SOURCE_DIRECTORY_NAME
    output = state_dir / OUTPUT_NAME
    try:
        validator = load_contract_validator()
        policy, policy_digest = load_policy(validator)
        candidates, withheld = read_candidates(source_dir, validator, policy)
        selected = select_current_revisions(candidates, withheld)
        document, payload = bounded_document(
            selected,
            withheld,
            policy,
            policy_digest,
            utc_now(),
            validator,
        )
        findings = validator.validate_document(document, source_bytes=len(payload))
        if findings:
            raise ExportError("the generated Cockpit run-evaluation document failed validation")
        atomic_publish(output, payload)
    except ExportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        f"published {len(document['records'])} run-evaluation record(s); "
        f"withheld {document['withheld']['count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
