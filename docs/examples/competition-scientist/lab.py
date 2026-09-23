#!/usr/bin/env python3
"""Inert, deterministic competition-scientist pilot.

The public interface is documented by ``--help``.
A run creates a new workspace and never modifies a project checkout.
The evaluator runs in a bounded subprocess and parses, but never executes, the
single editable ``candidate.py`` file.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import os
import platform
import random
import resource
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "competition-scientist-lab/v1"
ROOT = Path(__file__).resolve().parent
BASELINE_TEMPLATE = ROOT / "baseline_candidate.py"
TASKS = ("grouped-classification", "nonlinear-regression", "noisy-classification")
CONTROLLERS = ("linear", "proposed")
ALLOWED_FAILURES = ("", "network", "oom", "syntax", "timeout")
DEFAULT_CAPS = {
    "attempts": 6,
    "wall_seconds": 30,
    "cpu_seconds": 30,
    "memory_mb": 1024,
    "token_budget": 48_000,
    "planning_token_budget": 9_600,
    "branch_factor": 2,
    "plateau": 2,
}
TASK_LEVERS = {
    "grouped-classification": {
        "GROUPED_CAUSAL_WEIGHT",
        "GROUPED_SPURIOUS_WEIGHT",
        "GROUPED_THRESHOLD",
    },
    "nonlinear-regression": {
        "REGRESSION_COMPONENTS",
        "REGRESSION_SCALE",
        "REGRESSION_BIAS",
    },
    "noisy-classification": {
        "NOISY_THRESHOLD",
        "NOISY_MARGIN",
    },
}
EXPECTED_KEYS = {
    "GROUPED_CAUSAL_WEIGHT",
    "GROUPED_SPURIOUS_WEIGHT",
    "GROUPED_THRESHOLD",
    "REGRESSION_COMPONENTS",
    "REGRESSION_SCALE",
    "REGRESSION_BIAS",
    "NOISY_THRESHOLD",
    "NOISY_MARGIN",
    "INJECT_FAILURE",
}
DIRECTIONS = {
    "worst_group": 1,
    "grouped_mean": 1,
    "ood_stress": 1,
    "calibration_loss": -1,
}


class LabError(Exception):
    """A safe, expected refusal from the lab contract."""


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def write_json(path: Path, value: Any, *, immutable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    if immutable:
        path.chmod(0o444)


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LabError(f"cannot read JSON {path}: {exc}") from exc


def write_mutable_json(path: Path, value: Any) -> None:
    if path.exists():
        path.chmod(0o600)
    write_json(path, value)
    path.chmod(0o600)


def stable_seed(seed: int, task: str, split: str) -> int:
    raw = f"{SCHEMA_VERSION}:{seed}:{task}:{split}".encode("utf-8")
    return int.from_bytes(hashlib.sha256(raw).digest()[:8], "big")


def _classification_rows(seed: int, split: str, *, noisy: bool) -> list[dict[str, Any]]:
    rng = random.Random(stable_seed(seed, "noisy" if noisy else "grouped", split))
    groups = 6 if split == "dev" else 4
    rows: list[dict[str, Any]] = []
    for group in range(groups):
        stress = group >= groups - 2
        for index in range(40):
            latent = rng.gauss(0.0, 1.0) + (group - groups / 2) * 0.04
            label = 1 if latent >= 0 else 0
            sign = 1.0 if label else -1.0
            if noisy and (index + group * 3) % 7 == 0:
                label = 1 - label
                sign = 1.0 if label else -1.0
            causal = latent + rng.gauss(0.0, 0.42 if noisy else 0.32)
            spur_direction = -1.0 if stress or split == "sealed" else 1.0
            spurious = spur_direction * sign + rng.gauss(0.0, 0.20)
            rows.append(
                {
                    "group": f"g{group}",
                    "stress": stress or split == "sealed",
                    "causal": round(causal, 8),
                    "spurious": round(spurious, 8),
                    "label": label,
                }
            )
    return rows


def _regression_rows(seed: int, split: str) -> list[dict[str, Any]]:
    rng = random.Random(stable_seed(seed, "regression", split))
    groups = 6 if split == "dev" else 4
    rows: list[dict[str, Any]] = []
    for group in range(groups):
        stress = group >= groups - 2
        width = 2.4 if stress or split == "sealed" else 1.5
        for index in range(36):
            x = -width + (2 * width * index / 35.0) + rng.gauss(0.0, 0.025)
            linear = x
            quadratic = x * x - 0.8
            sine = math.sin(2.0 * x)
            target = 0.5 * linear + 0.5 * quadratic + 0.15 * sine + rng.gauss(0.0, 0.025)
            rows.append(
                {
                    "group": f"g{group}",
                    "stress": stress or split == "sealed",
                    "x": round(x, 8),
                    "target": round(target, 8),
                }
            )
    return rows


def generate_dataset(task: str, seed: int, split: str) -> list[dict[str, Any]]:
    if task == "grouped-classification":
        return _classification_rows(seed, split, noisy=False)
    if task == "noisy-classification":
        return _classification_rows(seed, split, noisy=True)
    if task == "nonlinear-regression":
        return _regression_rows(seed, split)
    raise LabError(f"unknown task: {task}")


def parse_candidate(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise LabError("candidate.py must not be a symlink")
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise LabError(f"cannot read candidate.py: {exc}") from exc
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        raise LabError(f"syntax:{exc.msg}:line={exc.lineno}") from exc
    values: dict[str, Any] = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            raise LabError("forbidden-syntax: candidate.py permits literal assignments only")
        name = node.targets[0].id
        if name not in EXPECTED_KEYS or name in values:
            raise LabError(f"forbidden-assignment:{name}")
        try:
            values[name] = ast.literal_eval(node.value)
        except (ValueError, TypeError) as exc:
            raise LabError(f"forbidden-expression:{name}") from exc
    missing = sorted(EXPECTED_KEYS - set(values))
    if missing:
        raise LabError("missing-assignments:" + ",".join(missing))
    validate_candidate(values)
    return values


def validate_candidate(values: dict[str, Any]) -> None:
    numeric_limits = {
        "GROUPED_CAUSAL_WEIGHT": (-4.0, 4.0),
        "GROUPED_SPURIOUS_WEIGHT": (-4.0, 4.0),
        "GROUPED_THRESHOLD": (-2.0, 2.0),
        "REGRESSION_SCALE": (0.1, 3.0),
        "REGRESSION_BIAS": (-2.0, 2.0),
        "NOISY_THRESHOLD": (-1.0, 1.0),
        "NOISY_MARGIN": (-1.0, 1.0),
    }
    for name, (lower, upper) in numeric_limits.items():
        value = values.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise LabError(f"invalid-value:{name}")
        if not lower <= float(value) <= upper:
            raise LabError(f"out-of-range:{name}")
    components = values.get("REGRESSION_COMPONENTS")
    if not isinstance(components, tuple) or not components or len(set(components)) != len(components):
        raise LabError("invalid-value:REGRESSION_COMPONENTS")
    if any(name not in {"linear", "quadratic", "sine"} for name in components):
        raise LabError("invalid-value:REGRESSION_COMPONENTS")
    if values.get("INJECT_FAILURE") not in ALLOWED_FAILURES:
        raise LabError("invalid-value:INJECT_FAILURE")


def render_candidate(values: dict[str, Any], *, break_syntax: bool = False) -> str:
    lines = [
        "# This is the only scientific surface a competition-scientist run may change.",
        "# The lab parses literal assignments and never executes this file.",
        "",
        f"GROUPED_CAUSAL_WEIGHT = {values['GROUPED_CAUSAL_WEIGHT']!r}",
        f"GROUPED_SPURIOUS_WEIGHT = {values['GROUPED_SPURIOUS_WEIGHT']!r}",
        f"GROUPED_THRESHOLD = {values['GROUPED_THRESHOLD']!r}",
        "",
        f"REGRESSION_COMPONENTS = {values['REGRESSION_COMPONENTS']!r}",
        f"REGRESSION_SCALE = {values['REGRESSION_SCALE']!r}",
        f"REGRESSION_BIAS = {values['REGRESSION_BIAS']!r}",
        "",
        f"NOISY_THRESHOLD = {values['NOISY_THRESHOLD']!r}",
        f"NOISY_MARGIN = {values['NOISY_MARGIN']!r}",
        "",
        f"INJECT_FAILURE = {values['INJECT_FAILURE']!r}",
        "",
    ]
    if break_syntax:
        lines.append("BROKEN =")
    return "\n".join(lines)


def validate_proposal(proposal: Any, task: str) -> dict[str, Any]:
    if not isinstance(proposal, dict):
        raise LabError("proposal-not-object")
    if "parse_error" in proposal:
        raise LabError("proposal-unparseable")
    required = {"id", "hypothesis", "changes"}
    allowed = required | {"falsifier", "branch", "token_cost", "planning_tokens"}
    missing = sorted(required - set(proposal))
    if missing:
        raise LabError("proposal-missing:" + ",".join(missing))
    unknown = sorted(set(proposal) - allowed)
    if unknown:
        raise LabError("proposal-unknown-fields:" + ",".join(unknown))
    if not isinstance(proposal["id"], str) or not proposal["id"].strip():
        raise LabError("proposal-id-invalid")
    if not isinstance(proposal["hypothesis"], str) or not proposal["hypothesis"].strip() or len(proposal["hypothesis"]) > 500:
        raise LabError("proposal-hypothesis-invalid")
    if not isinstance(proposal.get("falsifier", ""), str) or len(proposal.get("falsifier", "")) > 500:
        raise LabError("proposal-falsifier-invalid")
    changes = proposal["changes"]
    if not isinstance(changes, dict) or len(changes) != 1:
        raise LabError("confounded-hypothesis:exactly-one-change-required")
    lever = next(iter(changes))
    if lever not in TASK_LEVERS[task]:
        raise LabError(f"out-of-scope-lever:{lever}")
    branch = proposal.get("branch", "main")
    if not isinstance(branch, str) or not branch or not all(c.isalnum() or c in "-_" for c in branch):
        raise LabError("proposal-branch-invalid")
    token_cost = proposal.get("token_cost", 0)
    planning_tokens = proposal.get("planning_tokens", 0)
    if isinstance(token_cost, bool) or not isinstance(token_cost, int) or token_cost < 0:
        raise LabError("proposal-token-cost-invalid")
    if isinstance(planning_tokens, bool) or not isinstance(planning_tokens, int) or planning_tokens < 0:
        raise LabError("proposal-planning-tokens-invalid")
    result = dict(proposal)
    result["id"] = proposal["id"].strip()
    result["hypothesis"] = proposal["hypothesis"].strip()
    result["branch"] = branch
    result["token_cost"] = token_cost
    result["planning_tokens"] = planning_tokens
    return result


def group_metrics(task: str, rows: list[dict[str, Any]], values: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    failure = values["INJECT_FAILURE"]
    if failure == "timeout":
        time.sleep(3600)
    if failure == "oom":
        raise MemoryError("injected fixture out-of-memory failure")
    if failure == "network":
        import socket
        socket.create_connection(("127.0.0.1", 9), timeout=0.1)

    grouped: dict[str, list[tuple[float, float]]] = {}
    predictions: list[dict[str, Any]] = []
    losses: list[float] = []
    stress_scores: list[float] = []

    for index, row in enumerate(rows):
        if task == "grouped-classification":
            raw = (
                float(values["GROUPED_CAUSAL_WEIGHT"]) * row["causal"]
                + float(values["GROUPED_SPURIOUS_WEIGHT"]) * row["spurious"]
            )
            probability = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, raw))))
            prediction = 1 if raw >= float(values["GROUPED_THRESHOLD"]) else 0
            score = 1.0 if prediction == row["label"] else 0.0
            loss = (probability - row["label"]) ** 2
        elif task == "noisy-classification":
            raw = row["causal"] + float(values["NOISY_MARGIN"]) * row["spurious"]
            probability = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, raw))))
            prediction = 1 if raw >= float(values["NOISY_THRESHOLD"]) else 0
            score = 1.0 if prediction == row["label"] else 0.0
            loss = (probability - row["label"]) ** 2
        else:
            x = row["x"]
            component_values = {
                "linear": x,
                "quadratic": x * x - 0.8,
                "sine": math.sin(2.0 * x),
            }
            selected = values["REGRESSION_COMPONENTS"]
            raw = sum(component_values[name] for name in selected) / len(selected)
            prediction = float(values["REGRESSION_SCALE"]) * raw + float(values["REGRESSION_BIAS"])
            loss = (prediction - row["target"]) ** 2
            score = 1.0 / (1.0 + math.sqrt(loss))
            probability = prediction
        grouped.setdefault(row["group"], []).append((score, loss))
        losses.append(loss)
        if row["stress"]:
            stress_scores.append(score)
        predictions.append(
            {
                "index": index,
                "group": row["group"],
                "prediction": round(float(probability if task != "nonlinear-regression" else prediction), 10),
            }
        )

    per_group = {
        group: sum(score for score, _ in pairs) / len(pairs)
        for group, pairs in sorted(grouped.items())
    }
    metrics = {
        "worst_group": min(per_group.values()),
        "grouped_mean": sum(per_group.values()) / len(per_group),
        "ood_stress": sum(stress_scores) / len(stress_scores),
        "calibration_loss": sum(losses) / len(losses),
        "per_group": per_group,
        "rows": len(rows),
        "complexity": candidate_complexity(task, values),
    }
    return metrics, predictions


def estimate_noise_floor(task: str, rows: list[dict[str, Any]], values: dict[str, Any], seed: int) -> dict[str, float]:
    by_group: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        by_group.setdefault(row["group"], []).append(row)
    rng = random.Random(stable_seed(seed, task, "noise-floor"))
    samples: dict[str, list[float]] = {name: [] for name in DIRECTIONS}
    for _ in range(64):
        resampled: list[dict[str, Any]] = []
        for group_rows in by_group.values():
            resampled.extend(group_rows[rng.randrange(len(group_rows))] for _ in group_rows)
        metrics, _ = group_metrics(task, resampled, values)
        for name in DIRECTIONS:
            samples[name].append(float(metrics[name]))
    floors: dict[str, float] = {}
    for name, values_for_metric in samples.items():
        mean = sum(values_for_metric) / len(values_for_metric)
        variance = sum((value - mean) ** 2 for value in values_for_metric) / len(values_for_metric)
        floors[name] = round(1.96 * math.sqrt(variance), 6)
    return floors


def candidate_complexity(task: str, values: dict[str, Any]) -> int:
    if task == "grouped-classification":
        return int(values["GROUPED_CAUSAL_WEIGHT"] != 0.65) + int(values["GROUPED_SPURIOUS_WEIGHT"] != 1.0) + int(values["GROUPED_THRESHOLD"] != 0.0)
    if task == "nonlinear-regression":
        return len(values["REGRESSION_COMPONENTS"]) + int(values["REGRESSION_SCALE"] != 1.0) + int(values["REGRESSION_BIAS"] != 0.0)
    return int(values["NOISY_THRESHOLD"] != 0.0) + int(values["NOISY_MARGIN"] != 0.0)


def worker_main(args: argparse.Namespace) -> int:
    import socket

    def deny_network(*_args: Any, **_kwargs: Any) -> Any:
        raise PermissionError("network denied by competition-scientist lab")

    socket.socket = deny_network  # type: ignore[assignment]
    socket.create_connection = deny_network  # type: ignore[assignment]
    started = time.monotonic()
    try:
        values = parse_candidate(Path(args.candidate))
        rows = read_json(Path(args.data))
        metrics, predictions = group_metrics(args.task, rows, values)
        result = {
            "ok": True,
            "metrics": metrics,
            "predictions": predictions,
            "prediction_sha256": sha256_bytes(canonical_json(predictions).encode("utf-8")),
            "wall_seconds": round(time.monotonic() - started, 6),
        }
        write_json(Path(args.output), result)
        return 0
    except MemoryError as exc:
        write_json(Path(args.output), {"ok": False, "failure_class": "oom", "error": str(exc)})
        return 73
    except PermissionError as exc:
        write_json(Path(args.output), {"ok": False, "failure_class": "network-denied", "error": str(exc)})
        return 74
    except Exception as exc:
        write_json(Path(args.output), {"ok": False, "failure_class": "runtime", "error": f"{type(exc).__name__}: {exc}"})
        return 70


def limited_preexec(cpu_seconds: int, memory_mb: int) -> None:
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds + 1))
    if sys.platform != "darwin":
        memory_bytes = memory_mb * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))


EVALUATOR_POLL_SECONDS = 0.25


def resident_memory_mb(pid: int) -> float:
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-o", "rss=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return float(output or 0) / 1024.0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0.0


def stop_process_group(proc: subprocess.Popen[str]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        proc.kill()


def run_bounded_evaluator(workspace: Path, candidate: Path, split: str) -> dict[str, Any]:
    manifest = verify_frozen(workspace)
    caps = manifest["caps"]
    output_dir = workspace / ".run" / "tmp"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"evaluation-{os.getpid()}-{time.time_ns()}.json"
    generated_data: Path | None = None
    try:
        if split == "sealed":
            rows = generate_dataset(manifest["task"], manifest["seed"], "sealed")
            if sha256_bytes(canonical_json(rows).encode("utf-8")) != manifest["sealed_dataset_sha256"]:
                raise LabError("immutable-violation:sealed-generation")
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                prefix="sealed-",
                suffix=".json",
                dir=output_dir,
                delete=False,
            ) as handle:
                generated_data = Path(handle.name)
                json.dump(rows, handle, sort_keys=True)
                handle.write("\n")
            data_path = generated_data
        else:
            data_path = workspace / ".frozen" / f"{split}.json"

        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "_evaluate",
            "--task",
            manifest["task"],
            "--candidate",
            str(candidate),
            "--data",
            str(data_path),
            "--output",
            str(output),
        ]
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(workspace / ".run" / "empty-home"),
            "PYTHONHASHSEED": str(manifest["seed"]),
            "PYTHONNOUSERSITE": "1",
            "NO_PROXY": "*",
            "no_proxy": "*",
            "HTTP_PROXY": "",
            "HTTPS_PROXY": "",
            "ALL_PROXY": "",
        }
        started = time.monotonic()
        try:
            proc = subprocess.Popen(
                command,
                cwd=workspace,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                preexec_fn=lambda: limited_preexec(caps["cpu_seconds"], caps["memory_mb"]),
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return {
                "ok": False,
                "failure_class": "runtime",
                "error": f"cannot start evaluator: {exc}",
                "wall_seconds": round(time.monotonic() - started, 6),
            }
        failure_class = ""
        sample_memory = sys.platform == "darwin"
        while True:
            remaining = caps["wall_seconds"] - (time.monotonic() - started)
            if remaining <= 0:
                failure_class = "timeout"
                stop_process_group(proc)
                break
            try:
                proc.wait(timeout=min(remaining, EVALUATOR_POLL_SECONDS))
                break
            except subprocess.TimeoutExpired:
                pass
            if sample_memory and resident_memory_mb(proc.pid) > caps["memory_mb"]:
                failure_class = "oom"
                stop_process_group(proc)
                break
        stdout, stderr = proc.communicate()
        elapsed = round(time.monotonic() - started, 6)
        if failure_class:
            return {
                "ok": False,
                "failure_class": failure_class,
                "error": f"evaluator exceeded {failure_class} limit",
                "wall_seconds": elapsed,
            }
        if output.exists():
            result = read_json(output)
            result["wall_seconds"] = elapsed
            result["stderr"] = stderr[-2000:]
            return result
        if proc.returncode == -signal.SIGXCPU:
            failure = "cpu-limit"
        elif proc.returncode == -signal.SIGKILL:
            failure = "oom"
        else:
            failure = "runtime"
        return {
            "ok": False,
            "failure_class": failure,
            "error": (stderr or stdout or f"evaluator exited {proc.returncode}")[-2000:],
            "wall_seconds": elapsed,
        }
    finally:
        output.unlink(missing_ok=True)
        if generated_data is not None:
            generated_data.unlink(missing_ok=True)


def environment_record() -> dict[str, Any]:
    return {
        "python": platform.python_version(),
        "implementation": platform.python_implementation(),
        "platform": platform.platform(),
        "dependencies": [],
        "network": "denied",
    }


def manifest_digest(manifest: dict[str, Any]) -> str:
    unsigned = dict(manifest)
    unsigned.pop("manifest_sha256", None)
    return sha256_bytes(canonical_json(unsigned).encode("utf-8"))


def validate_run_limits(args: argparse.Namespace) -> None:
    if args.branch_factor > 2:
        raise LabError("branch-factor-may-not-exceed-two")
    if args.planning_token_budget * 5 > args.token_budget:
        raise LabError("planning-budget-may-not-exceed-twenty-percent")
    if args.token_budget // args.attempts <= 0:
        raise LabError("token-budget-too-small-for-attempt-count")


def init_workspace(args: argparse.Namespace) -> Path:
    validate_run_limits(args)
    workspace = Path(args.workspace).expanduser().resolve()
    if workspace.exists():
        raise LabError(f"workspace already exists: {workspace}")
    workspace.parent.mkdir(parents=True, exist_ok=True)
    workspace.mkdir(mode=0o700)
    frozen = workspace / ".frozen"
    run_dir = workspace / ".run"
    frozen.mkdir(mode=0o700)
    run_dir.mkdir(mode=0o700)
    (workspace / "artifacts").mkdir(mode=0o700)
    (run_dir / "tmp").mkdir(mode=0o700)
    (run_dir / "empty-home").mkdir(mode=0o700)

    baseline = BASELINE_TEMPLATE.read_bytes()
    (workspace / "candidate.py").write_bytes(baseline)
    (workspace / "candidate.py").chmod(0o600)

    for split in ("dev", "falsification"):
        write_json(
            frozen / f"{split}.json",
            generate_dataset(args.task, args.seed, split),
            immutable=True,
        )

    caps = {
        "attempts": args.attempts,
        "wall_seconds": args.wall_seconds,
        "cpu_seconds": args.cpu_seconds,
        "memory_mb": args.memory_mb,
        "token_budget": args.token_budget,
        "planning_token_budget": args.planning_token_budget,
        "branch_factor": args.branch_factor,
        "plateau": args.plateau,
    }
    dev_rows = read_json(frozen / "dev.json")
    baseline_values = parse_candidate(workspace / "candidate.py")
    noise_floor = estimate_noise_floor(args.task, dev_rows, baseline_values, args.seed)
    manifest = {
        "schema": SCHEMA_VERSION,
        "task": args.task,
        "controller": args.controller,
        "seed": args.seed,
        "created_utc": "deterministic-fixture" if args.fixture else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "editable_surface": "candidate.py",
        "engine": str(Path(__file__).resolve()),
        "engine_sha256": sha256_file(Path(__file__).resolve()),
        "baseline_template_sha256": sha256_bytes(baseline),
        "environment": environment_record(),
        "caps": caps,
        "per_attempt_token_cap": caps["token_budget"] // caps["attempts"],
        "noise_floor": noise_floor,
        "noise_floor_source": "one 1.96-sigma resolution floor per metric from 64 deterministic within-group bootstrap resamples of the baseline",
        "catastrophic_group_drop": 0.10,
        "frozen": {
            f"{split}.json": sha256_file(frozen / f"{split}.json")
            for split in ("dev", "falsification")
        },
        "sealed_dataset_sha256": sha256_bytes(
            canonical_json(generate_dataset(args.task, args.seed, "sealed")).encode("utf-8")
        ),
    }
    manifest["manifest_sha256"] = manifest_digest(manifest)
    write_json(frozen / "manifest.json", manifest, immutable=True)
    frozen.chmod(0o500)

    state = {
        "schema": SCHEMA_VERSION,
        "complete": False,
        "attempts_used": 0,
        "tokens_used": 0,
        "planning_tokens_used": 0,
        "consecutive_rejects": 0,
        "branching_enabled": False,
        "branches": {},
        "branch_names": [],
        "candidate_hashes": [],
        "hypotheses": [],
        "falsification_calls": 0,
        "sealed_calls": 0,
        "global_best_sha256": "",
        "baseline_sha256": "",
    }
    write_mutable_json(run_dir / "state.json", state)
    (run_dir / "ledger.jsonl").touch(mode=0o600)
    (run_dir / "results.tsv").write_text(
        "seq\tkind\tbranch\tcandidate\tprimary\tverdict\tfailure_class\twall_seconds\tdescription\n",
        encoding="utf-8",
    )
    baseline_result = evaluate_and_record(
        workspace,
        {
            "id": "baseline",
            "hypothesis": "Establish the immutable baseline before any proposal.",
            "changes": {},
            "branch": "main",
            "token_cost": 0,
            "planning_tokens": 0,
        },
        baseline=True,
    )
    if baseline_result["verdict"] != "KEEP":
        raise LabError("baseline evaluation failed")
    print(f"initialized: {workspace}")
    print(
        f"baseline: {baseline_result['candidate_sha256']} "
        f"primary={baseline_result['metrics']['worst_group']:.6f}"
    )
    return workspace


ALLOWED_WORKSPACE_FILES = frozenset({
    "candidate.py",
    ".frozen/dev.json",
    ".frozen/falsification.json",
    ".frozen/manifest.json",
    ".run/state.json",
    ".run/ledger.jsonl",
    ".run/results.tsv",
    ".run/final.json",
})


def allowed_workspace_file(relative: str) -> bool:
    if relative in ALLOWED_WORKSPACE_FILES:
        return True
    if relative.startswith(".run/tmp/evaluation-") and relative.endswith(".json"):
        return True
    parts = Path(relative).parts
    if len(parts) == 3 and parts[0] == "artifacts":
        artifact_name, filename = parts[1], parts[2]
        proposal_hash = artifact_name.removeprefix("proposal-")
        if artifact_name.startswith("proposal-") and len(proposal_hash) == 64 and all(c in "0123456789abcdef" for c in proposal_hash) and filename == "proposal.json":
            return True
        if len(artifact_name) == 64 and all(c in "0123456789abcdef" for c in artifact_name) and filename in {"candidate.py", "dev-predictions.json", "result.json"}:
            return True
    return False


def interrupted_write_target(relative: str) -> str:
    name = Path(relative).name
    if not name.startswith(".") or not name.endswith(".tmp"):
        return ""
    target, separator, pid = name[1:-len(".tmp")].rpartition(".")
    if not separator or not target or not pid.isdigit():
        return ""
    return (Path(relative).parent / target).as_posix()


def verify_workspace_surface(workspace: Path) -> None:
    for path in workspace.rglob("*"):
        relative = path.relative_to(workspace).as_posix()
        if path.is_symlink():
            raise LabError(f"undeclared-file-edit:symlink:{relative}")
        if path.is_dir():
            if relative in {".frozen", ".run", ".run/tmp", ".run/empty-home", "artifacts"}:
                continue
            if relative.startswith("artifacts/") and len(Path(relative).parts) == 2:
                continue
            raise LabError(f"undeclared-file-edit:directory:{relative}")
        if allowed_workspace_file(relative):
            continue
        interrupted_target = interrupted_write_target(relative)
        if interrupted_target and allowed_workspace_file(interrupted_target):
            continue
        raise LabError(f"undeclared-file-edit:file:{relative}")


def verify_frozen(workspace: Path) -> dict[str, Any]:
    verify_workspace_surface(workspace)
    frozen = workspace / ".frozen"
    manifest_path = frozen / "manifest.json"
    if manifest_path.is_symlink():
        raise LabError("immutable-violation:manifest-symlink")
    manifest = read_json(manifest_path)
    if manifest.get("manifest_sha256") != manifest_digest(manifest):
        raise LabError("immutable-violation:manifest-hash")
    if manifest.get("engine_sha256") != sha256_file(Path(__file__).resolve()):
        raise LabError("immutable-violation:evaluator-hash")
    if manifest.get("baseline_template_sha256") != sha256_file(BASELINE_TEMPLATE):
        raise LabError("immutable-violation:baseline-template-hash")
    if manifest.get("environment") != environment_record():
        raise LabError("immutable-violation:environment")
    for name, expected in manifest.get("frozen", {}).items():
        path = frozen / name
        if path.is_symlink() or not path.is_file() or sha256_file(path) != expected:
            raise LabError(f"immutable-violation:{name}")
    return manifest


def load_state(workspace: Path) -> dict[str, Any]:
    return read_json(workspace / ".run" / "state.json")


def save_state(workspace: Path, state: dict[str, Any]) -> None:
    write_mutable_json(workspace / ".run" / "state.json", state)


def append_record(workspace: Path, record: dict[str, Any]) -> None:
    ledger = workspace / ".run" / "ledger.jsonl"
    previous_hash = ""
    existing = [line for line in ledger.read_text(encoding="utf-8").splitlines() if line]
    if existing:
        previous_hash = json.loads(existing[-1])["record_sha256"]
    record["previous_record_sha256"] = previous_hash
    unsigned = dict(record)
    unsigned.pop("record_sha256", None)
    record["record_sha256"] = sha256_bytes(canonical_json(unsigned).encode("utf-8"))
    with ledger.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(record) + "\n")
    metrics = record.get("metrics") or {}
    primary = metrics.get("worst_group")
    primary_text = "" if primary is None else f"{primary:.6f}"
    fields = [
        str(record["seq"]),
        record["kind"],
        record.get("branch", ""),
        record.get("candidate_sha256", ""),
        primary_text,
        record["verdict"],
        record.get("failure_class", ""),
        f"{record.get('wall_seconds', 0.0):.6f}",
        record.get("hypothesis", "").replace("\t", " ").replace("\n", " "),
    ]
    with (workspace / ".run" / "results.tsv").open("a", encoding="utf-8") as handle:
        handle.write("\t".join(fields) + "\n")


def load_artifact_metrics(workspace: Path, candidate_sha: str) -> dict[str, Any]:
    return read_json(workspace / "artifacts" / candidate_sha / "result.json")["metrics"]


def metric_comparison(candidate: dict[str, Any], parent: dict[str, Any], manifest: dict[str, Any]) -> tuple[bool, str, float]:
    tolerance = float(manifest["catastrophic_group_drop"])
    if float(candidate["worst_group"]) < float(parent["worst_group"]):
        for group, parent_score in parent["per_group"].items():
            candidate_score = float(candidate["per_group"].get(group, 0.0))
            if candidate_score < parent_score - tolerance:
                return False, f"catastrophic-group-regression:{group}", candidate_score - parent_score
    for name, direction in DIRECTIONS.items():
        floor = float(manifest["noise_floor"][name])
        delta = direction * (float(candidate[name]) - float(parent[name]))
        if abs(delta) > floor:
            return delta > 0, f"lexicographic:{name}", delta
    complexity_delta = int(parent["complexity"]) - int(candidate["complexity"])
    if complexity_delta > 0:
        return True, "simplicity-win", float(complexity_delta)
    return False, "below-resolution", 0.0


def archive_candidate(workspace: Path, candidate: Path, result: dict[str, Any]) -> tuple[str, str]:
    candidate_bytes = candidate.read_bytes()
    candidate_sha = sha256_bytes(candidate_bytes)
    artifact = workspace / "artifacts" / candidate_sha
    artifact.mkdir(parents=True, exist_ok=True)
    stored_candidate = artifact / "candidate.py"
    if stored_candidate.exists() and stored_candidate.read_bytes() != candidate_bytes:
        raise LabError("artifact-collision:candidate")
    stored_candidate.write_bytes(candidate_bytes)
    predictions = result.get("predictions", [])
    predictions_text = canonical_json(predictions) + "\n"
    predictions_path = artifact / "dev-predictions.json"
    if predictions_path.exists() and predictions_path.read_text(encoding="utf-8") != predictions_text:
        raise LabError("artifact-collision:predictions")
    predictions_path.write_text(predictions_text, encoding="utf-8")
    stored_result = dict(result)
    stored_result.pop("predictions", None)
    write_json(artifact / "result.json", stored_result)
    return candidate_sha, result["prediction_sha256"]


def policy_reject(workspace: Path, proposal: Any, failure_class: str) -> dict[str, Any]:
    manifest = verify_frozen(workspace)
    state = load_state(workspace)
    proposal_text = canonical_json(proposal)
    proposal_sha = sha256_bytes(proposal_text.encode("utf-8"))
    artifact = workspace / "artifacts" / f"proposal-{proposal_sha}"
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / "proposal.json").write_text(proposal_text + "\n", encoding="utf-8")
    record = {
        "schema": SCHEMA_VERSION,
        "seq": state["attempts_used"],
        "kind": "policy-reject",
        "task": manifest["task"],
        "controller": manifest["controller"],
        "branch": proposal.get("branch", "") if isinstance(proposal, dict) else "",
        "parent_sha256": "",
        "candidate_sha256": "",
        "proposal_sha256": proposal_sha,
        "hypothesis": proposal.get("hypothesis", "") if isinstance(proposal, dict) else "",
        "changes": proposal.get("changes", {}) if isinstance(proposal, dict) else {},
        "metrics": None,
        "verdict": "REVERT",
        "failure_class": failure_class,
        "wall_seconds": 0.0,
        "resources": {
            "tokens": proposal.get("token_cost", 0) if isinstance(proposal, dict) and isinstance(proposal.get("token_cost", 0), int) else 0,
            "planning_tokens": proposal.get("planning_tokens", 0) if isinstance(proposal, dict) and isinstance(proposal.get("planning_tokens", 0), int) else 0,
        },
        "replay": "not-executed-policy-rejection",
    }
    append_record(workspace, record)
    state["attempts_used"] += 1
    save_state(workspace, state)
    return record


def evaluate_and_record(workspace: Path, proposal: dict[str, Any], *, baseline: bool = False, inject_failure: str = "") -> dict[str, Any]:
    manifest = verify_frozen(workspace)
    state = load_state(workspace)
    if state["complete"]:
        raise LabError("search already complete")
    if state["attempts_used"] >= manifest["caps"]["attempts"]:
        raise LabError("attempt-budget-exhausted")

    candidate_path = workspace / "candidate.py"
    if baseline:
        values = parse_candidate(candidate_path)
        parent_sha = ""
        branch = "main"
    else:
        proposal = validate_proposal(proposal, manifest["task"])
        branch = proposal["branch"]
        next_tokens = state["tokens_used"] + proposal["token_cost"] + proposal["planning_tokens"]
        next_planning = state["planning_tokens_used"] + proposal["planning_tokens"]
        if next_tokens > manifest["caps"]["token_budget"]:
            return policy_reject(workspace, proposal, "token-budget-exceeded")
        if proposal["token_cost"] + proposal["planning_tokens"] > manifest["per_attempt_token_cap"]:
            return policy_reject(workspace, proposal, "attempt-token-cap-exceeded")
        if next_planning > manifest["caps"]["planning_token_budget"]:
            return policy_reject(workspace, proposal, "planning-budget-exceeded")
        state["tokens_used"] = next_tokens
        state["planning_tokens_used"] = next_planning
        save_state(workspace, state)

        if manifest["controller"] == "linear" and proposal["planning_tokens"]:
            return policy_reject(workspace, proposal, "planning-disabled-linear")
        if manifest["controller"] == "linear" and branch != "main":
            return policy_reject(workspace, proposal, "branch-disabled-linear")
        if branch != "main":
            if not state["branching_enabled"]:
                if state["attempts_used"] < 4:
                    return policy_reject(workspace, proposal, "branch-before-four-attempts")
                if state["consecutive_rejects"] < manifest["caps"]["plateau"]:
                    return policy_reject(workspace, proposal, "branch-before-plateau")
                state["branching_enabled"] = True
            if branch not in state["branch_names"]:
                if len(state["branch_names"]) >= manifest["caps"]["branch_factor"]:
                    return policy_reject(workspace, proposal, "branch-factor-exceeded")
                state["branch_names"].append(branch)
                state["branches"][branch] = state["global_best_sha256"]
        elif branch not in state["branches"]:
            state["branches"][branch] = state["global_best_sha256"]
        save_state(workspace, state)

        normalized_hypothesis = " ".join(proposal["hypothesis"].lower().split())
        if normalized_hypothesis in state["hypotheses"]:
            return policy_reject(workspace, proposal, "duplicate-hypothesis")
        state["hypotheses"].append(normalized_hypothesis)
        save_state(workspace, state)
        parent_sha = state["branches"].get(branch) or state["global_best_sha256"]
        parent_candidate = workspace / "artifacts" / parent_sha / "candidate.py"
        values = parse_candidate(parent_candidate)
        lever, value = next(iter(proposal["changes"].items()))
        values[lever] = tuple(value) if lever == "REGRESSION_COMPONENTS" and isinstance(value, list) else value
        if inject_failure:
            values["INJECT_FAILURE"] = inject_failure
        validate_candidate(values)
        break_syntax = inject_failure == "syntax"
        candidate_path.write_text(render_candidate(values, break_syntax=break_syntax), encoding="utf-8")
        candidate_sha = sha256_file(candidate_path)
        if candidate_sha in state["candidate_hashes"]:
            candidate_path.write_bytes((workspace / "artifacts" / state["global_best_sha256"] / "candidate.py").read_bytes())
            return policy_reject(workspace, proposal, "duplicate-candidate")
        state["candidate_hashes"].append(candidate_sha)
        save_state(workspace, state)

    started = time.monotonic()
    try:
        parse_candidate(candidate_path)
        result = run_bounded_evaluator(workspace, candidate_path, "dev")
        result["evaluation_repeats"] = 1
        if result.get("ok"):
            repeated = run_bounded_evaluator(workspace, candidate_path, "dev")
            result["evaluation_repeats"] = 2
            result["wall_seconds"] = float(result.get("wall_seconds", 0.0)) + float(repeated.get("wall_seconds", 0.0))
            if not repeated.get("ok"):
                result = {
                    "ok": False,
                    "failure_class": f"repeat-{repeated.get('failure_class', 'runtime')}",
                    "error": repeated.get("error", "repeat evaluation failed"),
                    "wall_seconds": result["wall_seconds"],
                    "evaluation_repeats": 2,
                }
            elif result["prediction_sha256"] != repeated["prediction_sha256"] or canonical_json(result["metrics"]) != canonical_json(repeated["metrics"]):
                result = {
                    "ok": False,
                    "failure_class": "nondeterministic-replay",
                    "error": "the two development evaluations disagreed",
                    "wall_seconds": result["wall_seconds"],
                    "evaluation_repeats": 2,
                }
    except LabError as exc:
        message = str(exc)
        failure_class = "syntax" if message.startswith("syntax:") else "policy-violation"
        result = {"ok": False, "failure_class": failure_class, "error": message, "wall_seconds": 0.0, "evaluation_repeats": 0}
    elapsed = round(time.monotonic() - started, 6)
    result["wall_seconds"] = max(float(result.get("wall_seconds", 0.0)), elapsed)

    if not result.get("ok"):
        candidate_bytes = candidate_path.read_bytes()
        candidate_sha = sha256_bytes(candidate_bytes)
        artifact = workspace / "artifacts" / candidate_sha
        artifact.mkdir(parents=True, exist_ok=True)
        (artifact / "candidate.py").write_bytes(candidate_bytes)
        write_json(artifact / "result.json", result)
        verdict = "FAIL"
        reason = result.get("failure_class", "runtime")
        metrics = None
        predictions_sha = ""
    else:
        candidate_sha, predictions_sha = archive_candidate(workspace, candidate_path, result)
        metrics = result["metrics"]
        if baseline:
            verdict, reason = "KEEP", "baseline"
        else:
            parent_metrics = load_artifact_metrics(workspace, parent_sha)
            keep, reason, _ = metric_comparison(metrics, parent_metrics, manifest)
            verdict = "KEEP" if keep else "REVERT"

    state = load_state(workspace)
    seq = state["attempts_used"]
    record = {
        "schema": SCHEMA_VERSION,
        "seq": seq,
        "kind": "baseline" if baseline else "experiment",
        "task": manifest["task"],
        "controller": manifest["controller"],
        "branch": branch,
        "parent_sha256": parent_sha,
        "candidate_sha256": candidate_sha,
        "prediction_sha256": predictions_sha,
        "hypothesis": proposal["hypothesis"],
        "changes": proposal["changes"],
        "falsifier": proposal.get("falsifier", ""),
        "metrics": metrics,
        "verdict": verdict,
        "failure_class": "" if result.get("ok") else result.get("failure_class", "runtime"),
        "decision_reason": reason,
        "wall_seconds": result["wall_seconds"],
        "evaluation_repeats": result.get("evaluation_repeats", 0),
        "resources": {
            "tokens": proposal.get("token_cost", 0),
            "planning_tokens": proposal.get("planning_tokens", 0),
            "cpu_seconds_limit": manifest["caps"]["cpu_seconds"],
            "memory_mb_limit": manifest["caps"]["memory_mb"],
        },
        "frozen_hashes": manifest["frozen"],
        "evaluator_sha256": manifest["engine_sha256"],
        "environment": manifest["environment"],
        "replay": f"bin/fm-competition-scientist-lab.sh replay {workspace}",
    }
    append_record(workspace, record)

    state["attempts_used"] += 1
    if baseline:
        state["baseline_sha256"] = candidate_sha
        state["global_best_sha256"] = candidate_sha
        state["branches"] = {"main": candidate_sha}
        state["candidate_hashes"] = [candidate_sha]
        state["consecutive_rejects"] = 0
    elif verdict == "KEEP":
        state["branches"][branch] = candidate_sha
        state["consecutive_rejects"] = 0
        current_best = load_artifact_metrics(workspace, state["global_best_sha256"])
        is_better, _, _ = metric_comparison(metrics, current_best, manifest)
        if is_better:
            state["global_best_sha256"] = candidate_sha
    elif verdict == "REVERT":
        state["consecutive_rejects"] += 1
    save_state(workspace, state)

    best = workspace / "artifacts" / state["global_best_sha256"] / "candidate.py"
    if best.exists():
        candidate_path.unlink(missing_ok=True)
        candidate_path.write_bytes(best.read_bytes())
        candidate_path.chmod(0o600)
    return record


def print_final(final: dict[str, Any]) -> None:
    aborted = final.get("aborted")
    if aborted:
        print(
            f"aborted: task={final['task']} controller={final['controller']} "
            f"phase={aborted['phase']} error={aborted['error']}"
        )
        return
    metrics = final["sealed"].get("metrics") or {}
    print(
        f"final: task={final['task']} controller={final['controller']} "
        f"attempts={final['attempts_used']} selected={final['selected_candidate_sha256'][:12]} "
        f"sealed_worst_group={metrics.get('worst_group', 0.0):.6f}"
    )


def publish_final(workspace: Path, state: dict[str, Any], final: dict[str, Any]) -> dict[str, Any]:
    write_mutable_json(workspace / ".run" / "final.json", final)
    state["complete"] = True
    save_state(workspace, state)
    return final


def abandon_charged_search(
    workspace: Path,
    manifest: dict[str, Any],
    state: dict[str, Any],
    phase: str,
    error: BaseException,
    falsification: dict[str, Any] | None,
) -> None:
    publish_final(
        workspace,
        state,
        {
            "schema": SCHEMA_VERSION,
            "task": manifest["task"],
            "controller": manifest["controller"],
            "selected_candidate_sha256": "",
            "development_best_sha256": state["global_best_sha256"],
            "aborted": {
                "phase": phase,
                "error": f"{type(error).__name__}: {error}"[-2000:],
            },
            "falsification": None if falsification is None else {
                "ok": falsification.get("ok", False),
                "metrics": falsification.get("metrics"),
                "failure_class": falsification.get("failure_class", ""),
            },
            "sealed": {
                "ok": False,
                "metrics": None,
                "prediction_sha256": "",
                "failure_class": "sealed-not-completed" if state["sealed_calls"] else "",
            },
            "sealed_calls": state["sealed_calls"],
            "falsification_calls": state["falsification_calls"],
            "attempts_used": state["attempts_used"],
            "tokens_used": state["tokens_used"],
            "planning_tokens_used": state["planning_tokens_used"],
        },
    )


def finish_workspace(workspace: Path) -> dict[str, Any]:
    manifest = verify_frozen(workspace)
    state = load_state(workspace)
    if state["complete"]:
        stored = read_json(workspace / ".run" / "final.json")
        print_final(stored)
        return stored
    if state["sealed_calls"] >= 1:
        raise LabError("sealed-audit-already-called")
    if state["falsification_calls"] >= 1:
        raise LabError("falsification-budget-exhausted")
    best_sha = state["global_best_sha256"]
    selected_sha = best_sha
    falsification: dict[str, Any] | None = None
    charged_phase = ""
    try:
        if manifest["controller"] == "proposed":
            charged_phase = "falsification"
            state["falsification_calls"] += 1
            save_state(workspace, state)
            prior_records = [
                json.loads(line)
                for line in (workspace / ".run" / "ledger.jsonl").read_text(encoding="utf-8").splitlines()
                if line
            ]
            selected_record = next(
                (record for record in reversed(prior_records) if record.get("candidate_sha256") == best_sha),
                {},
            )
            requested_falsifier = selected_record.get("falsifier") or "Challenge the selected candidate on the frozen counterfactual split."
            candidate = workspace / "artifacts" / best_sha / "candidate.py"
            falsification = run_bounded_evaluator(workspace, candidate, "falsification")
            baseline_metrics = run_bounded_evaluator(
                workspace,
                workspace / "artifacts" / state["baseline_sha256"] / "candidate.py",
                "falsification",
            )
            if not falsification.get("ok") or not baseline_metrics.get("ok"):
                selected_sha = state["baseline_sha256"]
            else:
                keep, _, _ = metric_comparison(falsification["metrics"], baseline_metrics["metrics"], manifest)
                if best_sha != state["baseline_sha256"] and not keep:
                    selected_sha = state["baseline_sha256"]
            append_record(
                workspace,
                {
                    "schema": SCHEMA_VERSION,
                    "seq": state["attempts_used"],
                    "kind": "falsification",
                    "task": manifest["task"],
                    "controller": manifest["controller"],
                    "branch": "",
                    "parent_sha256": state["baseline_sha256"],
                    "candidate_sha256": best_sha,
                    "hypothesis": "Try to disconfirm the development-selected candidate on counterfactual data.",
                    "falsifier": requested_falsifier,
                    "changes": {},
                    "metrics": falsification.get("metrics") if falsification else None,
                    "verdict": "KEEP" if selected_sha == best_sha else "REVERT",
                    "failure_class": "" if falsification and falsification.get("ok") else (falsification or {}).get("failure_class", "runtime"),
                    "wall_seconds": (falsification or {}).get("wall_seconds", 0.0),
                    "resources": {"tokens": 0, "planning_tokens": 0},
                    "replay": "sealed-by-design:not-part-of-attempt-replay",
                },
            )

        charged_phase = "sealed"
        state["sealed_calls"] += 1
        save_state(workspace, state)
        sealed_candidate = workspace / "artifacts" / selected_sha / "candidate.py"
        sealed = run_bounded_evaluator(workspace, sealed_candidate, "sealed")
        state["selected_candidate_sha256"] = selected_sha
        final = publish_final(
            workspace,
            state,
            {
                "schema": SCHEMA_VERSION,
                "task": manifest["task"],
                "controller": manifest["controller"],
                "selected_candidate_sha256": selected_sha,
                "development_best_sha256": best_sha,
                "aborted": None,
                "falsification": None if falsification is None else {
                    "ok": falsification.get("ok", False),
                    "metrics": falsification.get("metrics"),
                    "failure_class": falsification.get("failure_class", ""),
                },
                "sealed": {
                    "ok": sealed.get("ok", False),
                    "metrics": sealed.get("metrics"),
                    "prediction_sha256": sealed.get("prediction_sha256", ""),
                    "failure_class": sealed.get("failure_class", ""),
                },
                "sealed_calls": state["sealed_calls"],
                "falsification_calls": state["falsification_calls"],
                "attempts_used": state["attempts_used"],
                "tokens_used": state["tokens_used"],
                "planning_tokens_used": state["planning_tokens_used"],
            },
        )
    except BaseException as exc:
        if charged_phase:
            abandon_charged_search(workspace, manifest, state, charged_phase, exc, falsification)
        raise
    (workspace / "candidate.py").write_bytes(sealed_candidate.read_bytes())
    print_final(final)
    return final


def load_proposals(path: Path) -> list[Any]:
    proposals: list[Any] = []
    try:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            try:
                proposals.append(json.loads(line))
            except json.JSONDecodeError as exc:
                proposals.append({"parse_error": f"line {line_number}: {exc}"})
    except OSError as exc:
        raise LabError(f"cannot read proposals: {exc}") from exc
    return proposals


def fixture_proposals(task: str, controller: str) -> list[dict[str, Any]]:
    branches = ["main", "main", "main", "branch-a", "branch-b"] if controller == "proposed" else ["main"] * 5
    raw: dict[str, list[tuple[str, Any, str]]] = {
        "grouped-classification": [
            ("GROUPED_THRESHOLD", 0.12, "Move the decision threshold away from zero."),
            ("GROUPED_CAUSAL_WEIGHT", 0.45, "Reduce the causal feature weight."),
            ("GROUPED_SPURIOUS_WEIGHT", 1.2, "Increase reliance on the development-correlated feature."),
            ("GROUPED_SPURIOUS_WEIGHT", 0.0, "Remove the feature whose relationship flips in stress groups."),
            ("GROUPED_CAUSAL_WEIGHT", 1.2, "Increase the stable causal signal."),
        ],
        "nonlinear-regression": [
            ("REGRESSION_BIAS", 0.8, "Shift every regression prediction upward."),
            ("REGRESSION_SCALE", 0.2, "Shrink the current linear prediction."),
            ("REGRESSION_BIAS", -0.8, "Shift every regression prediction downward."),
            ("REGRESSION_COMPONENTS", ["linear", "quadratic"], "Blend complementary linear and quadratic components."),
            ("REGRESSION_COMPONENTS", ["linear", "sine"], "Blend linear and periodic components."),
        ],
        "noisy-classification": [
            ("NOISY_THRESHOLD", 0.02, "Try a small positive threshold shift."),
            ("NOISY_THRESHOLD", -0.02, "Try a small negative threshold shift."),
            ("NOISY_THRESHOLD", 0.04, "Test whether the small threshold direction persists."),
            ("NOISY_THRESHOLD", 0.15, "Test a larger positive threshold after the plateau."),
            ("NOISY_THRESHOLD", -0.15, "Test a larger negative threshold after the plateau."),
        ],
    }
    proposals = []
    for index, ((lever, value, hypothesis), branch) in enumerate(zip(raw[task], branches), 1):
        proposals.append(
            {
                "id": f"fixture-{task}-{index}",
                "hypothesis": hypothesis,
                "falsifier": "Reject if the paired grouped result is below resolution or harms a group.",
                "changes": {lever: value},
                "branch": branch,
                "token_cost": 0,
                "planning_tokens": 0,
            }
        )
    return proposals


def run_attempt(workspace: Path, proposal: Any, inject_failure: str = "") -> dict[str, Any]:
    try:
        return evaluate_and_record(workspace, proposal, inject_failure=inject_failure)
    except LabError as exc:
        if workspace.exists() and (workspace / ".run" / "state.json").exists():
            message = str(exc)
            if message.startswith(("immutable-violation", "undeclared-file-edit", "attempt-budget-exhausted", "search already complete")):
                raise
            return policy_reject(workspace, proposal, message)
        raise


def run_all(args: argparse.Namespace) -> dict[str, Any]:
    workspace = init_workspace(args)
    proposals = fixture_proposals(args.task, args.controller) if args.fixture else load_proposals(Path(args.proposals))
    for proposal in proposals:
        state = load_state(workspace)
        if state["attempts_used"] >= args.attempts:
            break
        record = run_attempt(workspace, proposal)
        primary = "" if not record.get("metrics") else f" primary={record['metrics']['worst_group']:.6f}"
        print(f"attempt: seq={record['seq']} verdict={record['verdict']} class={record['failure_class'] or 'none'}{primary}")
    return finish_workspace(workspace)


def replay_workspace(workspace: Path) -> None:
    manifest = verify_frozen(workspace)
    records = [json.loads(line) for line in (workspace / ".run" / "ledger.jsonl").read_text(encoding="utf-8").splitlines() if line]
    checked = 0
    previous_hash = ""
    for record in records:
        recorded_hash = record.get("record_sha256", "")
        unsigned = dict(record)
        unsigned.pop("record_sha256", None)
        if record.get("previous_record_sha256", "") != previous_hash or sha256_bytes(canonical_json(unsigned).encode("utf-8")) != recorded_hash:
            raise LabError(f"replay-mismatch:ledger-chain:seq={record.get('seq')}")
        previous_hash = recorded_hash
        if record.get("kind") == "policy-reject":
            proposal_sha = record["proposal_sha256"]
            proposal_path = workspace / "artifacts" / f"proposal-{proposal_sha}" / "proposal.json"
            proposal = read_json(proposal_path)
            if sha256_bytes(canonical_json(proposal).encode("utf-8")) != proposal_sha:
                raise LabError(f"replay-mismatch:proposal:{proposal_sha}")
            continue
        if record.get("kind") not in {"baseline", "experiment"}:
            continue
        candidate_sha = record["candidate_sha256"]
        artifact = workspace / "artifacts" / candidate_sha
        if sha256_file(artifact / "candidate.py") != candidate_sha:
            raise LabError(f"replay-mismatch:candidate:{candidate_sha}")
        stored_result = read_json(artifact / "result.json")
        if canonical_json(stored_result.get("metrics")) != canonical_json(record.get("metrics")):
            raise LabError(f"replay-mismatch:stored-result:{candidate_sha}")
        if not record.get("metrics"):
            continue
        stored_predictions = read_json(artifact / "dev-predictions.json")
        if sha256_bytes(canonical_json(stored_predictions).encode("utf-8")) != record["prediction_sha256"]:
            raise LabError(f"replay-mismatch:stored-predictions:{candidate_sha}")
        result = run_bounded_evaluator(workspace, artifact / "candidate.py", "dev")
        if not result.get("ok"):
            raise LabError(f"replay-failed:{candidate_sha}:{result.get('failure_class')}")
        if canonical_json(result["metrics"]) != canonical_json(record["metrics"]):
            raise LabError(f"replay-mismatch:metrics:{candidate_sha}")
        if result["prediction_sha256"] != record["prediction_sha256"]:
            raise LabError(f"replay-mismatch:predictions:{candidate_sha}")
        checked += 1
    final = read_json(workspace / ".run" / "final.json")
    aborted = final.get("aborted")
    sealed_calls = final.get("sealed_calls")
    charged = 0 if (aborted or {}).get("phase") == "falsification" else 1
    if sealed_calls != charged or load_state(workspace).get("sealed_calls") != charged:
        raise LabError("replay-mismatch:sealed-call-count")
    outcome = "" if aborted is None else f" aborted={aborted['phase']}"
    print(f"replay: PASS task={manifest['task']} controller={manifest['controller']} candidates={checked} sealed_calls={sealed_calls}{outcome}")


def smoke(args: argparse.Namespace) -> None:
    root = Path(args.output).expanduser().resolve()
    if root.exists():
        raise LabError(f"output already exists: {root}")
    root.mkdir(parents=True, mode=0o700)
    summaries = []
    for task in TASKS:
        for controller in CONTROLLERS:
            workspace = root / f"{task}-{controller}"
            child_args = argparse.Namespace(
                workspace=str(workspace),
                task=task,
                controller=controller,
                seed=args.seed,
                attempts=DEFAULT_CAPS["attempts"],
                wall_seconds=args.wall_seconds,
                cpu_seconds=args.cpu_seconds,
                memory_mb=args.memory_mb,
                token_budget=DEFAULT_CAPS["token_budget"],
                planning_token_budget=DEFAULT_CAPS["planning_token_budget"],
                branch_factor=DEFAULT_CAPS["branch_factor"],
                plateau=DEFAULT_CAPS["plateau"],
                fixture=True,
                proposals=None,
            )
            final = run_all(child_args)
            replay_workspace(workspace)
            summaries.append(
                {
                    "task": task,
                    "controller": controller,
                    "attempts": final["attempts_used"],
                    "sealed_worst_group": round(final["sealed"]["metrics"]["worst_group"], 6),
                    "selected": final["selected_candidate_sha256"][:12],
                }
            )
    print("smoke-summary:" + canonical_json(summaries))


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def add_run_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workspace", required=True, help="New isolated output directory.")
    parser.add_argument("--task", required=True, choices=TASKS)
    parser.add_argument("--controller", required=True, choices=CONTROLLERS)
    parser.add_argument("--seed", type=int, default=20260922)
    parser.add_argument("--attempts", type=positive_int, default=DEFAULT_CAPS["attempts"], help="Total measured attempts including the baseline.")
    parser.add_argument("--wall-seconds", type=positive_int, default=DEFAULT_CAPS["wall_seconds"])
    parser.add_argument("--cpu-seconds", type=positive_int, default=DEFAULT_CAPS["cpu_seconds"])
    parser.add_argument("--memory-mb", type=positive_int, default=DEFAULT_CAPS["memory_mb"])
    parser.add_argument("--token-budget", type=positive_int, default=DEFAULT_CAPS["token_budget"])
    parser.add_argument("--planning-token-budget", type=positive_int, default=DEFAULT_CAPS["planning_token_budget"])
    parser.add_argument("--branch-factor", type=positive_int, default=DEFAULT_CAPS["branch_factor"])
    parser.add_argument("--plateau", type=positive_int, default=DEFAULT_CAPS["plateau"])


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Run an inert synthetic competition-scientist pilot with a frozen evaluator and one editable candidate surface.",
        epilog="This lab never invokes an LLM or submits to a competition. See docs/examples/competition-scientist/README.md.",
    )
    sub = result.add_subparsers(dest="command", required=True)

    init_parser = sub.add_parser("init", help="Create a workspace and record its baseline.")
    add_run_options(init_parser)
    init_parser.set_defaults(fixture=False)

    run_parser = sub.add_parser("run", help="Create and complete one bounded search.")
    add_run_options(run_parser)
    source = run_parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--fixture", action="store_true", help="Use deterministic built-in proposals and spend zero model tokens.")
    source.add_argument("--proposals", help="Read typed one-lever proposals from JSONL.")

    attempt_parser = sub.add_parser("attempt", help="Apply one typed proposal to an initialized workspace.")
    attempt_parser.add_argument("workspace")
    attempt_parser.add_argument("--proposal", required=True, help="Path to a one-object JSON proposal.")
    attempt_parser.add_argument(
        "--inject-failure",
        default="",
        choices=[failure for failure in ALLOWED_FAILURES if failure],
        help="Harness-only recovery drill: corrupt this attempt's candidate with the named failure. Not selectable by a proposal.",
    )

    finish_parser = sub.add_parser("finish", help="Run the bounded falsifier when enabled, then the sealed audit exactly once.")
    finish_parser.add_argument("workspace")

    replay_parser = sub.add_parser("replay", help="Verify hashes and reproduce every visible scored candidate without re-running the sealed audit.")
    replay_parser.add_argument("workspace")

    smoke_parser = sub.add_parser("smoke", help="Run one deterministic zero-token search for every task/controller pair.")
    smoke_parser.add_argument("--output", required=True, help="New directory for all six smoke workspaces.")
    smoke_parser.add_argument("--seed", type=int, default=20260922)
    smoke_parser.add_argument("--wall-seconds", type=positive_int, default=5)
    smoke_parser.add_argument("--cpu-seconds", type=positive_int, default=5)
    smoke_parser.add_argument("--memory-mb", type=positive_int, default=512)

    worker = sub.add_parser("_evaluate", help=argparse.SUPPRESS)
    worker.add_argument("--task", required=True, choices=TASKS)
    worker.add_argument("--candidate", required=True)
    worker.add_argument("--data", required=True)
    worker.add_argument("--output", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "_evaluate":
            return worker_main(args)
        if args.command == "init":
            init_workspace(args)
            return 0
        if args.command == "run":
            run_all(args)
            return 0
        if args.command == "attempt":
            proposal = read_json(Path(args.proposal))
            record = run_attempt(Path(args.workspace).expanduser().resolve(), proposal, args.inject_failure)
            print(canonical_json(record))
            return 0
        if args.command == "finish":
            final = finish_workspace(Path(args.workspace).expanduser().resolve())
            return 2 if final.get("aborted") else 0
        if args.command == "replay":
            replay_workspace(Path(args.workspace).expanduser().resolve())
            return 0
        if args.command == "smoke":
            smoke(args)
            return 0
        raise LabError(f"unknown command: {args.command}")
    except LabError as exc:
        print(f"competition-scientist-lab: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
