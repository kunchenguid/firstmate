#!/usr/bin/env python3
"""Localize one provider-neutral cloud worker return bundle.

The worker result and its digest-verified Git bundle are the transport record.
This command copies only the task's authorized report/status/visual/scratch
artifacts, reconstructs the ordinary ship branch without overwriting local
divergence, and appends one truthful terminal status. Re-running the same
command converges on the same files, refs, branch, and status line.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unicodedata


RESULT_SCHEMA = "fm.worker-execution-result/v1"
RETURN_SCHEMA = "fm.worker-return/v1"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SAFE_TASK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SAFE_GENERATION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
REQUIRED_SECTIONS = (
    "Summary", "What changed", "Verification", "Visual evidence", "Artifacts", "Follow-ups",
)
MAX_RESULT_BYTES = 8 * 1024 * 1024
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_ARTIFACT_BYTES = 128 * 1024 * 1024
MAX_VISUAL_BYTES = 20 * 1024 * 1024
MAX_VISUAL_ENTRIES = 512
STATUS_LINE = re.compile(r"^(working|needs-decision|blocked|paused|resolved|done|failed):\s+\S.*$")
TERMINAL_LINE = re.compile(r"^(done|failed):")


class ReturnError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256(body):
    return hashlib.sha256(body).hexdigest()


def read_regular(path, label, limit):
    if path.is_symlink() or not path.is_file():
        raise ReturnError("{} is absent or redirected: {}".format(label, path))
    size = path.stat().st_size
    if size <= 0 or size > limit:
        raise ReturnError("{} has an invalid byte count: {}".format(label, size))
    return path.read_bytes()


def read_result(path, task, generation, assignment):
    body = read_regular(path, "worker result", MAX_RESULT_BYTES)
    try:
        result = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReturnError("worker result is truncated or corrupt: {}".format(exc))
    if not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA:
        raise ReturnError("worker result schema is not supported")
    supplied = result.get("result_digest")
    unsigned = dict(result)
    unsigned.pop("result_digest", None)
    if not HEX64.fullmatch(str(supplied)) or supplied != sha256(canonical(unsigned)):
        raise ReturnError("worker result digest is not exact")
    expected = {
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
    }
    for field, value in expected.items():
        if result.get(field) != value:
            raise ReturnError("worker result {} binding differs".format(field))
    if result.get("return_present") is not True:
        raise ReturnError("worker result has no authorized return bundle")
    for field in ("request_digest", "return_manifest_sha256", "outcome_sha256"):
        if not HEX64.fullmatch(str(result.get(field))):
            raise ReturnError("worker result {} is malformed".format(field))
    for field in ("repository_generation", "return_commit", "outcome_tip"):
        if not HEX40.fullmatch(str(result.get(field))):
            raise ReturnError("worker result {} is malformed".format(field))
    commits = result.get("outcome_commits")
    if not isinstance(commits, int) or isinstance(commits, bool) or commits < 0:
        raise ReturnError("worker result outcome commit count is malformed")
    outcome_bytes = result.get("outcome_bytes")
    if not isinstance(outcome_bytes, int) or isinstance(outcome_bytes, bool) or outcome_bytes <= 0:
        raise ReturnError("worker result outcome byte count is malformed")
    if result.get("outcome_present") is not (commits > 0):
        raise ReturnError("worker result outcome presence differs from its commit count")
    if not isinstance(result.get("outcome_uncommitted_changes"), bool):
        raise ReturnError("worker result working-tree disposition is malformed")
    if not isinstance(result.get("exit_code"), int) or isinstance(result.get("exit_code"), bool):
        raise ReturnError("worker result exit code is malformed")
    if not isinstance(result.get("timed_out"), bool):
        raise ReturnError("worker result timeout disposition is malformed")
    expected_return_ref = "refs/fm-return/{}".format(result["request_digest"][:32])
    if result.get("return_ref") != expected_return_ref:
        raise ReturnError("worker result return ref is not exact")
    return result


def git(worktree, *arguments, input_bytes=None, check=True):
    completed = subprocess.run(
        ["git", "-C", str(worktree), *arguments], input=input_bytes,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if check and completed.returncode != 0:
        raise ReturnError(
            "git {} failed: {}".format(
                arguments[0] if arguments else "command",
                completed.stderr.decode("utf-8", errors="replace").strip()[-500:],
            )
        )
    return completed


def meta_values(path):
    body = read_regular(path, "task metadata", 1024 * 1024)
    try:
        lines = body.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ReturnError("task metadata is not UTF-8: {}".format(exc))
    values = {}
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return values


def exactly(values, key):
    found = values.get(key, [])
    if len(found) != 1 or not found[0]:
        raise ReturnError("task metadata {} is not exact".format(key))
    return found[0]


def fetch_return_refs(worktree, bundle, result, task, generation):
    body = read_regular(bundle, "worker return bundle", MAX_BUNDLE_BYTES)
    if len(body) != result.get("outcome_bytes") or sha256(body) != result.get("outcome_sha256"):
        raise ReturnError("worker return bundle differs from the digest-bound result")
    git(worktree, "bundle", "verify", str(bundle))
    listed = git(worktree, "bundle", "list-heads", str(bundle)).stdout.decode().splitlines()
    heads = {}
    for line in listed:
        parts = line.split(" ", 1)
        if len(parts) == 2:
            heads[parts[1]] = parts[0]
    return_ref = result.get("return_ref")
    if heads.get(return_ref) != result["return_commit"]:
        raise ReturnError("worker return ref does not bind the declared artifact commit")
    namespace = "refs/fm-cloud-return/{}/{}".format(task, result["request_digest"][:32])
    artifact_ref = namespace + "/artifacts"
    git(worktree, "fetch", "--quiet", "--no-tags", str(bundle), "+{}:{}".format(return_ref, artifact_ref))
    outcome_ref = "refs/fm-outcome/{}".format(result["request_digest"][:32])
    outcome_custody_ref = namespace + "/outcome"
    if result.get("outcome_commits", 0):
        if heads.get(outcome_ref) != result["outcome_tip"]:
            raise ReturnError("worker outcome ref does not bind the declared outcome tip")
        git(worktree, "fetch", "--quiet", "--no-tags", str(bundle), "+{}:{}".format(outcome_ref, outcome_custody_ref))
    return artifact_ref, outcome_custody_ref


def object_bytes(worktree, commit, name, limit=MAX_ARTIFACT_BYTES):
    shown = git(worktree, "show", "{}:{}".format(commit, name), check=False)
    if shown.returncode != 0:
        raise ReturnError("worker return bundle lacks authorized artifact {}".format(name))
    if len(shown.stdout) > limit:
        raise ReturnError("worker return artifact {} exceeds its byte bound".format(name))
    return shown.stdout


def read_manifest(worktree, result, task, generation, assignment):
    body = object_bytes(worktree, result["return_commit"], "manifest.json", 1024 * 1024)
    if sha256(body) != result["return_manifest_sha256"]:
        raise ReturnError("worker return manifest differs from the digest-bound result")
    try:
        manifest = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReturnError("worker return manifest is truncated or corrupt: {}".format(exc))
    if not isinstance(manifest, dict) or manifest.get("schema") != RETURN_SCHEMA:
        raise ReturnError("worker return manifest schema is not supported")
    expected = {
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
        "request_digest": result["request_digest"],
        "repository_generation": result["repository_generation"],
        "outcome_commits": result.get("outcome_commits", 0),
        "outcome_tip": result["outcome_tip"],
    }
    for field, value in expected.items():
        if manifest.get(field) != value:
            raise ReturnError("worker return manifest {} binding differs".format(field))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or any(not isinstance(item, dict) for item in artifacts.values()):
        raise ReturnError("worker return manifest artifacts are malformed")
    allowed = {"report.md", "status.log", "visuals.tar", "scratch.patch", "scratch-untracked.tar"}
    if not set(artifacts).issubset(allowed):
        raise ReturnError("worker return manifest names an unauthorized artifact")
    bodies = {}
    for name, descriptor in artifacts.items():
        body = object_bytes(worktree, result["return_commit"], name)
        if descriptor.get("bytes") != len(body) or descriptor.get("sha256") != sha256(body):
            raise ReturnError("worker return artifact {} is truncated or corrupt".format(name))
        bodies[name] = body
    return manifest, bodies


def substantive_report(body):
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return False, "report is not UTF-8"
    sections = {name: [] for name in REQUIRED_SECTIONS}
    seen = []
    current = None
    fenced = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            if current:
                sections[current].append("")
            continue
        if not fenced and stripped.startswith("## ") and not stripped.startswith("### "):
            heading = stripped[3:]
            if heading in sections:
                expected_index = len(seen)
                if expected_index >= len(REQUIRED_SECTIONS) or heading != REQUIRED_SECTIONS[expected_index]:
                    return False, "required report sections are duplicated or out of order"
                seen.append(heading)
                current = heading
            else:
                current = None
            continue
        if current is not None:
            sections[current].append(raw)
    missing = [name for name in REQUIRED_SECTIONS if name not in seen]
    empty = []
    for name, lines in sections.items():
        if not any(
            any(character.isalnum() or unicodedata.category(character).startswith("S") for character in line)
            for line in lines
        ):
            empty.append(name)
    if missing or empty:
        return False, "missing={} empty={}".format(",".join(missing) or "none", ",".join(empty) or "none")
    return True, ""


def atomic_write(path, body):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists():
        if path.is_symlink() or not path.is_file():
            raise ReturnError("local artifact destination is redirected: {}".format(path))
        if path.read_bytes() == body:
            return
        raise ReturnError("local artifact destination diverged: {}".format(path))
    descriptor, temporary = tempfile.mkstemp(prefix=".fm-cloud-return-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def extract_visuals(body, destination):
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    total = 0
    count = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:") as archive:
            for member in archive.getmembers():
                count += 1
                if count > MAX_VISUAL_ENTRIES or not member.isreg():
                    raise ReturnError("worker visual artifact archive is unsafe")
                relative = Path(member.name)
                if relative.is_absolute() or ".." in relative.parts or not relative.parts:
                    raise ReturnError("worker visual artifact path is unsafe")
                content = archive.extractfile(member).read()
                total += len(content)
                if total > MAX_VISUAL_BYTES:
                    raise ReturnError("worker visual artifacts exceed their byte bound")
                # The archive path includes data/<task>/visuals. Keep only the
                # part beneath visuals at the authorized local destination.
                try:
                    visual_index = relative.parts.index("visuals")
                except ValueError:
                    raise ReturnError("worker visual artifact is outside the authorized visual root")
                target_relative = Path(*relative.parts[visual_index + 1:])
                if not target_relative.parts:
                    raise ReturnError("worker visual artifact has no file name")
                atomic_write(destination / target_relative, content)
    except tarfile.TarError as exc:
        raise ReturnError("worker visual artifact archive is corrupt: {}".format(exc))


def branch_custody(worktree, task, result, kind):
    base = result["repository_generation"]
    tip = result["outcome_tip"]
    commits = result["outcome_commits"]
    if git(worktree, "merge-base", "--is-ancestor", base, tip, check=False).returncode != 0:
        raise ReturnError("returned outcome tip does not descend from the dispatched generation")
    counted = git(worktree, "rev-list", "--count", "{}..{}".format(base, tip))
    if int(counted.stdout.decode().strip()) != commits:
        raise ReturnError("returned outcome commit count differs from its Git history")
    if kind == "scout":
        if commits:
            raise ReturnError("a scout returned project commits; they remain in the custody ref")
        return
    if commits <= 0:
        return
    branch = "refs/heads/fm/{}".format(task)
    existing = git(worktree, "rev-parse", "--verify", branch, check=False)
    if existing.returncode == 0:
        branch_head = existing.stdout.decode().strip()
        if branch_head not in (base, tip) and git(
            worktree, "merge-base", "--is-ancestor", tip, branch_head, check=False,
        ).returncode != 0:
            raise ReturnError("local task branch diverged from the returned outcome")
    else:
        branch_head = ""
    head = git(worktree, "rev-parse", "HEAD").stdout.decode().strip()
    if head not in (base, tip, branch_head):
        raise ReturnError("local worktree diverged from the dispatched generation")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all").stdout.strip():
        raise ReturnError("local worktree is dirty; returned work remains in the custody ref")
    if not branch_head or branch_head == base:
        git(worktree, "update-ref", branch, tip, branch_head or "0" * 40)
        branch_head = tip
    if head in (base, tip, branch_head):
        switched = git(worktree, "checkout", "--quiet", "fm/{}".format(task), check=False)
        if switched.returncode != 0:
            raise ReturnError("returned task branch exists but cannot be checked out in its worktree")
    final_branch = git(worktree, "symbolic-ref", "--quiet", "HEAD", check=False)
    if final_branch.returncode != 0 or final_branch.stdout.decode().strip() != branch:
        raise ReturnError("returned task branch is not checked out in its worktree")
    final_head = git(worktree, "rev-parse", "HEAD").stdout.decode().strip()
    if git(worktree, "merge-base", "--is-ancestor", tip, final_head, check=False).returncode != 0:
        raise ReturnError("returned outcome is not reachable from the task branch")


def merge_status(local_path, raw_status, terminal):
    local_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    existing = ""
    if local_path.exists():
        if local_path.is_symlink() or not local_path.is_file():
            raise ReturnError("local status trail is redirected")
        existing = local_path.read_text(encoding="utf-8")
    additions = []
    if raw_status:
        try:
            remote_lines = raw_status.decode("utf-8").splitlines()
        except UnicodeDecodeError as exc:
            raise ReturnError("returned status trail is not UTF-8: {}".format(exc))
        for line in remote_lines:
            line = line.strip()
            if not line:
                continue
            if not STATUS_LINE.fullmatch(line):
                raise ReturnError("returned status trail contains a malformed event")
            if TERMINAL_LINE.match(line):
                continue
            if line not in existing.splitlines() and line not in additions:
                additions.append(line)
    if terminal not in existing.splitlines():
        additions.append(terminal)
    if additions:
        with local_path.open("a", encoding="utf-8") as handle:
            for line in additions:
                handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())


def collect(args):
    if not SAFE_TASK.fullmatch(args.task):
        raise ReturnError("task identity is malformed")
    if not SAFE_GENERATION.fullmatch(args.task_generation):
        raise ReturnError("task generation identity is malformed")
    if not SAFE_GENERATION.fullmatch(args.assignment_generation):
        raise ReturnError("assignment identity is malformed")
    state = Path(args.state).resolve()
    if state.name != "state" or state.is_symlink() or not state.is_dir():
        raise ReturnError("task state directory is unavailable")
    home = state.parent
    values = meta_values(state / (args.task + ".meta"))
    if exactly(values, "generation_id") != args.task_generation:
        raise ReturnError("task metadata generation differs")
    kind = exactly(values, "kind")
    if kind not in ("ship", "scout"):
        raise ReturnError("only ship and scout returns are supported")
    placement = exactly(values, "placement")
    if placement != "azure":
        raise ReturnError("task is not an Azure placement")
    worktree_text = read_regular(state / (args.task + ".cloud-worktree"), "cloud worktree pointer", 64 * 1024)
    try:
        worktree = Path(worktree_text.decode("utf-8").strip()).resolve()
    except UnicodeDecodeError as exc:
        raise ReturnError("cloud worktree pointer is not UTF-8: {}".format(exc))
    recorded_worktree = Path(exactly(values, "worktree")).resolve()
    if worktree != recorded_worktree:
        raise ReturnError("cloud worktree pointer differs from task metadata")
    if not worktree.is_dir() or Path(git(worktree, "rev-parse", "--show-toplevel").stdout.decode().strip()).resolve() != worktree:
        raise ReturnError("cloud worktree pointer does not name the exact repository root")
    result = read_result(
        state / (args.task + ".worker-result.json"), args.task,
        args.task_generation, args.assignment_generation,
    )
    bundle = state / (args.task + ".cloud-outcome") / "outcome.bundle"
    fetch_return_refs(worktree, bundle, result, args.task, args.task_generation)
    manifest, artifacts = read_manifest(
        worktree, result, args.task, args.task_generation, args.assignment_generation,
    )
    if manifest.get("kind") != kind or manifest.get("report_required") is not True:
        raise ReturnError("worker return task contract differs from local task metadata")
    expected_report = "data/{}/{}".format(args.task, "completion.md" if kind == "ship" else "report.md")
    expected_status = "state/{}.status".format(args.task)
    if manifest.get("report_path") != expected_report or manifest.get("status_path") != expected_status:
        raise ReturnError("worker return authorized paths differ from the local task contract")
    data_dir = home / "data" / args.task
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    report = artifacts.get("report.md")
    report_valid = False
    report_reason = "worker returned no report"
    if report is not None:
        report_valid, report_reason = substantive_report(report)
        if not report_valid:
            atomic_write(data_dir / "cloud-return-report.invalid.md", report)
    if not report_valid:
        raise ReturnError("required worker report was absent or invalid: {}".format(report_reason))
    report_target = data_dir / ("completion.md" if kind == "ship" else "report.md")
    if report_target.exists():
        if report_target.is_symlink() or not report_target.is_file():
            raise ReturnError("local report destination is redirected")
        local_report = report_target.read_bytes()
        local_valid, _local_reason = substantive_report(local_report)
        if not local_valid:
            raise ReturnError("local report destination diverged with an invalid report")
        report = local_report
    else:
        atomic_write(report_target, report)
    atomic_write(data_dir / "cloud-return.json", canonical(manifest) + b"\n")
    if "status.log" in artifacts:
        atomic_write(data_dir / "cloud-status.log", artifacts["status.log"])
    if "scratch.patch" in artifacts:
        atomic_write(data_dir / "cloud-scratch.patch", artifacts["scratch.patch"])
    if "scratch-untracked.tar" in artifacts:
        atomic_write(data_dir / "cloud-scratch-untracked.tar", artifacts["scratch-untracked.tar"])
    if "visuals.tar" in artifacts:
        extract_visuals(artifacts["visuals.tar"], data_dir / "visuals")
    branch_custody(worktree, args.task, result, kind)
    succeeded = (
        result.get("exit_code") == 0 and result.get("timed_out") is False
        and not result.get("outcome_error")
        and (kind == "scout" or not result.get("outcome_uncommitted_changes"))
        and (kind != "ship" or int(result.get("outcome_commits", 0)) > 0)
    )
    if succeeded:
        terminal = "done: cloud outcome returned to local custody"
    else:
        reasons = []
        if result.get("timed_out"):
            reasons.append("worker timed out")
        elif result.get("exit_code") != 0:
            reasons.append("worker exited {}".format(result.get("exit_code")))
        if result.get("outcome_error"):
            reasons.append("return collection reported an error")
        if kind == "ship" and result.get("outcome_uncommitted_changes"):
            reasons.append("uncommitted scratch was retained")
        if kind == "ship" and int(result.get("outcome_commits", 0)) <= 0:
            reasons.append("ship returned no commits")
        terminal = "failed: {}".format("; ".join(reasons) or "cloud outcome was incomplete")
    merge_status(state / (args.task + ".status"), artifacts.get("status.log"), terminal)
    print(terminal)


def parser():
    value = argparse.ArgumentParser()
    sub = value.add_subparsers(dest="command", required=True)
    collect_parser = sub.add_parser("collect")
    collect_parser.add_argument("--state", required=True)
    collect_parser.add_argument("--task", required=True)
    collect_parser.add_argument("--task-generation", required=True)
    collect_parser.add_argument("--assignment-generation", required=True)
    return value


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "collect":
        collect(args)
        return 0
    raise ReturnError("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ReturnError, OSError, ValueError) as exc:
        print("CLOUD RETURN REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
