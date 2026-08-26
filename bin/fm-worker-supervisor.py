#!/usr/bin/env python3
"""Pinned minimal guest supervisor for one exact Azure author assignment.

The host installs this exact committed file through the immutable bootstrap Run
Command.  It accepts one canonical request, re-proves assignment/environment
bindings, runs one command without a shell, and atomically writes one bounded
result.  It has no fleet, secondmate, browser, network, or child-worker API.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


SCHEMA = "fm.worker-execution/v1"
RESULT_SCHEMA = "fm.worker-execution-result/v1"
HEX = re.compile(r"^[0-9a-f]{64}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESULT_BYTES = 8 * 1024 * 1024
MAX_WALL_SECONDS = 6 * 60 * 60
MAX_OUTPUT_BYTES = 4 * 1024 * 1024


class SupervisorError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def read_request(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_REQUEST_BYTES:
        raise SupervisorError("execution request is absent, redirected, or oversized")
    try:
        request = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SupervisorError("execution request is unreadable: {}".format(exc))
    if not isinstance(request, dict) or request.get("schema") != SCHEMA:
        raise SupervisorError("execution request schema is not supported")
    supplied = request.get("request_digest")
    unsigned = dict(request)
    unsigned.pop("request_digest", None)
    if not isinstance(supplied, str) or supplied != digest(unsigned):
        raise SupervisorError("execution request digest is not exact")
    for field in (
        "home_binding", "task", "task_generation", "assignment_generation",
        "repository_generation", "cloud_instance_id",
    ):
        value = request.get(field)
        if field == "home_binding":
            if not isinstance(value, str) or not HEX.fullmatch(value):
                raise SupervisorError("execution home binding is malformed")
        elif not isinstance(value, str) or not SAFE_ID.fullmatch(value):
            raise SupervisorError("execution {} is malformed".format(field))
    for field in ("account_binding", "worktree_binding", "repository_binding"):
        if not isinstance(request.get(field), str) or not HEX.fullmatch(request[field]):
            raise SupervisorError("execution {} is malformed".format(field))
    argv = request.get("argv")
    if (
        not isinstance(argv, list) or not argv or len(argv) > 64
        or any(not isinstance(item, str) or not item or "\x00" in item or len(item) > 4096 for item in argv)
    ):
        raise SupervisorError("execution argv is malformed or unbounded")
    wall = request.get("wall_seconds")
    if not isinstance(wall, int) or isinstance(wall, bool) or not 1 <= wall <= MAX_WALL_SECONDS:
        raise SupervisorError("execution wall deadline is invalid")
    outcome_expected = request.get("outcome_expected", False)
    if not isinstance(outcome_expected, bool):
        raise SupervisorError("execution outcome expectation is malformed")
    existing_task_disk = request.get("existing_task_disk", False)
    if not isinstance(existing_task_disk, bool):
        raise SupervisorError("execution existing task-disk disposition is malformed")
    if existing_task_disk:
        if "payload_files" in request or "account_files" in request:
            raise SupervisorError("existing task-disk recovery cannot replace staged state")
        supervisor_digest = request.get("supervisor_sha256")
        if not isinstance(supervisor_digest, str) or not HEX.fullmatch(supervisor_digest):
            raise SupervisorError("existing task-disk recovery supervisor binding is malformed")
        try:
            running_digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        except OSError as exc:
            raise SupervisorError("existing task-disk recovery supervisor is unreadable: {}".format(exc))
        if running_digest != supervisor_digest:
            raise SupervisorError("existing task-disk recovery supervisor binding differs")
    elif "supervisor_sha256" in request:
        raise SupervisorError("ordinary execution cannot select a recovery supervisor")
    return_contract = request.get("return_contract")
    if return_contract is not None:
        if not isinstance(return_contract, dict) or set(return_contract) != {
            "schema", "kind", "report_required", "report_path", "status_path",
            "visuals_path", "branch",
        }:
            raise SupervisorError("execution return contract is malformed")
        if return_contract.get("schema") != "fm.worker-return-contract/v1":
            raise SupervisorError("execution return contract schema is not supported")
        if return_contract.get("kind") not in ("ship", "scout"):
            raise SupervisorError("execution return kind is not supported")
        if return_contract.get("report_required") is not True:
            raise SupervisorError("execution return contract must require its task report")
        for field in ("report_path", "status_path", "visuals_path"):
            value = return_contract.get(field)
            if (
                not isinstance(value, str) or not value or value.startswith("/")
                or ".." in Path(value).parts or "\x00" in value
            ):
                raise SupervisorError("execution return {} is unsafe".format(field))
        branch = return_contract.get("branch")
        if return_contract["kind"] == "ship":
            if not isinstance(branch, str) or not branch.startswith("fm/") or not SAFE_ID.fullmatch(branch[3:]):
                raise SupervisorError("execution return branch is malformed")
        elif branch != "":
            raise SupervisorError("a scout return contract must not name a task branch")
        if not outcome_expected:
            raise SupervisorError("execution return contract requires the outcome transport")
    if existing_task_disk and (return_contract is None or not outcome_expected):
        raise SupervisorError("existing task-disk recovery requires an authorized return outcome")
    worker_role = request.get("worker_role", "author")
    if worker_role not in ("author", "no-mistakes"):
        raise SupervisorError("execution worker role is not supported")
    service_contract = request.get("service_return_contract")
    if worker_role == "no-mistakes":
        if service_contract != {
            "schema": "fm.no-mistakes-worker-return/v1",
            "step_outcome_path": "outcome.json",
            "step_outcome_max_bytes": 1024 * 1024,
        }:
            raise SupervisorError("no-mistakes service return contract is not exact")
        if not outcome_expected or not isinstance(request.get("payload_files"), dict):
            raise SupervisorError("no-mistakes execution requires staged outcome transport")
    elif service_contract is not None:
        raise SupervisorError("ordinary execution cannot select a service return contract")
    if outcome_expected:
        # An ordinary outcome is bundled from the repository this request
        # stages. Explicit recovery instead binds the already-assigned task
        # disk and must never replace the repository it exists to preserve.
        if not existing_task_disk and not isinstance(request.get("payload_files"), dict):
            raise SupervisorError("an outcome cannot be collected without a staged repository")
        # The URL is an unbound protected parameter; refusing here means a
        # control-plane actor cannot silently downgrade a landing task into a
        # fire-and-forget one by withholding it.
        # The URL alone arms the lane. FM_WORKER_OUTCOME_FILE only redirects
        # the sink for the hermetic test lane and can never satisfy this gate,
        # so adding an unprotected FILE cannot stand in for a stripped
        # protected URL.
        if not os.environ.get("FM_WORKER_OUTCOME_URL", "").startswith("https://"):
            raise SupervisorError("execution expects an outcome but no outcome staging URL was armed")
    return request


def verify_environment(request):
    bindings = {
        "FM_WORKER_HOME_BINDING": "home_binding",
        "FM_WORKER_TASK": "task",
        "FM_WORKER_TASK_GENERATION": "task_generation",
        "FM_WORKER_ASSIGNMENT_GENERATION": "assignment_generation",
        "FM_WORKER_ACCOUNT_BINDING": "account_binding",
        "FM_WORKER_WORKTREE_BINDING": "worktree_binding",
        "FM_WORKER_REPOSITORY_BINDING": "repository_binding",
        "FM_WORKER_REPOSITORY_GENERATION": "repository_generation",
        "FM_WORKER_CLOUD_INSTANCE_ID": "cloud_instance_id",
    }
    for env_name, field in bindings.items():
        if os.environ.get(env_name) != request[field]:
            raise SupervisorError("guest environment {} binding differs".format(field))
    worktree = Path(os.environ.get("FM_WORKER_WORKTREE", "")).resolve()
    if not worktree.is_dir() or worktree == Path("/"):
        raise SupervisorError("guest worktree is unavailable")
    return worktree


def bounded(value):
    if len(value) <= MAX_OUTPUT_BYTES:
        return value, False
    return value[:MAX_OUTPUT_BYTES], True


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SupervisorError("staging fetch was redirected, which is refused")


MAX_ARCHIVE_BYTES = 600 * 1024 * 1024
MAX_OUTCOME_BYTES = 256 * 1024 * 1024
MAX_RETURN_REPORT_BYTES = 16 * 1024 * 1024
MAX_RETURN_STATUS_BYTES = 4 * 1024 * 1024
MAX_RETURN_VISUAL_BYTES = 20 * 1024 * 1024
MAX_RETURN_VISUAL_ENTRIES = 512
MAX_RETURN_SCRATCH_BYTES = 128 * 1024 * 1024

# Every bounded step that runs OUTSIDE the wall, named once and used at the
# call site, so the budget below is the same number the code actually spends.
# Reading these back out of the source text instead was tried and was worse
# than nothing: it silently under-counted the moment a literal became a name,
# which is the direction that kills a run.
ARCHIVE_FETCH_TIMEOUT = 300      # per staged archive, and there are two
REPO_CLONE_TIMEOUT = 600
GIT_HEAD_TIMEOUT = 60
GIT_COUNT_TIMEOUT = 120
GIT_STATUS_TIMEOUT = 120
BUNDLE_CREATE_TIMEOUT = 600
OUTCOME_UPLOAD_TIMEOUT = 600
STAGED_ARCHIVE_COUNT = 2

# The collection tail has two mutually exclusive branches: with no commits the
# supervisor only asks git whether the tree is dirty; with commits it builds a
# bundle and uploads it. The budget takes the larger.
_COLLECTION_TAIL = max(
    GIT_STATUS_TIMEOUT,
    BUNDLE_CREATE_TIMEOUT + OUTCOME_UPLOAD_TIMEOUT,
)
# What a bound covering a whole guest run must add to the wall. Anything that
# grows a step here grows this, and bin/fm-azure-worker-provider.py is checked
# against it by tests/fm-azure-pilot.test.sh.
NON_WALL_BUDGET_SECONDS = (
    STAGED_ARCHIVE_COUNT * ARCHIVE_FETCH_TIMEOUT
    + REPO_CLONE_TIMEOUT
    + GIT_HEAD_TIMEOUT
    + GIT_COUNT_TIMEOUT
    + _COLLECTION_TAIL
)
SAFE_STAGED_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def fetch_archive(label):
    """Fetch one staged archive named by the launch environment and verify it
    byte-for-byte against the digest the digest-bound request carries."""
    prefix = "FM_WORKER_{}_".format(label.upper())
    url = os.environ.get(prefix + "URL", "")
    expected_digest = os.environ.get(prefix + "SHA256", "")
    expected_bytes = os.environ.get(prefix + "BYTES", "")
    if not url.startswith("https://") or not HEX.match(expected_digest) or not expected_bytes.isdigit():
        raise SupervisorError("{} staging environment is incomplete".format(label))
    size = int(expected_bytes)
    if not 0 < size <= MAX_ARCHIVE_BYTES:
        raise SupervisorError("{} staging archive size is unbounded".format(label))
    local_source = os.environ.get(prefix + "FILE", "")
    if local_source:
        # Hermetic test lane: the archive is supplied as a file instead of a
        # network fetch; every verification below still runs unchanged.
        body = Path(local_source).read_bytes()
    else:
        # A redirect-refusing opener: the staging endpoint never redirects,
        # and following one could silently downgrade to plaintext before the
        # digest check.
        opener = urllib.request.build_opener(_NoRedirect())
        try:
            with opener.open(url, timeout=ARCHIVE_FETCH_TIMEOUT) as response:
                body = response.read(size + 1)
        except OSError as exc:
            raise SupervisorError("{} staging fetch failed: {}".format(label, exc))
    if len(body) != size or hashlib.sha256(body).hexdigest() != expected_digest:
        raise SupervisorError("{} staging archive differs from its bound digest".format(label))
    return body


def extract_staged_archive(body, manifest, target, label):
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(target, 0o700)
    seen = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as archive:
            for member in archive.getmembers():
                if not member.isreg() or not SAFE_STAGED_NAME.match(member.name):
                    raise SupervisorError("{} staging archive member is unsupported: {}".format(label, member.name))
                expected = manifest.get(member.name)
                if not isinstance(expected, dict):
                    raise SupervisorError("{} staging archive member is not in the bound manifest: {}".format(label, member.name))
                handle = archive.extractfile(member)
                content = handle.read() if handle else b""
                if (
                    len(content) != expected.get("bytes")
                    or hashlib.sha256(content).hexdigest() != expected.get("sha256")
                ):
                    raise SupervisorError("{} staged file differs from its bound manifest: {}".format(label, member.name))
                destination = target / member.name
                destination.write_bytes(content)
                destination.chmod(0o600)
                seen.add(member.name)
    except tarfile.TarError as exc:
        raise SupervisorError("{} staging archive is malformed: {}".format(label, exc))
    missing = sorted(set(manifest) - seen)
    if missing:
        raise SupervisorError("{} staging archive lacks bound files: {}".format(label, ", ".join(missing)))


def stage_payload(request, worktree, account_home):
    """Materialize a new payload or bind an explicitly retained task disk."""
    if request.get("existing_task_disk"):
        repo = worktree / "repo"
        if repo.is_symlink() or not repo.is_dir():
            raise SupervisorError("existing task-disk repository is unavailable or redirected")
        top = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=GIT_HEAD_TIMEOUT, check=False,
        )
        if top.returncode != 0 or Path(top.stdout.decode().strip()).resolve() != repo.resolve():
            raise SupervisorError("existing task-disk repository is not the exact repository root")
        lineage = subprocess.run(
            [
                "git", "-C", str(repo), "merge-base", "--is-ancestor",
                request["repository_generation"], "HEAD",
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=GIT_HEAD_TIMEOUT, check=False,
        )
        if lineage.returncode != 0:
            raise SupervisorError("existing task-disk repository lost its dispatched lineage")
        readable = subprocess.run(
            ["git", "-C", str(repo), "status", "--porcelain"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=GIT_STATUS_TIMEOUT, check=False,
        )
        if readable.returncode != 0:
            raise SupervisorError("existing task-disk working tree is unreadable")
        return repo
    payload_manifest = request.get("payload_files")
    account_manifest = request.get("account_files")
    if payload_manifest is None and account_manifest is None:
        return worktree
    if not isinstance(payload_manifest, dict) or not isinstance(account_manifest, dict):
        raise SupervisorError("payload and account manifests travel together or not at all")
    staging = worktree / ".fm-task"
    extract_staged_archive(fetch_archive("payload"), payload_manifest, staging, "payload")
    account_target = account_home / "pi-agent"
    extract_staged_archive(fetch_archive("account"), account_manifest, account_target, "account")
    repo = worktree / "repo"
    if repo.exists():
        # Explicit retained-disk recovery returned above and can never reach
        # this remover. Ordinary staging gets here only for the repository its
        # own payload is replacing, typically debris from interrupted staging.
        if repo.is_symlink() or not repo.is_dir():
            raise SupervisorError("staged repository target is not a removable directory")
        shutil.rmtree(repo)
    bundle = staging / "repo.bundle"
    clone = subprocess.run(
        ["git", "clone", "--quiet", str(bundle), str(repo)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=REPO_CLONE_TIMEOUT, check=False,
    )
    if clone.returncode != 0:
        raise SupervisorError(
            "staged repository bundle clone failed: {}".format(
                clone.stderr.decode("utf-8", errors="replace")[-500:]
            )
        )
    head = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=GIT_HEAD_TIMEOUT, check=False,
    )
    if head.returncode != 0 or head.stdout.decode().strip() != request["repository_generation"]:
        raise SupervisorError("staged repository head differs from the bound repository generation")
    if request.get("worker_role") == "no-mistakes":
        stage_no_mistakes_runtime(staging / "runtime.tar.gz", worktree / ".fm-runtime")
    return repo


def stage_no_mistakes_runtime(source, target, enforce_linux=True):
    """Extract and re-verify the sealed credential-free runtime in the guest."""
    if source.is_symlink() or not source.is_file():
        raise SupervisorError("no-mistakes runtime bundle is unavailable or redirected")
    if target.exists():
        if target.is_symlink() or not target.is_dir():
            raise SupervisorError("no-mistakes runtime target is unsafe")
        shutil.rmtree(target)
    target.mkdir(mode=0o700)
    extracted = {}
    total = 0
    try:
        with tarfile.open(source, mode="r:gz") as archive:
            members = archive.getmembers()
            if not members or len(members) > 4096:
                raise SupervisorError("no-mistakes runtime member inventory is unbounded")
            for member in members:
                parts = Path(member.name).parts
                if (
                    not member.isreg() or not parts or member.name.startswith("/")
                    or any(part in ("", ".", "..") for part in parts)
                    or member.mode not in (0o644, 0o755)
                    or member.name in extracted
                ):
                    raise SupervisorError(
                        "no-mistakes runtime member is unsafe: {}".format(member.name))
                handle = archive.extractfile(member)
                body = handle.read() if handle else b""
                total += len(body)
                if total > 2 * 1024 * 1024 * 1024:
                    raise SupervisorError("no-mistakes runtime expands beyond its bound")
                destination = target.joinpath(*parts)
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                destination.write_bytes(body)
                destination.chmod(member.mode)
                extracted[member.name] = body
    except tarfile.TarError as exc:
        raise SupervisorError("no-mistakes runtime archive is malformed: {}".format(exc))
    try:
        manifest = json.loads(extracted["runtime.json"].decode("utf-8"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SupervisorError("no-mistakes runtime manifest is unreadable: {}".format(exc))
    records = manifest.get("files") if isinstance(manifest, dict) else None
    manifest_fields = {
        "schema", "provider", "no_mistakes_version", "no_mistakes_source_commit",
        "owner_decision_protocol", "no_mistakes_path", "provider_path", "gh_path",
        "node_path", "gh_axi_path", "gh_axi_entrypoint", "gh_axi_closure", "files",
    }
    if (
        not isinstance(manifest, dict)
        or set(manifest) != manifest_fields
        or manifest.get("schema") != "fm.azure-validation-runtime/v1"
        or manifest.get("provider") != "pi"
        or manifest.get("no_mistakes_path") != "bin/no-mistakes"
        or manifest.get("provider_path") != "bin/pi"
        or manifest.get("node_path") != "bin/node"
        or manifest.get("gh_path") != ""
        or manifest.get("gh_axi_path") != ""
        or manifest.get("gh_axi_entrypoint") != ""
        or manifest.get("gh_axi_closure") != []
        or manifest.get("owner_decision_protocol") != "fm.azure-validation-owner-decision/v1"
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", str(manifest.get("no_mistakes_version", "")))
        or not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("no_mistakes_source_commit", "")))
        or not isinstance(records, list) or not records
    ):
        raise SupervisorError("no-mistakes runtime manifest identity is not exact")
    expected = {"runtime.json"}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "digest"}:
            raise SupervisorError("no-mistakes runtime file record is malformed")
        path = record.get("path")
        digest_claim = record.get("digest")
        if (
            not isinstance(path, str) or path in expected or path not in extracted
            or Path(path).name.lower() in {
                ".env", ".netrc", ".npmrc", "auth.json", "credentials.json",
                "credentials", "id_rsa", "id_ed25519",
            }
            or not isinstance(digest_claim, str) or not digest_claim.startswith("sha256:")
            or hashlib.sha256(extracted[path]).hexdigest() != digest_claim[7:]
        ):
            raise SupervisorError("no-mistakes runtime file inventory differs")
        expected.add(path)
    required_executables = ("bin/no-mistakes", "bin/node", "bin/pi")
    if (
        set(extracted) != expected
        or any(not os.access(target / path, os.X_OK) for path in required_executables)
        or "lib/pi/dist/cli.js" not in extracted
        or "extensions/pi-openai-fast-mode/src/index.ts" not in extracted
        or "extensions/fast-mode-all-codex-accounts.ts" not in extracted
        or "extensions/pi-ketch/src/index.ts" not in extracted
    ):
        raise SupervisorError("no-mistakes runtime is not exactly inventoried and executable")
    if enforce_linux:
        for path in ("bin/no-mistakes", "bin/node"):
            header = extracted[path][:20]
            if not (
                len(header) == 20 and header[:4] == b"\x7fELF"
                and header[4] == 2 and header[5] == 1
                and int.from_bytes(header[18:20], "little") == 62
            ):
                raise SupervisorError(
                    "no-mistakes runtime {} is not Linux amd64".format(path))


def git_in(repo, *arguments, timeout=BUNDLE_CREATE_TIMEOUT):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=timeout, check=False,
    )


def _safe_return_file(root, relative, limit):
    path = root / relative
    try:
        relative_parts = Path(relative).parts
        current = root
        for part in relative_parts:
            current = current / part
            if current.is_symlink():
                raise SupervisorError("returned artifact is redirected: {}".format(relative))
        if not path.is_file():
            return None
        body = path.read_bytes()
    except OSError as exc:
        raise SupervisorError("returned artifact is unreadable: {}: {}".format(relative, exc))
    if len(body) > limit:
        raise SupervisorError("returned artifact exceeds its byte bound: {}".format(relative))
    return body


def _deterministic_tar(root, relative_paths, byte_limit, entry_limit):
    """Archive already-authorized relative paths without following redirects."""
    output = io.BytesIO()
    total = 0
    with tarfile.open(fileobj=output, mode="w") as archive:
        for relative in sorted(relative_paths):
            if len(relative_paths) > entry_limit:
                raise SupervisorError("returned artifact archive has too many entries")
            source = root / relative
            current = root
            for part in Path(relative).parts:
                current = current / part
                if current.is_symlink():
                    raise SupervisorError("returned artifact archive contains a redirect: {}".format(relative))
            if not source.is_file():
                raise SupervisorError("returned artifact archive entry is not a regular file: {}".format(relative))
            body = source.read_bytes()
            total += len(body)
            if total > byte_limit:
                raise SupervisorError("returned artifact archive exceeds its byte bound")
            info = tarfile.TarInfo(relative)
            info.size = len(body)
            info.mode = 0o600
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(body))
    return output.getvalue()


def _visual_archive(return_root, relative):
    root = return_root / relative
    if not root.exists():
        return None
    if root.is_symlink() or not root.is_dir():
        raise SupervisorError("returned visual evidence root is redirected or not a directory")
    paths = []
    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        directory_path = Path(directory)
        if directory_path.is_symlink():
            raise SupervisorError("returned visual evidence contains a redirected directory")
        for name in files:
            source = directory_path / name
            paths.append(str(source.relative_to(return_root)))
    if not paths:
        return None
    return _deterministic_tar(
        return_root, paths, MAX_RETURN_VISUAL_BYTES, MAX_RETURN_VISUAL_ENTRIES,
    )


def _scratch_artifacts(repo):
    patch = git_in(repo, "diff", "--binary", "HEAD", timeout=GIT_STATUS_TIMEOUT)
    if patch.returncode != 0:
        raise SupervisorError("returned scratch diff is unreadable")
    listed = git_in(
        repo, "ls-files", "-z", "--others", "--exclude-standard",
        timeout=GIT_STATUS_TIMEOUT,
    )
    if listed.returncode != 0:
        raise SupervisorError("returned untracked scratch is unreadable")
    try:
        untracked = [item.decode("utf-8") for item in listed.stdout.split(b"\0") if item]
    except UnicodeDecodeError as exc:
        raise SupervisorError("returned untracked scratch path is not UTF-8: {}".format(exc))
    archive = None
    if untracked:
        archive = _deterministic_tar(
            repo, untracked, MAX_RETURN_SCRATCH_BYTES, MAX_RETURN_VISUAL_ENTRIES,
        )
    if len(patch.stdout) > MAX_RETURN_SCRATCH_BYTES:
        raise SupervisorError("returned scratch diff exceeds its byte bound")
    return patch.stdout or None, archive


def _hash_blob(repo, body):
    result = subprocess.run(
        ["git", "-C", str(repo), "hash-object", "-w", "--stdin"], input=body,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=GIT_HEAD_TIMEOUT, check=False,
    )
    if result.returncode != 0:
        raise SupervisorError("returned artifact could not be stored in the repository")
    return result.stdout.decode().strip()


def _return_commit(repo, base, artifacts, request):
    entries = []
    for name, body in sorted(artifacts.items()):
        entries.append("100644 blob {}\t{}\n".format(_hash_blob(repo, body), name))
    tree = subprocess.run(
        ["git", "-C", str(repo), "mktree"], input="".join(entries).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=GIT_HEAD_TIMEOUT, check=False,
    )
    if tree.returncode != 0:
        raise SupervisorError("returned artifact tree could not be created")
    environment = dict(os.environ)
    environment.update({
        "GIT_AUTHOR_NAME": "Firstmate worker return",
        "GIT_AUTHOR_EMAIL": "worker-return@localhost",
        "GIT_COMMITTER_NAME": "Firstmate worker return",
        "GIT_COMMITTER_EMAIL": "worker-return@localhost",
        "GIT_AUTHOR_DATE": "@0 +0000",
        "GIT_COMMITTER_DATE": "@0 +0000",
    })
    committed = subprocess.run(
        ["git", "-C", str(repo), "commit-tree", tree.stdout.decode().strip(), "-p", base],
        input=("Firstmate worker return {}\n".format(request["request_digest"])).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=GIT_HEAD_TIMEOUT,
        check=False, env=environment,
    )
    if committed.returncode != 0:
        raise SupervisorError("returned artifact commit could not be created")
    return committed.stdout.decode().strip()


def outcome_bundle_path(request, worktree):
    """Where the collected bundle lives on the RETAINED task disk.

    Keeping the bytes rather than a temp copy is what makes a replay able to
    re-upload the exact same bundle: the recorded result already commits to
    its digest, so a blob lost between execution and collection is recoverable
    instead of wedging the lifecycle forever.
    """
    return worktree / ".fm-worker" / "{}-outcome.bundle".format(request["request_digest"][:32])



def put_outcome_blob(body):
    """Upload the outcome bundle to the single write-scoped staging URL the
    execute request armed.  The URL arrives as a protected run-command
    parameter, so it is never readable off the control plane, and it grants
    create/write on exactly one blob name for the wall's duration."""
    local_sink = os.environ.get("FM_WORKER_OUTCOME_FILE", "")
    if local_sink:
        # Hermetic test lane: the blob is a local file instead of a network
        # PUT. The result records this sink, so a control-plane actor who adds
        # an unprotected FILE to divert a real upload produces a result the
        # controller refuses rather than a claim it cannot collect.
        Path(local_sink).write_bytes(body)
        return "file"
    url = os.environ.get("FM_WORKER_OUTCOME_URL", "")
    if not url.startswith("https://"):
        raise SupervisorError("outcome staging environment is incomplete")
    request = urllib.request.Request(
        url, data=body, method="PUT",
        headers={
            "x-ms-blob-type": "BlockBlob",
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(body)),
        },
    )
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=OUTCOME_UPLOAD_TIMEOUT) as response:
            status = response.status
    except OSError as exc:
        raise SupervisorError("outcome staging upload failed: {}".format(exc))
    if status not in (201, 202):
        raise SupervisorError("outcome staging upload was rejected: status={}".format(status))
    return "blob"


