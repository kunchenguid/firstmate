#!/usr/bin/env python3
"""Trusted in-cell bridge to identity-less Azure command shards.

The bridge never runs a declared validation command in the credentialed cell.
It publishes a digest-bound clean bundle to the cell's private blob container,
waits for the local dispatcher to return exact runner receipts, verifies that
each requested shard used a different VM instance and boot, and performs only
the behavior-manifest completeness check in the cell.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


SCHEMA = "fm.azure-validation-shard/v1"
RESULT_SCHEMA = "fm.azure-validation-shard-result/v1"
SAFE_CELL = re.compile(r"^azv-[a-z0-9]{12}$")
SAFE_PUBLIC_REMOTE = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$")
SHA = re.compile(r"^[0-9a-f]{40,64}$")
MAX_ARCHIVE = 1024**3
# The cell declares, BY NAME, the sealed-suite host capabilities its shard
# workers cannot provide. FOUR of them, and the list below is the authority;
# if you are reading this comment to learn what the cell skips, read the
# constant too, and docs/azure-requirements.md R4 which owns the full account.
#
# Measured on the first live cell (azv-36b2726cbcf3, 2026-08-20): the shard
# worker has no tmux server it can create windows in, no passwordless sudo or
# systemd-run, and no /usr/bin/cpp to derive SYS_openat from. A local
# reproduction of that package closure (Ubuntu 24.04 with this repo's own apt
# set, unprivileged, no build toolchain) reproduced all three.
#
# The fourth is origin-egress, and it is by far the largest: the runner unit
# that executes these shards sets PrivateNetwork=yes,
# RestrictAddressFamilies=AF_UNIX and IPAddressDeny=any, so bin/fm-teardown.sh's
# secondmate upstream-authority probe can never resolve or reach the origin
# remote's host. That skips THIRTY-SEVEN units, the whole secondmate
# teardown/retirement family in tests/fm-teardown-suite.sh. The set was
# enumerated to convergence - both teardown files run to completion with the
# network off, 143 of 143 cases - and those units are SKIPPED in the cell, not
# preserved by some other route; macOS and CI are where that coverage lives.
# tests/host-capability-gate.sh turns each name into a LOUD skip of the
# exact units bound to it in tests/host-capabilities.tsv; nothing else changes,
# and no other host is affected. Keep this string byte-identical to the copy in
# bin/fm-azure-validation.py, which refuses any shard command that differs.
CELL_HOST_CAPABILITY_DECLARATION = (
    "FM_TEST_HOST_CAPABILITIES_ABSENT="
    "real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress"
)
MAX_WAIT_SECONDS = 4 * 3600


class BridgeError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest_bytes(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def run(argv, cwd=None, check=True):
    result = subprocess.run(argv, cwd=str(cwd) if cwd else None, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise BridgeError("command failed ({}): {}".format(result.returncode, (result.stderr or "").strip()))
    return result


def env():
    required = (
        "FM_AZURE_VALIDATION_CELL_ID", "FM_AZURE_VALIDATION_SHARD_EXCHANGE",
        "FM_AZURE_VALIDATION_STORAGE_ACCOUNT", "FM_AZURE_VALIDATION_STORAGE_CONTAINER",
        "FM_AZURE_VALIDATION_IDENTITY_CLIENT_ID",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise BridgeError("cell shard environment is incomplete: " + ", ".join(missing))
    cell = os.environ["FM_AZURE_VALIDATION_CELL_ID"]
    if not SAFE_CELL.match(cell):
        raise BridgeError("cell id is malformed")
    exchange = Path(os.environ["FM_AZURE_VALIDATION_SHARD_EXCHANGE"]).resolve()
    exchange.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(exchange, 0o700)
    return {
        "cell": cell,
        "exchange": exchange,
        "account": os.environ["FM_AZURE_VALIDATION_STORAGE_ACCOUNT"],
        "container": os.environ["FM_AZURE_VALIDATION_STORAGE_CONTAINER"],
        "client_id": os.environ["FM_AZURE_VALIDATION_IDENTITY_CLIENT_ID"],
        "timeout": int(os.environ.get("FM_AZURE_VALIDATION_SHARD_WAIT_SECONDS", str(MAX_WAIT_SECONDS))),
    }


def storage_token(environment):
    query = urllib.parse.urlencode({
        "api-version": "2018-02-01",
        "resource": "https://storage.azure.com/",
        "client_id": environment["client_id"],
    })
    request = urllib.request.Request(
        "http://169.254.169.254/metadata/identity/oauth2/token?" + query,
        headers={"Metadata": "true"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            value = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise BridgeError("exact cell storage identity is unavailable: {}".format(exc))
    token = value.get("access_token")
    if not token:
        raise BridgeError("exact cell storage identity returned no access token")
    return token


def blob_url(environment, name):
    quoted = "/".join(urllib.parse.quote(part, safe="") for part in name.split("/"))
    return "https://{}.blob.core.windows.net/{}/{}".format(environment["account"], environment["container"], quoted)


def storage_request(environment, token, method, name, data=None):
    headers = {
        "Authorization": "Bearer " + token,
        "x-ms-version": "2023-11-03",
        "x-ms-date": dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT"),
    }
    if method == "PUT":
        headers["x-ms-blob-type"] = "BlockBlob"
        headers["Content-Length"] = str(len(data or b""))
    request = urllib.request.Request(blob_url(environment, name), data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        if method in ("GET", "HEAD") and exc.code == 404:
            return None
        raise BridgeError("private cell blob {} failed with HTTP {}".format(method, exc.code))
    except urllib.error.URLError as exc:
        raise BridgeError("private cell blob transport failed: {}".format(exc))


def repository_identity(repo):
    repo = Path(run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"]).stdout.strip()).resolve()
    dirty = run(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=all"]).stdout
    if dirty:
        raise BridgeError("cell worktree must be clean at the shard boundary")
    probe = run(["git", "-C", str(repo), "symbolic-ref", "--short", "HEAD"], check=False)
    if probe.returncode == 0:
        branch = probe.stdout.strip()
    else:
        # The pipeline executes gate steps on a detached snapshot of the
        # submitted branch, so HEAD carries no symbolic ref there; the branch
        # identity then comes from the guest-declared environment.
        branch = os.environ.get("FM_AZURE_VALIDATION_BRANCH", "").strip()
        if not branch:
            raise BridgeError("cell worktree is detached and no declared branch identity is present")
    head = run(["git", "-C", str(repo), "rev-parse", "HEAD"]).stdout.strip()
    tree = run(["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"]).stdout.strip()
    remote = run(["git", "-C", str(repo), "remote", "get-url", "origin"]).stdout.strip()
    remote_match = SAFE_PUBLIC_REMOTE.match(remote)
    if not SHA.match(head) or not SHA.match(tree) or not remote_match or "@" in remote:
        raise BridgeError("cell repository identity or credential-free public origin is malformed")
    slug = "{}/{}".format(remote_match.group(1), remote_match.group(2))
    return repo, branch, head, tree, slug


def make_archive(environment, repo, request, bundle, destination):
    manifest = destination.parent / "request.json"
    unsigned = dict(request)
    unsigned.pop("request_digest", None)
    request["request_digest"] = digest_bytes(canonical(unsigned))
    manifest.write_bytes(canonical(request) + b"\n")
    os.chmod(manifest, 0o600)
    with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source, name in ((manifest, "request.json"), (bundle, "snapshot.bundle")):
            info = archive.gettarinfo(str(source), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as handle:
                archive.addfile(info, handle)
    if destination.stat().st_size > MAX_ARCHIVE:
        raise BridgeError("shard request archive exceeds one GiB")
    return request


def submit_requests(environment, kind, count, command):
    repo, branch, head, tree, slug = repository_identity(Path.cwd())
    round_id = "round-" + uuid.uuid4().hex[:12]
    round_dir = environment["exchange"] / round_id
    round_dir.mkdir(mode=0o700)
    bundle = round_dir / "snapshot.bundle"
    # The runner admits only a single bundle head named for the source ref at
    # the snapshot's exact HEAD commit. The gate snapshot is detached, and its
    # branch ref can lag HEAD by the pipeline's own commits or point at
    # pre-rebase history the pipeline has already rewritten, so the ref always
    # follows HEAD before bundling; a non-fast-forward move is reported for
    # the record instead of refusing, because the snapshot HEAD is the exact
    # commit under validation whatever its relation to the stale local ref.
    ref = "refs/heads/" + branch
    on_branch = run(["git", "-C", str(repo), "symbolic-ref", "--quiet", "HEAD"], check=False)
    if on_branch.returncode != 0:
        ref_probe = run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", ref], check=False)
        if ref_probe.returncode == 0:
            ancestry = run(
                ["git", "-C", str(repo), "merge-base", "--is-ancestor", ref, "HEAD"],
                check=False,
            )
            if ancestry.returncode != 0:
                print(
                    "shard bridge: branch ref {} does not fast-forward to the snapshot HEAD (pipeline rewrite); following HEAD".format(branch),
                    file=sys.stderr,
                )
        run(["git", "-C", str(repo), "branch", "-f", branch, "HEAD"])
    run(["git", "-C", str(repo), "bundle", "create", str(bundle), ref])
    run(["git", "bundle", "verify", str(bundle)])
    snapshot_digest = digest_file(bundle)
    requests = []
    for shard in range(1, count + 1):
        if kind == "behavior":
            argv = [
                "bin/fm-azure-runner-command.sh", "bash", "-c",
                "{} FM_TEST_SKIP_HERDR=1 bin/fm-behavior-shards.sh --run {} {} results/executed-{}.tsv".format(
                    CELL_HOST_CAPABILITY_DECLARATION, shard, count, shard
                ),
            ]
            artifacts = ["results/executed-{}.tsv".format(shard)]
            resource_class = "behavior-heavy"
        elif kind == "lint":
            argv = list(command)
            artifacts = []
            resource_class = "validation-standard"
        else:
            raise BridgeError("unknown shard kind")
        request = {
            "schema": SCHEMA,
            "cell": environment["cell"],
            "round": round_id,
            "kind": kind,
            "shard": shard,
            "shard_count": count,
            "repository": {
                "slug": slug,
                "branch": branch,
                "head": head,
                "tree": tree,
                "snapshot_digest": snapshot_digest,
            },
            "command": {"argv": argv},
            "command_digest": digest_bytes(canonical({"argv": argv})),
            "resource_class": resource_class,
            "artifacts": artifacts,
            "created_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        }
        path = round_dir / "request-{}.tar.gz".format(shard)
        request = make_archive(environment, repo, request, bundle, path)
        name = "shards/{}/request-{}.tar.gz".format(round_id, shard)
        token = storage_token(environment)
        storage_request(environment, token, "PUT", name, path.read_bytes())
        requests.append(request)
    return round_id, round_dir, requests


def extract_response(path, destination):
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        allowed = {"result.json", "executed.tsv", "stdout.log", "stderr.log"}
        if not {member.name for member in members}.issubset(allowed) or "result.json" not in {member.name for member in members}:
            raise BridgeError("shard response member set is invalid")
        for member in members:
            if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 64 * 1024**2:
                raise BridgeError("shard response contains unsafe member")
        archive.extractall(destination, members=members)


def wait_responses(environment, round_id, round_dir, requests):
    deadline = time.monotonic() + environment["timeout"]
    pending = {request["shard"]: request for request in requests}
    results = {}
    while pending and time.monotonic() < deadline:
        token = storage_token(environment)
        for shard, request in list(pending.items()):
            name = "shards/{}/response-{}.tar.gz".format(round_id, shard)
            data = storage_request(environment, token, "GET", name)
            if data is None:
                continue
            response_path = round_dir / "response-{}.tar.gz".format(shard)
            response_path.write_bytes(data)
            extracted = round_dir / "response-{}".format(shard)
            extracted.mkdir(mode=0o700)
            extract_response(response_path, extracted)
            result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
            expected = {
                "schema": RESULT_SCHEMA,
                "cell": environment["cell"],
                "round": round_id,
                "kind": request["kind"],
                "shard": shard,
                "shard_count": request["shard_count"],
                "head": request["repository"]["head"],
                "tree": request["repository"]["tree"],
                "request_digest": request["request_digest"],
                "command_digest": request["command_digest"],
            }
            for key, value in expected.items():
                if result.get(key) != value:
                    raise BridgeError("shard {} response identity mismatch: {}".format(shard, key))
            if result.get("exit_code") != 0:
                raise BridgeError("shard {} failed with exit {}".format(shard, result.get("exit_code")))
            if not result.get("boot_id") or not result.get("vm_instance_id") or not result.get("invocation"):
                raise BridgeError("shard {} lacks independent run/machine identity".format(shard))
            artifact = result.get("artifact")
            if request["artifacts"]:
                returned = extracted / "executed.tsv"
                if (
                    not isinstance(artifact, dict)
                    or artifact.get("path") != request["artifacts"][0]
                    or not returned.is_file()
                    or artifact.get("bytes") != returned.stat().st_size
                    or artifact.get("digest") != digest_file(returned)
                ):
                    raise BridgeError("shard {} returned a mismatched behavior manifest".format(shard))
            elif artifact is not None:
                raise BridgeError("lint shard returned an undeclared artifact")
            results[shard] = {"result": result, "directory": extracted}
            del pending[shard]
        if pending:
            time.sleep(5)
    if pending:
        raise BridgeError("timed out waiting for shard responses: {}".format(sorted(pending)))
    boots = {item["result"]["boot_id"] for item in results.values()}
    machines = {item["result"]["vm_instance_id"] for item in results.values()}
    if len(boots) != len(results) or len(machines) != len(results):
        raise BridgeError("parallel shards reused a boot or VM instance")
    return results


def trusted_behavior_plan(repo, count):
    inventory = sorted(
        path.relative_to(repo).as_posix()
        for path in (repo / "tests").glob("*.test.sh")
        if path.is_file() and not path.is_symlink()
    )
    duration_path = repo / "tests" / "behavior-test-durations.tsv"
    try:
        lines = duration_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise BridgeError("behavior duration inventory is unreadable: {}".format(exc))
    durations = {}
    for line_number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if (
            len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) <= 0
            or not re.match(r"^tests/[A-Za-z0-9._-]+\.test\.sh$", fields[1])
            or fields[1] in durations
        ):
            raise BridgeError("behavior duration row {} is invalid or duplicated".format(line_number))
        durations[fields[1]] = int(fields[0])
    if sorted(durations) != inventory:
        raise BridgeError("behavior duration inventory differs from exact tests/*.test.sh")
    loads = [0] * count
    plan = {}
    for path, duration in sorted(durations.items(), key=lambda item: (-item[1], item[0])):
        shard = min(range(count), key=lambda index: (loads[index], index))
        plan.setdefault(shard + 1, []).append(path)
        loads[shard] += duration
    return plan


def trusted_verify_manifests(repo, manifest_dir, count):
    expected_files = {"executed-{}.tsv".format(shard) for shard in range(1, count + 1)}
    actual_files = {path.name for path in manifest_dir.iterdir() if path.is_file()}
    if actual_files != expected_files:
        raise BridgeError("behavior manifest file inventory is incomplete or foreign")
    expected = trusted_behavior_plan(repo, count)
    observed = {}
    failures = []
    for shard in range(1, count + 1):
        path = manifest_dir / "executed-{}.tsv".format(shard)
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise BridgeError("behavior manifest {} is unreadable: {}".format(shard, exc))
        if not lines:
            raise BridgeError("behavior manifest {} is empty".format(shard))
        for line_number, line in enumerate(lines, 1):
            fields = line.split("\t")
            if (
                len(fields) != 4 or fields[0] != str(shard)
                or not re.match(r"^tests/[A-Za-z0-9._-]+\.test\.sh$", fields[1])
                or not fields[2].isdigit() or not fields[3].isdigit()
            ):
                raise BridgeError("behavior manifest {} row {} is malformed".format(shard, line_number))
            observed.setdefault(shard, []).append(fields[1])
            if int(fields[2]) != 0:
                failures.append((shard, fields[1], int(fields[2])))
    if any(sorted(observed.get(shard, [])) != sorted(expected.get(shard, [])) for shard in range(1, count + 1)):
        raise BridgeError("executed shard union differs from the complete deterministic plan")
    if failures:
        raise BridgeError("one or more behavior manifests report failed tests: {}".format(failures))


def verify_behavior(environment, round_dir, results, count):
    manifest_dir = round_dir / "manifests"
    manifest_dir.mkdir(mode=0o700)
    receipts = []
    for shard in range(1, count + 1):
        source = results[shard]["directory"] / "executed.tsv"
        if not source.is_file():
            raise BridgeError("behavior shard {} returned no executed manifest".format(shard))
        shutil.copyfile(str(source), str(manifest_dir / "executed-{}.tsv".format(shard)))
        result = results[shard]["result"]
        receipts.append({
            "round": result["round"],
            "kind": result["kind"],
            "shard": shard,
            "shard_count": result["shard_count"],
            "head": result["head"],
            "tree": result["tree"],
            "request_digest": result["request_digest"],
            "command_digest": result["command_digest"],
            "invocation": result["invocation"],
            "vm_instance_id": result["vm_instance_id"],
            "boot_id": result["boot_id"],
            "artifact": result["artifact"],
            "duration_seconds": result.get("duration_seconds"),
            "cost_usd": result.get("cost_usd"),
        })
    trusted_verify_manifests(Path.cwd().resolve(), manifest_dir, count)
    receipt_path = environment["exchange"] / "receipts.json"
    receipt_path.write_bytes(canonical(receipts) + b"\n")
    os.chmod(receipt_path, 0o600)


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="kind", required=True)
    behavior = commands.add_parser("behavior")
    behavior.add_argument("--count", type=int, required=True)
    lint = commands.add_parser("lint")
    lint.add_argument("command", nargs=argparse.REMAINDER)
    return root


def main():
    args = parser().parse_args()
    try:
        environment = env()
        if args.kind == "behavior":
            if args.count < 1 or args.count > 8:
                raise BridgeError("behavior shard count must be 1-8")
            count = args.count
            command = []
        else:
            if not args.command or args.command[0] != "--" or len(args.command) < 2:
                raise BridgeError("lint requires -- <exact argv>")
            count = 1
            command = args.command[1:]
        round_id, round_dir, requests = submit_requests(environment, args.kind, count, command)
        results = wait_responses(environment, round_id, round_dir, requests)
        if args.kind == "behavior":
            verify_behavior(environment, round_dir, results, count)
        print("AZURE VALIDATION SHARDS passed kind={} count={} round={}".format(args.kind, count, round_id))
        return 0
    except BridgeError as exc:
        print("AZURE VALIDATION SHARDS FAILED: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
