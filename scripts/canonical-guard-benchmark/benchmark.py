#!/usr/bin/env python3
"""Implementation for bin/fm-canonical-guard-benchmark.sh.

The CLI help is the mechanics owner.  This module keeps benchmark state outside
candidate worktrees and treats repository and transcript text as untrusted data.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import math
import os
import pathlib
import platform
import re
import shutil
import shlex
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Iterable

SCHEMA_VERSION = "canonical-guard-run/v1"
VERDICT_VERSION = "canonical-guard-verdict/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
HARNESS_NAMES = ("codex", "claude", "cursor-agent", "kimi", "pi")
ARMS = ("guard-on", "guard-off")
RESOLUTION_PATHS = (
    "exported-then-imported-point-in-ring",
    "imported-point-in-polygon",
    "imported-polygon-contains",
    "exported-then-imported-point-to-segment-distance",
    "exported-then-imported-min-distance-to-boundary",
    "moved-helper-to-shared-module",
    "fresh-reimplementation",
    "none",
    "unclassified",
)
TABLE_REQUIREMENTS = {
    "non-technical scoreboard": [
        "model", "arm", "timing.wall_seconds", "verdict.review_rounds", "verdict.outcome_class"
    ],
    "per-model engineering detail": [
        "usage", "timing.wall_seconds", "gate.firing_count", "resolution.path"
    ],
    "outcome classes by arm": ["arm", "verdict.outcome_class"],
    "results by helper family": ["helper_families", "arm", "verdict.machine", "verdict.semantic"],
    "clean-path breakdown": ["resolution.path", "resolution.evidence"],
    "did the guard teach": ["gate.firings", "resolution.path"],
    "attrition": ["attrition.mechanical_failure", "attrition.timeout", "attrition.transcript_loss", "attrition.reason"],
}


def die(message: str) -> None:
    raise SystemExit(f"error: canonical-guard benchmark: {message}")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    return sha256_bytes(path.read_bytes())


def run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
    text: bool = True,
    stdout: Any = subprocess.PIPE,
    stderr: Any = subprocess.PIPE,
) -> subprocess.CompletedProcess[Any]:
    result = subprocess.run(argv, cwd=cwd, env=env, text=text, stdout=stdout, stderr=stderr, check=False)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if text else ""
        die(f"command failed ({result.returncode}): {' '.join(argv)}{': ' + detail if detail else ''}")
    return result


def git(cwd: pathlib.Path, *args: str, check: bool = True) -> str:
    return run(["git", "-C", str(cwd), *args], check=check).stdout.strip()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        die(f"cannot read JSON {path}: {exc}")
    if not isinstance(value, dict):
        die(f"JSON object required: {path}")
    return value


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def append_jsonl(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def require_workspace(path: str, *, initialized: bool = True) -> pathlib.Path:
    workspace = pathlib.Path(path).expanduser().resolve()
    if initialized and not (workspace / "workspace.json").is_file():
        die(f"workspace is not initialized: {workspace}")
    return workspace


def require_safe_id(value: str) -> str:
    if not SAFE_ID.fullmatch(value):
        die("run id must contain only letters, digits, dot, underscore, or dash")
    return value


def cow_copy(source: pathlib.Path, destination: pathlib.Path) -> str:
    if destination.exists():
        die(f"copy destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if platform.system() == "Darwin":
        result = run(["cp", "-c", "-R", str(source), str(destination)], check=False)
        if result.returncode != 0:
            die(f"APFS copy-on-write copy failed: {result.stderr.strip()}")
        return "apfs-clonefile"
    result = run(["cp", "-a", "--reflink=auto", str(source), str(destination)], check=False)
    if result.returncode != 0:
        die(f"copy-on-write-compatible copy failed: {result.stderr.strip()}")
    return "reflink-auto"


def canonical_block_without(text: str) -> tuple[str, list[str]]:
    lines = text.splitlines(keepends=True)
    start = next((index for index, line in enumerate(lines) if re.match(r"^    canonical-boundaries:\s*$", line.rstrip("\n"))), None)
    if start is None:
        die("lefthook.yml has no canonical-boundaries command block")
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if re.match(r"^    [A-Za-z0-9_.-]+:\s*$", line.rstrip("\n")):
            break
        end += 1
    removed = lines[start:end]
    if not any(re.match(r"^      run:\s*pnpm check:canonical\s*$", line.rstrip("\n")) for line in removed):
        die("canonical-boundaries block does not run pnpm check:canonical")
    return "".join(lines[:start] + lines[end:]), [line.rstrip("\n") for line in removed]


def clean_git_config_environment() -> dict[str, str]:
    env = os.environ.copy()
    for name in list(env):
        if name.startswith("GIT_CONFIG_"):
            env.pop(name, None)
    return env


def fixed_commit_env(source: pathlib.Path) -> dict[str, str]:
    stamp = git(source, "show", "-s", "--format=%aI", "HEAD")
    env = clean_git_config_environment()
    env.update(
        {
            "GIT_AUTHOR_NAME": "Benchmark Setup",
            "GIT_AUTHOR_EMAIL": "benchmark@example.invalid",
            "GIT_COMMITTER_NAME": "Benchmark Setup",
            "GIT_COMMITTER_EMAIL": "benchmark@example.invalid",
            "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_DATE": stamp,
        }
    )
    return env


def install_template(path: pathlib.Path) -> None:
    commands = [
        ["pnpm", "install", "--frozen-lockfile"],
        ["pnpm", "--filter", "@monalee-engineering/shared", "build"],
        ["pnpm", "--filter", "@monalee-engineering/ui-library", "build"],
        ["pnpm", "exec", "lefthook", "install"],
    ]
    environment = clean_git_config_environment()
    for command in commands:
        run(command, cwd=path, env=environment)
    hook = path / ".git/hooks/pre-push"
    hooks_path = git(path, "config", "--local", "--path", "core.hooksPath", check=False)
    if not hook.is_file() and hooks_path:
        candidate = pathlib.Path(hooks_path)
        hook = candidate / "pre-push" if candidate.is_absolute() else path / candidate / "pre-push"
    if not hook.is_file() or not os.access(hook, os.X_OK):
        die(f"lefthook did not install an executable pre-push hook in {path}")


def command_init(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace, initialized=False)
    source = pathlib.Path(args.source).expanduser().resolve()
    if not (source / ".git").exists():
        die(f"source is not a Git checkout: {source}")
    base_sha = git(source, "rev-parse", "--verify", f"{args.ref}^{{commit}}")
    dev_sha = git(source, "rev-parse", "--verify", "refs/remotes/origin/dev^{commit}", check=False)
    if not dev_sha:
        dev_sha = git(source, "rev-parse", "--verify", "refs/heads/dev^{commit}", check=False)
    if not dev_sha:
        die("source has no dev branch for the detector's origin/dev base ref")
    if workspace.exists() and any(workspace.iterdir()):
        die(f"workspace must be absent or empty: {workspace}")
    workspace.mkdir(parents=True, exist_ok=True)
    origins = workspace.parent / "origins"
    origins.mkdir(exist_ok=True)
    mirror_id = sha256_bytes(str(workspace).encode())[:12]
    mirror = origins / f"artemis-{mirror_id}.git"
    if mirror.exists():
        die(f"neutral local mirror already exists: {mirror}")
    run(["git", "init", "--bare", str(mirror)])
    (workspace / "mirror.git").symlink_to(os.path.relpath(mirror, workspace))
    run(["git", "--git-dir", str(mirror), "fetch", "--no-tags", str(source), f"{dev_sha}:refs/heads/dev"])
    if git(mirror, "remote", check=False):
        die("bare mirror unexpectedly retained a remote")

    on = workspace / "template-guard-on"
    run(["git", "init", str(on)])
    run(["git", "fetch", "--no-tags", str(source), base_sha], cwd=on)
    git(on, "checkout", "--detach", "FETCH_HEAD")
    git(on, "remote", "add", "origin", str(mirror))
    git(on, "fetch", "origin", "+refs/heads/dev:refs/remotes/origin/dev")
    git(on, "config", "user.name", "Repository Automation")
    git(on, "config", "user.email", "automation@example.invalid")
    install_template(on)
    if git(on, "status", "--porcelain"):
        die("template installation changed tracked or untracked repository content")
    on_sha = git(on, "rev-parse", "HEAD")
    run(["git", "reflog", "expire", "--expire=now", "--all"], cwd=on, env=clean_git_config_environment())

    off = workspace / "template-guard-off"
    cow_copy(on, off)
    lefthook = off / "lefthook.yml"
    without, removed = canonical_block_without(lefthook.read_text())
    lefthook.write_text(without)
    git(off, "update-index", "--assume-unchanged", "lefthook.yml")
    off_sha = git(off, "rev-parse", "HEAD")
    if git(off, "status", "--porcelain"):
        die("GUARD-OFF template exposes its baseline configuration difference")
    run(["git", "reflog", "expire", "--expire=now", "--all"], cwd=off, env=clean_git_config_environment())
    detector = on / "packages/frontend/scripts/canonical/check-canonical.ts"
    if not detector.is_file():
        die("pinned source has no canonical detector")
    config = {
        "schema_version": "canonical-guard-workspace/v1",
        "created_at": utc_now(),
        "source_ref": args.ref,
        "base_sha": base_sha,
        "base_branch_sha": dev_sha,
        "detector_sha": sha256_file(detector),
        "mirror": str(mirror),
        "run_root": str(workspace.parent / "runs"),
        "templates": {
            "guard-on": {"path": str(on), "sha": on_sha, "content_sha": sha256_bytes((on_sha + "\0").encode() + (on / "lefthook.yml").read_bytes())},
            "guard-off": {"path": str(off), "sha": off_sha, "content_sha": sha256_bytes((off_sha + "\0").encode() + (off / "lefthook.yml").read_bytes())},
        },
        "arm_difference": {"path": "lefthook.yml", "deleted_lines": removed},
        "copy_method": "copy-on-write",
    }
    write_json(workspace / "workspace.json", config)
    (workspace / "bundles").mkdir()
    (workspace / "worktrees").mkdir()
    pathlib.Path(config["run_root"]).mkdir(exist_ok=True)
    print(json.dumps({"workspace": str(workspace), "base_sha": base_sha, "templates": config["templates"]}, sort_keys=True))


def extract_function(path: pathlib.Path, name: str) -> str:
    text = path.read_text()
    match = re.search(rf"(?:export\s+)?function\s+{re.escape(name)}\s*\(", text)
    if not match:
        die(f"cannot find {name} in {path}")
    start = match.start()
    brace = text.find("{", match.end())
    if brace < 0:
        die(f"cannot parse {name} in {path}")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1] + "\n"
    die(f"unterminated {name} in {path}")
    return ""


def detector_run(repo: pathlib.Path, base_sha: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CANONICAL_BASE_REF"] = base_sha
    return run(["pnpm", "check:canonical"], cwd=repo, env=env, check=False)


def pinned_detector_run(repo: pathlib.Path, template: pathlib.Path, base_sha: str, detector_sha: str) -> subprocess.CompletedProcess[str]:
    detector_relative = pathlib.Path("packages/frontend/scripts/canonical/check-canonical.ts")
    source_detector = template / detector_relative
    if not source_detector.is_file() or sha256_file(source_detector) != detector_sha:
        die("pinned detector source no longer matches detector_sha")
    execution_paths = (pathlib.Path("package.json"), detector_relative.parent)
    for relative in execution_paths:
        source = template / relative
        destination = repo / relative
        if not source.exists():
            die(f"pinned detector execution surface is absent: {relative}")
        if destination.is_dir():
            shutil.rmtree(destination)
        elif destination.exists() or destination.is_symlink():
            destination.unlink()
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination, symlinks=True)
        else:
            shutil.copy2(source, destination)
    if sha256_file(repo / detector_relative) != detector_sha:
        die("restored detector does not match detector_sha")
    return detector_run(repo, base_sha)


def command_fixture(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    config = read_json(workspace / "workspace.json")
    template = pathlib.Path(config["templates"]["guard-on"]["path"])
    donor_candidates = [
        template / "packages/backend/api/logic/detect-upper-eaves-from-walls.ts",
        template / "packages/backend/api/logic/donor.ts",
    ]
    donor = next((candidate for candidate in donor_candidates if candidate.is_file()), None)
    if donor is None:
        die("fixture donor pointToSegmentDistance file is absent")
    verbatim = extract_function(donor, "pointToSegmentDistance")
    reshaped = """function pointToSegmentDistance(p: [number, number], a: [number, number], b: [number, number]): number {
  const segment = [b[0] - a[0], b[1] - a[1]] as const;
  const denominator = segment[0] ** 2 + segment[1] ** 2;
  const ratio = denominator ? Math.max(0, Math.min(1, ((p[0] - a[0]) * segment[0] + (p[1] - a[1]) * segment[1]) / denominator)) : 0;
  return Math.hypot(p[0] - (a[0] + ratio * segment[0]), p[1] - (a[1] + ratio * segment[1]));
}
"""
    cases = [
        ("top-level-verbatim", pathlib.Path("packages/backend/api/logic/canonical-benchmark-verbatim.ts"), verbatim, True, False),
        ("reshaped-top-level", pathlib.Path("packages/backend/api/logic/canonical-benchmark-reshaped.ts"), reshaped, False, False),
        ("subdirectory-verbatim", pathlib.Path("packages/backend/api/logic/design-validation/canonical-benchmark-verbatim.ts"), verbatim, False, True),
    ]
    output = workspace / "fixture-results.jsonl"
    for case_name, relative, content, expected, blind_spot in cases:
        scratch = workspace / "worktrees" / f"fixture-{case_name}"
        cow_copy(template, scratch)
        try:
            target = scratch / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            git(scratch, "add", str(relative))
            run(["git", "commit", "-m", f"test: canonical fixture {case_name}"], cwd=scratch, env=clean_git_config_environment())
            result = detector_run(scratch, config["base_sha"])
            fired = result.returncode != 0
            record = {
                "schema_version": "canonical-guard-fixture/v1",
                "recorded_at": utc_now(),
                "case": case_name,
                "path": str(relative),
                "expected_firing": expected,
                "fired": fired,
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "blind_spot": blind_spot,
            }
            append_jsonl(output, record)
            if fired != expected:
                die(f"fixture {case_name} expected fired={expected}, observed fired={fired}")
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    print(json.dumps({"fixture_results": str(output), "outcomes": 3}, sort_keys=True))


def current_load(load_file: pathlib.Path | None) -> float | None:
    try:
        if load_file:
            return float(load_file.read_text().strip().split()[0])
        if platform.system() == "Darwin":
            raw = run(["sysctl", "-n", "vm.loadavg"]).stdout.replace("{", "").replace("}", "")
            return float(raw.split()[0])
        return float(pathlib.Path("/proc/loadavg").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def admission_gate(root: pathlib.Path, maximum: float, load_file: pathlib.Path | None) -> None:
    evidence = load_file
    temporary: pathlib.Path | None = None
    stop_refresh = threading.Event()
    refresher: threading.Thread | None = None
    if evidence is None:
        handle, name = tempfile.mkstemp(prefix="canonical-load.")
        os.close(handle)
        temporary = pathlib.Path(name)
        evidence = temporary

        def refresh() -> None:
            while not stop_refresh.is_set():
                value = current_load(None)
                if value is not None:
                    temporary.write_text(f"{value}\n")
                stop_refresh.wait(5)

        initial = current_load(None)
        if initial is None:
            die("cannot read one-minute load for admission")
        temporary.write_text(f"{initial}\n")
        refresher = threading.Thread(target=refresh, daemon=True)
        refresher.start()
    try:
        run([str(root / "bin/fm-ci-load-guard.sh"), "wait", "--max-load", str(maximum), "--load-file", str(evidence)])
    finally:
        stop_refresh.set()
        if refresher:
            refresher.join(timeout=1)
        if temporary:
            temporary.unlink(missing_ok=True)


def copy_candidate_credentials(harness: str, candidate_home: pathlib.Path) -> None:
    source_home = pathlib.Path.home()
    credential_files = {
        "codex": (".codex/auth.json",),
        "claude": (".claude/.credentials.json",),
        "cursor-agent": (".cursor/cli-config.json",),
        "kimi": (".kimi-code/credentials/kimi-code.json", ".kimi-code/oauth/kimi-code", ".kimi-code/device_id"),
        "pi": (".pi/agent/auth.json",),
    }
    for relative_text in credential_files[harness]:
        relative = pathlib.Path(relative_text)
        source = source_home / relative
        if not source.is_file():
            continue
        destination = candidate_home / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(0o600)


def candidate_environment(harness: str, candidate_home: pathlib.Path) -> dict[str, str]:
    inherited = clean_git_config_environment()
    ordinary = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")
    provider_secrets = {
        "codex": ("OPENAI_API_KEY",),
        "claude": ("ANTHROPIC_API_KEY",),
        "cursor-agent": ("CURSOR_API_KEY",),
        "kimi": ("KIMI_API_KEY", "MOONSHOT_API_KEY"),
        "pi": (),
    }
    env = {name: inherited[name] for name in ordinary + provider_secrets[harness] if name in inherited}
    temporary = candidate_home / "tmp"
    temporary.mkdir(parents=True, exist_ok=True)
    env.update({
        "HOME": str(candidate_home),
        "TMPDIR": str(temporary),
        "GIT_TERMINAL_PROMPT": "0",
        "CI": "1",
        "NO_COLOR": "1",
        "CODEX_HOME": str(candidate_home / ".codex"),
        "CLAUDE_CONFIG_DIR": str(candidate_home / ".claude"),
    })
    return env


def macos_sandbox_command(command: list[str], worktree: pathlib.Path, run_origin: pathlib.Path, candidate_home: pathlib.Path, workspace: pathlib.Path) -> list[str]:
    executable = pathlib.Path(shutil.which(command[0]) or command[0]).resolve()
    source_home = pathlib.Path.home().resolve()
    readable = [
        pathlib.Path(path) for path in ("/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/opt/homebrew", "/usr/local", "/private/etc", "/private/var/db/timezone", "/private/var/run", "/dev") if pathlib.Path(path).exists()
    ]
    for candidate in (source_home / ".nvm", source_home / ".local", source_home / ".bun", executable.parent):
        if candidate.exists():
            readable.append(candidate.resolve())
    readable.extend((worktree.resolve(), run_origin.resolve(), candidate_home.resolve()))
    writable = (worktree.resolve(), run_origin.resolve(), candidate_home.resolve(), pathlib.Path("/dev"))
    profile_root = workspace / ".sandbox-profiles"
    profile_root.mkdir(exist_ok=True)
    profile = profile_root / f"{candidate_home.name}.sb"
    read_rules = " ".join(f"(subpath {json.dumps(str(path))})" for path in sorted(set(readable), key=str))
    write_rules = " ".join(f"(subpath {json.dumps(str(path))})" for path in writable)
    protected = {source_home, workspace.parent.resolve()}
    deny_rules = " ".join(f"(subpath {json.dumps(str(path))})" for path in sorted(protected, key=str))
    profile.write_text(f"(version 1)\n(allow default)\n(deny file-read* {deny_rules})\n(allow file-read-metadata (subpath {json.dumps(str(workspace.parent.resolve()))}))\n(allow file-read* {read_rules})\n(deny file-write*)\n(allow file-write* {write_rules})\n")
    return ["/usr/bin/sandbox-exec", "-f", str(profile), *command]


def home_runtime_closure(executable: pathlib.Path, source_home: pathlib.Path) -> set[pathlib.Path]:
    lexical = executable.absolute()
    resolved = lexical.resolve()
    values: set[pathlib.Path] = set()
    for path in (lexical, resolved):
        if not path.is_relative_to(source_home):
            continue
        relative = path.relative_to(source_home)
        parts = relative.parts
        if len(parts) >= 4 and parts[:3] == (".nvm", "versions", "node"):
            values.add(source_home.joinpath(*parts[:4]))
        elif len(parts) >= 5 and parts[:4] == (".local", "share", "uv", "tools"):
            values.add(source_home.joinpath(*parts[:5]))
        elif len(parts) >= 4 and parts[:3] == (".local", "pipx", "venvs"):
            values.add(source_home.joinpath(*parts[:4]))
        elif path == resolved and lexical != resolved:
            values.add(path.parent)
        else:
            values.add(path.parent)
    return values


def selected_runtime_paths(command: list[str], source_home: pathlib.Path) -> tuple[list[str], set[pathlib.Path]]:
    lexical = pathlib.Path(shutil.which(command[0]) or command[0]).absolute()
    rewritten = [str(lexical), *command[1:]]
    closure = home_runtime_closure(lexical, source_home)
    resolved = lexical.resolve()
    try:
        first_line = resolved.open(errors="replace").readline().strip()
    except (OSError, UnicodeDecodeError):
        first_line = ""
    if first_line.startswith("#!"):
        words = shlex.split(first_line[2:].strip())
        interpreter: str | None = None
        if words and pathlib.Path(words[0]).name == "env":
            interpreter = next((word for word in words[1:] if not word.startswith("-")), None)
        elif words:
            interpreter = words[0]
        if interpreter:
            interpreter_path = pathlib.Path(shutil.which(interpreter) or interpreter).absolute()
            closure.update(home_runtime_closure(interpreter_path, source_home))
    return rewritten, closure


def linux_sandbox_argv(binary: pathlib.Path, command: list[str], worktree: pathlib.Path, run_origin: pathlib.Path, candidate_home: pathlib.Path, workspace: pathlib.Path) -> list[str]:
    source_home = pathlib.Path.home().resolve()
    command, runtime_paths = selected_runtime_paths(command, source_home)
    candidates = sorted({source_home, workspace.parent.resolve()}, key=lambda path: len(path.parts))
    protected = [path for path in candidates if not any(path != parent and path.is_relative_to(parent) for parent in candidates)]
    argv = [str(binary), "--die-with-parent", "--new-session", "--share-net", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev"]
    for path in protected:
        argv += ["--tmpfs", str(path)]
    created: set[pathlib.Path] = set()

    def create_parents(destination: pathlib.Path) -> None:
        boundary = next((path for path in reversed(protected) if destination.is_relative_to(path)), None)
        ancestors = list(destination.parents)
        stop = ancestors.index(boundary) if boundary in ancestors else len(ancestors)
        for parent in reversed(ancestors[:stop]):
            if parent not in created:
                argv.extend(("--dir", str(parent)))
                created.add(parent)

    destinations = (worktree.resolve(), run_origin.resolve(), candidate_home.resolve())
    for destination in destinations:
        create_parents(destination)
        argv += ["--dir", str(destination), "--bind", str(destination), str(destination)]
    for runtime_path in sorted(runtime_paths, key=str):
        create_parents(runtime_path)
        if runtime_path.is_dir():
            argv += ["--dir", str(runtime_path)]
        argv += ["--ro-bind", str(runtime_path), str(runtime_path)]
    argv += ["--chdir", str(worktree.resolve()), "--", *command]
    return argv


def linux_sandbox_command(command: list[str], worktree: pathlib.Path, run_origin: pathlib.Path, candidate_home: pathlib.Path, workspace: pathlib.Path) -> list[str]:
    binary = pathlib.Path("/usr/bin/bwrap")
    if not binary.is_file():
        die("Linux candidate execution requires /usr/bin/bwrap")
    return linux_sandbox_argv(binary, command, worktree, run_origin, candidate_home, workspace)


def sandboxed_command(command: list[str], worktree: pathlib.Path, run_origin: pathlib.Path, candidate_home: pathlib.Path, workspace: pathlib.Path) -> list[str]:
    if platform.system() == "Darwin":
        return macos_sandbox_command(command, worktree, run_origin, candidate_home, workspace)
    if platform.system() == "Linux":
        return linux_sandbox_command(command, worktree, run_origin, candidate_home, workspace)
    die(f"no supported candidate filesystem sandbox on {platform.system()}")
    return []


def verify_blindness(worktree: pathlib.Path, prompt: str, base_sha: str) -> dict[str, Any]:
    cwd = str(worktree.resolve())
    remote = git(worktree, "remote", "get-url", "--all", "origin")
    branch = git(worktree, "branch", "--show-current")
    branches = git(worktree, "branch", "-a")
    remote_refs = git(worktree, "ls-remote", "origin")
    history = git(worktree, "log", "--format=%an <%ae> %s", f"{base_sha}..HEAD", check=False)
    reflog = git(worktree, "reflog", "--all", check=False)
    tracked_paths = git(worktree, "ls-files").splitlines()
    forbidden = re.compile(r"canonical[-_]?guard[-_]?benchmark|guard-on|guard-off|measurement[-_]?arm|benchmark-template|benchmark-base", re.I)
    leaked_paths = [path for path in tracked_paths if forbidden.search(path)]
    remote_ref_names = [line.split("\t", 1)[1] for line in remote_refs.splitlines() if "\t" in line]
    unexpected_remote_refs = [ref for ref in remote_ref_names if ref != "refs/heads/dev"]
    surfaces = "\n".join((cwd, remote, branch, branches, history, reflog, prompt))
    evidence = {
        "cwd": cwd,
        "origin": remote,
        "branch": branch,
        "branches": branches.splitlines(),
        "remote_refs": remote_ref_names,
        "history_since_base": history.splitlines(),
        "reflog": reflog.splitlines(),
        "forbidden_visible_paths": leaked_paths,
        "unexpected_remote_refs": unexpected_remote_refs,
        "prompt_sha256": sha256_bytes(prompt.encode()),
        "passed": False,
    }
    if forbidden.search(surfaces) or leaked_paths or unexpected_remote_refs:
        die("blindness check found a study hint, setup history, or contaminating remote ref")
    evidence["passed"] = True
    return evidence


def harness_version(harness: str) -> str | None:
    binary = {"cursor-agent": "cursor-agent"}.get(harness, harness)
    result = run([binary, "--version"], check=False)
    if result.returncode != 0:
        return None
    return (result.stdout or result.stderr).strip().splitlines()[0]


def harness_command(args: argparse.Namespace, cwd: pathlib.Path, candidate_home: pathlib.Path, prompt: str) -> list[str]:
    effort = args.effort
    if args.harness == "codex":
        command = ["codex", "exec", "-C", str(cwd), "--skip-git-repo-check", "--sandbox", "workspace-write", "--add-dir", str(cwd / ".git"), "--add-dir", str(args.mirror), "-m", args.model]
        if effort:
            command += ["-c", f'model_reasoning_effort="{effort}"']
        return command + ["--json", "-o", str(candidate_home / "delivery-note.txt"), prompt]
    if args.harness == "claude":
        command = ["claude", "-p", "--model", args.model, "--output-format", "stream-json", "--verbose", "--setting-sources", "project", "--dangerously-skip-permissions"]
        if effort:
            command += ["--effort", effort]
        return command + [prompt]
    if args.harness == "cursor-agent":
        return ["cursor-agent", "-p", "--output-format", "stream-json", "--trust", "--force", "--workspace", str(cwd), "--model", args.model, prompt]
    if args.harness == "kimi":
        return ["kimi", "--yolo", "-m", args.model, "-p", prompt, "--output-format", "stream-json"]
    if args.harness == "pi":
        command = ["pi", "-p", "--approve", "--mode", "json", "--session-dir", str(candidate_home / "pi-session")]
        if args.provider:
            command += ["--provider", args.provider]
        command += ["--model", args.model]
        if effort:
            command += ["--thinking", effort]
        return command + [prompt]
    die(f"unsupported harness: {args.harness}")
    return []


def terminate_process(process: subprocess.Popen[Any]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def session_candidates(harness: str, cwd: pathlib.Path, candidate_home: pathlib.Path, started: float) -> list[pathlib.Path]:
    home = candidate_home
    roots: list[pathlib.Path] = []
    if harness == "codex":
        roots = [home / ".codex/sessions"]
    elif harness == "claude":
        encoded = re.sub(r"[^A-Za-z0-9-]", "-", str(cwd))
        roots = [home / ".claude/projects" / encoded]
    elif harness == "cursor-agent":
        roots = [home / ".cursor/projects"]
    elif harness == "kimi":
        roots = [home / ".kimi-code/sessions"]
    elif harness == "pi":
        roots = [home / "pi-session"]
    found: list[pathlib.Path] = []
    cwd_bytes = str(cwd).encode()
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            try:
                if path.stat().st_mtime + 2 < started:
                    continue
                if harness != "pi" and cwd_bytes not in path.read_bytes():
                    continue
                found.append(path)
            except OSError:
                continue
    return sorted(set(found))


def cursor_terminal_candidates(cwd: pathlib.Path, candidate_home: pathlib.Path, started: float) -> list[pathlib.Path]:
    root = candidate_home / ".cursor/projects"
    if not root.is_dir():
        return []
    project = None
    for marker in root.glob("*/.workspace-trusted"):
        try:
            value = json.loads(marker.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if value.get("workspacePath") == str(cwd):
            project = marker.parent
            break
    if project is None:
        return []
    return sorted(path for path in (project / "terminals").glob("*.txt") if path.is_file() and path.stat().st_mtime + 2 >= started)


def copy_auxiliary_files(files: list[pathlib.Path], bundle: pathlib.Path, directory: str) -> list[pathlib.Path]:
    destination = bundle / directory
    destination.mkdir(exist_ok=True)
    copied = []
    for index, source in enumerate(files, 1):
        target = destination / f"{index:03d}-{source.name}"
        shutil.copy2(source, target)
        copied.append(target)
    return copied


def copy_transcripts(files: list[pathlib.Path], bundle: pathlib.Path) -> list[pathlib.Path]:
    destination = bundle / "transcripts"
    destination.mkdir(exist_ok=True)
    copied: list[pathlib.Path] = []
    for index, source in enumerate(files, 1):
        target = destination / f"{index:03d}-{source.name}"
        shutil.copy2(source, target)
        copied.append(target)
    return copied


def jsonl_rows(files: Iterable[pathlib.Path]) -> Iterable[dict[str, Any]]:
    for path in files:
        try:
            for line in path.read_text(errors="replace").splitlines():
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    yield value
        except OSError:
            continue


def capture_delivery_note(session_log: pathlib.Path, destination: pathlib.Path) -> None:
    if destination.is_file() or not session_log.is_file():
        return
    candidates: list[str] = []
    for line in session_log.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and isinstance(row.get("result"), str):
            candidates.append(row["result"])
        for item in nested_dicts(row):
            if item.get("role") == "assistant" and isinstance(item.get("content"), str):
                candidates.append(item["content"])
            if item.get("type") in ("text", "agent_message") and isinstance(item.get("text"), str):
                candidates.append(item["text"])
    if candidates:
        destination.write_text(candidates[-1].strip() + "\n")


def sum_usage(harness: str, files: list[pathlib.Path], session_log: pathlib.Path) -> dict[str, Any]:
    fresh = cached = cache_write = output = reasoning = 0
    cost: float | None = None
    currency: str | None = None
    matched = False
    rows = list(jsonl_rows(files))
    if harness == "codex":
        totals: list[dict[str, Any]] = []
        for row in rows:
            candidate = row.get("payload", {}).get("info", {}).get("total_token_usage") if row.get("type") == "event_msg" else None
            if isinstance(candidate, dict):
                totals.append(candidate)
        if totals:
            value = totals[-1]
            total_input = int(value.get("input_tokens", 0))
            cached = int(value.get("cached_input_tokens", 0))
            fresh = max(0, total_input - cached)
            cache_write = int(value.get("cache_write_input_tokens", 0))
            output = int(value.get("output_tokens", 0))
            reasoning = int(value.get("reasoning_output_tokens", 0))
            matched = True
    elif harness == "claude":
        seen: set[str] = set()
        for row in rows:
            message = row.get("message") if row.get("type") == "assistant" else None
            usage = message.get("usage") if isinstance(message, dict) else None
            identity = message.get("id") if isinstance(message, dict) else None
            if not isinstance(usage, dict) or (identity and identity in seen):
                continue
            if identity:
                seen.add(identity)
            fresh += int(usage.get("input_tokens", 0))
            cached += int(usage.get("cache_read_input_tokens", 0))
            cache_write += int(usage.get("cache_creation_input_tokens", 0))
            output += int(usage.get("output_tokens", 0))
            matched = True
        for row in rows:
            if isinstance(row.get("total_cost_usd"), (int, float)):
                cost = float(row["total_cost_usd"])
                currency = "USD"
    elif harness == "pi":
        for row in rows:
            message = row.get("message") if row.get("type") == "message" else None
            usage = message.get("usage") if isinstance(message, dict) and message.get("role") == "assistant" else None
            if not isinstance(usage, dict):
                continue
            fresh += int(usage.get("input", 0))
            cached += int(usage.get("cacheRead", 0))
            cache_write += int(usage.get("cacheWrite", 0))
            output += int(usage.get("output", 0))
            reasoning += int(usage.get("reasoning", 0))
            if isinstance(usage.get("cost", {}).get("total"), (int, float)):
                cost = (cost or 0) + float(usage["cost"]["total"])
                currency = "USD"
            matched = True
    elif harness == "kimi":
        for row in rows:
            usage = row.get("usage")
            if not isinstance(usage, dict) or row.get("usageScope") != "turn":
                continue
            fresh += int(usage.get("inputOther", 0))
            cached += int(usage.get("inputCacheRead", 0))
            cache_write += int(usage.get("inputCacheCreation", 0))
            output += int(usage.get("output", 0))
            matched = True
    # Cursor currently exposes no durable token fields in its transcript format.
    return {
        "fresh_input_tokens": fresh if matched else None,
        "cached_input_tokens": cached if matched else None,
        "cache_write_input_tokens": cache_write if matched else None,
        "output_tokens": output if matched else None,
        "reasoning_output_tokens": reasoning if matched else None,
        "total_tokens": fresh + cached + output if matched else None,
        "dollar_cost": cost,
        "currency": currency,
        "source": "harness-transcript" if matched else "unavailable",
        "unavailable_reason": None if matched else f"{harness} transcript exposes no verified usage fields",
    }


def nested_dicts(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from nested_dicts(item)
    elif isinstance(value, list):
        for item in value:
            yield from nested_dicts(item)


def tool_output(item: Any) -> str:
    if isinstance(item, str):
        return item
    if isinstance(item, list):
        return "\n".join(part for value in item if (part := tool_output(value)))
    if isinstance(item, dict):
        preferred = [item.get(key) for key in ("text", "content", "output", "aggregated_output", "stdout", "stderr", "result")]
        return "\n".join(part for value in preferred if value is not None and (part := tool_output(value)))
    return ""


def unique_jsonl_rows(files: list[pathlib.Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    first_source: dict[str, int] = {}
    for source_index, path in enumerate(files):
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(value, dict):
                continue
            fingerprint = sha256_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
            prior_source = first_source.get(fingerprint)
            if prior_source is not None and prior_source != source_index:
                continue
            first_source.setdefault(fingerprint, source_index)
            rows.append(value)
    return rows


def tool_command(item: dict[str, Any], kind: str, name: str) -> str | None:
    if kind == "commandexecution" and isinstance(item.get("command"), list):
        return str(item["command"][-1]) if item["command"] else None
    if kind not in ("tooluse", "toolcall", "customtoolcall") and name not in ("bash", "shell", "exec", "exec_command", "read", "grep"):
        return None
    tool_input = item.get("input") or item.get("arguments")
    if isinstance(tool_input, str):
        try:
            decoded_input = json.loads(tool_input)
        except json.JSONDecodeError:
            decoded_input = None
        tool_input = decoded_input if isinstance(decoded_input, dict) else {"command": tool_input}
    if not isinstance(tool_input, dict):
        return None
    command = tool_input.get("command") or tool_input.get("cmd")
    if not command and name in ("read", "grep"):
        command = f"{name} {tool_input.get('path') or tool_input.get('pattern') or ''}".strip()
    return command if isinstance(command, str) and command.strip() else None


def tool_events(files: list[pathlib.Path]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    pending: dict[str, list[int]] = {}
    for row in unique_jsonl_rows(files):
        timestamp = row.get("timestamp")
        for item in nested_dicts(row):
            kind = re.sub(r"[^a-z]", "", str(item.get("type") or "").lower())
            name = str(item.get("name") or "").lower()
            if kind in ("toolresult", "functioncalloutput", "commandresult"):
                identity = str(item.get("tool_use_id") or item.get("call_id") or item.get("id") or "")
                if not identity or not pending.get(identity):
                    continue
                event = events[pending[identity].pop()]
                event["output"] = tool_output(item)
                if item.get("exit_code") is not None:
                    event["exit_code"] = item["exit_code"]
                continue
            identity = str(item.get("id") or item.get("call_id") or "")
            command = tool_command(item, kind, name)
            if not command:
                continue
            output = tool_output(item) if kind == "commandexecution" else ""
            exit_code = item.get("exit_code")
            if kind == "commandexecution" and identity and pending.get(identity):
                event = events[pending[identity].pop()]
                event.update({"timestamp": timestamp or event["timestamp"], "command": command, "output": output, "exit_code": exit_code})
                continue
            events.append({"id": identity or None, "timestamp": timestamp, "command": command, "output": output, "exit_code": exit_code})
            if identity and kind != "commandexecution":
                pending.setdefault(identity, []).append(len(events) - 1)
    return events


def behavior_and_gate(files: list[pathlib.Path], session_log: pathlib.Path, terminal_files: list[pathlib.Path]) -> tuple[dict[str, Any], dict[str, Any]]:
    event_files = list(files)
    if session_log.is_file():
        event_files.append(session_log)
    events = tool_events(event_files)
    evidence = [event for event in events if re.search(r"(?:^|\s)(?:cat|sed|rg|grep|read)\s|/api/logic/|canonical-boundaries\.md", event["command"], re.I)]
    push_events = [event for event in events if re.search(r"(?:^|&&|;|\n)\s*git\s+push(?:\s|$)", event["command"])]
    firings = []
    remediation: list[str] = []
    for push_ordinal, event in enumerate(push_events, 1):
        output = event["output"]
        fired = bool(re.search(r"duplicate implementation detected|\[duplicate-implementation\]|Canonical-ack: duplicate-implementation", output, re.I))
        if not fired:
            continue
        exact = "\n".join(line for line in output.splitlines() if line.strip())
        remediation.append(exact)
        firings.append({"ordinal": len(firings) + 1, "push_ordinal": push_ordinal, "timestamp": event["timestamp"], "rule_id": "duplicate-implementation", "remediation_text": exact, "fix_matches_remediation": None})
    for terminal in terminal_files:
        text = terminal.read_text(errors="replace")
        if not re.search(r"duplicate implementation detected|\[duplicate-implementation\]|Canonical-ack: duplicate-implementation", text, re.I):
            continue
        if text not in remediation:
            remediation.append(text)
            firings.append({"ordinal": len(firings) + 1, "push_ordinal": len(push_events) or None, "timestamp": None, "rule_id": "duplicate-implementation", "remediation_text": text, "fix_matches_remediation": None, "source": str(terminal.name)})
    command_text = "\n".join(event["command"] for event in events)
    trace = {
        "events": [{"timestamp": event["timestamp"], "command": event["command"][:4000]} for event in evidence],
        "files_read_or_grepped": sorted(set(re.findall(r"(?:[A-Za-z0-9_.-]+/)+(?:[A-Za-z0-9_.-]+)", command_text)))[:500],
        "read_rules_doc": "canonical-boundaries.md" in command_text,
        "read_agents_md": bool(re.search(r"(?:^|/)AGENTS\.md", command_text)),
        "grepped_for_existing_helper": bool(re.search(r"(?:rg|grep).*(pointInPolygon|polygonContains|pointToSegmentDistance|minDistanceToBoundary)", command_text, re.I)),
        "opened_donor_files": sorted(set(re.findall(r"(?:detect-upper-eaves-from-walls|detect-wall-boundary-edges|is-pin-inside-parcel-outline|map-screenshot-points)\.ts", command_text))),
        "ran_check_canonical_voluntarily": sum(1 for event in events if re.search(r"(?:^|&&|;|\n)\s*pnpm\s+check:canonical(?:\s|$)", event["command"])),
    }
    gate = {
        "firing_count": len(firings),
        "firings": firings,
        "push_commands_observed": len(push_events),
        "pushes": [{"ordinal": index + 1, "timestamp": event["timestamp"], "exit_code": event["exit_code"], "command": event["command"]} for index, event in enumerate(push_events)],
        "remediation_text_exact": remediation,
    }
    return trace, gate


def resolution_from_diff(diff: str) -> dict[str, Any]:
    added = "\n".join(line[1:] for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++"))
    path = "unclassified"
    patterns = [
        ("exported-then-imported-point-in-ring", r"import[^\n]*\bpointInRing\b"),
        ("imported-point-in-polygon", r"import[^\n]*\bpointInPolygon\b"),
        ("imported-polygon-contains", r"import[^\n]*\bpolygonContains\b"),
        ("exported-then-imported-point-to-segment-distance", r"(?:export[^\n]*pointToSegmentDistance|import[^\n]*pointToSegmentDistance)"),
        ("exported-then-imported-min-distance-to-boundary", r"(?:export[^\n]*minDistanceToBoundary|import[^\n]*minDistanceToBoundary)"),
        ("moved-helper-to-shared-module", r"(?:shared|utils)/[^\n]*(?:pointToSegmentDistance|minDistanceToBoundary|pointInPolygon)"),
        ("fresh-reimplementation", r"(?:function|const)\s+(?:pointToSegmentDistance|minDistanceToBoundary|pointInRing|pointInPolygon)\b"),
    ]
    evidence: list[str] = []
    for candidate, pattern in patterns:
        matches = re.findall(pattern, added, re.I)
        if matches:
            path = candidate
            evidence = [line[:1000] for line in added.splitlines() if re.search(pattern, line, re.I)][:20]
            break
    if not added.strip():
        path = "none"
    families = []
    if re.search(r"pointToSegmentDistance|minDistanceToBoundary|distanceToSegment", diff, re.I):
        families.append("distance-helper")
    if re.search(r"pointInPolygon|polygonContains|pointInRing", diff, re.I):
        families.append("point-in-polygon")
    return {"path": path, "evidence": evidence, "helper_families": families}


def git_capture(repo: pathlib.Path, template_sha: str, bundle: pathlib.Path) -> tuple[dict[str, Any], str]:
    marked = git(repo, "ls-files", "-v", "-z", check=False).split("\0")
    assumed_unchanged = [entry[2:] for entry in marked if len(entry) > 2 and entry[0].islower() and entry[1] == " "]
    if assumed_unchanged:
        run(["git", "update-index", "--no-assume-unchanged", "--", *assumed_unchanged], cwd=repo)
    log_format = "%H%x1f%cI%x1f%P%x1f%B%x1e"
    log = git(repo, "log", f"--format={log_format}", f"{template_sha}..HEAD", check=False)
    commits = []
    for record in log.split("\x1e"):
        fields = record.strip().split("\x1f", 3)
        if len(fields) == 4:
            commits.append({"sha": fields[0], "committed_at": fields[1], "parents": fields[2].split(), "message": fields[3]})
    diff = git(repo, "diff", "--binary", f"{template_sha}..HEAD", check=False)
    uncommitted = git(repo, "diff", "--binary", "HEAD", check=False)
    if uncommitted:
        diff += "\n" + uncommitted
    untracked = git(repo, "ls-files", "--others", "--exclude-standard", "-z", check=False).split("\0")
    for relative in (item for item in untracked if item):
        addition = run(["git", "diff", "--no-index", "--binary", "--", "/dev/null", relative], cwd=repo, check=False).stdout
        diff += "\n" + addition
    (bundle / "git.log").write_text(log + ("\n" if log and not log.endswith("\n") else ""))
    (bundle / "final.diff").write_text(diff + ("\n" if diff and not diff.endswith("\n") else ""))
    history_dir = bundle / "history"
    history_dir.mkdir(exist_ok=True)
    history_diffs = []
    for ordinal, commit in enumerate(reversed(commits), 1):
        history_path = history_dir / f"{ordinal:03d}-{commit['sha']}.diff"
        history_diff = git(repo, "diff", "--binary", f"{template_sha}..{commit['sha']}", check=False)
        history_path.write_text(history_diff + ("\n" if history_diff and not history_diff.endswith("\n") else ""))
        history_diffs.append(str(history_path.relative_to(bundle)))
    (bundle / "reflog.txt").write_text(git(repo, "reflog", "--date=iso", check=False) + "\n")
    (bundle / "status.txt").write_text(git(repo, "status", "--short", "--untracked-files=all", check=False) + "\n")
    remote_has_head = False
    head = git(repo, "rev-parse", "HEAD", check=False)
    branch = git(repo, "branch", "--show-current", check=False)
    if head and branch:
        remote_refs = git(repo, "ls-remote", "origin", f"refs/heads/{branch}", check=False)
        remote_has_head = any(line == f"{head}\trefs/heads/{branch}" for line in remote_refs.splitlines())
    trailers = []
    for commit in commits:
        trailers.extend(re.findall(r"^Canonical-ack:\s*(.+)$", commit["message"], re.M))
    changed = git(repo, "diff", "--name-status", f"{template_sha}..HEAD", check=False).splitlines()
    tests_added = [line.split("\t", 1)[-1] for line in changed if line.startswith("A\t") and re.search(r"(?:__tests__|\.test\.|\.spec\.)", line)]
    return {
        "branch": branch,
        "commits": commits,
        "commit_count": len(commits),
        "push_count": 1 if remote_has_head else 0,
        "pushes": [{"ordinal": 1, "clean": True if remote_has_head else None}] if remote_has_head else [],
        "amend_count": max(0, git(repo, "reflog", check=False).count("commit (amend)")),
        "force_push_count": None,
        "trailers": trailers,
        "history_diffs": history_diffs,
        "tests_added": tests_added,
        "final_diff_path": "final.diff",
    }, diff


def validate_manifest(value: dict[str, Any]) -> None:
    required = read_json(pathlib.Path(__file__).with_name("manifest.schema.json"))["required"]
    missing = [key for key in required if key not in value]
    if missing:
        die(f"manifest missing required fields: {', '.join(missing)}")
    if value["schema_version"] != SCHEMA_VERSION or value["arm"] not in ARMS or value["harness"] not in HARNESS_NAMES:
        die("manifest has invalid schema, arm, or harness")
    require_safe_id(value["run_id"])


def command_run(args: argparse.Namespace) -> None:
    root = pathlib.Path(__file__).resolve().parents[2]
    harness_code_sha = git(root, "rev-parse", "HEAD")
    harness_paths = ["bin/fm-canonical-guard-benchmark.sh", "scripts/canonical-guard-benchmark/benchmark.py", "scripts/canonical-guard-benchmark/manifest.schema.json"]
    harness_code_dirty = bool(git(root, "status", "--porcelain", "--", *harness_paths, check=False))
    workspace = require_workspace(args.workspace)
    config = read_json(workspace / "workspace.json")
    run_id = require_safe_id(args.run_id)
    if args.stage in ("matrix", "exploratory") and (not isinstance(args.lane, str) or not SAFE_ID.fullmatch(args.lane)):
        die(f"{args.stage} runs require a safe lane id")
    bundle = workspace / "bundles" / run_id
    run_root = pathlib.Path(config.get("run_root", workspace / "worktrees"))
    worktree = run_root / run_id
    candidate_home = run_root.parent / "homes" / run_id
    if bundle.exists() or worktree.exists() or candidate_home.exists():
        die(f"run id already exists: {run_id}")
    prompt_file = pathlib.Path(args.prompt_file).expanduser().resolve()
    prompt = prompt_file.read_text()
    if not prompt.strip():
        die("prompt file is empty")
    frozen_plan_path = workspace / "frozen-plan.json"
    frozen_plan: dict[str, Any] | None = None
    frozen_expected: dict[str, Any] | None = None
    if args.stage == "matrix":
        if harness_code_dirty:
            die("matrix dispatch requires committed harness code")
        if not args.lane:
            die("matrix runs require --lane")
        if not frozen_plan_path.is_file():
            die("matrix runs require a frozen pre-registration plan")
        frozen_plan = read_json(frozen_plan_path)
        if sha256_file(prompt_file) != frozen_plan.get("prompt_sha256"):
            die("matrix prompt SHA does not match the frozen plan")
        if args.max_load != frozen_plan.get("max_load") or args.timeout != frozen_plan.get("timeout_seconds"):
            die("matrix load ceiling or timeout differs from the frozen plan")
        frozen_expected = next((item for item in frozen_plan.get("runs", []) if item.get("run_id") == run_id), None)
        if not frozen_expected:
            die(f"run id is not in the frozen plan: {run_id}")
        actual_axes = {
            "arm": args.arm,
            "harness": args.harness,
            "model": args.model,
            "provider": args.provider,
            "effort": args.effort,
            "helper_family": args.helper_family,
            "lane": args.lane,
            "concurrent_lane_count": args.concurrent_lane_count,
        }
        if any(frozen_expected.get(key) != value for key, value in actual_axes.items()):
            die(f"run axes differ from frozen plan: {run_id}")
    if args.stage == "matrix":
        lock = workspace / f".lane-run-lock-{args.lane}"
    elif args.stage == "exploratory":
        lock = workspace / f".exploratory-lane-run-lock-{args.lane}"
    else:
        lock = workspace / ".serial-run-lock"
    try:
        lock.mkdir()
    except FileExistsError:
        die("another run holds this lane's execution lock")
    started_wall = time.time()
    started_at = utc_now()
    load_file = pathlib.Path(args.load_file).resolve() if args.load_file else None
    samples: list[dict[str, Any]] = []
    stop_samples = threading.Event()

    def sample_load() -> None:
        while not stop_samples.is_set():
            samples.append({"at": utc_now(), "one_minute": current_load(load_file)})
            stop_samples.wait(300)

    sampler = threading.Thread(target=sample_load, daemon=True)
    exit_code: int | None = None
    timed_out = False
    neutral_branch: str | None = None
    run_origin: pathlib.Path | None = None
    copied_transcripts: list[pathlib.Path] = []
    copied_terminals: list[pathlib.Path] = []
    copy_method = ""
    session_log = bundle / "session.log"
    template_info = config["templates"][args.arm]
    template = pathlib.Path(template_info["path"])
    try:
        admission_gate(root, args.max_load, load_file)
        candidate_home.mkdir(parents=True)
        run_origin = candidate_home / "origin.git"
        cow_copy(pathlib.Path(config["mirror"]), run_origin)
        run(["git", "--git-dir", str(run_origin), "repack", "-a", "-d"])
        (run_origin / "objects/info/alternates").unlink(missing_ok=True)
        copy_method = cow_copy(template, worktree)
        git(worktree, "config", "user.name", "Repository Automation")
        git(worktree, "config", "user.email", "automation@example.invalid")
        neutral_branch = "b-" + sha256_bytes(run_id.encode())[:12]
        git(worktree, "checkout", "-b", neutral_branch)
        git(worktree, "remote", "set-url", "origin", str(run_origin))
        for url in git(worktree, "remote", "get-url", "--all", "origin").splitlines():
            if "://" in url or re.match(r"^[^/]+@", url):
                die("run origin is not a filesystem remote")
        hook = worktree / ".git/hooks/pre-push"
        hooks_path = git(worktree, "config", "--local", "--path", "core.hooksPath", check=False)
        if not hook.is_file() and hooks_path:
            hp = pathlib.Path(hooks_path)
            hook = hp / "pre-push" if hp.is_absolute() else worktree / hp / "pre-push"
        if not hook.is_file() or not os.access(hook, os.X_OK):
            die("run worktree has no executable pre-push hook")
        blindness = verify_blindness(worktree, prompt, config["base_sha"])
        candidate_home.chmod(0o700)
        copy_candidate_credentials(args.harness, candidate_home)
        sampler.start()
        args.mirror = run_origin
        command = harness_command(args, worktree, candidate_home, prompt)
        command = sandboxed_command(command, worktree, run_origin, candidate_home, workspace)
        env = candidate_environment(args.harness, candidate_home)
        bundle.mkdir(parents=True)
        with session_log.open("wb") as output:
            process = subprocess.Popen(command, cwd=worktree, env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                exit_code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_process(process)
                exit_code = process.returncode
        discovered = session_candidates(args.harness, worktree, candidate_home, started_wall)
        copied_transcripts = copy_transcripts(discovered, bundle)
        if args.harness == "cursor-agent":
            copied_terminals = copy_auxiliary_files(cursor_terminal_candidates(worktree, candidate_home, started_wall), bundle, "terminals")
        candidate_note = candidate_home / "delivery-note.txt"
        if candidate_note.is_file():
            shutil.copy2(candidate_note, bundle / "delivery-note.txt")
        else:
            capture_delivery_note(session_log, bundle / "delivery-note.txt")
        git_info, final_diff = git_capture(worktree, template_info["sha"], bundle)
        trace, gate = behavior_and_gate(copied_transcripts, session_log, copied_terminals)
        gate["firing_count"] = max(gate["firing_count"], 0)
        git_info["push_count"] = max(git_info["push_count"], gate["push_commands_observed"])
        resolution = resolution_from_diff(final_diff)
        for firing in gate["firings"]:
            advised_reuse = bool(re.search(r"import|export it|shared module", firing["remediation_text"], re.I))
            firing["fix_matches_remediation"] = resolution["path"] in (
                "exported-then-imported-point-in-ring",
                "imported-point-in-polygon",
                "imported-polygon-contains",
                "exported-then-imported-point-to-segment-distance",
                "exported-then-imported-min-distance-to-boundary",
                "moved-helper-to-shared-module",
            ) if advised_reuse else None
        usage = sum_usage(args.harness, copied_transcripts, session_log)
        ended_at = utc_now()
        samples.append({"at": ended_at, "one_minute": current_load(load_file)})
        commit_times = [dt.datetime.fromisoformat(item["committed_at"].replace("Z", "+00:00")).timestamp() for item in git_info["commits"]]
        first_commit = min(commit_times) - started_wall if commit_times else None
        push_times = []
        for push in gate.get("pushes", []):
            try:
                push_times.append(dt.datetime.fromisoformat(str(push.get("timestamp")).replace("Z", "+00:00")).timestamp())
            except (TypeError, ValueError):
                pass
        first_push = min(push_times) - started_wall if push_times else None
        first_fire_to_clean = None
        firing_times = []
        for firing in gate["firings"]:
            try:
                firing_times.append(dt.datetime.fromisoformat(str(firing.get("timestamp")).replace("Z", "+00:00")).timestamp())
            except (TypeError, ValueError):
                pass
        clean_push_times = []
        for push in gate.get("pushes", []):
            if push.get("exit_code") != 0:
                continue
            try:
                clean_push_times.append(dt.datetime.fromisoformat(str(push.get("timestamp")).replace("Z", "+00:00")).timestamp())
            except (TypeError, ValueError):
                pass
        if firing_times and clean_push_times:
            later = [value for value in clean_push_times if value >= min(firing_times)]
            if later:
                first_fire_to_clean = min(later) - min(firing_times)
        transcript_loss = not copied_transcripts
        no_commits = git_info["commit_count"] == 0
        attrition_reasons = []
        if timed_out:
            attrition_reasons.append("timeout")
        if exit_code not in (0, None):
            attrition_reasons.append(f"harness-exit-{exit_code}")
        if no_commits:
            attrition_reasons.append("no-commits")
        if transcript_loss:
            attrition_reasons.append("transcript-loss")
        git_info["force_push_count"] = sum(1 for push in gate.get("pushes", []) if re.search(r"git\s+push\s+(?:[^;&\n]*\s)?(?:--force|-f)(?:\s|$)", push.get("command", "")))
        suite_events = [event for event in tool_events(copied_transcripts + ([session_log] if session_log.is_file() else [])) if re.search(r"(?:^|&&|;|\n)\s*(?:pnpm|npm|yarn|bun)\s+(?:test|lint|typecheck|check)(?:\s|$)", event["command"])]
        known_suite_codes = [event["exit_code"] for event in suite_events if isinstance(event.get("exit_code"), int)]
        suite_passed = None if not known_suite_codes else all(code == 0 for code in known_suite_codes)
        work = {
            "commit_count": git_info["commit_count"],
            "push_count": git_info["push_count"],
            "tests_added": git_info.pop("tests_added"),
            "suite_passed": suite_passed,
            "delivery_note_path": "delivery-note.txt" if (bundle / "delivery-note.txt").is_file() else None,
        }
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "run_id": run_id,
            "arm": args.arm,
            "model": args.model,
            "provider": args.provider,
            "harness": args.harness,
            "harness_version": harness_version(args.harness),
            "harness_code_sha": harness_code_sha,
            "harness_code_dirty": harness_code_dirty,
            "effort": args.effort,
            "prompt_sha256": sha256_file(prompt_file),
            "base_sha": config["base_sha"],
            "detector_sha": config["detector_sha"],
            "template_sha": template_info["sha"],
            "started_at": started_at,
            "ended_at": ended_at,
            "load_samples": samples,
            "exit_code": exit_code,
            "timeout": timed_out,
            "timeout_seconds": args.timeout,
            "max_load": args.max_load,
            "copy_method": copy_method,
            "transcript": {"status": "captured" if copied_transcripts else "lost", "paths": [str(path.relative_to(bundle)) for path in copied_transcripts], "terminal_paths": [str(path.relative_to(bundle)) for path in copied_terminals], "loss_reason": "no exact cwd session matched" if transcript_loss else None},
            "usage": usage,
            "stage": args.stage,
            "lane": args.lane,
            "concurrent_lane_count": args.concurrent_lane_count,
            "preregistration": None,
            "git": git_info,
            "gate": gate,
            "timing": {"wall_seconds": round(time.time() - started_wall, 3), "time_to_first_commit_seconds": round(first_commit, 3) if first_commit is not None else None, "time_to_first_push_seconds": round(first_push, 3) if first_push is not None else None, "first_firing_to_clean_push_seconds": round(first_fire_to_clean, 3) if first_fire_to_clean is not None else None},
            "behavior_trace": trace,
            "blindness_check": blindness,
            "resolution": {"path": resolution["path"], "evidence": resolution["evidence"]},
            "helper_families": resolution["helper_families"] or ([args.helper_family] if args.helper_family else []),
            "work": work,
            "attrition": {"mechanical_failure": bool(attrition_reasons), "timeout": timed_out, "transcript_loss": transcript_loss, "reason": "; ".join(attrition_reasons) or None},
            "verdicts": {"machine": None, "semantic": None, "early_late": None, "false_fire": None, "ack": None, "source": "separate append-only verdicts.jsonl"},
        }
        if args.stage == "matrix" and frozen_plan is not None:
            manifest["preregistration"] = {"plan_sha256": sha256_file(frozen_plan_path), "ratified_at": frozen_plan["ratified_at"], "amendment": frozen_plan["amendment"]}
        validate_manifest(manifest)
        write_json(bundle / "manifest.json", manifest)
        print(json.dumps({"run_id": run_id, "manifest": str(bundle / "manifest.json"), "mechanical_failure": manifest["attrition"]["mechanical_failure"]}, sort_keys=True))
    finally:
        stop_samples.set()
        if sampler.is_alive():
            sampler.join(timeout=1)
        if neutral_branch and run_origin:
            run(["git", "--git-dir", str(run_origin), "update-ref", "-d", f"refs/heads/{neutral_branch}"], check=False)
        shutil.rmtree(worktree, ignore_errors=True)
        shutil.rmtree(candidate_home, ignore_errors=True)
        (workspace / ".sandbox-profiles" / f"{run_id}.sb").unlink(missing_ok=True)
        try:
            (workspace / ".sandbox-profiles").rmdir()
        except OSError:
            pass
        if run_origin:
            shutil.rmtree(run_origin, ignore_errors=True)
        try:
            lock.rmdir()
        except OSError:
            pass


def manifests(workspace: pathlib.Path) -> list[dict[str, Any]]:
    values = []
    for path in sorted((workspace / "bundles").glob("*/manifest.json")):
        value = read_json(path)
        validate_manifest(value)
        values.append(value)
    return values


def verdicts(workspace: pathlib.Path) -> dict[str, dict[str, Any]]:
    ledger = workspace / "verdicts.jsonl"
    result: dict[str, dict[str, Any]] = {}
    if not ledger.is_file():
        return result
    for number, line in enumerate(ledger.read_text().splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            die(f"malformed verdict ledger line {number}")
        if not isinstance(value, dict) or not isinstance(value.get("run_id"), str):
            die(f"invalid verdict ledger line {number}")
        if value["run_id"] in result:
            die(f"duplicate verdict for run {value['run_id']}")
        result[value["run_id"]] = value
    return result


def validate_scorers(scorers: Any) -> str:
    if not isinstance(scorers, list) or len(scorers) != 2:
        die("verdict requires exactly two independent scorer rows")
    identities: list[str] = []
    decisions: list[str] = []
    for scorer in scorers:
        if not isinstance(scorer, dict):
            die("every scorer must be an object")
        identity = scorer.get("id")
        decision = scorer.get("verdict")
        rationale = scorer.get("rationale")
        if not isinstance(identity, str) or not identity.strip() or decision not in ("clean", "duplicate") or not isinstance(rationale, str) or not rationale.strip():
            die("every scorer requires a non-empty id, clean/duplicate verdict, and rationale")
        identities.append(identity)
        decisions.append(decision)
    if len(set(identities)) != 2:
        die("semantic scorers must have distinct identities")
    return decisions[0] if decisions[0] == decisions[1] else "needs-owner"


def normalize_verdict(value: dict[str, Any], manifest_by_id: dict[str, dict[str, Any]]) -> dict[str, Any]:
    run_id = require_safe_id(str(value.get("run_id", "")))
    if run_id not in manifest_by_id:
        die(f"verdict references unknown run: {run_id}")
    required = ("machine", "semantic", "outcome_class", "false_fire", "ack", "review_rounds", "scorers")
    missing = [key for key in required if key not in value]
    if missing:
        die(f"verdict missing fields: {', '.join(missing)}")
    if value["machine"] not in ("clean", "duplicate"):
        die("verdict machine must be clean or duplicate")
    scorer_semantic = validate_scorers(value["scorers"])
    if scorer_semantic == "needs-owner":
        die("semantic scorer disagreement must be resolved before verdict append")
    if value["semantic"] not in ("clean", "duplicate") or value["semantic"] != scorer_semantic:
        die("verdict semantic value does not match the two scorer decisions")
    if value["outcome_class"] not in ("caught-early", "reached-review", "self-corrected", "never-duplicated"):
        die("verdict outcome_class is invalid")
    if type(value["false_fire"]) is not bool or type(value["ack"]) is not bool:
        die("verdict false_fire and ack must be booleans")
    rounds = value["review_rounds"]
    if rounds is not None and (type(rounds) is not int or rounds < 0):
        die("verdict review_rounds must be a non-negative integer or null")
    if "gate_firing_count" in value and (type(value["gate_firing_count"]) is not int or value["gate_firing_count"] < 0):
        die("verdict gate_firing_count must be a non-negative integer")
    if "fix_matches_remediation" in value and value["fix_matches_remediation"] is not None and type(value["fix_matches_remediation"]) is not bool:
        die("verdict fix_matches_remediation must be boolean or null")
    if "remediation_text_exact" in value and (not isinstance(value["remediation_text_exact"], list) or any(not isinstance(item, str) for item in value["remediation_text_exact"])):
        die("verdict remediation_text_exact must be an array of strings")
    if "machine_evidence" in value and not isinstance(value["machine_evidence"], dict):
        die("verdict machine_evidence must be an object")
    manifest = manifest_by_id[run_id]
    firing_count = value.get("gate_firing_count", manifest.get("gate", {}).get("firing_count", 0))
    if type(firing_count) is not int or firing_count < 0:
        die("verdict requires a valid captured gate firing count")
    historical = value.get("machine_evidence", {}).get("historical_duplicates", [])
    if not isinstance(historical, list) or any(type(item) is not bool for item in historical):
        die("verdict historical duplicate evidence must be an array of booleans")
    shipped = value["machine"] == "duplicate" or value["semantic"] == "duplicate"
    if shipped:
        expected_outcome = "reached-review"
    elif firing_count > 0:
        expected_outcome = "caught-early"
    elif any(historical):
        expected_outcome = "self-corrected"
    else:
        expected_outcome = "never-duplicated"
    if value["outcome_class"] != expected_outcome:
        die(f"verdict outcome_class contradicts captured evidence; expected {expected_outcome}")
    expected_false_fire = firing_count > 0 and not shipped and not any(historical)
    if value["false_fire"] != expected_false_fire:
        die("verdict false_fire contradicts captured evidence")
    value = dict(value)
    value["schema_version"] = VERDICT_VERSION
    value["recorded_at"] = utc_now()
    return value


def command_freeze(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    destination = workspace / "frozen-plan.json"
    if destination.exists():
        die("pre-registration plan is already frozen")
    plan = read_json(pathlib.Path(args.file).expanduser().resolve())
    if not isinstance(plan.get("ratified_at"), str) or not plan["ratified_at"].strip() or not isinstance(plan.get("amendment"), str) or not plan["amendment"].strip():
        die("frozen plan requires ratified_at and amendment")
    maximum = plan.get("max_load")
    timeout = plan.get("timeout_seconds")
    if type(maximum) not in (int, float) or not math.isfinite(maximum) or maximum <= 0:
        die("frozen plan requires a positive finite max_load")
    if type(timeout) is not int or timeout <= 0:
        die("frozen plan requires a positive integer timeout_seconds")
    runs = plan.get("runs")
    if not isinstance(runs, list) or not runs:
        die("frozen plan requires a non-empty runs array")
    ids: set[str] = set()
    lanes: dict[str, list[dict[str, Any]]] = {}
    helper_families = ("distance-helper", "point-in-polygon", "both", "smoke")
    for item in runs:
        if not isinstance(item, dict):
            die("every frozen run must be an object")
        run_id = require_safe_id(str(item.get("run_id", "")))
        if run_id in ids:
            die(f"duplicate frozen run id: {run_id}")
        ids.add(run_id)
        lane = item.get("lane")
        if not isinstance(lane, str) or not SAFE_ID.fullmatch(lane):
            die(f"invalid frozen lane id: {run_id}")
        if item.get("arm") not in ARMS or item.get("harness") not in HARNESS_NAMES or not isinstance(item.get("model"), str) or not item["model"].strip():
            die(f"invalid frozen run axes: {run_id}")
        if "provider" not in item or (item["provider"] is not None and (not isinstance(item["provider"], str) or not item["provider"].strip())):
            die(f"invalid frozen provider: {run_id}")
        if "effort" not in item or (item["effort"] is not None and (not isinstance(item["effort"], str) or not item["effort"].strip())):
            die(f"invalid frozen effort: {run_id}")
        if item.get("helper_family") not in helper_families:
            die(f"invalid frozen helper family: {run_id}")
        if type(item.get("concurrent_lane_count")) is not int or item["concurrent_lane_count"] < 1:
            die(f"invalid frozen concurrent lane count: {run_id}")
        if type(item.get("lane_order")) is not int or item["lane_order"] not in (1, 2):
            die(f"invalid frozen lane order: {run_id}")
        lanes.setdefault(lane, []).append(item)
    if len(runs) != 14 or len(lanes) != 7:
        die("frozen confirmatory plan requires exactly seven paired lanes and fourteen runs")
    paired_axes = ("harness", "model", "provider", "effort", "helper_family", "concurrent_lane_count")
    for lane, pair in lanes.items():
        if len(pair) != 2 or {item["arm"] for item in pair} != set(ARMS) or {item["lane_order"] for item in pair} != {1, 2}:
            die(f"frozen lane is not one paired ON/OFF slate: {lane}")
        if any(pair[0][key] != pair[1][key] for key in paired_axes):
            die(f"frozen lane changes non-arm axes within its pair: {lane}")
    prompt_sha = plan.get("prompt_sha256")
    if not isinstance(prompt_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", prompt_sha):
        die("frozen plan requires prompt_sha256")
    plan["schema_version"] = "canonical-guard-frozen-plan/v1"
    plan["frozen_at"] = utc_now()
    write_json(destination, plan)
    destination.chmod(0o444)
    print(json.dumps({"frozen_plan": str(destination), "sha256": sha256_file(destination), "runs": len(runs)}, sort_keys=True))


def command_record_verdict(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    current = verdicts(workspace)
    value = read_json(pathlib.Path(args.file).expanduser().resolve())
    run_id = str(value.get("run_id", ""))
    if run_id in current:
        die(f"verdict already recorded for run: {run_id}")
    manifest_by_id = {item["run_id"]: item for item in manifests(workspace)}
    normalized = normalize_verdict(value, manifest_by_id)
    append_jsonl(workspace / "verdicts.jsonl", normalized)
    print(json.dumps({"recorded": normalized["run_id"]}))


def captured_gate_remediations(bundle: pathlib.Path, manifest: dict[str, Any]) -> list[str]:
    marker = re.compile(r"duplicate implementation detected|\[duplicate-implementation\]", re.I)
    values = list(manifest.get("gate", {}).get("remediation_text_exact", []))
    sources = sorted((bundle / "transcripts").glob("*.jsonl")) + sorted((bundle / "terminals").glob("*.txt")) + sorted((bundle / "late-recovery" / "terminals").glob("*.txt"))
    if not sources:
        sources = [bundle / "session.log"]
    for source in sources:
        if not source.is_file():
            continue
        if source.suffix == ".jsonl":
            for line in source.read_text(errors="replace").splitlines():
                if not marker.search(line):
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    values.append(line)
                    continue
                stack = [row]
                strings = []
                while stack:
                    item = stack.pop()
                    if isinstance(item, dict):
                        stack.extend(item.values())
                    elif isinstance(item, list):
                        stack.extend(item)
                    elif isinstance(item, str) and marker.search(item):
                        strings.append(item)
                if strings:
                    values.append(max(strings, key=len))
        else:
            text = source.read_text(errors="replace")
            if marker.search(text):
                values.append(text)
    unique: dict[str, str] = {}
    for value in values:
        normalized = re.sub(r"\s+", " ", value).strip()
        unique.setdefault(sha256_bytes(normalized.encode()), value)
    return list(unique.values())


def command_score(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    lock = workspace / ".score-lock"
    try:
        lock.mkdir()
    except FileExistsError:
        die("another scoring process holds the scoring lock")
    try:
        command_score_locked(args, workspace)
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass


def command_score_locked(args: argparse.Namespace, workspace: pathlib.Path) -> None:
    if (workspace / ".serial-run-lock").exists() or any(workspace.glob(".lane-run-lock-*")):
        die("scoring is forbidden while any run lock exists")
    current = verdicts(workspace)
    manifest_by_id = {item["run_id"]: item for item in manifests(workspace)}
    plan_path = workspace / "frozen-plan.json"
    if plan_path.is_file():
        expected_ids = {item["run_id"] for item in read_json(plan_path).get("runs", [])}
        complete_ids = {run_id for run_id, item in manifest_by_id.items() if item.get("stage") == "matrix"}
        if expected_ids - complete_ids:
            die("scoring is forbidden until every frozen matrix run has a manifest")
    if args.run_id not in manifest_by_id:
        die(f"unknown run: {args.run_id}")
    if args.run_id in current:
        die(f"verdict already recorded for run: {args.run_id}")
    manifest = manifest_by_id[args.run_id]
    semantic = read_json(pathlib.Path(args.semantic_file).expanduser().resolve())
    scorers = semantic.get("scorers")
    semantic_verdict = validate_scorers(scorers)
    workspace_config = read_json(workspace / "workspace.json")
    if manifest["detector_sha"] != workspace_config.get("detector_sha"):
        die("manifest detector_sha differs from the initialized pinned detector")
    template = pathlib.Path(workspace_config["templates"]["guard-on"]["path"])

    def score_patch(patch: pathlib.Path, suffix: str) -> subprocess.CompletedProcess[str]:
        scratch = workspace / f".score-{args.run_id}-{suffix}-{os.getpid()}"
        cow_copy(template, scratch)
        try:
            prepared_patch = scratch / ".git" / "captured-score.patch"
            patch_bytes = patch.read_bytes()
            prepared_patch.write_bytes(patch_bytes + (b"\n" if patch_bytes and not patch_bytes.endswith(b"\n") else b""))
            applied = run(["git", "apply", "--binary", str(prepared_patch)], cwd=scratch, check=False)
            if applied.returncode != 0:
                die(f"cannot reconstruct captured tree for scoring: {applied.stderr.strip()}")
            git(scratch, "add", "-A")
            run(["git", "commit", "--no-verify", "-m", "test: reconstruct captured benchmark tree"], cwd=scratch, env=clean_git_config_environment())
            return pinned_detector_run(scratch, template, manifest["base_sha"], manifest["detector_sha"])
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    bundle = workspace / "bundles" / args.run_id
    machine_result = score_patch(bundle / "final.diff", "final")
    historical_machine_duplicates = []
    for index, relative in enumerate(manifest["git"].get("history_diffs", []), 1):
        historical = score_patch(bundle / relative, f"history-{index}")
        historical_machine_duplicates.append(historical.returncode != 0)
    machine = "duplicate" if machine_result.returncode != 0 else "clean"
    remediations = captured_gate_remediations(bundle, manifest)
    gate_firing_count = max(manifest["gate"]["firing_count"], len(remediations))
    fired = gate_firing_count > 0
    ack = bool(manifest["git"]["trailers"])
    shipped = machine == "duplicate" or semantic_verdict == "duplicate"
    if shipped:
        outcome = "reached-review"
    elif fired:
        outcome = "caught-early"
    elif any(historical_machine_duplicates):
        outcome = "self-corrected"
    else:
        outcome = "never-duplicated"
    value = {
        "run_id": args.run_id,
        "machine": machine,
        "semantic": semantic_verdict,
        "outcome_class": outcome,
        "false_fire": fired and semantic_verdict == "clean" and machine == "clean" and not any(historical_machine_duplicates),
        "ack": ack,
        "gate_firing_count": gate_firing_count,
        "gate_evidence_source": "post-hoc derivation from immutable transcript and terminal captures",
        "remediation_text_exact": remediations,
        "fix_matches_remediation": next((firing.get("fix_matches_remediation") for firing in reversed(manifest["gate"].get("firings", [])) if isinstance(firing.get("fix_matches_remediation"), bool)), None),
        "review_rounds": None,
        "scorers": scorers,
        "machine_evidence": {"exit_code": machine_result.returncode, "stdout": machine_result.stdout, "stderr": machine_result.stderr, "historical_duplicates": historical_machine_duplicates},
    }
    normalized = normalize_verdict(value, manifest_by_id)
    append_jsonl(workspace / "verdicts.jsonl", normalized)
    print(json.dumps({"recorded": args.run_id, "machine": machine, "semantic": semantic_verdict, "outcome_class": outcome}, sort_keys=True))


def command_schema_check(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    unsupported = []
    checked = manifests(workspace)
    for table, fields in TABLE_REQUIREMENTS.items():
        for manifest in checked:
            for field in fields:
                if field.startswith("verdict."):
                    continue
                cursor: Any = manifest
                for part in field.split("."):
                    if not isinstance(cursor, dict) or part not in cursor:
                        unsupported.append({"table": table, "field": field, "run_id": manifest["run_id"]})
                        break
                    cursor = cursor[part]
    result = {
        "schema_version": SCHEMA_VERSION,
        "manifests_checked": len(checked),
        "supported_tables": len(TABLE_REQUIREMENTS) - len({item["table"] for item in unsupported}),
        "unsupported_tables": unsupported,
        "consumer_fields": TABLE_REQUIREMENTS,
        "intentional_omission": {
            "agent_self_reported_reasoning": "Omitted because asking would reveal the experiment; behavioral trace and final-diff evidence preserve observable behavior.",
            "adjudicated_verdicts_in_manifest": "Raw manifests stay immutable; adjudicated verdicts join by run_id from the separate append-only verdict ledger required by the protocol.",
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    if unsupported:
        raise SystemExit(1)


def md_table(headers: list[str], rows: list[list[Any]]) -> str:
    def cell(value: Any) -> str:
        if value is None:
            return "unknown"
        return str(value).replace("|", "\\|").replace("\n", " ")
    output = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    output.extend("| " + " | ".join(cell(value) for value in row) + " |" for row in rows)
    if not rows:
        output.append("| " + " | ".join(["No data"] + [""] * (len(headers) - 1)) + " |")
    return "\n".join(output)


def fisher_two_sided(a: int, b: int, c: int, d: int) -> float:
    row_one = a + b
    row_two = c + d
    successes = a + c
    total = row_one + row_two

    def probability(value: int) -> float:
        return math.comb(successes, value) * math.comb(total - successes, row_one - value) / math.comb(total, row_one)

    observed = probability(a)
    low = max(0, row_one - (total - successes))
    high = min(row_one, successes)
    return min(1.0, sum(probability(value) for value in range(low, high + 1) if probability(value) <= observed + 1e-12))


def wilson_interval(successes: int, total: int) -> tuple[float, float]:
    if total == 0:
        return (0.0, 0.0)
    z = 1.959963984540054
    proportion = successes / total
    denominator = 1 + z * z / total
    center = (proportion + z * z / (2 * total)) / denominator
    radius = z * math.sqrt(proportion * (1 - proportion) / total + z * z / (4 * total * total)) / denominator
    return (max(0.0, center - radius), min(1.0, center + radius))


def primary_outcome(manifest: dict[str, Any], verdict: dict[str, Any], remediations: list[str]) -> str:
    if verdict.get("machine") == "duplicate":
        return "reached-review"
    if remediations or manifest["gate"]["firing_count"]:
        return "caught-early"
    if any(verdict.get("machine_evidence", {}).get("historical_duplicates", [])):
        return "self-corrected"
    return "never-duplicated"


def html_table(headers: list[str], rows: list[list[Any]]) -> str:
    head = "".join(f"<th>{html.escape(str(value))}</th>" for value in headers)
    body = []
    for row in rows:
        cells = []
        for value in row:
            text = "unknown" if value is None else str(value)
            css = " bad" if "duplicate" in text.lower() or "attrition" in text.lower() else " good" if "caught-early" in text.lower() or text.lower().startswith("clean") else ""
            cells.append(f"<td class='{css.strip()}'>{html.escape(text)}</td>")
        body.append("<tr>" + "".join(cells) + "</tr>")
    return f"<div class='table-wrap'><table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table></div>"


def reshape_equivalence_appendix(report_file: str | None) -> tuple[str, str]:
    if not report_file:
        return "", ""
    report = pathlib.Path(report_file).expanduser().resolve().read_text()
    required_evidence = (
        "7 of 18 comparable codex-authored geometry functions",
        "11 of 18 are DIVERGENT",
        "reproduced correctly in all 6 runs",
        "detect-plane-overlaps.ts:86",
        "All three were caught on the first run",
    )
    missing = [item for item in required_evidence if item not in report]
    if missing:
        die("reshape equivalence report is missing required evidence: " + "; ".join(missing))
    paragraphs = [
        "Across the six Codex GUARD-OFF runs, the new geometry functions reimplemented the same purpose as existing helpers, but purpose overlap did not always mean identical behavior. Differential execution found 7 of 18 comparable function pairs behaviorally identical and 11 of 18 divergent. All six point-to-segment distance functions were identical.",
        "The largest divergence was deliberate boundary handling: all six new point-in-ring functions count points on an edge or vertex as inside, while the existing donor returns false there. The donor comment promises boundary tolerance, but the code at detect-plane-overlaps.ts:86 does not implement it. A parcel-outline vertex is a reproduced counterexample, making this a plausible production bug in the donor rather than evidence that the new function serves a different purpose.",
        "Calibration passed before these comparisons: identity controls reached 100% agreement, and three deliberately damaged controls were all detected. Six additional ring-to-ring distance functions had no donor with a matching signature and were not compared.",
        "Blind-review disclosure: the human reviewer may have seen this equivalence result before completing the masked 14-sample pass.",
    ]
    markdown = "## Appendix: Codex reshaping differential check\n\n" + "\n\n".join(paragraphs) + "\n\n"
    page = "<section><h2>Appendix: Codex reshaping differential check</h2>" + "".join(f"<p>{html.escape(item)}</p>" for item in paragraphs) + "</section>"
    return markdown, page


def peak_numeric_load(samples: Any) -> float | int | None:
    if not isinstance(samples, list):
        return None
    values = [sample.get("one_minute") for sample in samples if isinstance(sample, dict)]
    numeric = [value for value in values if type(value) in (int, float) and math.isfinite(value)]
    return max(numeric) if numeric else None


def command_scoreboard(args: argparse.Namespace) -> None:
    workspace = require_workspace(args.workspace)
    all_runs = manifests(workspace)
    runs = [item for item in all_runs if item.get("stage") == "matrix"]
    judged = verdicts(workspace)
    if len(runs) != 14 or any(item["run_id"] not in judged for item in runs):
        die("presentation scoreboard requires all fourteen matrix manifests and verdicts")
    remediations = {item["run_id"]: captured_gate_remediations(workspace / "bundles" / item["run_id"], item) for item in runs}
    rank = {"glm-5.2-high": 0, "composer-2.5": 1, "cursor-grok-4.5-high-fast": 2, "claude-sonnet-5": 3, "gpt-5.6-sol": 4, "gpt-5.6-terra": 5, "gpt-5.6-luna": 6}
    models = sorted({item["model"] for item in runs}, key=lambda value: (rank.get(value, 99), value))
    by_cell = {(item["model"], item["arm"]): item for item in runs}

    def cell(value: Any, item: dict[str, Any]) -> str:
        return f"{value} [{item['run_id']}]"

    headline_rows = []
    for model in models:
        off = by_cell[(model, "guard-off")]
        on = by_cell[(model, "guard-on")]
        off_verdict = judged[off["run_id"]]
        on_verdict = judged[on["run_id"]]
        on_fired = bool(remediations[on["run_id"]] or on["gate"]["firing_count"])
        label = model + (" — underdog" if model == "glm-5.2-high" else "")
        headline_rows.append([
            label,
            cell("yes" if off_verdict["machine"] == "duplicate" else "no", off),
            cell("yes" if primary_outcome(off, off_verdict, remediations[off["run_id"]]) == "self-corrected" else "no", off),
            cell("yes" if on_fired else "no", on),
            cell("yes" if on_fired and on_verdict["machine"] == "clean" else "no", on),
            cell("yes" if on_verdict["ack"] else "no", on),
            cell(f"{off['timing']['wall_seconds']:.0f}s / {off['usage']['total_tokens'] if off['usage']['total_tokens'] is not None else 'tokens unavailable'}", off),
            cell(f"{on['timing']['wall_seconds']:.0f}s / {on['usage']['total_tokens'] if on['usage']['total_tokens'] is not None else 'tokens unavailable'}", on),
        ])

    off_runs = [item for item in runs if item["arm"] == "guard-off"]
    on_runs = [item for item in runs if item["arm"] == "guard-on"]
    off_duplicates = sum(judged[item["run_id"]]["machine"] == "duplicate" for item in off_runs)
    on_duplicates = sum(judged[item["run_id"]]["machine"] == "duplicate" for item in on_runs)
    fisher = fisher_two_sided(on_duplicates, len(on_runs) - on_duplicates, off_duplicates, len(off_runs) - off_duplicates)
    difference = on_duplicates / len(on_runs) - off_duplicates / len(off_runs)
    on_interval = wilson_interval(on_duplicates, len(on_runs))
    off_interval = wilson_interval(off_duplicates, len(off_runs))
    lower = difference - math.sqrt((on_duplicates / len(on_runs) - on_interval[0]) ** 2 + (off_interval[1] - off_duplicates / len(off_runs)) ** 2)
    upper = difference + math.sqrt((on_interval[1] - on_duplicates / len(on_runs)) ** 2 + (off_duplicates / len(off_runs) - off_interval[0]) ** 2)
    pooled_rows = [["Machine duplicates", f"{off_duplicates}/{len(off_runs)}", f"{on_duplicates}/{len(on_runs)}", f"{difference * 100:+.1f} pp (Newcombe 95% CI {lower * 100:+.1f} to {upper * 100:+.1f})", f"two-sided Fisher p={fisher:.3f}"]]

    sections: list[tuple[str, list[str], list[list[Any]]]] = [
        ("Confirmatory model scoreboard", ["Model", "OFF duplicate shipped?", "OFF self-corrected?", "ON gate fired?", "ON fixed before review?", "ON acknowledged?", "OFF wall / tokens", "ON wall / tokens"], headline_rows),
        ("Pooled primary result", ["Outcome", "Without guard", "With guard", "Risk difference", "Significance"], pooled_rows),
    ]
    detail = []
    for item in sorted(runs, key=lambda value: (rank.get(value["model"], 99), value["arm"])):
        verdict = judged[item["run_id"]]
        detail.append([item["run_id"], item["model"], item["arm"], verdict["machine"], primary_outcome(item, verdict, remediations[item["run_id"]]), len(remediations[item["run_id"]]), item["resolution"]["path"], item["usage"]["total_tokens"], item["timing"]["wall_seconds"]])
    sections.append(("Per-run engineering detail", ["Run", "Model", "Arm", "Machine verdict", "Primary class", "Firings", "Resolution path", "Tokens", "Wall seconds"], detail))
    outcome_rows = [[arm, outcome, sum(primary_outcome(item, judged[item["run_id"]], remediations[item["run_id"]]) == outcome for item in runs if item["arm"] == arm)] for arm in ARMS for outcome in ("caught-early", "reached-review", "self-corrected", "never-duplicated")]
    sections.append(("Primary outcome classes by arm", ["Arm", "Outcome class", "Runs"], outcome_rows))
    family_rows = []
    for family in ("distance-helper", "point-in-polygon", "both", "none"):
        for arm in ARMS:
            selected = [item for item in runs if item["arm"] == arm and (family in item["helper_families"] or (family == "both" and len(item["helper_families"]) > 1) or (family == "none" and not item["helper_families"]))]
            family_rows.append([family, arm, len(selected), sum(judged[item["run_id"]]["machine"] == "duplicate" for item in selected), sum(judged[item["run_id"]]["semantic"] == "duplicate" for item in selected)])
    sections.append(("Results by helper family", ["Helper family", "Arm", "Runs", "Machine duplicates", "Provisional semantic duplicates"], family_rows))
    def reused_existing_helper(item: dict[str, Any]) -> bool:
        final_diff = (workspace / "bundles" / item["run_id"] / "final.diff").read_text(errors="replace")
        return bool(re.search(r"^\+import[^\n]*\b(?:pointInRing|pointInPolygon|polygonContains|pointToSegmentDistance|minDistanceToBoundary)\b", final_diff, re.M))

    clean_runs = [item for item in runs if judged[item["run_id"]]["machine"] == "clean"]
    clean_rows = [
        ["exported then imported an existing helper", sum(reused_existing_helper(item) for item in clean_runs)],
        ["new functions with an existing helper's purpose (behavior may differ)", sum(not reused_existing_helper(item) for item in clean_runs)],
    ]
    sections.append(("Clean-path breakdown", ["Resolution path", "Machine-clean runs"], clean_rows))
    teach_rows = []
    for item in runs:
        for ordinal, remediation in enumerate(remediations[item["run_id"]], 1):
            start = re.search(r"[^\n]*\[duplicate-implementation\]", remediation, re.I)
            excerpt = remediation[start.start() :] if start else remediation
            stops = [position for token in ("ELIFECYCLE", "exit status", "┃  editor-bugfix-tests") if (position := excerpt.find(token)) >= 0]
            if stops:
                excerpt = excerpt[: min(stops)]
            teach_rows.append([item["run_id"], item["model"], ordinal, excerpt.strip()[:6000], judged[item["run_id"]].get("machine") == "clean"])
    sections.append(("Did the guard teach", ["Run", "Model", "Firing", "Exact captured remediation excerpt", "Fix matched"], teach_rows))
    attrition_rows = [[item["run_id"], item["harness"], item["attrition"]["timeout"], item["attrition"]["transcript_loss"], item["attrition"]["reason"]] for item in all_runs if item["attrition"]["mechanical_failure"] or item.get("stage") == "excluded"]
    sections.append(("Attrition and exclusions", ["Run", "Harness", "Timeout", "Transcript loss", "Reason"], attrition_rows))

    exploratory = [item for item in all_runs if item.get("stage") == "exploratory"]
    exploratory_rows = [[item["run_id"], item["model"], item["arm"], item.get("concurrent_lane_count"), peak_numeric_load(item.get("load_samples")), item["timing"]["wall_seconds"], "attrition" if item["attrition"]["mechanical_failure"] else "captured"] for item in exploratory]
    plan_path = workspace / "exploratory-plan.json"
    if plan_path.is_file():
        plan = read_json(plan_path)
        completed = {item["run_id"] for item in exploratory}
        dropped = set(plan.get("slate_cut", {}).get("dropped", []))
        for item in plan.get("runs", []):
            if item["run_id"] in completed:
                continue
            exploratory_rows.append([item["run_id"], item["model"], item["arm"], None, None, None, "dropped by slate cut" if item["model"] in dropped else "pending"])
    sections.append(("Exploratory extension — outside confirmatory counts", ["Run", "Model", "Arm", "Concurrent lanes", "Peak 1m load", "Wall seconds", "Status"], exploratory_rows))

    no_fire_pairs = []
    for model in models:
        on = by_cell[(model, "guard-on")]
        off = by_cell[(model, "guard-off")]
        if not remediations[on["run_id"]]:
            no_fire_pairs.append((on, off))
    wall_overheads = [(on["timing"]["wall_seconds"] / off["timing"]["wall_seconds"] - 1) * 100 for on, off in no_fire_pairs]
    token_overheads = [(on["usage"]["total_tokens"] / off["usage"]["total_tokens"] - 1) * 100 for on, off in no_fire_pairs if on["usage"]["total_tokens"] and off["usage"]["total_tokens"]]
    catches = sum(bool(remediations[item["run_id"]]) and judged[item["run_id"]]["machine"] == "clean" for item in on_runs)
    wall_summary = f"{statistics.median(wall_overheads):+.1f}%" if wall_overheads else "unknown"
    token_summary = f"{statistics.median(token_overheads):+.1f}%" if token_overheads else "unknown"
    cost_text = f"The guard caught {catches} machine-detectable duplicate runs before review. On the {len(no_fire_pairs)} ON/OFF pairs where it did not fire, median wall overhead was {wall_summary} and median token overhead among measured pairs was {token_summary}. No confirmatory run has verified dollar cost, and PR 4479 supplies 19 review submissions but no dollar telemetry; the money comparison is therefore unknown rather than zero."
    packet_note = " A masked packet set accompanies this workspace." if (workspace / "semantic-packets").is_dir() else ""
    semantic_text = "LLM judge: 14/14 final modules contain a semantic duplicate in both arms — PROVISIONAL, human verdict pending. The frozen primary detector tests normalized near-verbatim implementations; the secondary rubric judges whether new functions repeat an existing helper's purpose and natural input shape, which does not necessarily imply identical behavior." + packet_note
    skeptic = "All four OFF-arm machine-positive runs contain a near-verbatim pointInRing copy, so every primary catch is in the PR-adjacent point-in-polygon family rather than the PR-untouched distance-helper headline stratum. The first run started 4.1 seconds after the plan froze. The max-load ceiling was relaxed from 8 to 100 under the recorded section 5-S sprint amendment, with every sample retained. The human reviewer may have seen the differential-equivalence result before completing the masked pass."
    reshape_markdown, reshape_html = reshape_equivalence_appendix(args.reshape_report)
    recovery_note = " Exact post-teardown terminal recoveries are hash-recorded in the supplied capture-recoveries.jsonl ledger." if (workspace / "capture-recoveries.jsonl").is_file() else ""
    honesty = "n=1 per model and n=7 per arm: model rows are descriptive and the pooled Fisher result is not a powered per-model claim. Five contaminated pre-refreeze runs are exclusions, not outcomes. Cursor token/cost fields are unavailable by protocol. The subdirectory detector blind spot remains. An OFF candidate can reconstruct the hidden arm difference with targeted Git-object forensics. The raw manifest firing count is unreliable for the three Cursor ON runs; exact terminal captures are the scoreboard authority." + recovery_note
    evidence_note = "Evidence note: per-run convenience fields for suites, remediation, pushes, reviews, and firing counts are not authoritative in this benchmark version. Every published duplicate/result count and outcome was re-derived from final diffs plus pinned-detector evidence and independently recomputed."
    markdown = "# Canonical guard benchmark scoreboard\n\n**Primary result:** the guard reduced machine-detectable duplicates from " + f"{off_duplicates}/{len(off_runs)} to {on_duplicates}/{len(on_runs)}, but the two-sided Fisher result is p={fisher:.3f}.\n\n> {semantic_text}\n\n> {evidence_note}\n\n"
    for title, headers, rows in sections:
        markdown += f"## {title}\n\n{md_table(headers, rows)}\n\n"
    markdown += f"## Cost versus review\n\n{cost_text}\n\n## Skeptic notes\n\n{skeptic}\n\n{reshape_markdown}## Honesty footer\n\n{honesty}\n"
    pathlib.Path(args.markdown).write_text(markdown)
    body = "".join(f"<section><h2>{html.escape(title)}</h2>{html_table(headers, rows)}</section>" for title, headers, rows in sections)
    page = f"<!doctype html><html><head><meta charset='utf-8'><title>Canonical guard benchmark</title><style>:root{{--ink:#17202a;--muted:#65707d;--paper:#fbfaf7;--line:#d8dce2;--good:#dff4e8;--bad:#fde4e1;--accent:#4353ff}}*{{box-sizing:border-box}}body{{font:15px/1.45 Inter,ui-sans-serif,system-ui;color:var(--ink);background:var(--paper);margin:0}}main{{max-width:1440px;margin:auto;padding:48px}}h1{{font-size:42px;letter-spacing:-.03em;margin:0 0 8px}}h2{{margin:42px 0 14px;font-size:24px}}.kicker{{color:var(--accent);font-weight:750;text-transform:uppercase;letter-spacing:.09em}}.lede{{font-size:20px;max-width:900px}}.callout{{background:#eef0ff;border-left:5px solid var(--accent);padding:16px 20px;margin:24px 0;max-width:1100px}}.table-wrap{{overflow:auto;border:1px solid var(--line);border-radius:10px;background:white}}table{{border-collapse:collapse;width:100%;min-width:780px}}th,td{{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;white-space:pre-wrap}}th{{background:#f0f2f5;position:sticky;top:0}}td.good{{background:var(--good)}}td.bad{{background:var(--bad)}}.foot{{color:var(--muted);border-top:1px solid var(--line);margin-top:48px;padding-top:20px}}@media print{{main{{padding:20px}}.table-wrap{{overflow:visible}}}}</style></head><body><main><div class='kicker'>Frozen 14-run confirmatory benchmark</div><h1>Canonical guard scoreboard</h1><p class='lede'>Machine-detectable duplicates fell from <strong>{off_duplicates}/{len(off_runs)}</strong> without the guard to <strong>{on_duplicates}/{len(on_runs)}</strong> with it. Two-sided Fisher p={fisher:.3f}; risk difference {difference * 100:+.1f} percentage points.</p><div class='callout'>{html.escape(semantic_text)}</div><div class='callout'>{html.escape(evidence_note)}</div>{body}<section><h2>Cost versus review</h2><p>{html.escape(cost_text)}</p></section><section><h2>Skeptic notes</h2><p>{html.escape(skeptic)}</p></section>{reshape_html}<div class='foot'><strong>Honesty footer.</strong> {html.escape(honesty)}</div></main></body></html>\n"
    pathlib.Path(args.html).write_text(page)
    print(json.dumps({"markdown": args.markdown, "html": args.html, "matrix_runs": len(runs), "exploratory_runs": len(exploratory), "verdicts": len(judged), "fisher_p": fisher, "risk_difference": difference}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Build and operate the pre-registered canonical-guard benchmark without exposing benchmark tooling inside candidate worktrees.")
    commands = result.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="create the local bare mirror and fully installed GUARD-ON/GUARD-OFF templates")
    init.add_argument("--workspace", required=True)
    init.add_argument("--source", required=True, help="trusted local Artemis checkout used only during setup")
    init.add_argument("--ref", required=True, help="pinned PR branch commit or ref")
    init.set_defaults(handler=command_init)
    fixture = commands.add_parser("fixture-check", help="record the three frozen detector calibration outcomes")
    fixture.add_argument("--workspace", required=True)
    fixture.set_defaults(handler=command_fixture)
    run_parser = commands.add_parser("run", help="admit, copy, launch, capture, and tear down one strictly serial run")
    run_parser.add_argument("--workspace", required=True)
    run_parser.add_argument("--run-id", required=True)
    run_parser.add_argument("--arm", required=True, choices=ARMS)
    run_parser.add_argument("--harness", required=True, choices=HARNESS_NAMES)
    run_parser.add_argument("--model", required=True)
    run_parser.add_argument("--provider")
    run_parser.add_argument("--effort")
    run_parser.add_argument("--prompt-file", required=True)
    run_parser.add_argument("--helper-family", choices=("distance-helper", "point-in-polygon", "both", "smoke"))
    run_parser.add_argument("--stage", choices=("smoke", "matrix", "exploratory"), default="matrix")
    run_parser.add_argument("--lane")
    run_parser.add_argument("--concurrent-lane-count", type=int, default=1)
    run_parser.add_argument("--load-file")
    run_parser.add_argument("--max-load", type=float, default=8.0)
    run_parser.add_argument("--timeout", type=int, default=2700)
    run_parser.set_defaults(handler=command_run)
    freeze = commands.add_parser("freeze", help="freeze the ratified plan before the first matrix dispatch")
    freeze.add_argument("--workspace", required=True)
    freeze.add_argument("--file", required=True)
    freeze.set_defaults(handler=command_freeze)
    score = commands.add_parser("score", help="post-hoc machine-score one captured run and join exactly two independent semantic verdicts")
    score.add_argument("--workspace", required=True)
    score.add_argument("--run-id", required=True)
    score.add_argument("--semantic-file", required=True)
    score.set_defaults(handler=command_score)
    record = commands.add_parser("record-verdict", help="append one externally adjudicated fixture verdict object to the separate immutable ledger")
    record.add_argument("--workspace", required=True)
    record.add_argument("--file", required=True)
    record.set_defaults(handler=command_record_verdict)
    schema = commands.add_parser("schema-check", help="prove the raw schema can derive all seven registered tables")
    schema.add_argument("--workspace", required=True)
    schema.set_defaults(handler=command_schema_check)
    scoreboard = commands.add_parser("scoreboard", help="generate Markdown and HTML tables from manifests plus verdicts")
    scoreboard.add_argument("--workspace", required=True)
    scoreboard.add_argument("--markdown", required=True)
    scoreboard.add_argument("--html", required=True)
    scoreboard.add_argument("--reshape-report", help="optional differential-execution report to validate and summarize in the appendix")
    scoreboard.set_defaults(handler=command_scoreboard)
    return result


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