def collect_outcome(request, repo, worktree_root):
    """Bundle the commits the crewmate added on top of the bound repository
    generation and push them to the staging blob.

    No provider or forge credential exists on the worker: the bundle is the
    whole return path, and the local side (which owns the lease, the branch and
    the landing authority) is what pushes.  The result carries the bundle's
    digest, so a tampered blob cannot land.
    """
    if not request.get("outcome_expected"):
        return {
            "outcome_present": False, "outcome_sha256": "", "outcome_bytes": 0,
            "outcome_commits": 0, "outcome_sink": "",
        }
    base = request["repository_generation"]
    counted = git_in(repo, "rev-list", "--count", "{}..HEAD".format(base), timeout=GIT_COUNT_TIMEOUT)
    if counted.returncode != 0:
        raise SupervisorError(
            "outcome commit range is unreadable: {}".format(
                counted.stderr.decode("utf-8", errors="replace")[-500:]
            )
        )
    try:
        commits = int(counted.stdout.decode().strip())
    except ValueError:
        raise SupervisorError("outcome commit count is not a number")
    dirty = git_in(repo, "status", "--porcelain", timeout=GIT_STATUS_TIMEOUT)
    if dirty.returncode != 0:
        # Unknown is not clean. Reporting False here would render an
        # unreadable tree as a tidy read-only task, which is the exact
        # confusion this field exists to prevent.
        raise SupervisorError(
            "outcome working-tree state is unreadable: {}".format(
                dirty.stderr.decode("utf-8", errors="replace")[-200:]
            )
        )
    contract = request.get("return_contract")
    service_contract = request.get("service_return_contract")
    if commits == 0 and contract is None and service_contract is None:
        return {
            "outcome_present": False, "outcome_sha256": "", "outcome_bytes": 0,
            "outcome_commits": 0, "outcome_sink": "",
            "outcome_uncommitted_changes": bool(dirty.stdout.strip()),
        }

    bundle = outcome_bundle_path(request, worktree_root)
    bundle.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    bundle_refs = []
    returned = {}
    if contract is not None:
        return_root = worktree_root / ".fm-return"
        report = _safe_return_file(return_root, contract["report_path"], MAX_RETURN_REPORT_BYTES)
        status = _safe_return_file(return_root, contract["status_path"], MAX_RETURN_STATUS_BYTES)
        visuals = _visual_archive(return_root, contract["visuals_path"])
        scratch_patch, scratch_untracked = _scratch_artifacts(repo)
        artifact_bodies = {}
        artifact_sources = {
            "report.md": (report, contract["report_path"]),
            "status.log": (status, contract["status_path"]),
            "visuals.tar": (visuals, contract["visuals_path"]),
            "scratch.patch": (scratch_patch, "git-diff"),
            "scratch-untracked.tar": (scratch_untracked, "git-untracked"),
        }
        manifest_artifacts = {}
        for name, (body, source) in artifact_sources.items():
            if body is None:
                continue
            artifact_bodies[name] = body
            manifest_artifacts[name] = {
                "source": source, "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
            }
        manifest = {
            "schema": "fm.worker-return/v1",
            "task": request["task"],
            "task_generation": request["task_generation"],
            "assignment_generation": request["assignment_generation"],
            "request_digest": request["request_digest"],
            "repository_generation": base,
            "kind": contract["kind"],
            "branch": contract["branch"],
            "report_required": contract["report_required"],
            "report_path": contract["report_path"],
            "status_path": contract["status_path"],
            "visuals_path": contract["visuals_path"],
            "outcome_commits": commits,
            "outcome_tip": git_in(repo, "rev-parse", "HEAD", timeout=GIT_HEAD_TIMEOUT).stdout.decode().strip(),
            "uncommitted_changes": bool(dirty.stdout.strip()),
            "artifacts": manifest_artifacts,
        }
        manifest_body = canonical(manifest) + b"\n"
        artifact_bodies["manifest.json"] = manifest_body
        return_commit = _return_commit(repo, base, artifact_bodies, request)
        return_ref = "refs/fm-return/{}".format(request["request_digest"][:32])
        updated = git_in(repo, "update-ref", return_ref, return_commit, timeout=GIT_HEAD_TIMEOUT)
        if updated.returncode != 0:
            raise SupervisorError("returned artifact ref could not be created")
        bundle_refs.append(return_ref)
        if commits:
            outcome_ref = "refs/fm-outcome/{}".format(request["request_digest"][:32])
            updated = git_in(repo, "update-ref", outcome_ref, manifest["outcome_tip"], timeout=GIT_HEAD_TIMEOUT)
            if updated.returncode != 0:
                raise SupervisorError("returned outcome ref could not be created")
            bundle_refs.append(outcome_ref)
        # The local repository already has the exact dispatched generation.
        # Excluding it keeps the bundle to the artifact commit plus only the
        # project commits this assignment added, rather than retransmitting
        # arbitrary repository history.
        bundle_refs.append("^{}".format(base))
        returned = {
            "return_present": True,
            "return_ref": return_ref,
            "return_commit": return_commit,
            "return_manifest_sha256": hashlib.sha256(manifest_body).hexdigest(),
            "outcome_tip": manifest["outcome_tip"],
        }
    elif service_contract is not None:
        outcome_path = repo / service_contract["step_outcome_path"]
        outcome_body = None
        if outcome_path.exists():
            if outcome_path.is_symlink() or not outcome_path.is_file():
                raise SupervisorError("no-mistakes step outcome is redirected or not regular")
            outcome_body = outcome_path.read_bytes()
            if not outcome_body or len(outcome_body) > service_contract["step_outcome_max_bytes"]:
                raise SupervisorError("no-mistakes step outcome is empty or oversized")
        if outcome_body is not None:
            manifest = {
                "schema": "fm.no-mistakes-worker-return/v1",
                "task": request["task"],
                "task_generation": request["task_generation"],
                "assignment_generation": request["assignment_generation"],
                "request_digest": request["request_digest"],
                "repository_generation": base,
                "outcome_commits": commits,
                "outcome_tip": git_in(
                    repo, "rev-parse", "HEAD", timeout=GIT_HEAD_TIMEOUT
                ).stdout.decode().strip(),
                "step_outcome_sha256": hashlib.sha256(outcome_body).hexdigest(),
            }
            manifest_body = canonical(manifest) + b"\n"
            return_commit = _return_commit(
                repo, base,
                {"manifest.json": manifest_body, "step-outcome.json": outcome_body},
                request,
            )
            return_ref = "refs/fm-return/{}".format(request["request_digest"][:32])
            if git_in(
                repo, "update-ref", return_ref, return_commit, timeout=GIT_HEAD_TIMEOUT
            ).returncode != 0:
                raise SupervisorError("no-mistakes service return ref could not be created")
            bundle_refs.append(return_ref)
            if commits:
                outcome_ref = "refs/fm-outcome/{}".format(request["request_digest"][:32])
                if git_in(
                    repo, "update-ref", outcome_ref, manifest["outcome_tip"],
                    timeout=GIT_HEAD_TIMEOUT,
                ).returncode != 0:
                    raise SupervisorError("no-mistakes outcome ref could not be created")
                bundle_refs.append(outcome_ref)
            bundle_refs.append("^{}".format(base))
            returned = {
                "return_present": True,
                "return_ref": return_ref,
                "return_commit": return_commit,
                "return_manifest_sha256": hashlib.sha256(manifest_body).hexdigest(),
                "outcome_tip": manifest["outcome_tip"],
                "service_return_present": True,
                "step_outcome_sha256": manifest["step_outcome_sha256"],
            }
        elif commits:
            bundle_refs.append("{}..HEAD".format(base))
            returned = {"service_return_present": False, "step_outcome_sha256": ""}
        else:
            return {
                "outcome_present": False, "outcome_sha256": "", "outcome_bytes": 0,
                "outcome_commits": 0, "outcome_sink": "",
                "outcome_uncommitted_changes": bool(dirty.stdout.strip()),
                "service_return_present": False, "step_outcome_sha256": "",
            }
    elif commits:
        bundle_refs.append("{}..HEAD".format(base))

    created = git_in(
        repo, "bundle", "create", str(bundle), *bundle_refs,
        timeout=BUNDLE_CREATE_TIMEOUT,
    )
    if created.returncode != 0 or not bundle.is_file():
        raise SupervisorError(
            "outcome bundle creation failed: {}".format(
                created.stderr.decode("utf-8", errors="replace")[-500:]
            )
        )
    if bundle.stat().st_size > MAX_OUTCOME_BYTES:
        raise SupervisorError("outcome bundle exceeds its bounded allowance")
    body = bundle.read_bytes()
    sink = put_outcome_blob(body)
    return {
        "outcome_present": commits > 0,
        "outcome_sha256": hashlib.sha256(body).hexdigest(),
        "outcome_bytes": len(body),
        "outcome_commits": commits,
        "outcome_sink": sink,
        "outcome_uncommitted_changes": bool(dirty.stdout.strip()),
        **returned,
    }


