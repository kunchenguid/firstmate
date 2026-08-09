#!/usr/bin/env python3
"""Fail-closed wrapper for one approved Higgsfield image or video job."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterator, TextIO


MAX_REQUEST_BYTES = 1_000_000
MAX_PROMPT_CHARS = 20_000
MAX_MEDIA_ITEMS = 20
MODEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,127}$")
PARAM_RE = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-"
    r"[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MEDIA_FLAGS = {
    "end-image",
    "image",
    "image-references",
    "start-image",
    "video",
    "video-references",
}
DISALLOWED_MEDIA_PARAMS = {"audio", "audio-references"}
AUDIO_CONTROL_PARAMS = {"generate-audio", "sound"}
AUDIO_OFF_BY_JOB_TYPE = {
    "cinematic_studio_3_0": {"generate_audio": "false"},
    "cinematic_studio_video": {"sound": "false"},
    "cinematic_studio_video_3_5": {"generate_audio": "false"},
    "cinematic_studio_video_v2": {"sound": "off"},
    "kling2_6": {"sound": "false"},
    "kling3_0": {"sound": "off"},
    "seedance1_5": {"generate_audio": "false"},
    "seedance_2_0": {"generate_audio": "false"},
    "seedance_2_0_mini": {"generate_audio": "false"},
    "veo3_1_lite": {"generate_audio": "false"},
}
EXPLICITLY_PROVEN_SILENT_VIDEO_JOB_TYPES: frozenset[str] = frozenset()
APPROVAL_SCOPE = {
    "capability_binds": ["request_including_prompt", "vendor_credits_field"],
    "capability_does_not_bind": [
        "account",
        "billing_workspace",
        "vendor_credits_exact_field",
    ],
    "credits_exact_warning": (
        "The capability binds and the wrapper rechecks the vendor credits field, not "
        "credits_exact; a distinct credits_exact value can differ from the approved "
        "displayed credits value."
    ),
    "prompt_disclosure_warning": (
        "The capability binds the request including its prompt, but the mandated "
        "operator-visible disclosure does not attest or guarantee that the exact prompt "
        "was shown before approval."
    ),
    "precreate_validation_reuse_warning": (
        "A run that reaches a create attempt consumes the capability, but failures during "
        "live model or cost validation before creation leave it pending and reusable. "
        "Discard it and obtain a fresh approval instead of retrying."
    ),
    "workspace_switch_warning": (
        "Switching the active billing workspace between approval and run can charge "
        "a different workspace at the same displayed credits value."
    ),
}
RESERVED_PARAMS = MEDIA_FLAGS | DISALLOWED_MEDIA_PARAMS | {
    "json",
    "no-color",
    "prompt",
    "wait",
    "wait-interval",
    "wait-timeout",
}
BULK_PARAMS = {
    "batch-size",
    "batch_size",
    "num-images",
    "num-outputs",
    "num_images",
    "num_outputs",
    "number-of-images",
    "number-of-outputs",
    "number_of_images",
    "number_of_outputs",
    "output-count",
    "output_count",
    "samples",
    "variants",
}
BLOCKED_MODEL_PREFIXES = ("marketing_studio", "soul_")


class PolicyError(Exception):
    """A request violated a local safety boundary."""


def _json_output(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def _read_json(path: Path, label: str) -> Any:
    if not path.is_absolute():
        raise PolicyError(f"{label} path must be absolute: {path}")
    if path.is_symlink() or not path.is_file():
        raise PolicyError(f"{label} must be a regular non-symlink file: {path}")
    if path.stat().st_size > MAX_REQUEST_BYTES:
        raise PolicyError(f"{label} exceeds {MAX_REQUEST_BYTES} bytes")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PolicyError(f"cannot read {label}: {exc}") from exc


def _primitive_value(name: str, value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise PolicyError(f"parameter {name!r} must be finite")
        return str(value)
    if isinstance(value, str):
        if "\x00" in value:
            raise PolicyError(f"parameter {name!r} contains a NUL byte")
        lowered = value.strip().lower()
        if lowered.startswith(("@", "file://", "http://", "https://")) or Path(value).is_absolute():
            raise PolicyError(f"parameter {name!r} must not contain a path or remote URL")
        return value
    raise PolicyError(f"parameter {name!r} must be a string, number, or boolean")


def _is_more_than_one(value: str) -> bool:
    try:
        return Decimal(value) > 1
    except InvalidOperation:
        return True


def _normalize_request(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise PolicyError("request must be a JSON object")
    unknown = set(raw) - {"job_type", "media", "parameters", "prompt"}
    if unknown:
        raise PolicyError(f"unknown request fields: {', '.join(sorted(unknown))}")

    job_type = raw.get("job_type")
    if not isinstance(job_type, str) or not MODEL_RE.fullmatch(job_type):
        raise PolicyError("job_type must contain only lowercase letters, digits, dashes, or underscores")
    if job_type.startswith(BLOCKED_MODEL_PREFIXES):
        raise PolicyError(f"model {job_type!r} is outside the hardened generation boundary")
    prompt = raw.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise PolicyError("prompt must be a non-empty string")
    if len(prompt) > MAX_PROMPT_CHARS or "\x00" in prompt:
        raise PolicyError(f"prompt must contain at most {MAX_PROMPT_CHARS} characters and no NUL byte")

    parameters = raw.get("parameters", {})
    if not isinstance(parameters, dict):
        raise PolicyError("parameters must be a JSON object")
    normalized_parameters: dict[str, str] = {}
    for name, value in parameters.items():
        if not isinstance(name, str) or not PARAM_RE.fullmatch(name):
            raise PolicyError(f"invalid parameter name: {name!r}")
        flag_name = name.replace("_", "-")
        if flag_name in RESERVED_PARAMS:
            raise PolicyError(f"reserved parameter must not be supplied: {name}")
        if flag_name in AUDIO_CONTROL_PARAMS:
            continue
        normalized_value = _primitive_value(name, value)
        if flag_name in BULK_PARAMS and _is_more_than_one(normalized_value):
            raise PolicyError(f"bulk parameter {name!r} is not supported by this single-job wrapper")
        normalized_parameters[name] = normalized_value

    media = raw.get("media", [])
    if not isinstance(media, list) or len(media) > MAX_MEDIA_ITEMS:
        raise PolicyError(f"media must be an array of at most {MAX_MEDIA_ITEMS} items")
    normalized_media: list[dict[str, str]] = []
    for index, item in enumerate(media):
        if not isinstance(item, dict) or set(item) != {"flag", "value"}:
            raise PolicyError(f"media item {index} must contain exactly flag and value")
        flag = item.get("flag")
        value = item.get("value")
        if flag not in MEDIA_FLAGS or not isinstance(value, str) or not value:
            raise PolicyError(f"invalid media item {index}")
        candidate = Path(value)
        if candidate.is_absolute():
            if candidate.is_symlink() or not candidate.is_file():
                raise PolicyError(f"local media must be a regular non-symlink file: {candidate}")
            normalized_value = str(candidate.resolve())
        elif UUID_RE.fullmatch(value):
            normalized_value = value.lower()
        else:
            raise PolicyError(f"media value must be an absolute file path or Higgsfield UUID: {value}")
        normalized_media.append({"flag": flag, "value": normalized_value})

    return {
        "job_type": job_type,
        "prompt": prompt,
        "parameters": dict(
            sorted({**normalized_parameters, **AUDIO_OFF_BY_JOB_TYPE.get(job_type, {})}.items())
        ),
        "media": normalized_media,
    }


def _load_request(path_text: str) -> dict[str, Any]:
    path = Path(path_text)
    return _normalize_request(_read_json(path, "request"))


def _canonical_bytes(request: dict[str, Any]) -> bytes:
    return json.dumps(request, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _digest(request: dict[str, Any]) -> str:
    return hashlib.sha256(_canonical_bytes(request)).hexdigest()


def _local_upload_paths(request: dict[str, Any]) -> list[str]:
    uploads: list[str] = []
    seen: set[str] = set()
    for item in request["media"]:
        value = item["value"]
        path = Path(value)
        if not path.is_absolute() or value in seen:
            continue
        seen.add(value)
        uploads.append(value)
    return uploads


def _open_regular_file(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise PolicyError(f"cannot open local media {path}: {exc}") from exc
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise PolicyError(f"local media must remain a regular non-symlink file: {path}")
    return descriptor


def _hash_regular_file(path: Path) -> tuple[int, str]:
    descriptor = _open_regular_file(path)
    digest = hashlib.sha256()
    byte_count = 0
    with os.fdopen(descriptor, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
            byte_count += len(chunk)
    return byte_count, digest.hexdigest()


def _upload_manifest(request: dict[str, Any]) -> list[dict[str, Any]]:
    uploads: list[dict[str, Any]] = []
    for value in _local_upload_paths(request):
        byte_count, digest = _hash_regular_file(Path(value))
        uploads.append({"path": value, "bytes": byte_count, "sha256": digest})
    return uploads


def _require_cli() -> str:
    executable = shutil.which("higgsfield")
    if executable is None:
        raise PolicyError("higgsfield CLI is missing; stop and ask the captain to install it")
    return executable


def _run_cli(arguments: list[str], timeout: int) -> Any:
    command = [_require_cli(), *arguments]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            check=False,
            shell=False,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise PolicyError("higgsfield command timed out; do not retry automatically") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown error").strip()[:2_000]
        raise PolicyError(f"higgsfield command failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise PolicyError("higgsfield returned invalid JSON") from exc


def _ensure_image_or_video(request: dict[str, Any]) -> str:
    job_type = request["job_type"]
    model = _run_cli(["model", "get", job_type, "--json"], timeout=120)
    model_type = model.get("type") if isinstance(model, dict) else None
    if model_type not in {"image", "video"}:
        raise PolicyError(f"model type {model_type!r} is outside the image/video boundary")
    audio_off = AUDIO_OFF_BY_JOB_TYPE.get(job_type)
    enforces_audio_off = audio_off is not None and all(
        request["parameters"].get(name) == value for name, value in audio_off.items()
    )
    if (
        model_type == "video"
        and not enforces_audio_off
        and job_type not in EXPLICITLY_PROVEN_SILENT_VIDEO_JOB_TYPES
    ):
        raise PolicyError(f"video model {job_type!r} has no enforced no-audio policy")
    return model_type


def _generation_arguments(request: dict[str, Any], action: str) -> list[str]:
    arguments = ["generate", action, request["job_type"], f"--prompt={request['prompt']}"]
    for name, value in request["parameters"].items():
        arguments.append(f"--{name}={value}")
    for item in request["media"]:
        arguments.append(f"--{item['flag']}={item['value']}")
    if action == "create":
        arguments.extend(["--wait", "--wait-timeout=20m", "--wait-interval=5s"])
    arguments.append("--json")
    return arguments


def _credits(request: dict[str, Any]) -> tuple[Any, str]:
    _ensure_image_or_video(request)
    response = _run_cli(_generation_arguments(request, "cost"), timeout=120)
    adjustments = response.get("adjustments") if isinstance(response, dict) else None
    if adjustments not in (None, [], {}):
        raise PolicyError("cost response adjusted request parameters; revise the request and cost it again")
    value = response.get("credits") if isinstance(response, dict) else None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PolicyError("cost response did not contain numeric credits")
    try:
        decimal_value = Decimal(str(value))
    except InvalidOperation as exc:
        raise PolicyError("cost response contained invalid credits") from exc
    if not decimal_value.is_finite() or decimal_value < 0:
        raise PolicyError("cost response contained invalid credits")
    return value, format(decimal_value, "f")


def _require_temporary_location(path: Path, label: str) -> None:
    candidate = path.resolve()
    roots = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
    for root in roots:
        try:
            candidate.relative_to(root)
            return
        except ValueError:
            continue
    raise PolicyError(f"{label} must be inside a system temporary directory")


def _temporary_output(path_text: str, label: str) -> Path:
    path = Path(path_text)
    if not path.is_absolute():
        raise PolicyError(f"{label} path must be absolute")
    parent = path.parent.resolve()
    _require_temporary_location(parent, label)
    if not parent.is_dir() or path.exists() or path.is_symlink():
        raise PolicyError(f"{label} parent must exist and destination must be new")
    return path


def _require_temporary_input(path: Path, label: str) -> None:
    if not path.is_absolute():
        raise PolicyError(f"{label} path must be absolute")
    _require_temporary_location(path, label)


def _write_private_json(path: Path, payload: Any) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _upload_token(receipt_path: Path, secret: str) -> str:
    encoded_path = base64.urlsafe_b64encode(
        str(receipt_path).encode("utf-8")
    ).decode("ascii")
    return f"upload:v1:{encoded_path.rstrip('=')}:{secret}"


def _decode_upload_token(token: str) -> tuple[Path, str]:
    parts = token.split(":", 3)
    if (
        len(parts) != 4
        or parts[:2] != ["upload", "v1"]
        or not parts[2]
        or len(parts[3]) < 32
    ):
        raise PolicyError("upload approval token is invalid or already consumed")
    try:
        encoded_path = parts[2] + "=" * (-len(parts[2]) % 4)
        path_text = base64.urlsafe_b64decode(encoded_path.encode("ascii")).decode("utf-8")
    except (UnicodeError, ValueError) as exc:
        raise PolicyError("upload approval token is invalid or already consumed") from exc
    receipt_path = Path(path_text)
    _require_temporary_input(receipt_path, "upload approval")
    if receipt_path.name != "approval.json" or not receipt_path.parent.name.startswith(
        "higgsfield-upload-approval."
    ):
        raise PolicyError("upload approval token is invalid or already consumed")
    return receipt_path, parts[3]


def _create_upload_approval(
    request: dict[str, Any], uploads: list[dict[str, Any]]
) -> str:
    approval_directory = Path(tempfile.mkdtemp(prefix="higgsfield-upload-approval."))
    receipt_path = approval_directory / "approval.json"
    secret = secrets.token_urlsafe(32)
    token = _upload_token(receipt_path, secret)
    signed = {
        "request_digest": _digest(request),
        "status": "pending",
        "token_sha256": hashlib.sha256(token.encode("utf-8")).hexdigest(),
        "uploads": uploads,
    }
    receipt = {
        **signed,
        "approval_hmac": hmac.new(
            secret.encode("utf-8"), _canonical_bytes(signed), hashlib.sha256
        ).hexdigest(),
    }
    try:
        _write_private_json(receipt_path, receipt)
    except OSError:
        approval_directory.rmdir()
        raise
    return token


def _cost_capability(approval_path: Path, secret: str) -> str:
    encoded_path = base64.urlsafe_b64encode(
        str(approval_path).encode("utf-8")
    ).decode("ascii")
    return f"cost:v1:{encoded_path.rstrip('=')}:{secret}"


def _decode_cost_capability(capability: str) -> tuple[Path, str]:
    parts = capability.split(":", 3)
    if (
        len(parts) != 4
        or parts[:2] != ["cost", "v1"]
        or not parts[2]
        or len(parts[3]) < 32
    ):
        raise PolicyError("cost approval is invalid or already consumed")
    try:
        encoded_path = parts[2] + "=" * (-len(parts[2]) % 4)
        path_text = base64.urlsafe_b64decode(encoded_path.encode("ascii")).decode("utf-8")
    except (UnicodeError, ValueError) as exc:
        raise PolicyError("cost approval is invalid or already consumed") from exc
    approval_path = Path(path_text)
    _require_temporary_input(approval_path, "cost approval")
    if approval_path.name != "approval.json" or not approval_path.parent.name.startswith(
        "higgsfield-cost-approval."
    ):
        raise PolicyError("cost approval is invalid or already consumed")
    return approval_path, parts[3]


def _create_cost_approval(
    visible_path: Path,
    request: dict[str, Any],
    credits: Any,
    credits_text: str,
) -> None:
    approval_directory = Path(tempfile.mkdtemp(prefix="higgsfield-cost-approval."))
    approval_path = approval_directory / "approval.json"
    secret = secrets.token_urlsafe(32)
    capability = _cost_capability(approval_path, secret)
    signed = {
        "capability_sha256": hashlib.sha256(capability.encode("utf-8")).hexdigest(),
        "credits": credits,
        "credits_text": credits_text,
        "request_digest": _digest(request),
        "status": "pending",
    }
    approval = {
        **signed,
        "approval_hmac": hmac.new(
            secret.encode("utf-8"), _canonical_bytes(signed), hashlib.sha256
        ).hexdigest(),
    }
    try:
        _write_private_json(approval_path, approval)
        _write_private_json(visible_path, {"cost_approval_capability": capability})
    except BaseException:
        approval_path.unlink(missing_ok=True)
        approval_directory.rmdir()
        raise


def _read_cost_capability(path: Path) -> tuple[Path, str, str]:
    _require_temporary_input(path, "cost receipt")
    visible = _read_json(path, "cost receipt")
    if not isinstance(visible, dict) or set(visible) != {"cost_approval_capability"}:
        raise PolicyError("cost receipt is invalid or already consumed")
    capability = visible.get("cost_approval_capability")
    if not isinstance(capability, str):
        raise PolicyError("cost receipt is invalid or already consumed")
    approval_path, secret = _decode_cost_capability(capability)
    return approval_path, secret, capability


@contextmanager
def _locked_json(path: Path, label: str) -> Iterator[tuple[TextIO, Any]]:
    _require_temporary_input(path, label)
    flags = os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise PolicyError(f"{label} is invalid or already consumed") from exc
    handle: TextIO | None = None
    try:
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_size > MAX_REQUEST_BYTES:
            raise PolicyError(f"{label} is invalid or already consumed")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PolicyError(f"{label} is already being consumed") from exc
        handle = os.fdopen(descriptor, "r+", encoding="utf-8")
        descriptor = -1
        try:
            payload = json.load(handle)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise PolicyError(f"{label} is invalid or already consumed") from exc
        yield handle, payload
    finally:
        if handle is not None:
            handle.close()
        elif descriptor >= 0:
            os.close(descriptor)


def _rewrite_locked_json(handle: TextIO, payload: Any) -> None:
    handle.seek(0)
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.truncate()
    handle.flush()
    os.fsync(handle.fileno())


def _validated_upload_manifest(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise PolicyError("upload approval is invalid or already consumed")
    uploads: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"bytes", "path", "sha256"}:
            raise PolicyError("upload approval is invalid or already consumed")
        byte_count = item.get("bytes")
        path = item.get("path")
        digest = item.get("sha256")
        if (
            isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or byte_count < 0
            or not isinstance(path, str)
            or not Path(path).is_absolute()
            or not isinstance(digest, str)
            or not SHA256_RE.fullmatch(digest)
        ):
            raise PolicyError("upload approval is invalid or already consumed")
        uploads.append({"bytes": byte_count, "path": path, "sha256": digest})
    return uploads


def _snapshot_uploads(
    approval_path: Path, uploads: list[dict[str, Any]]
) -> tuple[Path, list[dict[str, str]]]:
    snapshot_directory = Path(
        tempfile.mkdtemp(prefix="snapshots.", dir=approval_path.parent)
    )
    snapshots: list[dict[str, str]] = []
    try:
        for index, upload in enumerate(uploads):
            source_path = Path(upload["path"])
            snapshot_path = snapshot_directory / f"media-{index}"
            source_descriptor = _open_regular_file(source_path)
            try:
                snapshot_descriptor = os.open(
                    snapshot_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
                )
            except OSError:
                os.close(source_descriptor)
                raise
            digest = hashlib.sha256()
            byte_count = 0
            with os.fdopen(source_descriptor, "rb") as source, os.fdopen(
                snapshot_descriptor, "wb"
            ) as snapshot:
                while chunk := source.read(1024 * 1024):
                    snapshot.write(chunk)
                    digest.update(chunk)
                    byte_count += len(chunk)
                snapshot.flush()
                os.fsync(snapshot.fileno())
            if byte_count != upload["bytes"] or not hmac.compare_digest(
                digest.hexdigest(), upload["sha256"]
            ):
                raise PolicyError(
                    f"local media changed after approval: {source_path}; plan and approve it again"
                )
            snapshots.append({"path": upload["path"], "snapshot": str(snapshot_path)})
    except BaseException:
        _remove_snapshots(snapshot_directory, snapshots)
        raise
    return snapshot_directory, snapshots


def _remove_snapshots(
    snapshot_directory: Path, snapshots: list[dict[str, str]]
) -> None:
    for upload in snapshots:
        Path(upload["snapshot"]).unlink(missing_ok=True)
    for remaining in snapshot_directory.iterdir():
        remaining.unlink()
    snapshot_directory.rmdir()


def _extract_upload_id(payload: Any) -> str | None:
    if isinstance(payload, dict):
        for key in ("id", "upload_id", "uuid"):
            value = payload.get(key)
            if isinstance(value, str) and UUID_RE.fullmatch(value):
                return value.lower()
        for value in payload.values():
            found = _extract_upload_id(value)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = _extract_upload_id(value)
            if found is not None:
                return found
    return None


def command_plan(args: argparse.Namespace) -> None:
    request = _load_request(args.request)
    digest = _digest(request)
    uploads = _upload_manifest(request)
    approval_token = _create_upload_approval(request, uploads) if uploads else None
    _json_output(
        {
            "action": "plan",
            "job_count": 1,
            "job_type": request["job_type"],
            "parameters": request["parameters"],
            "prompt_characters": len(request["prompt"]),
            "prompt_sha256": hashlib.sha256(request["prompt"].encode("utf-8")).hexdigest(),
            "request_digest": digest,
            "upload_approval_token": approval_token,
            "uploads": uploads,
        }
    )


def command_upload(args: argparse.Namespace) -> None:
    request = _load_request(args.request)
    digest = _digest(request)
    upload_paths = _local_upload_paths(request)
    if not upload_paths:
        raise PolicyError("request has no local media to upload")
    output = _temporary_output(args.output, "uploaded request")
    approval_path, secret = _decode_upload_token(args.approval_token)
    with _locked_json(approval_path, "upload approval") as (approval_handle, receipt):
        if not isinstance(receipt, dict):
            raise PolicyError("upload approval is invalid or already consumed")
        signed = {
            "request_digest": receipt.get("request_digest"),
            "status": receipt.get("status"),
            "token_sha256": receipt.get("token_sha256"),
            "uploads": receipt.get("uploads"),
        }
        expected_hmac = hmac.new(
            secret.encode("utf-8"), _canonical_bytes(signed), hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(
            str(receipt.get("approval_hmac", "")), expected_hmac
        ) or not hmac.compare_digest(
            str(receipt.get("token_sha256", "")),
            hashlib.sha256(args.approval_token.encode("utf-8")).hexdigest(),
        ):
            raise PolicyError("upload approval is invalid or already consumed")
        if receipt.get("status") != "pending":
            raise PolicyError("upload approval is invalid or already consumed")
        if not hmac.compare_digest(str(receipt.get("request_digest", "")), digest):
            raise PolicyError("upload approval does not match the exact request")
        uploads = _validated_upload_manifest(receipt.get("uploads"))
        if [upload["path"] for upload in uploads] != upload_paths:
            raise PolicyError("upload approval does not match the exact request")
        _ensure_image_or_video(request)
        consumed = dict(receipt)
        consumed["status"] = "consumed"
        _rewrite_locked_json(approval_handle, consumed)

    snapshot_directory, snapshots = _snapshot_uploads(approval_path, uploads)
    ids_by_path: dict[str, str] = {}
    try:
        for upload in snapshots:
            response = _run_cli(
                ["upload", "create", upload["snapshot"], "--json"], timeout=600
            )
            upload_id = _extract_upload_id(response)
            if upload_id is None:
                raise PolicyError(
                    f"upload response for {upload['path']} did not contain a UUID"
                )
            ids_by_path[upload["path"]] = upload_id
    finally:
        _remove_snapshots(snapshot_directory, snapshots)
    uploaded_request = json.loads(json.dumps(request))
    for item in uploaded_request["media"]:
        if item["value"] in ids_by_path:
            item["value"] = ids_by_path[item["value"]]
    _write_private_json(output, uploaded_request)
    _json_output(
        {
            "action": "upload",
            "output": str(output),
            "request_digest": _digest(uploaded_request),
            "uploaded": [{"path": path, "upload_id": upload_id} for path, upload_id in ids_by_path.items()],
        }
    )


def command_cost(args: argparse.Namespace) -> None:
    request = _load_request(args.request)
    if _local_upload_paths(request):
        raise PolicyError("costing local paths would upload them; run the approved upload phase first")
    receipt_path = _temporary_output(args.receipt, "cost receipt")
    credits, credits_text = _credits(request)
    digest = _digest(request)
    _create_cost_approval(receipt_path, request, credits, credits_text)
    _json_output(
        {
            "action": "cost",
            "approval_scope": APPROVAL_SCOPE,
            "credits": credits,
            "job_count": 1,
            "job_type": request["job_type"],
            "media": request["media"],
            "parameters": request["parameters"],
            "request_digest": digest,
            "receipt": str(receipt_path),
        }
    )


def command_run(args: argparse.Namespace) -> None:
    request = _load_request(args.request)
    if _local_upload_paths(request):
        raise PolicyError("run refuses local paths; run the approved upload phase first")
    approval_path, secret, capability = _read_cost_capability(Path(args.cost_receipt))
    digest = _digest(request)
    with _locked_json(approval_path, "cost approval") as (approval_handle, approval):
        if not isinstance(approval, dict) or set(approval) != {
            "approval_hmac",
            "capability_sha256",
            "credits",
            "credits_text",
            "request_digest",
            "status",
        }:
            raise PolicyError("cost approval is invalid or already consumed")
        signed = {
            "capability_sha256": approval.get("capability_sha256"),
            "credits": approval.get("credits"),
            "credits_text": approval.get("credits_text"),
            "request_digest": approval.get("request_digest"),
            "status": approval.get("status"),
        }
        expected_hmac = hmac.new(
            secret.encode("utf-8"), _canonical_bytes(signed), hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(
            str(approval.get("approval_hmac", "")), expected_hmac
        ) or not hmac.compare_digest(
            str(approval.get("capability_sha256", "")),
            hashlib.sha256(capability.encode("utf-8")).hexdigest(),
        ):
            raise PolicyError("cost approval is invalid or already consumed")
        if approval.get("status") != "pending":
            raise PolicyError("cost approval is invalid or already consumed")
        if not hmac.compare_digest(str(approval.get("request_digest", "")), digest):
            raise PolicyError("cost approval does not match the exact request")
        _, current_credits_text = _credits(request)
        if not hmac.compare_digest(
            str(approval.get("credits_text", "")), current_credits_text
        ):
            raise PolicyError("vendor credits value changed; run cost again and obtain new approval")
        consumed_signed = {**signed, "status": "consumed"}
        consumed = {
            **consumed_signed,
            "approval_hmac": hmac.new(
                secret.encode("utf-8"),
                _canonical_bytes(consumed_signed),
                hashlib.sha256,
            ).hexdigest(),
        }
        _rewrite_locked_json(approval_handle, consumed)
        result = _run_cli(_generation_arguments(request, "create"), timeout=1_500)
    _json_output(
        {
            "action": "run",
            "credits": approval["credits"],
            "job_count": 1,
            "job_type": request["job_type"],
            "request_digest": digest,
            "result": result,
        }
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan = subparsers.add_parser("plan", help="validate and disclose a request without network access")
    plan.add_argument("request")
    plan.set_defaults(handler=command_plan)

    upload = subparsers.add_parser("upload", help="upload explicitly approved local media once")
    upload.add_argument("request")
    upload.add_argument("--approval-token", required=True)
    upload.add_argument("--output", required=True)
    upload.set_defaults(handler=command_upload)

    cost = subparsers.add_parser(
        "cost", help="estimate credits and write an approval capability for one create attempt"
    )
    cost.add_argument("request")
    cost.add_argument("--receipt", required=True)
    cost.set_defaults(handler=command_cost)

    run = subparsers.add_parser(
        "run", help="validate and consume an approved capability, then attempt one create"
    )
    run.add_argument("request")
    run.add_argument("--cost-receipt", required=True)
    run.set_defaults(handler=command_run)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.handler(args)
    except PolicyError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
