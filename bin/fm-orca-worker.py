#!/usr/bin/env python3
"""Task-scoped filesystem transport for remote Orca workers.

Usage:
  fm-orca-worker.py spawn HOME CODE STATE DATA CONFIG ID PROJECT MACHINE ARGS...
  fm-orca-worker.py sync STATE ID
  fm-orca-worker.py run STATE ID SCRIPT ARGS...
  fm-orca-worker.py head STATE ID
  fm-orca-worker.py receipt STATE ID
  fm-orca-worker.py landing STATE ID
  fm-orca-worker.py complete-empty STATE ID

MACHINE is the JSON row returned by fm-orca-machines.py. The coordinator writes
a durable route before contacting the host. A lost launch reply retains that
route and refuses a second launch. The remote task gets a private workspace,
not a secondmate or a supervisor: only the existing worker lifecycle scripts
run there. SSH carries filesystem operations; Orca carries terminal operations.
No credentials, pairing codes, or account stores are copied. Source/config and
the task brief are staged once, messages are immutable, handled messages are
never resurrected, and status imports carry an offset for idempotent replay.
The remote script validates the workspace token before every filesystem action.
Publishing code snapshots include a self-contained full-history HEAD bundle
and origin, with the current script overlay applied after checkout. Publishing
tasks require a full-history target mirror with the same origin and working
git-crypt filters when used; missing context refuses before staging, without
repairing shared mirrors or transferring encryption keys.
"""

import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import uuid

# Copy policy, never an arbitrary token/credential file in config/. Account pins
# are references; the target must already have the named login. A configured
# local launch environment needs an explicit remote credential arrangement.
CONFIG_FILES = {
    "firstmate-role", "crew-harness", "crew-dispatch.json", "crew-model",
    "crew-effort", "crew-exclude-tools", "crew-approval-mode", "claude-account",
    "claude-accounts", "pi-account", "launch-env-allowlist", "keep-ai-trailers",
    "herdr-lifecycle-spawn-guard", "project-capacity", "task-tmp-root",
    "claude-permission-mode", "codex-approval-mode", "codex-permission-mode",
    "spawn-base-primary-checkout", "lavish-axi-host",
}
STATE_FILES = ("status", "busy-state", "busy-gen", "progress", "turn-ended",
               "model-stream", "model-stream-order", "model-progress")
PROGRAM_SOURCE = Path(__file__).read_text() if "__file__" in globals() else None


def encode(data):
    return base64.b64encode(data).decode("ascii")


def decode(data):
    return base64.b64decode(data, validate=True)


def atom(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise ValueError("invalid task/environment identity")
    return value


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"not a regular file: {path}")
    return path.read_bytes()


def write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError(f"refusing symlink: {path}")
    fd, tmp = tempfile.mkstemp(prefix=".orca-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def metadata(path):
    result = {}
    for line in regular(path).decode().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            if key in result:
                raise ValueError(f"duplicate metadata key: {key}")
            result[key] = value
    return result


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, check=True,
                          timeout=kwargs.pop("timeout", 30), **kwargs).stdout


def remote(route, request, timeout=60):
    # The program is code, never task input. Everything variable rides stdin.
    program = PROGRAM_SOURCE
    argv = ["python3", "-c", program, "worker"]
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         route["ssh"], shlex.join(argv)],
        input=json.dumps({"route": route, **request}).encode(),
        capture_output=True, timeout=min(timeout, 5) if "--poll" in sys.argv else timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip()
                           or "remote operation failed; completion may be unknown")
    return json.loads(result.stdout)


def files_under(root, prefix=""):
    if root.is_symlink():
        raise ValueError("refusing linked task directory")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            continue
        if path.is_file():
            result[prefix + str(path.relative_to(root))] = [
                encode(regular(path)), path.stat().st_mode & 0o777]
    return result


def install(root, files):
    for name, (data, mode) in files.items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("unsafe transfer path")
        target = root / path
        for parent in target.parents:
            if parent == root:
                break
            if parent.is_symlink():
                raise ValueError("symlink in transfer path")
        write(target, decode(data), mode & 0o700)