def replay_outcome_upload(request, worktree, recorded):
    """Re-upload the retained bundle on a replay.

    A replay happens when the controller lost the result in transport, or when
    it could not collect the blob. These are the exact bytes the recorded
    result already committed to, so the controller's digest check still gates
    the landing. Without this the lifecycle wedges forever on a lost blob and
    the crewmate's commits die with the VM. A failure here must not stop the
    replay from answering, so it is reported and swallowed.
    """
    if not (recorded.get("outcome_present") or recorded.get("return_present")):
        return False
    retained = outcome_bundle_path(request, worktree)
    try:
        body = retained.read_bytes()
        if hashlib.sha256(body).hexdigest() != recorded.get("outcome_sha256"):
            raise SupervisorError("retained outcome bundle differs from the recorded result")
        put_outcome_blob(body)
        return True
    except Exception as exc:  # noqa: BLE001 - a replay must still answer
        print(
            "outcome re-upload on replay failed: {}: {}".format(type(exc).__name__, exc),
            file=os.sys.stderr,
        )
        return False


def write_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = canonical(value) + b"\n"
    if len(payload) > MAX_RESULT_BYTES:
        raise SupervisorError("execution result exceeds its bounded allowance")
    fd, name = tempfile.mkstemp(prefix=".worker-result-", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def execute(request, worktree, worktree_root):
    path = "/usr/local/bin:/usr/bin:/bin"
    if request.get("worker_role") == "no-mistakes":
        path = str((worktree_root / ".fm-runtime" / "bin").resolve()) + ":" + path
    account_home = Path(os.environ.get("FM_WORKER_ACCOUNT_HOME", "/nonexistent")).resolve()
    safe_env = {
        "HOME": str(account_home),
        "PI_CODING_AGENT_DIR": str(account_home / "pi-agent"),
        "PATH": path,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
    }
    try:
        completed = subprocess.run(
            request["argv"], cwd=str(worktree), env=safe_env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=request["wall_seconds"], check=False,
        )
        timed_out = False
        exit_code = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        exit_code = 124
        stdout = exc.stdout or b""
        stderr = exc.stderr or b""
    stdout, stdout_truncated = bounded(stdout)
    stderr, stderr_truncated = bounded(stderr)
    # NOTHING after the task command may raise. Its effects already happened,
    # so any escape here means no executed marker is written, and the next
    # ordinary dispatch both re-runs the command and (through stage_payload's
    # rmtree of the staged repository) destroys the commits the first run produced.
    # Every post-command failure is therefore recorded in the digest-bound
    # result instead of raised, whatever its exception class: a full disk
    # reaches the stream write, a git timeout or MemoryError reaches the
    # bundle, and both must still produce a result.
    post_command_errors = []
    # Persist the exact digested streams on the retained task disk so the
    # bounded result's stream digests stay verifiable after the VM is gone.
    logs_dir = worktree_root / ".fm-worker"
    try:
        logs_dir.mkdir(mode=0o700, exist_ok=True)
        for suffix, data in (("stdout", stdout), ("stderr", stderr)):
            stream_path = logs_dir / "{}-{}.log".format(request["request_digest"][:32], suffix)
            fd = os.open(str(stream_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
        streams_persisted = True
    except Exception as exc:  # noqa: BLE001 - see above; losing the marker is worse
        streams_persisted = False
        post_command_errors.append(
            "stream evidence: {}: {}".format(type(exc).__name__, exc)
        )
    try:
        outcome = collect_outcome(request, worktree, worktree_root)
        outcome["outcome_error"] = ""
    except Exception as exc:  # noqa: BLE001 - see above; losing the marker is worse
        outcome = {
            "outcome_present": False, "outcome_sha256": "", "outcome_bytes": 0,
            "outcome_commits": 0, "outcome_error": "", "outcome_sink": "",
        }
        post_command_errors.append("outcome: {}: {}".format(type(exc).__name__, exc))
    if post_command_errors:
        outcome["outcome_error"] = "; ".join(post_command_errors)[:500]
    result = {
        "schema": RESULT_SCHEMA,
        **outcome,
        "streams_persisted": streams_persisted,
        "request_digest": request["request_digest"],
        "task": request["task"],
        "task_generation": request["task_generation"],
        "assignment_generation": request["assignment_generation"],
        "cloud_instance_id": request["cloud_instance_id"],
        "repository_binding": request["repository_binding"],
        "repository_generation": request["repository_generation"],
        "exit_code": exit_code,
        "timed_out": timed_out,
        "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
        "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
    }
    unsigned = dict(result)
    result["result_digest"] = digest(unsigned)
    return result


def steer_ack(args):
    assignment_path = Path(
        os.environ.get("FM_WORKER_ASSIGNMENT_PATH", "/var/lib/firstmate-worker/assignment.json")
    )
    try:
        assignment = json.loads(assignment_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SupervisorError("guest assignment record is unreadable: {}".format(exc))
    expected = {
        "home_binding": args.home_binding,
        "task": args.task,
        "task_generation": args.task_generation,
        "assignment_generation": args.assignment_generation,
    }
    for field, value in sorted(expected.items()):
        if assignment.get(field) != value:
            raise SupervisorError("steer {} binding differs from the guest assignment".format(field))
    if not HEX.match(str(args.request_digest)):
        raise SupervisorError("steer request digest is malformed")
    ack = {
        "schema": "fm.worker-steer-ack/v1",
        "assignment_generation": args.assignment_generation,
        "request_digest": args.request_digest,
    }
    ack["ack_digest"] = digest(ack)
    print("FM-WORKER-STEER-ACK:" + json.dumps(ack, sort_keys=True, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    exe = sub.add_parser("execute")
    exe.add_argument("--request", required=True)
    exe.add_argument("--result", required=True)
    steer = sub.add_parser("steer")
    steer.add_argument("--home-binding", required=True)
    steer.add_argument("--task", required=True)
    steer.add_argument("--task-generation", required=True)
    steer.add_argument("--assignment-generation", required=True)
    steer.add_argument("--request-digest", required=True)
    args = parser.parse_args()
    if args.mode == "steer":
        steer_ack(args)
        return
    if args.mode != "execute":
        raise SupervisorError("only one-task execute is supported")
    request = read_request(args.request)
    worktree = verify_environment(request)
    # One request digest executes at most once on this guest: a controller
    # replay after a transport loss re-emits the recorded result instead of
    # running the task command a second time.
    executed_dir = Path(
        os.environ.get("FM_WORKER_EXECUTED_DIR", "/var/lib/firstmate-worker/executed")
    )
    marker = executed_dir / (request["request_digest"] + ".json")
    if marker.is_file():
        try:
            recorded = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SupervisorError("recorded execution replay evidence is unreadable: {}".format(exc))
        unsigned = dict(recorded)
        supplied = unsigned.pop("result_digest", None)
        if supplied != digest(unsigned) or recorded.get("request_digest") != request["request_digest"]:
            raise SupervisorError("recorded execution replay evidence is not exact")
        replay_outcome_upload(request, worktree, recorded)
        write_atomic(args.result, recorded)
        print(json.dumps({"result_digest": recorded["result_digest"]}, separators=(",", ":")))
        return
    # Staging happens only on a first execution: a controller replay above
    # re-emits the recorded result without touching the staged repository.
    account_home = Path(os.environ.get("FM_WORKER_ACCOUNT_HOME", "/nonexistent")).resolve()
    repo = stage_payload(request, worktree, account_home)
    result = execute(request, repo, worktree)
    write_atomic(marker, result)
    write_atomic(args.result, result)
    print(json.dumps({"result_digest": result["result_digest"]}, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except SupervisorError as exc:
        print("WORKER SUPERVISOR REFUSED: {}".format(exc), file=os.sys.stderr)
        raise SystemExit(2)
