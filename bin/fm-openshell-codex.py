#!/usr/bin/env python3
"""Run a Herdr Codex task from a private OpenShell worktree snapshot."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import tarfile
import time
from pathlib import Path


MAX_REQUEST = 1024 * 1024
MAX_STATUS_LINE = 2048
WORKSPACE_IN_SANDBOX = "/sandbox"
CAPABILITY_IN_SANDBOX = "/sandbox/.git/fm-openshell/fm-task-capability"
HOOKS_IN_SANDBOX = "/sandbox/.git/fm-openshell/task-hooks"
CHANNEL_IN_SANDBOX = "/sandbox/.git/fm-openshell/channel"
STATUS_RE = re.compile(
    r"^(?:working|needs-decision|blocked|paused|done|failed|resolved|note) "
    r"(?:\[at=[0-9]+\](?: \[key=[a-z0-9][a-z0-9-]*\])?|"
    r"\[key=[a-z0-9][a-z0-9-]*\] \[at=[0-9]+\]): [^\r\n]{1,1900}$"
)
INBOX_NAME_RE = re.compile(r"^[0-9]+\.msg$")
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
PROVIDER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SANDBOX_NOT_FOUND = ("not found", "does not exist", "notfound", "no sandbox")


class Refusal(RuntimeError):
    pass


def fail(message):
    raise Refusal(message)


def run(argv, *, cwd=None, env=None, input_bytes=None, capture=False, check=True):
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            input=input_bytes,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            check=False,
        )
    except OSError as exc:
        if check:
            fail("could not run " + str(argv[0]) + ": " + str(exc))
        return None
    if check and result.returncode:
        detail = ""
        if capture:
            detail = (result.stderr or b"").decode("utf-8", "replace").strip()
        fail("command failed (" + str(result.returncode) + "): " + " ".join(argv[:4]) + (": " + detail if detail else ""))
    return result


def cli_env():
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("GIT_", "SSH_")):
            env.pop(key, None)
    env.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_TERMINAL_PROMPT="0",
        GIT_OPTIONAL_LOCKS="0",
        GIT_NO_REPLACE_OBJECTS="1",
        GIT_NO_LAZY_FETCH="1",
    )
    return env


def git(repo, *args, capture=True, input_bytes=None, check=True):
    argv = [
        "git",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-C",
        str(repo),
        *args,
    ]
    result = run(argv, env=cli_env(), capture=capture, input_bytes=input_bytes, check=check)
    if result is None:
        return None
    return (result.stdout or b"").decode("utf-8", "surrogateescape").strip() if capture else result.returncode


def git_bytes(repo, *args, input_bytes=None, check=True):
    argv = [
        "git",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-C",
        str(repo),
        *args,
    ]
    result = run(argv, env=cli_env(), capture=True, input_bytes=input_bytes, check=check)
    return None if result is None else result.stdout


def load_context(task_id, *, require_live=True):
    if not TASK_ID_RE.fullmatch(task_id):
        fail("invalid task id")
    root = Path(os.environ.get("FM_ROOT_OVERRIDE") or Path(__file__).resolve().parents[1]).resolve()
    home = Path(os.environ.get("FM_HOME") or root).resolve()
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE") or (home / "state")).resolve()
    config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE") or (home / "config")).resolve()
    meta = state_dir / (task_id + ".meta")
    if meta.is_symlink() or not meta.is_file():
        fail("task metadata is missing or is not a regular file: " + str(meta))
    values = {}
    for line in meta.read_text(encoding="utf-8").splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in values:
            fail("task metadata contains a duplicate " + key + " field")
        values[key] = value
    if values.get("openshell") != "codex-v1":
        fail("task metadata does not authorize the OpenShell Codex path")
    if values.get("harness") != "codex" or values.get("backend") != "herdr":
        fail("OpenShell metadata is not bound to a Herdr Codex task")
    if values.get("kind") != "ship" or values.get("mode") != "no-mistakes":
        fail("OpenShell Codex currently supports no-mistakes ship tasks only")
    providers = values.get("openshell_providers", "").split(",")
    if (
        not providers
        or len(providers) > 4
        or len(set(providers)) != len(providers)
        or "codex" not in providers
        or any(not PROVIDER_RE.fullmatch(x) for x in providers)
    ):
        fail("task metadata has an invalid OpenShell provider list")
    gateway = values.get("openshell_gateway", "")
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?", gateway):
        fail("task metadata has an invalid OpenShell gateway name")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", values.get("openshell_name", "")):
        fail("task metadata has an invalid OpenShell sandbox name")
    expected_sandbox = "fm-codex-" + hashlib.sha256(
        os.fsencode(str(home)) + bytes([0]) + task_id.encode("utf-8")
    ).hexdigest()[:24]
    if values["openshell_name"] != expected_sandbox:
        fail("OpenShell sandbox name is not bound to this Firstmate home and task")
    if values.get("openshell_keep_ai_trailers", "0") not in ("0", "1"):
        fail("task metadata has an invalid AI trailer setting")
    workspace = values.get("openshell_workspace", "")
    workspace_id = values.get("openshell_workspace_id", "")
    validate_workspace(workspace, workspace_id)
    worktree_value = values.get("worktree", "")
    worktree_input = Path(worktree_value)
    if (not worktree_input.is_absolute() or worktree_input.is_symlink()
            or (worktree_input.exists() and not worktree_input.is_dir())
            or (require_live and not worktree_input.is_dir())):
        fail("assigned task worktree is missing or is a symlink")
    worktree = worktree_input.resolve()
    tasktmp_value = values.get("tasktmp", "")
    if not tasktmp_value or not Path(tasktmp_value).is_absolute():
        fail("task temp root is missing or is not absolute")
    tasktmp = Path(tasktmp_value)
    if (not tasktmp.is_absolute() or tasktmp.is_symlink()
            or (tasktmp.exists() and not tasktmp.is_dir())
            or (require_live and not tasktmp.is_dir())):
        fail("task temp root is missing or unsafe")
    tasktmp = tasktmp.resolve()
    if tasktmp_value != "/tmp/fm-" + task_id:
        fail("task temp root does not match Firstmate's task-scoped temp path")
    if tasktmp.exists() and (tasktmp.stat().st_uid != os.getuid() or tasktmp.stat().st_mode & 0o077):
        fail("task temp root is not private to the launching user")
    branch = values.get("branch", "")
    checked = run(["git", "check-ref-format", "--branch", branch], env=cli_env(), capture=True, check=False) if branch else None
    if checked is None or checked.returncode:
        fail("task metadata has an invalid branch name")
    return {
        "id": task_id,
        "root": root,
        "home": home,
        "state": state_dir,
        "config": config_dir,
        "gateway": gateway,
        "workspace": workspace,
        "workspace_id": workspace_id,
        "meta": meta,
        "values": values,
        "providers": providers,
        "worktree": worktree,
        "branch": branch,
        "tasktmp": tasktmp,
        "stage_root": tasktmp / "openshell-codex",
        "stage": tasktmp / "openshell-codex" / "workspace",
        "journal": tasktmp / "openshell-codex-state.json",
        "validation": state_dir / (task_id + ".openshell-validation.json"),
        "bridge_dir": tasktmp / "openshell-codex-bridge",
        "channel": tasktmp / "openshell-codex-bridge" / "inbox",
        "responses": tasktmp / "openshell-codex-bridge" / "responses",
        "policy": tasktmp / "openshell-codex-policy.yaml",
        "sandbox": values["openshell_name"],
    }


def read_journal(ctx):
    path = ctx["journal"]
    if path.is_symlink():
        fail("OpenShell recovery journal is a symlink")
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail("OpenShell recovery journal is unreadable: " + str(exc))
    if data.get("task_id") != ctx["id"] or data.get("worktree") != str(ctx["worktree"]):
        fail("OpenShell recovery journal identity does not match this task")
    if data.get("workspace") != ctx["workspace"] or data.get("workspace_id") != ctx["workspace_id"]:
        fail("OpenShell recovery journal workspace does not match this task")
    return data


def write_journal(ctx, data):
    path = ctx["journal"]
    data["workspace"] = ctx["workspace"]
    data["workspace_id"] = ctx["workspace_id"]
    data["task_id"] = ctx["id"]
    data["worktree"] = str(ctx["worktree"])
    tmp = path.with_name(path.name + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(str(tmp), flags, 0o600)
    try:
        payload = (json.dumps(data, ensure_ascii=True, sort_keys=True) + "\n").encode("ascii")
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(str(tmp), str(path))


def git_paths(repo):
    raw = git_bytes(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if raw is None:
        fail("could not enumerate task worktree paths")
    result = set()
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        path = os.fsdecode(entry)
        validate_relative(path)
        result.add(path)
    return sorted(result, key=os.fsencode)


def validate_relative(path):
    if not path or path.startswith("/") or "\x00" in path or "\\" in path:
        fail("worktree contains an unsupported path")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts) or parts[0] == ".git":
        fail("worktree contains a path outside its assigned root")


def state_for(root, rel):
    path = root / rel
    current = root
    for part in rel.split("/")[:-1]:
        current = current / part
        try:
            parent_mode = current.lstat().st_mode
        except FileNotFoundError:
            return {"kind": "missing"}
        if not stat.S_ISDIR(parent_mode):
            return {"kind": "missing"}
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"kind": "missing"}
    if stat.S_ISDIR(info.st_mode):
        return {"kind": "missing"}
    if stat.S_ISLNK(info.st_mode):
        return {"kind": "symlink", "target": os.readlink(str(path))}
    if stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        return {"kind": "file", "sha256": digest.hexdigest(), "mode": stat.S_IMODE(info.st_mode)}
    fail("task worktree contains a non-file entry at " + rel)


def same_content(left, right):
    if left.get("kind") != right.get("kind"):
        return False
    if left.get("kind") == "file":
        return left.get("sha256") == right.get("sha256")
    if left.get("kind") == "symlink":
        return left.get("target") == right.get("target")
    return left.get("kind") == "missing"


def snapshot(root, paths):
    return {path: state_for(root, path) for path in paths}


def remove_leaf(root, rel):
    current = root
    for part in rel.split("/")[:-1]:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(mode):
            return
    target = root / rel
    try:
        mode = target.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISDIR(mode):
        return
    if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
        fail("refusing to remove an unsupported worktree entry: " + rel)
    target.unlink()
    parent = target.parent
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent


def copy_path(source_root, dest_root, rel, baseline=None):
    validate_relative(rel)
    source = source_root / rel
    target = dest_root / rel
    if state_for(source_root, rel)["kind"] == "missing":
        remove_leaf(dest_root, rel)
        return
    for root, path in ((source_root, source), (dest_root, target)):
        current = root
        for part in rel.split("/")[:-1]:
            current = current / part
            try:
                mode = current.lstat().st_mode
            except FileNotFoundError:
                if root == dest_root:
                    current.mkdir(mode=0o755)
                continue
            if not stat.S_ISDIR(mode):
                fail("refusing to follow a non-directory parent in " + rel)
    info = source.lstat()
    try:
        old = target.lstat()
    except FileNotFoundError:
        old = None
    if old and stat.S_ISDIR(old.st_mode):
        try:
            target.rmdir()
        except OSError:
            fail("worktree file would replace a directory containing unrelated data: " + rel)
    if stat.S_ISLNK(info.st_mode):
        link = os.readlink(str(source))
        normalized_link = os.path.normpath(os.path.join(os.path.dirname(rel), link))
        if os.path.isabs(link) or normalized_link == ".." or normalized_link.startswith("../"):
            if not (baseline and baseline.get(rel, {}).get("kind") == "symlink" and baseline[rel].get("target") == link):
                fail("sandbox created a symlink that escapes the task worktree: " + rel)
        tmp = target.with_name("." + target.name + ".fm-openshell-tmp")
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        os.symlink(link, str(tmp))
        os.replace(str(tmp), str(target))
        return
    if not stat.S_ISREG(info.st_mode):
        fail("sandbox produced an unsupported file type: " + rel)
    fd, tmp_name = tempfile.mkstemp(prefix=".fm-openshell-", dir=str(target.parent))
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        if baseline and baseline.get(rel, {}).get("kind") == "file":
            mode = baseline[rel].get("mode", 0o644) & 0o666
        else:
            mode = stat.S_IMODE(info.st_mode) & 0o666
        mode |= stat.S_IMODE(info.st_mode) & 0o111
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, str(target))
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def apply_files(source_root, dest_root, paths, states, baseline, expected):
    deletions = {path for path in paths if states.get(path, {}).get("kind", "missing") == "missing"}
    ordered = sorted(deletions, key=lambda path: (-path.count("/"), os.fsencode(path)))
    ordered.extend(sorted(set(paths) - deletions, key=os.fsencode))
    for rel in ordered:
        if not same_content(state_for(dest_root, rel), expected.get(rel, {"kind": "missing"})):
            fail("task worktree changed during OpenShell file transition: " + rel)
        copy_path(source_root, dest_root, rel, baseline)


def safe_origin(repo):
    result = run(["git", "-c", "core.fsmonitor=false", "-C", str(repo), "remote", "get-url", "origin"], env=cli_env(), capture=True, check=False)
    if result is None or result.returncode:
        return ""
    url = result.stdout.decode("utf-8", "replace").strip()
    match = re.fullmatch(r"https://([A-Za-z0-9.-]+)(/[^\s?#]*)", url)
    if not match or "@" in match.group(1) or ".." in match.group(2):
        return ""
    return url


def local_config(repo, key):
    result = run(["git", "-c", "core.fsmonitor=false", "-C", str(repo), "config", "--local", "--get", key], env=cli_env(), capture=True, check=False)
    return "" if result is None or result.returncode else result.stdout.decode("utf-8", "replace").strip()


def git_identity(repo, key):
    value = local_config(repo, key)
    if not value:
        result = run(["git", "config", "--global", "--get", key], env=os.environ.copy(), capture=True, check=False)
        value = "" if result is None or result.returncode else result.stdout.decode("utf-8", "replace").strip()
    if "\n" in value or "\r" in value or len(value) > 200:
        fail("Git identity contains unsupported characters")
    return value


def write_private_config(ctx, origin, object_format, project_hooks):
    config = ctx["stage"] / ".git" / "config"
    if config.is_symlink():
        fail("private Git config is a symlink")
    lines = ["[core]", "\trepositoryformatversion = 0", "\tfilemode = true", "\tbare = false", "\tlogallrefupdates = true"]
    if object_format == "sha256":
        lines[1] = "\trepositoryformatversion = 1"
        lines.extend(["[extensions]", "\tobjectformat = sha256"])
    if project_hooks:
        lines.extend(["[core]", "\thooksPath = /sandbox/.git/fm-openshell/project-hooks"])
    if origin:
        lines.extend(["[remote \"origin\"]", "\turl = " + origin, "\tfetch = +refs/heads/*:refs/remotes/origin/*"])
        lines.extend(["[branch \"" + ctx["branch"].replace("\\", "\\\\").replace('"', '\\"') + "\"]", "\tremote = origin", "\tmerge = refs/heads/" + ctx["branch"]])
    config.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(str(config), 0o600)


def copy_project_hooks(ctx):
    configured = local_config(ctx["worktree"], "core.hooksPath")
    if not configured:
        return False
    candidate = Path(configured)
    if not candidate.is_absolute():
        candidate = ctx["worktree"] / candidate
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(ctx["worktree"])
    except (OSError, ValueError):
        return False
    if not resolved.is_dir() or resolved.is_symlink():
        return False
    destination = ctx["stage"] / ".git" / "fm-openshell" / "project-hooks"
    for root, dirs, files in os.walk(str(resolved), followlinks=False):
        relative_root = os.path.relpath(root, str(resolved))
        target_root = destination if relative_root == "." else destination / relative_root
        target_root.mkdir(parents=True, exist_ok=True)
        for name in dirs[:]:
            source = Path(root) / name
            if source.is_symlink():
                fail("project Git hook directory contains a symlink")
            (target_root / name).mkdir(exist_ok=True)
        for name in files:
            source = Path(root) / name
            if source.is_symlink() or not source.is_file():
                fail("project Git hooks contain an unsupported file")
            shutil.copy2(str(source), str(target_root / name))
    return True


def prepare_workspace(ctx):
    wt = ctx["worktree"]
    if wt.is_symlink() or not wt.is_dir():
        fail("assigned task worktree is missing or is a symlink")
    current_branch = git(wt, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if current_branch != ctx["branch"]:
        fail("task worktree is not on its recorded task branch")
    if git(wt, "ls-files", "-u"):
        fail("task worktree has unresolved Git index entries")
    gitlinks = git_bytes(wt, "ls-files", "--stage", "-z") or b""
    if re.search(rb"(?:^|\0)160000 ", gitlinks):
        fail("OpenShell Codex does not support submodules in the assigned worktree")
    base = git(wt, "rev-parse", "HEAD")
    index_tree = git(wt, "write-tree")
    paths = git_paths(wt)
    states = snapshot(wt, paths)
    patch = git_bytes(wt, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD") or b""
    origin = safe_origin(wt)
    object_format = git(wt, "rev-parse", "--show-object-format")
    for path in (ctx["stage_root"], ctx["journal"], ctx["bridge_dir"], ctx["policy"]):
        if path.exists() or path.is_symlink():
            fail("OpenShell task staging already exists; recover it before relaunching")
    journal = {
        "phase": "preparing",
        "base_head": base,
        "base_index_tree": index_tree,
        "base_paths": paths,
        "base_files": states,
        "origin": origin,
        "object_format": object_format,
        "project_hooks": False,
        "keep_ai_trailers": ctx["values"].get("openshell_keep_ai_trailers", "0"),
        "user_name": git_identity(wt, "user.name"),
        "user_email": git_identity(wt, "user.email"),
    }
    write_journal(ctx, journal)
    ctx["stage_root"].mkdir(mode=0o700, parents=True)
    ctx["stage"].mkdir(mode=0o777)
    os.chmod(str(ctx["stage"]), 0o777)
    result = run(
        ["git", "clone", "--no-hardlinks", "--no-checkout", "--single-branch", "--branch", ctx["branch"], "--", str(wt), str(ctx["stage"])],
        env=cli_env(),
        capture=True,
    )
    if result.returncode:
        fail("could not create the private task-branch clone")
    if (ctx["stage"] / ".git" / "objects" / "info" / "alternates").exists():
        fail("private Git clone unexpectedly references shared host objects")
    if object_format == "sha256" and git(ctx["stage"], "rev-parse", "--show-object-format") != "sha256":
        fail("private Git clone object format changed")
    config_tmp = ctx["stage"] / ".git" / "config"
    if config_tmp.is_symlink():
        fail("private Git config is a symlink")
    config_tmp.unlink(missing_ok=True)
    write_private_config(ctx, origin, object_format, False)
    git(ctx["stage"], "reset", "--mixed", base)
    for path in paths:
        if states[path]["kind"] != "missing":
            copy_path(wt, ctx["stage"], path)
    if patch:
        git_bytes(ctx["stage"], "apply", "--cached", "--binary", "--whitespace=nowarn", "-", input_bytes=patch)
    if git(ctx["stage"], "write-tree") != index_tree:
        fail("private clone did not preserve the task worktree's staged index")
    project_hooks = copy_project_hooks(ctx)
    if project_hooks:
        write_private_config(ctx, origin, object_format, True)
    hook_script = ctx["stage"] / ".git" / "fm-openshell" / "fm-git-strip-ai-trailers.sh"
    hook_script.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(ctx["root"] / "bin" / "fm-git-strip-ai-trailers.sh"), str(hook_script))
    os.chmod(str(hook_script), 0o700)
    capability = ctx["stage"] / ".git" / "fm-openshell" / "fm-task-capability"
    shutil.copy2(str(ctx["root"] / "bin" / "fm-openshell-capability.py"), str(capability))
    os.chmod(str(capability), 0o700)
    setup = ctx["stage"] / ".git" / "fm-openshell" / "setup-hooks.sh"
    setup.write_text(
        "#!/bin/sh\nset -eu\n"
        "root=/sandbox/.git/fm-openshell\n"
        "if [ \"${FM_KEEP_AI_TRAILERS:-0}\" != 1 ]; then\n"
        "  \"$root/fm-git-strip-ai-trailers.sh\" install \"$root/task-hooks\" /sandbox\n"
        "fi\n",
        encoding="utf-8",
    )
    os.chmod(str(setup), 0o700)
    channel = ctx["stage"] / ".git" / "fm-openshell" / "channel"
    for name in ("inbox", "outbox", "responses"):
        (channel / name).mkdir(parents=True, exist_ok=True)
    (channel / "outbox" / "keep").write_text("OpenShell task channel\n", encoding="ascii")
    (channel / "responses" / "keep").write_text("OpenShell task channel\n", encoding="ascii")
    ctx["bridge_dir"].mkdir(mode=0o700)
    ctx["responses"].mkdir(mode=0o700)
    refresh_inbox_mirror(ctx, channel / "inbox")
    for root, dirs, files in os.walk(str(ctx["stage"]), followlinks=False):
        os.chmod(root, 0o777)
        for name in files:
            path = Path(root) / name
            if path.is_symlink():
                continue
            mode = stat.S_IMODE(path.stat().st_mode)
            os.chmod(str(path), 0o666 | (mode & 0o111))
    journal["phase"] = "prepared"
    journal["project_hooks"] = project_hooks
    write_journal(ctx, journal)
    return journal


def policy_file(ctx):
    ctx["policy"].write_text(
        "version: 1\n"
        "filesystem_policy:\n"
        "  include_workdir: false\n"
        "  read_only: [/usr, /lib, /bin, /etc, /proc, /dev/urandom, /var/log]\n"
        "  read_write: [/sandbox, /tmp, /dev/null]\n"
        "landlock:\n"
        "  compatibility: hard_requirement\n",
        encoding="utf-8",
    )
    os.chmod(str(ctx["policy"]), 0o600)


def sandbox_get(ctx):
    result = openshell_run(ctx, "sandbox", "get", ctx["sandbox"], "--output", "json", check=False)
    if result is None:
        fail("OpenShell CLI is unavailable")
    if result.returncode == 0:
        return True
    detail = ((result.stderr or b"") + (result.stdout or b"")).decode("utf-8", "replace").lower()
    if any(token in detail for token in SANDBOX_NOT_FOUND):
        return False
    fail("could not establish whether the task's named OpenShell sandbox exists: " + detail.strip()[:500])


def delete_sandbox(ctx):
    if not sandbox_get(ctx):
        return
    openshell_run(ctx, "sandbox", "delete", ctx["sandbox"])
    deadline = time.time() + 90
    while time.time() < deadline:
        if not sandbox_get(ctx):
            return
        time.sleep(1)
    fail("OpenShell accepted sandbox deletion but has not completed it; task artifacts were preserved")


def sandbox_phase(ctx):
    result = openshell_run(ctx, "sandbox", "get", ctx["sandbox"], "--output", "json")
    try:
        row = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeError, ValueError) as exc:
        fail("OpenShell returned malformed sandbox state: " + str(exc))
    phase = row.get("status", {}).get("phase") if isinstance(row, dict) else None
    if not isinstance(phase, str):
        fail("OpenShell sandbox state has no lifecycle phase")
    return phase.lower()


def wait_for_phase(ctx, wanted, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        phase = sandbox_phase(ctx)
        if phase == wanted.lower():
            return
        if phase in ("error", "deleting", "completed"):
            fail("OpenShell sandbox entered unexpected phase " + phase)
        time.sleep(1)
    fail("OpenShell sandbox did not reach phase " + wanted)


def stop_then_start_sandbox(ctx):
    if not sandbox_get(ctx):
        return
    phase = sandbox_phase(ctx)
    if phase != "stopped":
        openshell_run(ctx, "sandbox", "stop", ctx["sandbox"])
        wait_for_phase(ctx, "stopped")
    openshell_run(ctx, "sandbox", "start", ctx["sandbox"])
    wait_for_phase(ctx, "ready")


def stop_sandbox(ctx):
    if not sandbox_get(ctx):
        return
    if sandbox_phase(ctx) != "stopped":
        openshell_run(ctx, "sandbox", "stop", ctx["sandbox"])
        wait_for_phase(ctx, "stopped")


def workspace_archive(ctx):
    archive_path = ctx["stage_root"] / (".fm-openshell-workspace-" + secrets.token_hex(16) + ".tar")
    if archive_path.exists() or archive_path.is_symlink():
        fail("OpenShell workspace archive already exists")
    for root, dirs, files in os.walk(str(ctx["stage"]), followlinks=False):
        for name in list(dirs) + files:
            path = Path(root) / name
            info = path.lstat()
            rel = path.relative_to(ctx["stage"]).as_posix()
            if not rel or rel.startswith("/") or "\\" in rel or any(part in ("", ".", "..") for part in rel.split("/")):
                fail("task snapshot contains an unsupported archive path")
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                fail("task snapshot contains an unsupported archive entry at " + rel)
            if stat.S_ISLNK(info.st_mode) and name in dirs:
                dirs.remove(name)
    with tarfile.open(str(archive_path), mode="w", format=tarfile.PAX_FORMAT) as archive:
        archive.add(str(ctx["stage"]), arcname=".", recursive=True)
    os.chmod(str(archive_path), 0o600)
    return archive_path


def extract_workspace(ctx, archive_path):
    if not re.fullmatch(r"\.fm-openshell-workspace-[0-9a-f]{32}\.tar", archive_path.name):
        fail("OpenShell workspace archive has an invalid transfer name")
    extraction = (
        "import os,tarfile\n"
        "source='/sandbox/" + archive_path.name + "'\n"
        "target='/sandbox'\n"
        "if set(os.listdir(target)) != {os.path.basename(source)}:\n"
        " raise SystemExit('sandbox workspace is not empty before the task snapshot upload')\n"
        "with tarfile.open(source, 'r:*') as archive:\n"
        " members=archive.getmembers()\n"
        " entries={}\n"
        " symlinks=set()\n"
        " for member in members:\n"
        "  name=os.path.normpath(member.name)\n"
        "  if name in ('', '.'): continue\n"
        "  if name.startswith('/') or name == '..' or name.startswith('../') or '..' in name.split('/'):\n"
        "   raise SystemExit('workspace archive contains an escaping path')\n"
        "  if not (member.isdir() or member.isfile() or member.issym()):\n"
        "   raise SystemExit('workspace archive contains an unsupported file type')\n"
        "  if name in entries:\n"
        "   raise SystemExit('workspace archive contains a duplicate path')\n"
        "  entries[name]=member\n"
        "  if member.issym(): symlinks.add(name)\n"
        " for name,member in entries.items():\n"
        "  if any(name.startswith(link + '/') for link in symlinks):\n"
        "   raise SystemExit('workspace archive writes through a symlink')\n"
        "  parts=name.split('/')\n"
        "  current=target\n"
        "  for index,part in enumerate(parts):\n"
        "   current=os.path.join(current,part)\n"
        "   prefix='/'.join(parts[:index+1])\n"
        "   if index < len(parts)-1 and prefix in entries and not entries[prefix].isdir():\n"
        "    raise SystemExit('workspace archive has a non-directory parent')\n"
        "   if index < len(parts)-1 and os.path.lexists(current) and (os.path.islink(current) or not os.path.isdir(current)):\n"
        "    raise SystemExit('workspace destination has an unsafe parent')\n"
        "  if os.path.lexists(current):\n"
        "   raise SystemExit('workspace destination already contains task data')\n"
        " archive.extractall(target, members=members)\n"
        "os.unlink(source)\n"
    )
    openshell_run(
        ctx,
        "sandbox", "exec", "--name", ctx["sandbox"],
        "--workdir", WORKSPACE_IN_SANDBOX, "--no-login-shell", "--no-tty",
        "--", "python3", "-c", extraction,
    )
    archive_path.unlink()


def download_workspace(ctx, journal):
    download_root = ctx["stage_root"] / "download"
    seed = ctx["stage_root"] / "workspace-seed"
    for path in (download_root,):
        if path.is_symlink():
            fail("OpenShell download staging path is a symlink")
        if path.exists():
            if not path.is_dir():
                fail("OpenShell download staging path is not a directory")
            shutil.rmtree(str(path))
    if seed.is_symlink() or (seed.exists() and not seed.is_dir()):
        fail("OpenShell workspace recovery seed is unsafe")
    journal["phase"] = "downloading"
    write_journal(ctx, journal)
    download_root.mkdir(mode=0o700)
    try:
        openshell_run(ctx, "sandbox", "download", ctx["sandbox"], WORKSPACE_IN_SANDBOX, str(download_root))
        if (download_root / ".git").is_dir():
            candidate = download_root
        else:
            candidates = [item for item in download_root.iterdir() if item.is_dir() and (item / ".git").is_dir()]
            if len(candidates) != 1:
                fail("OpenShell download did not contain exactly one task Git workspace")
            candidate = candidates[0]
        if candidate.is_symlink() or not candidate.is_dir():
            fail("OpenShell returned an invalid task workspace directory")
        gitdir = candidate / ".git"
        if gitdir.is_symlink() or not gitdir.is_dir():
            fail("OpenShell snapshot omitted the task Git directory")
        if ctx["stage"].exists():
            if seed.exists():
                shutil.rmtree(str(seed))
            os.replace(str(ctx["stage"]), str(seed))
        os.replace(str(candidate), str(ctx["stage"]))
        journal["phase"] = "snapshot-downloaded"
        write_journal(ctx, journal)
    except Exception:
        if not ctx["stage"].exists() and seed.is_dir():
            os.replace(str(seed), str(ctx["stage"]))
        raise
    if seed.exists():
        shutil.rmtree(str(seed))
    if download_root.exists():
        shutil.rmtree(str(download_root))


def safe_inbox(ctx):
    path = ctx["state"] / (ctx["id"] + ".inbox")
    if path.is_symlink() or not path.is_dir():
        fail("assigned task inbox is missing or not a real directory")
    return path


def read_inbox(ctx, name):
    if not INBOX_NAME_RE.fullmatch(name):
        fail("inbox message name must be a numeric .msg basename")
    path = safe_inbox(ctx) / name
    if path.is_symlink():
        fail("refusing to read an inbox symlink")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_REQUEST:
            fail("inbox message is not a bounded regular file")
        chunks = []
        total = 0
        while True:
            data = os.read(fd, min(65536, MAX_REQUEST + 1 - total))
            if not data:
                break
            chunks.append(data)
            total += len(data)
            if total > MAX_REQUEST:
                fail("inbox message exceeds the capability size limit")
    finally:
        os.close(fd)
    return b"".join(chunks).decode("utf-8")


def inbox_list(ctx):
    root = safe_inbox(ctx)
    entries = []
    for item in root.iterdir():
        if not INBOX_NAME_RE.fullmatch(item.name):
            continue
        if item.is_symlink() or not item.is_file():
            fail("assigned inbox contains an unsafe .msg entry")
        entries.append(item.name)
    entries.sort(key=lambda name: (int(name[:-4]), name))
    return "".join(name + "\n" for name in entries)


def inbox_ack(ctx, name):
    if not INBOX_NAME_RE.fullmatch(name):
        fail("inbox message name must be a numeric .msg basename")
    root = safe_inbox(ctx)
    handled = root / "handled"
    if handled.is_symlink():
        fail("assigned inbox handled directory is a symlink")
    if not handled.exists():
        handled.mkdir(mode=0o700)
    if not handled.is_dir():
        fail("assigned inbox handled path is not a directory")
    source, dest = root / name, handled / name
    if source.is_symlink() or not source.is_file():
        fail("assigned inbox message is missing or unsafe")
    if dest.exists() or dest.is_symlink():
        fail("handled inbox destination already exists; refusing to overwrite it")
    os.rename(str(source), str(dest))
    return "acknowledged " + name


def status_append(ctx, line):
    if len(line.encode("utf-8")) > MAX_STATUS_LINE or not STATUS_RE.fullmatch(line):
        fail("status line does not match the one-line task event format")
    path = ctx["state"] / (ctx["id"] + ".status")
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail("task status path is not a regular file")
        fcntl.flock(fd, fcntl.LOCK_EX)
        payload = (line + "\n").encode("utf-8")
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                fail("could not append the complete task status line")
            offset += written
        os.fsync(fd)
    finally:
        os.close(fd)
    if (ctx["config"] / "fleet-ledger").exists():
        run(
            [str(ctx["root"] / "bin" / "fm-fleet-ledger.sh"), "appended", str(ctx["config"]), str(path)],
            env={**os.environ, "FM_HOME": str(ctx["home"]), "FM_STATE_OVERRIDE": str(ctx["state"]), "FM_CONFIG_OVERRIDE": str(ctx["config"])},
            capture=True,
            check=False,
        )
    return "appended task status"


def turn_ended(ctx):
    path = ctx["state"] / (ctx["id"] + ".turn-ended")
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail("task turn-ended marker is not a regular file")
        os.utime(fd, None)
    finally:
        os.close(fd)
    return ""


def atomic_write(path, payload, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        fail("refusing to replace a symlinked task channel file")
    fd, temp_name = tempfile.mkstemp(prefix=".fm-openshell-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, str(path))
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def refresh_inbox_mirror(ctx, stage_inbox=None):
    mirror = ctx["channel"]
    mirror.mkdir(mode=0o700, parents=True, exist_ok=True)
    names = inbox_list(ctx).splitlines()
    wanted = set(names)
    for item in mirror.iterdir():
        if item.name.endswith(".msg"):
            if item.is_symlink() or not item.is_file():
                fail("task channel inbox mirror contains an unsafe message")
            if item.name not in wanted:
                item.unlink()
    for name in names:
        payload = read_inbox(ctx, name).encode("utf-8")
        atomic_write(mirror / name, payload, 0o600)
    index = ("".join(name + "\n" for name in names)).encode("ascii")
    atomic_write(mirror / "index.txt", index, 0o600)
    fingerprint = hashlib.sha256(index)
    for name in names:
        fingerprint.update(name.encode("ascii") + b"\0")
        fingerprint.update(hashlib.sha256((mirror / name).read_bytes()).digest())
    if stage_inbox is not None:
        stage_inbox.mkdir(mode=0o777, parents=True, exist_ok=True)
        for item in stage_inbox.iterdir():
            if item.name.endswith(".msg") or item.name == "index.txt":
                if item.is_symlink() or not item.is_file():
                    fail("sandbox task inbox snapshot contains an unsafe file")
                item.unlink()
        for name in names:
            shutil.copyfile(str(mirror / name), str(stage_inbox / name))
            os.chmod(str(stage_inbox / name), 0o666)
        shutil.copyfile(str(mirror / "index.txt"), str(stage_inbox / "index.txt"))
        os.chmod(str(stage_inbox / "index.txt"), 0o666)
    return fingerprint.hexdigest()


def validate_workspace(name, workspace_id):
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,17}[a-z0-9])?", name):
        fail("task has a missing or invalid OpenShell workspace name")
    if not isinstance(workspace_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", workspace_id):
        fail("task has a missing or invalid OpenShell workspace ID")


def workspace_identity(gateway, name):
    validate_workspace(name, "lookup")
    result = run(["openshell", "--gateway", gateway, "--workspace", name,
                  "--color", "never", "workspace", "get", name], capture=True)
    text = result.stdout.decode("utf-8", "strict")
    names = re.findall(r"^  Name: (\S+)\s*$", text, re.MULTILINE)
    ids = re.findall(r"^  Id: (\S+)\s*$", text, re.MULTILINE)
    if names != [name] or len(ids) != 1:
        fail("OpenShell could not establish the exact selected workspace identity")
    validate_workspace(name, ids[0])
    return ids[0]


def openshell_argv(ctx, *args):
    validate_workspace(ctx.get("workspace"), ctx.get("workspace_id"))
    if workspace_identity(ctx["gateway"], ctx["workspace"]) != ctx["workspace_id"]:
        fail("OpenShell workspace ID differs from the task's recorded identity")
    return ["openshell", "--gateway", ctx["gateway"], "--workspace", ctx["workspace"], *args]


def openshell_run(ctx, *args, capture=True, check=True, input_bytes=None):
    return run(openshell_argv(ctx, *args), capture=capture, check=check, input_bytes=input_bytes)


def ensure_no_global_policy(ctx):
    token = ""
    seen_tokens = set()
    while True:
        command = ["policy", "list", "--global", "--output", "json"]
        if token:
            command.extend(["--page-token", token])
        result = openshell_run(ctx, *command, check=False)
        if result is None or result.returncode:
            fail("could not establish whether the selected OpenShell gateway has a global policy")
        try:
            data = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeError, ValueError) as exc:
            fail("OpenShell returned malformed global policy history: " + str(exc))
        revisions = data.get("revisions") if isinstance(data, dict) else None
        if not isinstance(revisions, list):
            fail("OpenShell global policy history has an unsupported response shape")
        for revision in revisions:
            if not isinstance(revision, dict) or str(revision.get("status", "")).lower() != "superseded":
                fail("the selected OpenShell gateway has an active or unverified global policy; per-task filesystem and provider rules cannot be guaranteed")
        next_token = data.get("next_page_token") or ""
        if not isinstance(next_token, str):
            fail("OpenShell returned an invalid global policy page token")
        if not next_token:
            return
        if next_token in seen_tokens:
            fail("OpenShell repeated a global policy history page token")
        seen_tokens.add(next_token)
        token = next_token


def upload_file(ctx, source, destination):
    openshell_run(ctx, "sandbox", "upload", "--no-git-ignore", ctx["sandbox"], str(source), destination)


def upload_files(ctx, source_dir, destination_dir):
    if source_dir.is_symlink() or not source_dir.is_dir():
        fail("OpenShell transfer source is not a real directory")
    for item in sorted(source_dir.iterdir(), key=lambda path: os.fsencode(path.name)):
        if item.is_symlink() or not item.is_file():
            fail("OpenShell transfer source contains an unsafe entry")
        upload_file(ctx, item, destination_dir)


def channel_request(ctx, request_id, request):
    if request_id in ctx["processed_requests"]:
        return
    response = {"ok": True, "text": ""}
    try:
        op = request.get("op") if isinstance(request, dict) else None
        if op == "inbox.ack" and set(request) == {"op", "name"} and isinstance(request["name"], str):
            text = inbox_ack(ctx, request["name"])
            refresh_inbox_mirror(ctx)
        elif op == "validation.request" and set(request) == {"op"}:
            journal = read_journal(ctx)
            if not journal or journal.get("phase") != "agent-running":
                fail("host validation can only be requested by the running task")
            journal["validation_requested"] = True
            write_journal(ctx, journal)
            ctx["validation_requested"] = True
            text = "host validation handoff requested; this sandbox session will end"
        elif op == "status.append" and set(request) == {"op", "line"} and isinstance(request["line"], str):
            if request["line"].startswith("done "):
                fail("use validation request; the host reports readiness after synchronization")
            text = status_append(ctx, request["line"])
        elif op == "turn-ended" and set(request) == {"op"}:
            text = turn_ended(ctx)
        else:
            fail("capability is not allowlisted")
        response["text"] = text
    except (Refusal, OSError, UnicodeError, ValueError, TypeError) as exc:
        response = {"ok": False, "error": str(exc)}
    atomic_write(ctx["responses"] / (request_id + ".json"), (json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
    ctx["processed_requests"].add(request_id)


def download_outbox(ctx):
    temp_root = Path(tempfile.mkdtemp(prefix="fm-openshell-poll-", dir=str(ctx["bridge_dir"])))
    target = temp_root / "outbox"
    try:
        openshell_run(
            ctx,
            "sandbox", "download", ctx["sandbox"],
            CHANNEL_IN_SANDBOX + "/outbox", str(target),
        )
        candidate = target / "outbox" if (target / "outbox").is_dir() else target
        if candidate.is_symlink() or not candidate.is_dir():
            fail("OpenShell returned an invalid task channel directory")
        requests = {}
        for item in candidate.iterdir():
            if item.name == "keep":
                continue
            if re.fullmatch(r"[0-9a-f]{32}\.tmp", item.name):
                continue
            match = re.fullmatch(r"([0-9a-f]{32})\.json", item.name)
            if not match:
                fail("sandbox task channel contains an unexpected request file")
            if item.is_symlink() or not item.is_file() or item.stat().st_size > 8192:
                fail("sandbox task channel request is unsafe or too large")
            try:
                requests[match.group(1)] = json.loads(item.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, ValueError) as exc:
                requests[match.group(1)] = {"invalid": str(exc)}
        return requests
    finally:
        shutil.rmtree(str(temp_root), ignore_errors=True)


def sync_channels(ctx):
    fingerprint = refresh_inbox_mirror(ctx)
    if fingerprint != ctx.get("inbox_fingerprint"):
        upload_files(ctx, ctx["channel"], CHANNEL_IN_SANDBOX + "/inbox")
        ctx["inbox_fingerprint"] = fingerprint
    requests = download_outbox(ctx)
    for request_id, request in requests.items():
        channel_request(ctx, request_id, request)
    pending_responses = [ctx["responses"] / (request_id + ".json") for request_id in requests]
    pending_responses = [path for path in pending_responses if path.is_file() and not path.is_symlink()]
    if pending_responses:
        upload_files(ctx, ctx["responses"], CHANNEL_IN_SANDBOX + "/responses")
    current = set(requests)
    for item in list(ctx["responses"].iterdir()):
        match = re.fullmatch(r"([0-9a-f]{32})\.json", item.name)
        if match and match.group(1) not in current and not item.is_symlink() and item.is_file():
            item.unlink()
            ctx["processed_requests"].discard(match.group(1))


def encoded_prompt(ctx, brief_path):
    path = Path(brief_path)
    if path.is_symlink() or not path.is_file():
        fail("task launch brief is missing or unsafe")
    body = path.read_text(encoding="utf-8")
    overlay = (
        "# OpenShell task channels\n\n"
        "This worker runs inside an OpenShell sandbox. Host paths named below are not mounted. "
        "This channel overlay takes precedence for inbox, status, and turn-end operations. "
        "The host relays these exact operations through OpenShell's sandbox file-transfer API.\n\n"
        "For no-mistakes delivery, this overlay also replaces host setup and validation instructions. "
        "Do not run no-mistakes doctor, init, or validation inside the sandbox. "
        "Implement the task, commit all project changes on the assigned branch, and leave a clean worktree. "
        f"Then run `{CAPABILITY_IN_SANDBOX} validation request` instead of appending done. "
        "This ends this sandbox session. The host synchronizes the committed tracked files before "
        "reporting readiness, and firstmate runs the explicit host validation command described in "
        "docs/openshell-codex.md with the task's authoritative intent. The registered forge contract "
        "still applies: Gerrit validation skips exactly push,pr,ci and its later publication stays on "
        "the host; other registered forges receive no additional skips. Do not push from the sandbox.\n\n"
        "Read the assigned steering messages in numeric order with "
        f"`{CAPABILITY_IN_SANDBOX} inbox list`, read each with "
        f"`{CAPABILITY_IN_SANDBOX} inbox read NNN.msg`, then acknowledge it with "
        f"`{CAPABILITY_IN_SANDBOX} inbox ack NNN.msg`. The channel contains only this task's inbox.\n\n"
        "Append a status event with "
        f"`{CAPABILITY_IN_SANDBOX} status append '<one status line>'`. "
        "The host appends it to this task's exact status stream and updates the fleet ledger when enabled. "
        "Do not try to write host paths or task markers directly. Codex turn-end notification is already "
        "wired to the one fixed marker for this task.\n\n"
    )
    # Keep the task's words and captain intent intact; this is an operational
    # channel overlay, not a rewrite of the underlying brief.
    result = run(
        [str(ctx["root"] / "bin" / "fm-operational-input.sh"), "encode", "launch-brief"],
        env={**os.environ, "FM_HOME": str(ctx["home"]), "FM_STATE_OVERRIDE": str(ctx["state"]), "FM_ROOT_OVERRIDE": str(ctx["root"])},
        input_bytes=(overlay + body).encode("utf-8"),
        capture=True,
    )
    # The canonical encoder owns the exact wire spelling; its stdin handling
    # also preserves embedded newlines from the original brief.
    return result.stdout.decode("utf-8").rstrip("\n")


def create_sandbox(ctx, journal):
    if sandbox_get(ctx):
        fail("the exact task OpenShell sandbox already exists; refusing to attach or overwrite it")
    command = [
        "sandbox", "create", "--name", ctx["sandbox"], "--from", "base",
        "--policy", str(ctx["policy"]), "--detach", "--no-auto-providers",
    ]
    for provider in ctx["providers"]:
        command.extend(["--provider", provider])
    command.extend(["--output", "json", "--", "/bin/sleep", "infinity"])
    openshell_run(ctx, *command)
    ctx["sandbox_owned"] = True
    journal["phase"] = "sandbox-created"
    write_journal(ctx, journal)
    archive_path = workspace_archive(ctx)
    upload_file(ctx, archive_path, "/sandbox")
    extract_workspace(ctx, archive_path)
    journal["phase"] = "workspace-uploaded"
    write_journal(ctx, journal)
    ctx["inbox_fingerprint"] = refresh_inbox_mirror(ctx)


def setup_sandbox(ctx, journal):
    setup = [
        "sandbox", "exec", "--name", ctx["sandbox"],
        "--workdir", WORKSPACE_IN_SANDBOX, "--no-login-shell", "--no-tty",
        "--env", "FM_KEEP_AI_TRAILERS=" + ("1" if journal.get("keep_ai_trailers") == "1" else "0"),
        "--", "/bin/sh", CAPABILITY_IN_SANDBOX.rsplit("/", 1)[0] + "/setup-hooks.sh",
    ]
    openshell_run(ctx, *setup)


def run_codex(ctx, journal, prompt, model, effort):
    args = [
        "sandbox", "exec", "--name", ctx["sandbox"],
        "--workdir", WORKSPACE_IN_SANDBOX, "--no-login-shell", "--tty",
    ]
    agent_env = {
        "CODEX_HOME": "/tmp/fm-codex-home",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    }
    for key in ("user_name", "user_email"):
        value = journal.get(key, "")
        if value:
            agent_env["GIT_AUTHOR_NAME" if key == "user_name" else "GIT_AUTHOR_EMAIL"] = value
            agent_env["GIT_COMMITTER_NAME" if key == "user_name" else "GIT_COMMITTER_EMAIL"] = value
    if journal.get("keep_ai_trailers") != "1":
        agent_env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": HOOKS_IN_SANDBOX})
    for key, value in agent_env.items():
        args.extend(["--env", key + "=" + value])
    model = "gpt-6.1-sol" if not model or model == "default" else model
    effort = "medium" if not effort or effort == "default" else effort
    codex_args = ["codex", "--model", model]
    if effort in ("low", "medium", "high", "xhigh"):
        codex_args.extend(["-c", "model_reasoning_effort=\"" + effort + "\""])
    elif effort == "max" and model == "gpt-5.6-luna":
        codex_args.extend(["-c", 'model_reasoning_effort="max"'])
    codex_args.extend(
        [
            "--dangerously-bypass-approvals-and-sandbox",
            "--disable",
            "hooks",
            "-c",
            'notify=["' + CAPABILITY_IN_SANDBOX + '","turn-ended"]',
            prompt,
        ]
    )
    command = openshell_argv(ctx, *args, "--", *codex_args)
    journal["phase"] = "agent-running"
    write_journal(ctx, journal)
    ctx["processed_requests"] = set()
    process = subprocess.Popen(command, env=os.environ.copy())
    try:
        next_sync = 0.0
        while process.poll() is None:
            now = time.monotonic()
            if now >= next_sync:
                sync_channels(ctx)
                if ctx.get("validation_requested"):
                    journal["validation_requested"] = True
                    write_journal(ctx, journal)
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    break
                next_sync = now + 1.0
            time.sleep(0.1)
        result = process.wait()
        sync_channels(ctx)
        if ctx.get("validation_requested"):
            journal["validation_requested"] = True
            write_journal(ctx, journal)
            return 0
        return result
    except Exception:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise


def verify_stage(ctx, journal):
    stage = ctx["stage"]
    gitdir = stage / ".git"
    if gitdir.is_symlink() or not gitdir.is_dir():
        fail("sandbox removed or replaced the private Git directory")
    for root, dirs, files in os.walk(str(gitdir), followlinks=False):
        for name in dirs + files:
            path = Path(root) / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                fail("sandbox Git metadata contains an unsafe filesystem entry")
    for rel in ("objects", "refs", "HEAD", "config", "index"):
        path = gitdir / rel
        if path.is_symlink():
            fail("sandbox replaced private Git metadata with a symlink")
    for rel in ("objects/info/alternates", "objects/info/http-alternates", "shallow", "info/grafts"):
        if (gitdir / rel).exists() or (gitdir / rel).is_symlink():
            fail("sandbox Git metadata contains an external object reference")
    head_file = gitdir / "HEAD"
    if not head_file.is_file() or head_file.read_text(encoding="ascii").strip() != "ref: refs/heads/" + ctx["branch"]:
        fail("sandbox changed the task branch identity")
    write_private_config(ctx, journal.get("origin", ""), journal.get("object_format", "sha1"), bool(journal.get("project_hooks")))
    if git(stage, "ls-files", "-u"):
        fail("sandbox left unresolved Git index entries")
    head = git(stage, "rev-parse", "HEAD")
    result = run(["git", "-C", str(stage), "merge-base", "--is-ancestor", journal["base_head"], head], env=cli_env(), capture=True, check=False)
    if result is None or result.returncode:
        fail("sandbox task branch is not a fast-forward from its launch point")
    patch = git_bytes(stage, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD") or b""
    paths = git_paths(stage)
    states = snapshot(stage, paths)
    return head, patch, paths, states


def task_index_path(wt):
    value = git(wt, "rev-parse", "--path-format=absolute", "--git-path", "index")
    path = Path(value)
    if path.is_symlink() or not path.is_file():
        fail("assigned worktree index is missing or unsafe")
    return path


def check_host_unchanged(ctx, journal):
    wt = ctx["worktree"]
    if git(wt, "rev-parse", "HEAD") != journal["base_head"]:
        fail("task branch moved while Codex was in OpenShell; sandbox changes were preserved")
    if git(wt, "write-tree") != journal["base_index_tree"]:
        fail("task index changed while Codex was in OpenShell; sandbox changes were preserved")
    paths = git_paths(wt)
    if paths != journal["base_paths"] or snapshot(wt, paths) != journal["base_files"]:
        fail("task worktree changed outside its OpenShell copy; sandbox changes were preserved")


def backup_host(ctx, journal):
    backup = ctx["stage_root"] / "host-backup"
    if backup.is_symlink():
        fail("task recovery backup is unsafe")
    if backup.exists():
        if journal.get("phase") != "snapshot-downloaded" or not backup.is_dir():
            fail("task recovery backup already exists")
        check_host_unchanged(ctx, journal)
        shutil.rmtree(str(backup))
    backup.mkdir(mode=0o700)
    (backup / "files").mkdir(mode=0o700)
    for path in journal["base_paths"]:
        if journal["base_files"][path]["kind"] != "missing":
            copy_path(ctx["worktree"], backup / "files", path, journal["base_files"])
    shutil.copy2(str(task_index_path(ctx["worktree"])), str(backup / "index"))
    return backup


def restore_host(ctx, journal, backup, final_head=None):
    wt = ctx["worktree"]
    baseline = set(journal["base_paths"])
    paths = baseline | set(journal.get("sync_paths", []))
    current_states = snapshot(wt, sorted(paths, key=os.fsencode))
    for path in sorted(paths, key=os.fsencode):
        actual = current_states[path]
        baseline_state = journal["base_files"].get(path, {"kind": "missing"})
        expected = journal.get("sync_files", {}).get(path, {"kind": "missing"})
        if not same_content(actual, baseline_state) and not same_content(actual, expected):
            fail("task worktree changed during OpenShell rollback; preserving recovery artifacts")
    if final_head and final_head != journal["base_head"]:
        current = git(wt, "rev-parse", "refs/heads/" + ctx["branch"])
        if current == final_head:
            run(["git", "-C", str(wt), "update-ref", "refs/heads/" + ctx["branch"], journal["base_head"], final_head], env=cli_env(), capture=True)
        elif current != journal["base_head"]:
            fail("task branch changed during OpenShell rollback; preserving recovery artifacts")
    run(["git", "-C", str(wt), "read-tree", journal["base_head"]], env=cli_env(), capture=True)
    apply_files(backup / "files", wt, paths, journal["base_files"], journal["base_files"], current_states)
    shutil.copy2(str(backup / "index"), str(task_index_path(wt)))


def sync_workspace(ctx, journal):
    head, staged_patch, paths, states = verify_stage(ctx, journal)
    if journal.get("validation_requested"):
        require_committed_workspace(ctx["stage"])
    check_host_unchanged(ctx, journal)
    backup = backup_host(ctx, journal)
    journal["phase"] = "syncing"
    journal["sync_head"] = head
    journal["sync_paths"] = paths
    journal["sync_files"] = states
    write_journal(ctx, journal)
    temporary_ref = "refs/fm-openshell/" + hashlib.sha256((ctx["id"] + str(ctx["home"])).encode()).hexdigest()[:32]
    branch_ref = "refs/heads/" + ctx["branch"]
    updated = False
    try:
        run(
            ["git", "-C", str(ctx["worktree"]), "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--no-write-fetch-head", str(ctx["stage"]), "+" + branch_ref + ":" + temporary_ref],
            env=cli_env(), capture=True,
        )
        fetched = git(ctx["worktree"], "rev-parse", temporary_ref)
        if fetched != head:
            fail("sandbox branch object transfer did not match its recorded HEAD")
        if head != journal["base_head"]:
            run(["git", "-C", str(ctx["worktree"]), "update-ref", branch_ref, head, journal["base_head"]], env=cli_env(), capture=True)
            updated = True
        run(["git", "-C", str(ctx["worktree"]), "read-tree", head], env=cli_env(), capture=True)
        if staged_patch:
            run(["git", "-C", str(ctx["worktree"]), "apply", "--cached", "--binary", "--whitespace=nowarn", "-"], env=cli_env(), input_bytes=staged_patch, capture=True)
        present = {path for path in paths if states[path]["kind"] != "missing"}
        obsolete = set(journal["base_paths"]) - set(paths)
        for path in set(paths) - present:
            if any(other.startswith(path + "/") or path.startswith(other + "/") for other in present):
                obsolete.add(path)
        all_paths = present | obsolete
        apply_files(ctx["stage"], ctx["worktree"], all_paths, states, journal["base_files"], journal["base_files"])
        run(["git", "-C", str(ctx["worktree"]), "update-ref", "-d", temporary_ref], env=cli_env(), capture=True, check=False)
        journal["phase"] = "synced"
        if journal.get("validation_requested"):
            journal["validation_head"] = head
        for key in ("sync_head", "sync_paths", "sync_files"):
            journal.pop(key, None)
        write_journal(ctx, journal)
    except Exception:
        try:
            restore_host(ctx, journal, backup, head if updated else None)
            run(["git", "-C", str(ctx["worktree"]), "update-ref", "-d", temporary_ref], env=cli_env(), capture=True, check=False)
            journal["phase"] = "snapshot-downloaded"
            for key in ("sync_head", "sync_paths", "sync_files"):
                journal.pop(key, None)
            write_journal(ctx, journal)
            shutil.rmtree(str(backup))
        except Exception as rollback_error:
            fail("OpenShell worktree sync failed and rollback is incomplete: " + str(rollback_error))
        raise
    shutil.rmtree(str(backup))


def cleanup_artifacts(ctx):
    if sandbox_get(ctx):
        fail("the task's OpenShell sandbox still exists; refusing to remove its workspace")
    journal = read_journal(ctx)
    if journal and journal.get("phase") != "synced":
        fail("OpenShell task data is not synchronized; refusing to remove its workspace")
    for path in (ctx["stage_root"], ctx["bridge_dir"], ctx["policy"], ctx["journal"]):
        if path.is_symlink():
            fail("refusing to remove a symlinked OpenShell task artifact")
        if path.is_dir():
            shutil.rmtree(str(path))
        else:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def run_task(task_id, brief_path, model, effort):
    ctx = load_context(task_id)
    if sys.platform != "linux":
        fail("the Herdr OpenShell Codex path currently requires a Linux worker host")
    for binary in ("openshell", "git"):
        if not shutil.which(binary):
            fail(binary + " is unavailable; configured OpenShell execution fails closed")
    journal = read_journal(ctx)
    if journal:
        fail("OpenShell task artifacts already exist; recover them before relaunching")
    prompt = encoded_prompt(ctx, brief_path)
    print("fm-openshell-codex: preparing the task's OpenShell sandbox", flush=True)
    status_append(ctx, "working [at=" + str(int(time.time())) + "]: preparing the OpenShell Codex sandbox")
    ensure_no_global_policy(ctx)
    journal = prepare_workspace(ctx)
    policy_file(ctx)
    try:
        create_sandbox(ctx, journal)
        setup_sandbox(ctx, journal)
        agent_rc = run_codex(ctx, journal, prompt, model, effort)
        journal["phase"] = "agent-exited"
        write_journal(ctx, journal)
        stop_then_start_sandbox(ctx)
        download_workspace(ctx, journal)
        sync_workspace(ctx, journal)
        delete_sandbox(ctx)
        publish_validation_handoff(ctx, journal)
        cleanup_artifacts(ctx)
        return agent_rc
    except BaseException:
        if ctx.get("sandbox_owned"):
            try:
                stop_sandbox(ctx)
            except Exception as stop_error:
                print("fm-openshell-codex: could not confirm sandbox stop; recovery artifacts remain: " + str(stop_error), file=sys.stderr)
        raise


def require_committed_workspace(worktree):
    if git(worktree, "status", "--porcelain", "--untracked-files=all"):
        fail("host validation handoff requires committed tracked changes and a clean worktree")


def publish_validation_handoff(ctx, journal):
    if not journal.get("validation_requested"):
        return
    if journal.get("phase") != "synced":
        fail("host validation handoff requires a synchronized task snapshot")
    require_committed_workspace(ctx["worktree"])
    head = git(ctx["worktree"], "rev-parse", "HEAD")
    if head != journal.get("validation_head"):
        fail("host validation handoff HEAD differs from the synchronized snapshot")
    record = {"task_id": ctx["id"], "worktree": str(ctx["worktree"]), "branch": ctx["branch"],
              "head": head, "gateway": ctx["gateway"],
              "workspace": ctx["workspace"], "workspace_id": ctx["workspace_id"]}
    atomic_write(ctx["validation"], (json.dumps(record, sort_keys=True) + "\n").encode("utf-8"))
    status_append(ctx, "done [at=" + str(int(time.time())) + "]: committed OpenShell snapshot ready for host validation at " + head)


def validate_task(task_id, intent_file):
    ctx = load_context(task_id, require_live=False)
    endpoint_agent_free(ctx)
    guard_task(task_id)
    path = ctx["validation"]
    if path.is_symlink() or not path.is_file():
        fail("task has no safe host validation handoff record")
    record = json.loads(path.read_text(encoding="utf-8"))
    expected = {"task_id": ctx["id"], "worktree": str(ctx["worktree"]), "branch": ctx["branch"],
                "head": git(ctx["worktree"], "rev-parse", "HEAD"),
                "gateway": ctx["gateway"], "workspace": ctx["workspace"], "workspace_id": ctx["workspace_id"]}
    if record != expected or git(ctx["worktree"], "symbolic-ref", "--short", "HEAD") != ctx["branch"]:
        fail("host validation handoff does not match the task's current identity and HEAD")
    require_committed_workspace(ctx["worktree"])
    intent_path = Path(intent_file)
    if intent_path.is_symlink() or not intent_path.is_file():
        fail("host validation requires a regular task intent file")
    intent = intent_path.read_text(encoding="utf-8")
    if not intent.strip():
        fail("host validation requires the task's authoritative intent")
    project = Path(ctx["values"].get("project", ""))
    if not project.is_absolute():
        fail("host validation requires the task's recorded project")
    result = run(["bash", str(ctx["root"] / "bin" / "fm-project-mode.sh"), "--forge", project.name],
                 env={**os.environ, "FM_HOME": str(ctx["home"]), "FM_ROOT_OVERRIDE": str(ctx["root"])}, capture=True)
    forge = result.stdout.decode("utf-8").strip()
    if forge not in ("none", "gerrit"):
        fail("task project has an unsupported registered forge")
    command = ["no-mistakes", "axi", "run", "--intent", intent]
    if forge == "gerrit":
        command.extend(["--skip", "push,pr,ci"])
    result = run(command,
                 cwd=ctx["worktree"], env=os.environ.copy(), capture=False, check=False)
    if result is None:
        fail("no-mistakes is unavailable on the host")
    return result.returncode


def endpoint_agent_free(ctx):
    target = ctx["values"].get("window", "")
    if not target:
        fail("task metadata has no Herdr endpoint target")
    command = (
        '. "$FM_ROOT_OVERRIDE/bin/fm-backend.sh"; '
        'fm_backend_source herdr >/dev/null || exit 3; '
        'fm_backend_agent_state herdr "$TASK_TARGET"'
    )
    result = run(
        ["bash", "-lc", command],
        env={**os.environ, "FM_HOME": str(ctx["home"]), "FM_STATE_OVERRIDE": str(ctx["state"]), "FM_ROOT_OVERRIDE": str(ctx["root"]), "TASK_TARGET": target},
        capture=True,
        check=False,
    )
    state = "" if result is None else (result.stdout or b"").decode("utf-8", "replace").strip()
    if state not in ("dead", "missing"):
        fail("recover requires this task's Herdr endpoint to be proven dead or missing; state=" + (state or "unreadable"))


def recover_task(task_id):
    ctx = load_context(task_id, require_live=False)
    endpoint_agent_free(ctx)
    journal = read_journal(ctx)
    exists = sandbox_get(ctx)
    if journal is None:
        if exists:
            fail("sandbox exists without its task recovery journal; preserve it for manual inspection")
        return
    phase = journal.get("phase")
    if phase != "synced":
        ctx = load_context(task_id)
    if phase in ("preparing", "prepared") and exists:
        fail("an OpenShell sandbox exists before its ownership was recorded; preserve it for manual inspection")
    if phase in ("preparing", "prepared", "sandbox-created", "workspace-uploaded"):
        if exists:
            delete_sandbox(ctx)
        journal["phase"] = "synced"
        write_journal(ctx, journal)
        cleanup_artifacts(ctx)
        print("discarded incomplete OpenShell setup before Codex started for " + task_id)
        return
    if phase not in ("agent-running", "agent-exited", "downloading", "snapshot-downloaded", "syncing", "synced"):
        fail("OpenShell recovery journal has an unsupported phase " + str(phase))
    if phase in ("agent-running", "agent-exited", "downloading") and not exists:
        fail("OpenShell sandbox disappeared before its workspace snapshot was recovered; preserving task artifacts")
    recovering_sync = phase == "syncing"
    if recovering_sync:
        backup = ctx["stage_root"] / "host-backup"
        if not backup.is_dir() or backup.is_symlink():
            fail("OpenShell sync was interrupted without a complete rollback backup")
        restore_host(ctx, journal, backup, journal.get("sync_head"))
        journal["phase"] = "snapshot-downloaded"
        for key in ("sync_head", "sync_paths", "sync_files"):
            journal.pop(key, None)
        write_journal(ctx, journal)
        shutil.rmtree(str(backup))
    if exists and phase != "synced":
        stop_then_start_sandbox(ctx)
        download_workspace(ctx, journal)
    if journal.get("phase") != "synced":
        sync_workspace(ctx, journal)
    if exists:
        delete_sandbox(ctx)
    publish_validation_handoff(ctx, journal)
    cleanup_artifacts(ctx)
    print("recovered the OpenShell worktree snapshot for " + task_id)


def guard_task(task_id):
    ctx = load_context(task_id, require_live=False)
    journal = read_journal(ctx)
    if sandbox_get(ctx):
        fail("task has a retained OpenShell sandbox; recover it before teardown")
    if journal and journal.get("phase") != "synced":
        fail("task has an unsynchronized OpenShell worktree; recover it before teardown")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("task_id")
    run_parser.add_argument("brief")
    run_parser.add_argument("--model", default="gpt-6.1-sol")
    run_parser.add_argument("--effort", default="medium")
    workspace_parser = sub.add_parser("workspace-id")
    workspace_parser.add_argument("gateway")
    workspace_parser.add_argument("workspace")
    validate_parser = sub.add_parser("validate")
    validate_parser.add_argument("task_id")
    validate_parser.add_argument("--intent-file", required=True)
    sub.add_parser("recover").add_argument("task_id")
    sub.add_parser("guard").add_argument("task_id")
    sub.add_parser("cleanup").add_argument("task_id")
    args = parser.parse_args()
    try:
        if args.action == "workspace-id":
            print(workspace_identity(args.gateway, args.workspace))
            return 0
        if args.action == "run":
            return run_task(args.task_id, args.brief, args.model, args.effort)
        if args.action == "validate":
            return validate_task(args.task_id, args.intent_file)
        if args.action == "recover":
            recover_task(args.task_id)
            return 0
        if args.action == "guard":
            guard_task(args.task_id)
            return 0
        if args.action == "cleanup":
            ctx = load_context(args.task_id, require_live=False)
            cleanup_artifacts(ctx)
            return 0
    except Refusal as exc:
        print("fm-openshell-codex: " + str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("fm-openshell-codex: interrupted; task artifacts are preserved for recovery", file=sys.stderr)
        return 130
    except Exception as exc:
        print("fm-openshell-codex: unexpected failure; task artifacts are preserved: " + str(exc), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
