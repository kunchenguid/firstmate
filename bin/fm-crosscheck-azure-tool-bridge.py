#!/usr/bin/env python3
"""Host-side bridge from an Azure model verdict to fresh Azure evidence VMs.

The credentialed model compartment never receives Azure control authority or a
repository checkout. This bridge runs in the local trusted controller, validates
reviewer-supplied evidence, and invokes the released private Azure runner twice
per accepted reproduction: one fresh tool attempt and one fresh verifier attempt.
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import tempfile
import time
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "bin" / "fm-azure-runner.py"
REPLAY = ROOT / "bin" / "fm-crosscheck-azure-replay.py"
MAX_EVIDENCE_FILES = 64
MAX_EVIDENCE_FILE_BYTES = 12 * 1024
MAX_EVIDENCE_TOTAL_BYTES = 24 * 1024
SAFE_EVIDENCE_PATH = re.compile(
    r"^\.crosscheck/(?:reproductions|mutations)/[A-Za-z0-9._/+@:-]{1,180}$"
)


class BridgeError(RuntimeError):
    """An exact-source, evidence, runner, or replay boundary failed."""


def canonical(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def digest(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def load_runner() -> Any:
    spec = importlib.util.spec_from_file_location("firstmate_azure_runner", RUNNER)
    if spec is None or spec.loader is None:
        raise BridgeError("Azure runner controller is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_evidence_files(value: Any) -> dict[str, bytes]:
    if not isinstance(value, dict) or len(value) > MAX_EVIDENCE_FILES:
        raise BridgeError("Azure review evidence manifest is missing or oversized")
    result: dict[str, bytes] = {}
    total = 0
    for relative, body in value.items():
        if (
            not isinstance(relative, str)
            or not SAFE_EVIDENCE_PATH.fullmatch(relative)
            or ".." in Path(relative).parts
            or "//" in relative
            or not isinstance(body, str)
        ):
            raise BridgeError("Azure review evidence path or body is invalid")
        encoded = body.encode("utf-8")
        if not encoded or len(encoded) > MAX_EVIDENCE_FILE_BYTES or b"\x00" in encoded:
            raise BridgeError("Azure review evidence file violates its byte contract")
        total += len(encoded)
        if total > MAX_EVIDENCE_TOTAL_BYTES:
            raise BridgeError("Azure review evidence manifest exceeds its aggregate byte bound")
        result[relative] = encoded
    return result


AZURE_EVIDENCE_BATCH_SECONDS = 4 * 3600

REMOTE_EVIDENCE_PROGRAM = REPLAY.read_text(encoding="utf-8")


MAX_ENCODED_MANIFEST_BYTES = 48 * 1024


def encoded_manifest(files: dict[str, bytes]) -> str:
    # The manifest rides the runner request, which is bounded at 48KiB for
    # its control-plane parameter transport; deterministic gzip (mtime=0)
    # keeps realistic textual evidence inside that envelope, and the bound
    # is asserted here so an oversized manifest fails loudly at build time
    # instead of opaquely inside the control plane.
    value = {
        relative: base64.b64encode(body).decode("ascii")
        for relative, body in sorted(files.items())
    }
    encoded = base64.b64encode(gzip.compress(canonical(value), mtime=0)).decode("ascii")
    if len(encoded) > MAX_ENCODED_MANIFEST_BYTES:
        raise BridgeError(
            "evidence manifest exceeds its control-plane parameter bound: "
            f"{len(encoded)} > {MAX_ENCODED_MANIFEST_BYTES} encoded bytes"
        )
    return encoded


def evidence_command(
    files: dict[str, bytes], value: dict[str, Any], receipt: dict[str, Any] | None
) -> list[str]:
    command = [
        "python3",
        "-c",
        REMOTE_EVIDENCE_PROGRAM,
        "--manifest",
        encoded_manifest(files),
        "--test-path",
        str(value["test_path"]),
        "--base-sha",
        str(value["base_sha"]),
        "--head-sha",
        str(value["head_sha"]),
        "--expected-exit",
        str(value["expected_exit"]),
        "--output-contains",
        str(value["output_contains"]),
    ]
    if receipt is not None:
        command.extend(["--receipt-path", str(receipt["path"])])
        for marker in receipt["contains"]:
            command.extend(["--receipt-contains", marker])
    return command


def mutation_command(
    files: dict[str, bytes],
    value: dict[str, Any],
    changed_paths: list[str],
    base_sha: str,
    head_sha: str,
) -> list[str]:
    mutation_files = {
        path: body
        for path, body in files.items()
        if path.startswith(".crosscheck/mutations/")
    }
    command = [
        "python3", "-c", REMOTE_EVIDENCE_PROGRAM,
        "--mode", "mutation",
        "--manifest", encoded_manifest(mutation_files),
        "--test-path", str(value["test_path"]),
        "--base-sha", base_sha,
        "--head-sha", head_sha,
        "--mutation-path", str(value["mutation_patch_path"]),
        "--test-runner", str(value["test_invocation"]["runner"]),
    ]
    for path in changed_paths:
        command.extend(["--changed-path", path])
    return command


def prepare_exact_snapshot(
    runner: Any,
    request: dict[str, Any],
    task_suffix: str,
    command: list[str],
    wall_seconds: int,
) -> tuple[dict[str, Any], Any, dict[str, Any]]:
    root = Path(request["repository_root"]).resolve()
    if not root.is_dir():
        raise BridgeError("exact review checkout is unavailable")
    if runner.git(root, "rev-parse", "HEAD").stdout.strip() != request["head_sha"]:
        raise BridgeError("review checkout head differs from the bound remote PR head")
    if runner.git(root, "status", "--porcelain", "--untracked-files=all").stdout:
        raise BridgeError("review checkout is not an exact clean source snapshot")
    observed_remote = runner.git(root, "remote", "get-url", "origin", check=False)
    if observed_remote.returncode != 0:
        runner.git(root, "remote", "add", "origin", request["remote"])
    elif observed_remote.stdout.strip() != request["remote"]:
        raise BridgeError("review checkout origin differs from the bound GitHub remote")
    parser = runner.parser()
    task = ("cc-" + request["review_generation"][:12] + "-" + task_suffix)[:64]
    with tempfile.TemporaryDirectory(prefix="fm-crosscheck-bundle-") as temporary:
        bundle = Path(temporary) / "snapshot.bundle"
        runner.git(root, "bundle", "create", str(bundle), "HEAD")
        arguments = parser.parse_args(
            [
                "prepare",
                "--repo",
                str(root),
                "--task",
                task,
                "--generation",
                request["review_generation"][:63],
                "--source-ref",
                request["source_ref"],
                "--private-snapshot-bundle",
                str(bundle),
                "--public-ancestor",
                request["base_sha"],
                "--resource-class",
                "crosscheck-tool",
                "--wall-seconds",
                str(wall_seconds),
                "--",
                *command,
            ]
        )
        runner.normalize_command(arguments)
        env = runner.environment()
        crosscheck_wait = int(
            os.environ.get("FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS", "7200")
        )
        if not 0 <= crosscheck_wait <= 86400:
            raise BridgeError(
                "FM_AZURE_CROSSCHECK_QUEUE_WAIT_SECONDS must be between 0 and 86400"
            )
        env["capacity_wait_seconds"] = crosscheck_wait
        state = runner.prepare(env, arguments)
    repository = state["request"]["repository"]
    for field, expected in (
        ("remote", request["remote"]),
        ("source_ref", request["source_ref"]),
        ("source_head", request["head_sha"]),
        ("source_ancestors", [request["base_sha"]]),
        ("commit", request["head_sha"]),
    ):
        if repository.get(field) != expected:
            raise BridgeError("Azure runner source identity mismatch: " + field)
    return state, arguments, env


def dispatch_once(
    runner: Any,
    request: dict[str, Any],
    suffix: str,
    command: list[str],
    wall_seconds: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    state, _arguments, env = prepare_exact_snapshot(
        runner, request, suffix, command, wall_seconds
    )
    # The runner accepts the cost-admission confirmation only as the
    # commissioning double-confirmation; a strict-mode dispatch must omit it.
    admission_mode = state["request"].get("cost_admission_mode")
    runner.dispatch_prepared(
        env, state, env["subscription"],
        confirm_cost_admission_mode=(
            admission_mode
            if admission_mode == runner.COMMISSIONING_COST_ADMISSION_MODE
            else None
        ),
    )
    if state.get("phase") != "complete":
        raise BridgeError("Azure runner did not prove complete exact cleanup")
    result = state.get("result")
    if not isinstance(result, dict):
        raise BridgeError("Azure runner produced no verified bounded result")
    identity = {
        "invocation": state["invocation"],
        "resource_id": result["vm_resource_id"],
        "vm_instance_id": result["vm_instance_id"],
        "boot_id": result["boot_id"],
        "request_digest": state["request_digest"],
        "deployment_generation": state["request"]["deployment_generation"],
        "review_generation": request["review_generation"],
        "source_ref": request["source_ref"],
        "head_sha": request["head_sha"],
        "base_sha": request["base_sha"],
        "network_bytes": state["request"]["limits"]["network_bytes"],
        "credential_present": False,
        "cleanup_phase": state["phase"],
        "result_digest": state["result_digest"],
    }
    return identity, result


def comparable_result(result: dict[str, Any]) -> dict[str, Any]:
    return {
        key: result.get(key)
        for key in (
            "exit_code",
            "timed_out",
            "signal",
            "stdout_bytes",
            "stderr_bytes",
            "stdout_truncated",
            "stderr_truncated",
            "stdout_digest",
            "stderr_digest",
        )
    }


class RemoteEvidenceExecutor:
    """Validate and replay each accepted reproduction in two fresh runner VMs."""

    def __init__(
        self,
        *,
        repository_root: Path,
        remote: str,
        source_ref: str,
        head_sha: str,
        base_sha: str,
        review_generation: str,
        evidence_files: dict[str, bytes],
    ) -> None:
        # The core's aggregate evidence deadline is sized for local replay
        # (seconds per item); every remote pair costs two fresh VM boots, so
        # the Azure executor owns its own aggregate bound instead: enough
        # for a bounded number of pairs, still finite against runaway
        # evidence, with each dispatch keeping its 900-second wall.
        self.batch_deadline = time.monotonic() + AZURE_EVIDENCE_BATCH_SECONDS
        self.request = {
            "repository_root": str(repository_root.resolve()),
            "remote": remote,
            "source_ref": source_ref,
            "head_sha": head_sha,
            "base_sha": base_sha,
            "review_generation": review_generation,
        }
        self.evidence_files = evidence_files
        self.attempts: list[dict[str, Any]] = []
        self.failed_attempts: list[dict[str, Any]] = []

    def validate_declared_paths(
        self, declared: set[str]
    ) -> None:
        if set(self.evidence_files) != declared:
            raise BridgeError(
                "Azure evidence manifest must exactly match every declared helper and mutation path"
            )

    def _execute_pair(
        self, runner: Any, command: list[str], deadline: float
    ) -> dict[str, Any]:
        del deadline
        deadline = self.batch_deadline
        suffix = str(len(self.attempts) + 1)
        remaining = int(deadline - time.monotonic())
        if remaining < 60:
            raise BridgeError("Azure evidence deadline expired before tool execution")
        tool_identity, tool_result = dispatch_once(
            runner, self.request, "tool-" + suffix, command, min(900, remaining)
        )
        remaining = int(deadline - time.monotonic())
        if remaining < 60:
            raise BridgeError("Azure evidence deadline expired before verifier execution")
        verifier_identity, verifier_result = dispatch_once(
            runner, self.request, "verify-" + suffix, command, min(900, remaining)
        )
        if tool_identity["vm_instance_id"] == verifier_identity["vm_instance_id"]:
            raise BridgeError("tool and verifier attempts reused one VM instance")
        tool_comparable = comparable_result(tool_result)
        verifier_comparable = comparable_result(verifier_result)
        clean = (
            tool_comparable == verifier_comparable
            and tool_comparable["exit_code"] == 0
            and tool_comparable["timed_out"] is False
            and tool_comparable["signal"] is None
            and tool_comparable["stdout_truncated"] is False
            and tool_comparable["stderr_truncated"] is False
        )
        if not clean:
            self.failed_attempts.append(
                {
                    "tool": tool_identity,
                    "tool_result": tool_comparable,
                    "verifier": verifier_identity,
                    "verifier_result": verifier_comparable,
                    "failure": (
                        "fresh verifier disagreed"
                        if tool_comparable != verifier_comparable
                        else "evidence command did not pass cleanly"
                    ),
                }
            )
            raise BridgeError("Azure evidence wrapper failed closed")
        attempt = {
            "tool": tool_identity,
            "verifier": verifier_identity,
            "result": tool_comparable,
        }
        self.attempts.append(attempt)
        return attempt

    def __call__(
        self,
        value: Any,
        _review_dir: Path,
        label: str,
        deadline: float,
        receipt: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise BridgeError(label + " must be an object")
        expected_keys = {"test_path", "command", "expected_exit", "output_contains"}
        if set(value) != expected_keys:
            raise BridgeError(label + " has invalid reproduction fields")
        test_path = value.get("test_path")
        if not isinstance(test_path, str) or test_path not in self.evidence_files:
            raise BridgeError(label + " names evidence that was not supplied by the reviewer")
        command_text = value.get("command")
        expected_argv = [
            "bash", "--noprofile", "--norc", test_path,
            self.request["base_sha"], self.request["head_sha"],
        ]
        try:
            command_argv = shlex.split(command_text) if isinstance(command_text, str) else []
        except ValueError as exc:
            raise BridgeError(label + " command has invalid shell quoting") from exc
        if command_argv != expected_argv:
            raise BridgeError(label + " command is not the exact bounded helper invocation")
        expected_exit = value.get("expected_exit")
        output_contains = value.get("output_contains")
        if (
            not isinstance(expected_exit, int)
            or isinstance(expected_exit, bool)
            or not 0 <= expected_exit <= 255
            or not isinstance(output_contains, str)
            or not output_contains
        ):
            raise BridgeError(label + " has invalid outcome expectations")
        if receipt is not None:
            path = receipt.get("path")
            contains = receipt.get("contains")
            if (
                not isinstance(path, str)
                or not SAFE_EVIDENCE_PATH.fullmatch(path)
                or not path.startswith(".crosscheck/reproductions/")
                or path in self.evidence_files
                or not isinstance(contains, list)
                or not contains
                or not all(isinstance(item, str) and item for item in contains)
            ):
                raise BridgeError(label + " has invalid receipt evidence")
        runner = load_runner()
        bound_value = {
            **value,
            "base_sha": self.request["base_sha"],
            "head_sha": self.request["head_sha"],
        }
        command = evidence_command(self.evidence_files, bound_value, receipt)
        attempt = self._execute_pair(runner, command, deadline)
        proof = {
            "test_path": test_path,
            "command": command_text,
            "expected_exit": expected_exit,
            "actual_exit": expected_exit,
            "output_contains": output_contains,
            "output": (
                "validated in fresh networkless Azure tool/verifier attempts; "
                + str(attempt["result"]["stdout_digest"])
            ),
            "azure_replay": attempt,
        }
        if receipt is not None:
            proof["reviewer_receipt"] = {
                "path": receipt["path"],
                "contains": receipt["contains"][0],
                "sha256": str(attempt["result"]["stdout_digest"]).removeprefix("sha256:"),
                "output": "private receipt content retained by digest",
            }
        return proof

    def execute_mutation(
        self,
        value: dict[str, Any],
        changed_paths: list[str],
        deadline: float,
    ) -> dict[str, Any]:
        mutation_path = value.get("mutation_patch_path")
        invocation = value.get("test_invocation")
        if (
            not isinstance(mutation_path, str)
            or mutation_path not in self.evidence_files
            or not isinstance(invocation, dict)
            or invocation.get("runner") != "pytest"
            or invocation.get("arguments") != []
            or not isinstance(value.get("test_path"), str)
            or not changed_paths
        ):
            raise BridgeError("Azure mutation proof request is not an allow-listed pytest proof")
        runner = load_runner()
        command = mutation_command(
            self.evidence_files,
            value,
            changed_paths,
            self.request["base_sha"],
            self.request["head_sha"],
        )
        attempt = self._execute_pair(runner, command, deadline)
        return {
            "test_path": value["test_path"],
            "test_invocation": invocation,
            "mutation_patch_sha256": hashlib.sha256(
                self.evidence_files[mutation_path]
            ).hexdigest(),
            "mutated_files": changed_paths,
            "baseline_exit": 0,
            "mutated_exit": 1,
            "baseline_output": "validated in fresh networkless Azure tool/verifier attempts",
            "mutated_output": "validated in fresh networkless Azure tool/verifier attempts",
            "azure_replay": attempt,
        }