def git_context(project):
    if command(["git", "-C", project, "rev-parse", "--is-shallow-repository"]).strip() != b"false":
        raise ValueError(f"full Git history required in {project}; provision the mirror before publishing")
    origin = command(["git", "-C", project, "remote", "get-url", "origin"]).decode().strip()
    if not origin:
        raise ValueError(f"origin remote required in {project}")
    url = urlsplit(origin)
    if url.password is not None or (url.scheme in ("http", "https") and url.username is not None):
        raise ValueError("credential-bearing origin cannot be staged; use host-local Git authentication")
    return origin


def publishing_context(project, origin, env):
    if git_context(project) != origin:
        raise ValueError("remote project origin differs from the coordinator; provision the intended publishing target")
    paths = command(["git", "-C", project, "ls-files", "-z"], env=env)
    attrs = command(["git", "-C", project, "check-attr", "--cached", "-z", "filter", "--stdin"],
                    input=paths, env=env).split(b"\0")
    checked = set()
    for path, _, value in zip(attrs[0::3], attrs[1::3], attrs[2::3]):
        if not value.startswith(b"git-crypt") or value in checked:
            continue
        if not shutil.which("git-crypt", path=env["PATH"]):
            raise ValueError("remote project needs git-crypt installed and unlocked on this machine")
        configured = subprocess.run(["git", "-C", project, "config", "--get",
                                     "filter." + os.fsdecode(value) + ".smudge"],
                                    env=env, capture_output=True, timeout=30)
        if configured.returncode or not configured.stdout.strip():
            raise ValueError("remote project git-crypt filter is locked; unlock the mirror on this machine")
        # A filter may cover plaintext exceptions as well as encrypted blobs.
        # Only a successful decrypt proves this key is available on the host.
        raw = command(["git", "-C", project, "cat-file", "blob", "HEAD:" + os.fsdecode(path)], env=env)
        if not raw.startswith(b"\0GITCRYPT\0"):
            continue
        blob = command(["git", "-C", project, "cat-file", "--filters", "HEAD:" + os.fsdecode(path)], env=env)
        if blob.startswith(b"\0GITCRYPT\0"):
            raise ValueError("remote project git-crypt filter is locked; unlock the mirror on this machine")
        checked.add(value)


def code_context(code):
    origin = git_context(code)
    with tempfile.TemporaryDirectory(prefix="fm-orca-code-") as tmp:
        bundle = Path(tmp) / "code.bundle"
        command(["git", "-C", code, "bundle", "create", str(bundle), "HEAD"], timeout=120)
        return {"bundle": encode(regular(bundle)), "origin": origin}


def worker(request):
    route = request["route"]
    task = atom(route["id"])
    root = Path(route["workspace"])
    if not root.is_absolute() or root.name != "orca-" + route["token"]:
        raise ValueError("invalid task workspace")
    home, code = root / "home", root / "code"
    state = home / "state"
    meta = state / (task + ".meta")
    op = request["op"]
    native_env = os.environ.copy()
    for key in list(native_env):
        if key.startswith("FM_") or key in ("ORCA_PAIRING_CODE", "ORCA_ENVIRONMENT"):
            native_env.pop(key)
    native_env["PATH"] = native_env.get("PATH", "") + ":" + os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/Applications/Orca.app/Contents/Resources/bin"
    orca = shutil.which("orca", path=native_env["PATH"]) or "/Applications/Orca.app/Contents/Resources/bin/orca"
    native = json.loads(command([orca, "status", "--json"], env=native_env, timeout=10))
    if native.get("result", {}).get("runtime", {}).get("runtimeId") != route["runtime_id"]:
        raise ValueError("SSH host no longer identifies the recorded Orca runtime")
    if op == "preflight":
        missing = [name for name in ("bash", "git", "node", "jq", "lsof", "tasks-axi")
                   if not shutil.which(name, path=native_env["PATH"])]
        if not any(shutil.which(name, path=native_env["PATH"]) for name in ("shasum", "sha256sum")):
            missing.append("shasum or sha256sum")
        harness = request.get("harness")
        if harness:
            atom(harness)
            candidates = {"cursor": ("cursor-agent", "agent"), "kiro": ("kiro-cli",)}.get(harness, (harness,))
            available = any(shutil.which(name, path=native_env["PATH"]) for name in candidates)
            if harness == "kimi":
                available = available or os.access(os.path.expanduser("~/.kimi-code/bin/kimi"), os.X_OK)
            if not available:
                missing.append(harness + " harness (" + " or ".join(candidates) + ")")
        if missing:
            raise ValueError("remote lifecycle tools missing: " + ", ".join(missing))
        # Reuse the compatibility owner, including its feature probes, without
        # installing anything or creating a task/worktree on the remote host.
        check = request["tasks_library"] + "\nfm_tasks_axi_compatible || exit 1\n"
        check += "tasks-axi hold --help | grep -F -- '--kind captain' >/dev/null\n"
        result = subprocess.run(["bash", "-c", check], env=native_env,
                                capture_output=True, timeout=30)
        if result.returncode:
            raise ValueError("remote lifecycle tool tasks-axi is incompatible; install the supported version and captain-hold capabilities")
        if request.get("project_origin"):
            publishing_context(route["project"], request["project_origin"], native_env)
        return {}
    if op == "stage":
        root.mkdir(parents=True, mode=0o700, exist_ok=False)
        write(root / "owner", route["token"].encode())
        context = request["code_context"]
        if context is not None:
            bundle = root / "code.bundle"
            write(bundle, decode(context["bundle"]))
            command(["git", "init", "-q", str(code)], env=native_env)
            command(["git", "-C", str(code), "fetch", "--no-tags", str(bundle), "HEAD"], env=native_env, timeout=120)
            command(["git", "-C", str(code), "checkout", "--detach", "FETCH_HEAD"], env=native_env, timeout=120)
            command(["git", "-C", str(code), "remote", "add", "origin", context["origin"]], env=native_env)
            git_context(str(code))
            bundle.unlink()
        install(root, request["files"])
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        return {}
    if root.is_symlink() or regular(root / "owner").decode() != route["token"]:
        raise ValueError("remote task workspace identity changed")
    # An SSH process must not inherit another Firstmate task's routing.
    env = native_env.copy()
    env.update(FM_HOME=str(home), FM_ROOT=str(code), FM_SPAWN_NO_GUARD="1")
    receipt = root / "teardown-receipt"
    retired = receipt.exists()
    if retired and (regular(receipt).decode() != route["token"] or meta.exists()):
        raise ValueError("invalid cleanup receipt")
    if op == "receipt":
        return {"complete": retired}
    if op == "run":
        script = request["script"]
        if script not in ("fm-spawn.sh", "fm-control.sh", "fm-crew-state.sh", "fm-teardown.sh"):
            raise ValueError("unsupported remote worker command")
        args = request["args"]
        if not args or args[0] != task:
            raise ValueError("remote command belongs to another task")
        if script == "fm-teardown.sh" and retired:
            return {"status": 0, "stdout": encode(b"remote cleanup already verified\n"), "stderr": ""}
        # A durable one-shot launch claim fences retries after SSH disconnect.
        if script == "fm-spawn.sh":
            with (root / "launch-claimed").open("xb") as stream:
                stream.write(route["token"].encode())
        completed = subprocess.run(["bash", str(code / "bin" / script), *args],
                                   env=env, cwd=home, capture_output=True, timeout=240)
        if script == "fm-teardown.sh" and completed.returncode == 0:
            if meta.exists():
                raise ValueError("remote cleanup returned success but retained task metadata")
            write(receipt, route["token"].encode())
        return {"status": completed.returncode,
                "stdout": encode(completed.stdout), "stderr": encode(completed.stderr)}
    if op == "snapshot":
        if retired:
            return {"retired": True}
        result = {"files": {}, "handled": {}, "meta": None, "missing": []}
        if meta.exists():
            result["meta"] = encode(regular(meta))
        for suffix in STATE_FILES:
            path = state / f"{task}.{suffix}"
            if path.exists():
                result["files"][suffix] = [encode(regular(path)), path.stat().st_mtime_ns]
            elif suffix != "status":
                result["missing"].append(suffix)
        result["reports"] = files_under(home / "data" / task)
        inbox = state / (task + ".inbox")
        for path in (inbox / "handled").glob("*.msg"):
            result["handled"][path.name] = hashlib.sha256(regular(path)).hexdigest()
        return result
    if op == "messages":
        inbox = state / (task + ".inbox")
        for name, data in request["messages"].items():
            if not re.fullmatch(r"[0-9]+\.msg", name):
                raise ValueError("invalid inbox sequence")
            content = decode(data)
            handled = inbox / "handled" / name
            pending = inbox / name
            existing = handled if handled.exists() else pending
            if existing.exists():
                if regular(existing) != content:
                    raise ValueError("remote inbox sequence collision")
            else:
                write(pending, content)
        status = state / (task + ".status")
        existing = regular(status) if status.exists() else b""
        for data in request.get("status", []):
            line = decode(data)
            head, colon, note = line.partition(b":")
            tag = b" [coordinator-event=" + hashlib.sha256(line).hexdigest().encode() + b"]"
            if colon and tag not in existing:
                with status.open("ab") as stream:
                    stream.write(head + tag + colon + note)
        return {}
    if op == "head":
        fields = metadata(meta)
        wt, project, branch = fields["worktree"], fields["project"], fields["branch"]
        sha = command(["git", "-C", wt, "rev-parse", "HEAD"]).decode().strip()
        if command(["git", "-C", wt, "status", "--porcelain"]).strip():
            raise ValueError("remote worktree is dirty")
        named = command(["git", "-C", project, "rev-parse", "refs/heads/" + branch]).decode().strip()
        if named != sha:
            raise ValueError("remote named branch does not hold worker HEAD")
        if sha == route["base_head"]:
            return {"head": sha, "branch": branch, "bundle": ""}
        bundle = root / "delivery.bundle"
        command(["git", "-C", project, "bundle", "create", str(bundle),
                 "refs/heads/" + branch, "^" + route["base_head"]])
        return {"head": sha, "branch": branch, "bundle": encode(regular(bundle))}
    if op == "landing":
        fields = metadata(meta)
        ref = "refs/remotes/fm-parent-" + route["token"] + "/landed"
        if not request["bundle"]:
            command(["git", "-C", fields["project"], "update-ref", ref, route["base_head"]])
            return {}
        bundle = root / "landing.bundle"
        write(bundle, decode(request["bundle"]))
        command(["git", "-C", fields["project"], "fetch", "--no-tags", str(bundle),
                 request["ref"] + ":" + ref])
        return {}
    if op == "done":
        fields = metadata(meta)
        script = '. "$1"; fm_dod_accept_ship_done "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"'
        result = subprocess.run(["bash", "-c", script, "orca-done",
                                 str(code / "bin/fm-dod-lib.sh"), fields["kind"],
                                 fields["mode"], fields["worktree"], fields["project"],
                                 request["line"], str(state), task, str(meta)],
                                capture_output=True, env=env, timeout=60)
        return {"status": result.returncode, "stdout": encode(result.stdout),
                "stderr": encode(result.stderr)}
    if op == "complete-empty":
        fields = metadata(meta)
        if fields.get("spawn_gen") != request["generation"] or fields.get("kind") != "scout":
            raise ValueError("completion belongs to another worker incarnation")
        command(["bash", str(code / "bin/fm-captain-hold.sh"), "complete", task, "--none"], env=env)
        return {}
    raise ValueError("unsupported worker transport operation")


def route_file(state, task):
    return Path(state) / (atom(task) + ".orca-route.json")


@contextlib.contextmanager
def route_lock(state, task):
    path = Path(state) / (atom(task) + ".orca-sync.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if "--poll" in sys.argv else 0))
        yield
    finally:
        os.close(fd)


def load_route(state, task):
    route = json.loads(regular(route_file(state, task)))
    if route["id"] != task or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", route["ssh"]):
        raise ValueError("invalid Orca worker route")
    atom(route["environment"])
    atom(route["runtime_id"])
    meta = Path(state) / (task + ".meta")
    if meta.exists():
        fields = metadata(meta)
        for key, value in (("orca_environment", route["environment"]),
                           ("orca_runtime_id", route["runtime_id"]),
                           ("orca_machine_host", route["ssh"]),
                           ("orca_machine_workspace", route["workspace"])):
            if fields.get(key) != value:
                raise ValueError("task metadata and remote route disagree")
    return route


def sync(state, task):
    route = load_route(state, task)
    # Read retirement before publishing anything. Cleanup removes task state;
    # replaying coordinator lines afterwards would resurrect a partial log.
    snap = remote(route, {"op": "snapshot"})
    if snap.get("retired"):
        return snap
    state = Path(state)
    inbox = state / (task + ".inbox")
    messages = {p.name: encode(regular(p)) for p in inbox.glob("*.msg")}
    local_status = state / (task + ".status")
    status = regular(local_status) if local_status.exists() else b""
    parent_lines = [encode(line) for line in status.splitlines(keepends=True)
                    if b"[orca-event=" not in line and line.endswith(b"\n")]
    if messages or parent_lines:
        remote(route, {"op": "messages", "messages": messages, "status": parent_lines})
    target_meta = state / (task + ".meta")
    if snap["meta"] and not target_meta.exists():
        raw = decode(snap["meta"])
        fields = dict(line.split("=", 1) for line in raw.decode().splitlines() if "=" in line)
        if fields.get("endpoint_task_id") != task or fields.get("backend") != "orca":
            raise ValueError("remote metadata does not identify this Orca task")
        write(target_meta, raw + (
            f"orca_environment={route['environment']}\n"
            f"orca_runtime_id={route['runtime_id']}\n"
            f"orca_machine_host={route['ssh']}\n"
            f"orca_machine_workspace={route['workspace']}\n").encode())
    for name, digest in snap["handled"].items():
        if not re.fullmatch(r"[0-9]+\.msg", name):
            raise ValueError("invalid remote acknowledgement")
        pending = inbox / name
        if pending.exists():
            if hashlib.sha256(regular(pending)).hexdigest() != digest:
                raise ValueError("inbox acknowledgement content differs")
            (inbox / "handled").mkdir(exist_ok=True)
            os.replace(pending, inbox / "handled" / name)
    # Reports are task-owned. Never overwrite the coordinator's original brief.
    reports = {k: v for k, v in snap["reports"].items() if k != "brief.md"}
    install(Path(route["data"]) / task / "remote", reports)
    if "report.md" in reports:
        write(Path(route["data"]) / task / "report.md", decode(reports["report.md"][0]))
    for suffix, (data, mtime) in snap["files"].items():
        if suffix not in STATE_FILES or not isinstance(mtime, int) or mtime < 0:
            raise ValueError("invalid remote event file")
        content = decode(data)
        target = state / f"{task}.{suffix}"
        if suffix == "status":
            source_log = Path(route["data"]) / task / "remote" / "status.raw"
            previous = regular(source_log) if source_log.exists() else b""
            if not content.startswith(previous):
                raise ValueError("remote status log was truncated or rewritten")
            old = regular(target) if target.exists() else b""
            offset = 0
            for line in content.splitlines(keepends=True):
                offset += len(line)
                if not line.endswith(b"\n"):
                    break
                if b"[coordinator-event=" in line:
                    continue
                tag = f" [orca-event={route['token']}-{offset}]".encode()
                if tag in old:
                    continue
                head, colon, note = line.partition(b":")
                if not colon:
                    continue
                fd = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    os.write(fd, head + tag + colon + note)
                    os.fsync(fd)
                finally:
                    os.close(fd)
            # Keep only complete lines; a worker may be midway through append.
            complete = content[:content.rfind(b"\n") + 1]
            write(source_log, complete)
        else:
            if not target.exists() or regular(target) != content or target.stat().st_mtime_ns != mtime:
                write(target, content)
                os.utime(target, ns=(mtime, mtime))
    for suffix in snap["missing"]:
        if suffix not in STATE_FILES or suffix == "status":
            raise ValueError("invalid remote event retirement")
        path = state / f"{task}.{suffix}"
        if path.exists():
            regular(path)
            path.unlink()
    return snap


def spawn(home, code, state, data, config, task, project, machine, args):
    row = json.loads(machine)
    atom(task)
    atom(row["environment"])
    route_path = route_file(state, task)
    if route_path.exists():
        raise ValueError("existing remote launch route; reconcile it before another launch")
    if (Path(config) / "launch-env-tmux-session").exists():
        raise ValueError("remote Orca cannot snapshot a local tmux credential session")
    token = uuid.uuid4().hex
    workspace = str(Path(home) / "data" / task / ("orca-" + token))
    route = {**row, "token": token, "workspace": workspace, "id": task,
             "home": home, "data": data, "project": project}
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", row["ssh"]):
        raise ValueError("invalid SSH alias")
    base_ref = args[args.index("--base-branch") + 1] if "--base-branch" in args else "HEAD"
    route["base_head"] = command(["git", "-C", project, "rev-parse", "--verify", base_ref + "^{commit}"]).decode().strip()
    files = {}
    for directory in ("bin", "docs", ".agents/skills"):
        files.update(files_under(Path(code) / directory, "code/" + directory + "/"))
    overlay = Path(code) / ".omp/fm-worker-overlay.yml"
    if overlay.exists():
        files["code/.omp/fm-worker-overlay.yml"] = [encode(regular(overlay)), 0o600]
    for name in CONFIG_FILES:
        path = Path(config) / name
        if path.exists():
            files["home/config/" + name] = [encode(regular(path)), 0o600]
    # The original home remains the only backlog owner and supervisor.
    files["home/config/backlog-backend"] = [encode(b"manual\n"), 0o600]
    remote_home = workspace + "/home"
    brief = regular(Path(data) / task / "brief.md").decode()
    paths = {code: workspace + "/code", home: remote_home,
             data: remote_home + "/data", state: remote_home + "/state",
             home + "/config": remote_home + "/config"}
    # Code and operational home may share a root. Resolve code resources before
    # the bare home prefix, including the skills referenced by generated briefs.
    for directory in ("bin", "docs", ".agents"):
        paths[code + "/" + directory] = workspace + "/code/" + directory
    pattern = "|".join(re.escape(path) for path in sorted(paths, key=len, reverse=True))
    # One pass: the destination workspace itself is below the source home.
    # Replacing a later source prefix in an already-rewritten path corrupts it.
    brief = re.sub(pattern, lambda match: paths[match.group()], brief)
    files[f"home/data/{task}/brief.md"] = [encode(brief.encode()), 0o600]
    # The remote spawn enforces the same recorded dispatch selection as its
    # coordinator. Carry the task's decision, rather than resolving it again.
    dispatch = Path(data) / task / "dispatch-resolution.json"
    if dispatch.exists():
        files[f"home/data/{task}/dispatch-resolution.json"] = [encode(regular(dispatch)), 0o600]
    harness = args[args.index("--harness") + 1] if "--harness" in args else None
    mode = args[args.index("--mode") + 1] if "--mode" in args else "local-only"
    project_origin = git_context(project) if mode in ("no-mistakes", "direct-PR") else None
    remote(route, {"op": "preflight", "harness": harness, "tasks_library": regular(
        Path(code) / "bin/fm-tasks-axi-lib.sh").decode(), "project_origin": project_origin})
    # Scouts/local-only tasks never enter the publication gate. Preserve their
    # existing source-only staging, including use from shallow installations.
    context = code_context(code) if project_origin else None
    with route_path.open("xb") as stream:
        stream.write(json.dumps(route).encode())
        stream.flush()
        os.fsync(stream.fileno())
    remote(route, {"op": "stage", "files": files, "code_context": context}, timeout=260)
    result = remote(route, {"op": "run", "script": "fm-spawn.sh", "args": args}, timeout=260)
    snap = sync(state, task)
    sys.stdout.buffer.write(decode(result["stdout"]))
    sys.stderr.buffer.write(decode(result["stderr"]))
    if result["status"] or not snap["meta"]:
        raise RuntimeError("remote spawn did not complete; route retained for reconciliation")


def head(state, task):
    route = load_route(state, task)
    fields = metadata(Path(state) / (task + ".meta"))
    result = remote(route, {"op": "head"})
    if result["branch"] != fields["branch"] or not re.fullmatch(r"[0-9a-f]{40,64}", result["head"]):
        raise ValueError("remote delivery identity differs")
    if route.get("accepted_head") and route["accepted_head"] != result["head"]:
        raise ValueError("remote readiness differs from the accepted head")
    bundle = Path(route["data"]) / task / "remote" / "delivery.bundle"
    # Git's ordinary fetch protects checked-out branches and refuses non-FF
    # updates. Never force a previously imported or independently held branch.
    ref = "refs/heads/" + result["branch"]
    if result["bundle"]:
        write(bundle, decode(result["bundle"]))
        command(["git", "-C", route["project"], "fetch", "--no-tags", str(bundle), ref + ":" + ref])
    else:
        # An unchanged head needs no pack. Create a missing branch atomically;
        # an existing branch is accepted only when it already has that head.
        existing = subprocess.run(["git", "-C", route["project"], "rev-parse", "--verify", ref], capture_output=True)
        if existing.returncode:
            command(["git", "-C", route["project"], "update-ref", ref, result["head"], "0" * len(result["head"])])
    actual = command(["git", "-C", route["project"], "rev-parse", ref]).decode().strip()
    if actual != result["head"]:
        raise ValueError("imported branch does not hold remote head")
    route["accepted_head"] = actual
    write(route_file(state, task), json.dumps(route).encode())
    return actual


def landing(state, task):
    route = load_route(state, task)
    fields = metadata(Path(state) / (task + ".meta"))
    if fields.get("mode") != "local-only" or fields.get("kind") != "ship":
        return
    sha = route.get("accepted_head", "")
    if not re.fullmatch(r"[0-9a-f]{40,64}", sha):
        raise ValueError("local-only remote cleanup requires an accepted delivery head")
    project = route["project"]
    default = command(["git", "-C", project, "symbolic-ref", "--short", "HEAD"]).decode().strip()
    if default not in ("main", "master"):
        expected = command(["git", "-C", project, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).decode().strip()
        if expected != "origin/" + default:
            raise ValueError("project checkout is not on its default branch")
    command(["git", "-C", project, "merge-base", "--is-ancestor", sha, "refs/heads/" + default])
    current = remote(route, {"op": "head"})
    if current["head"] != sha:
        raise ValueError("remote worker changed after local landing")
    path = Path(route["data"]) / task / "remote" / "landing.bundle"
    ref = "refs/heads/" + default
    tip = command(["git", "-C", project, "rev-parse", ref]).decode().strip()
    payload = ""
    if tip != route["base_head"]:
        command(["git", "-C", project, "bundle", "create", str(path), ref, "^" + route["base_head"]])
        payload = encode(regular(path))
    remote(route, {"op": "landing", "ref": ref, "bundle": payload})


def main():
    op, *args = sys.argv[1:]
    if op == "worker":
        print(json.dumps(worker(json.load(sys.stdin))))
    elif op == "spawn":
        spawn(*args[:8], args[8:])
    elif op in ("sync", "head", "run", "landing", "done", "complete-empty", "receipt"):
        state, task, *rest = args
        with route_lock(state, task):
            if op == "sync":
                poll = Path(state) / (task + ".orca-last-sync")
                if "--poll" in rest:
                    if poll.exists() and time.time() - poll.stat().st_mtime < 15:
                        return
                    write(poll, b"")
                sync(state, task)
            elif op == "head":
                print(head(state, task))
            elif op == "receipt":
                result = remote(load_route(state, task), {"op": "receipt"})
                print("complete" if result["complete"] else "pending")
            elif op == "landing":
                landing(state, task)
            elif op == "complete-empty":
                fields = metadata(Path(state) / (task + ".meta"))
                if fields.get("decisions_reviewed") != "1" or fields.get("decision_keys"):
                    raise ValueError("remote cleanup requires a reviewed empty parent inventory")
                remote(load_route(state, task), {"op": "complete-empty", "generation": fields["spawn_gen"]})
            elif op == "done":
                result = remote(load_route(state, task), {"op": "done", "line": rest[0]})
                sys.stdout.buffer.write(decode(result["stdout"]))
                sys.stderr.buffer.write(decode(result["stderr"]))
                sys.exit(result["status"])
            else:
                route = load_route(state, task)
                sync(state, task)
                result = remote(route, {"op": "run", "script": rest[0], "args": rest[1:]}, timeout=260)
                sync(state, task)
                sys.stdout.buffer.write(decode(result["stdout"]))
                sys.stderr.buffer.write(decode(result["stderr"]))
                sys.exit(result["status"])
    else:
        raise ValueError(__doc__)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"error: remote Orca worker: {exc}", file=sys.stderr)
        sys.exit(1)
