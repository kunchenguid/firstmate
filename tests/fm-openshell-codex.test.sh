#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import shutil
import time
import sys
import tempfile
import tarfile
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("runner", root / "bin/fm-openshell-codex.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

with tempfile.TemporaryDirectory(dir=root / "tests", prefix="openshell-test-") as tmp:
    base = Path(tmp)
    fake = base / "openshell"
    log = base / "commands.jsonl"
    identity = base / "identity"
    identity.write_text("workspace-original")
    remote_root = base / "sandbox"
    (remote_root / ".git" / "fm-openshell" / "channel" / "inbox").mkdir(parents=True)
    (remote_root / ".git" / "fm-openshell" / "channel" / "responses").mkdir()
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as f:
    f.write(json.dumps(args) + "\\n")
if "sandbox" in args and "create" in args and "--name" in args:
    name = args[args.index("--name") + 1]
    if len(name) > 19:
        sys.exit("name exceeds maximum length (" + str(len(name)) + " > 19)")
if "sandbox" in args and "upload" in args and "--no-git-ignore" in args:
    source = pathlib.Path(args[-2])
    destination = pathlib.PurePosixPath(args[-1])
    if args[-1].endswith("/") or destination.parent == pathlib.PurePosixPath("/"):
        destination = destination / source.name
    target = pathlib.Path(os.environ["REMOTE_ROOT"]) / destination.relative_to("/sandbox")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_dir():
        sys.exit("cannot extract a file over a directory")
    shutil.copy2(source, target)
    if source.name == "launch-brief.txt":
        pathlib.Path(os.environ["BRIEF_LOG"]).write_bytes(target.read_bytes())
workspace = args[args.index("--workspace") + 1] if "--workspace" in args else os.environ.get("OPENSHELL_WORKSPACE", "default")
if "workspace" in args and "get" in args:
    print("Workspace:\\n\\n  Name: " + workspace + "\\n  Id: " + pathlib.Path(os.environ["WORKSPACE_ID_FILE"]).read_text())
''')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ["PATH"],
               COMMAND_LOG=str(log), REMOTE_ROOT=str(remote_root), BRIEF_LOG=str(base / "brief-delivered"), WORKSPACE_ID_FILE=str(identity), OPENSHELL_WORKSPACE="other",
               SSH_AUTH_SOCK=str(base / "host-agent.sock"), GIT_SSH_COMMAND="host-ssh-command",
               GIT_CONFIG_GLOBAL=str(base / "host-gitconfig"))
    ctx = dict(id="task", home=base, state=base, gateway="local", workspace="team",
               workspace_id="workspace-original", journal=base / "journal.json", worktree=base,
               sandbox="task-sandbox", stage_root=base, values={})
    def commands():
        return [json.loads(line) for line in log.read_text().splitlines()]
    def refuses(call):
        try:
            call()
        except runner.Refusal:
            return
        raise AssertionError("expected a closed refusal")
    with patch.dict(os.environ, env):
        result = subprocess.run([sys.executable, str(root / "bin/fm-openshell-codex.py"),
                                 "workspace-id", "local", "team"], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "workspace-original"
        for command in [("sandbox", "create"), ("sandbox", "get"), ("sandbox", "delete"),
                        ("sandbox", "stop"), ("sandbox", "start"), ("sandbox", "upload"),
                        ("sandbox", "download"), ("sandbox", "exec"), ("policy", "list")]:
            runner.openshell_run(ctx, *command)
            assert commands()[-1][:4] == ["--gateway", "local", "--workspace", "team"]
        runner.write_journal(ctx, {"phase": "agent-exited"})
        assert runner.read_journal(ctx)["workspace_id"] == "workspace-original"
        refuses(lambda: runner.read_journal(dict(ctx, workspace_id="replacement")))
        refuses(lambda: runner.read_journal(dict(ctx, workspace="other")))
        count = len(commands())
        refuses(lambda: runner.openshell_run(dict(ctx, workspace_id=""), "sandbox", "delete"))
        assert len(commands()) == count
        identity.write_text("workspace-recreated")
        refuses(lambda: runner.delete_sandbox(ctx))
        assert commands()[-1][-3:] == ["workspace", "get", "team"]
        identity.write_text("workspace-original")
        image = "localhost/fm-openshell-codex@sha256:" + "c" * 64
        def generated_sandbox(home, task):
            result = subprocess.run([sys.executable, str(root / "bin/fm-openshell-codex.py"),
                                     "sandbox-name", str(home), task], capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()
        generated_name = generated_sandbox(base, "task")
        assert len(generated_name) == 19
        assert re.fullmatch(r"[a-z0-9][a-z0-9-]*", generated_name)
        assert generated_sandbox(base / ".", "task") == generated_name
        assert generated_sandbox(base, "task-other") != generated_name
        assert generated_sandbox(base / "other-home", "task") != generated_name
        launch_ctx = dict(ctx, sandbox=generated_name, image=image, policy=base / "policy.yaml", providers=["codex"])
        count = len(commands())
        for invalid in ["", "--host", "image with spaces", "image\nother"]:
            refuses(lambda: runner.create_sandbox(dict(launch_ctx, image=invalid), {}))
        assert len(commands()) == count
        with patch.object(runner, "sandbox_get", return_value={"name": generated_name}):
            refuses(lambda: runner.create_sandbox(launch_ctx, {}))
        assert len(commands()) == count
        with patch.object(runner, "sandbox_get", return_value=None), \
             patch.object(runner, "workspace_archive", return_value=base / "workspace.tar"), \
             patch.object(runner, "upload_file"), patch.object(runner, "extract_workspace"), \
             patch.object(runner, "refresh_inbox_mirror", return_value="inbox"):
            runner.create_sandbox(launch_ctx, {})
        create = [command for command in commands() if "create" in command][-1]
        assert create[create.index("--name") + 1] == generated_name, create
        assert create[create.index("--from") + 1] == image, create
        assert "--no-auto-providers" in create
        assert create[create.index("--provider") + 1] == "codex"
        for model, effort, expected_model, expected_effort in [
            ("default", "default", "gpt-6.1-sol", "medium"),
            ("", "", "gpt-6.1-sol", "medium"),
            ("custom-model", "high", "custom-model", "high"),
            ("gpt-5.6-luna", "max", "gpt-5.6-luna", "max")]:
            prompt = "FIRSTMATE_OP: v1 launch-brief\nPrivate task words: 'quoted' $value `literal`\nUnicode: café\n"
            with patch.object(runner, "sync_channels", lambda ctx: None):
                assert runner.run_codex(ctx, {}, prompt, model, effort) == 0
            assert (base / "brief-delivered").read_bytes() == prompt.encode("utf-8")
            assert all(prompt not in arg and "Private task words" not in arg for command in commands() for arg in command)
            assert not list(base.glob(".fm-openshell-brief-*"))
            args = commands()[-1]
            codex = args[args.index("--") + 1:]
            assert codex[codex.index("--model") + 1] == expected_model
            assert 'model_reasoning_effort="' + expected_effort + '"' in codex
            assert "--dangerously-bypass-approvals-and-sandbox" in codex
            assert codex[-1] == "Read the brief at /sandbox/.git/fm-openshell/launch-brief.txt and follow it exactly."
            upload = [command for command in commands() if "upload" in command][-1]
            assert upload[-1] == "/sandbox/.git/fm-openshell/"
            assert (remote_root / ".git" / "fm-openshell" / "launch-brief.txt").read_bytes() == prompt.encode("utf-8")
            assert "CODEX_HOME=/tmp/fm-codex-home" in args
            forwarded = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg == "--env")
            assert "SSH_AUTH_SOCK" not in forwarded
            assert "GIT_SSH_COMMAND" not in forwarded
            assert forwarded["GIT_CONFIG_GLOBAL"] == "/dev/null"
        for leaf, destination in [("0001.msg", "/sandbox/.git/fm-openshell/channel/inbox"),
                                  ("response.json", "/sandbox/.git/fm-openshell/channel/responses/")]:
            source = base / ("source-" + leaf)
            source.mkdir()
            (source / leaf).write_text("task channel payload")
            runner.upload_files(ctx, source, destination)
            assert (remote_root / destination.removeprefix("/sandbox/") / leaf).read_text() == "task channel payload"
        archive_source = base / "workspace.tar"
        archive_source.write_bytes(b"archive payload")
        runner.upload_file(ctx, archive_source, "/sandbox")
        assert (remote_root / "workspace.tar").read_bytes() == b"archive payload"
        for options, expected in [([], ("gpt-6.1-sol", "medium")),
                                  (["--model", "custom", "--effort", "high"], ("custom", "high"))]:
            with patch.object(sys, "argv", ["runner", "run", "task", "brief", *options]), patch.object(runner, "run_task", return_value=0) as launch:
                assert runner.main() == 0
                assert launch.call_args.args == ("task", "brief", *expected)
        old_journal = json.loads(ctx["journal"].read_text())
        old_journal.pop("workspace_id")
        ctx["journal"].write_text(json.dumps(old_journal))
        refuses(lambda: runner.read_journal(ctx))
        state = base / "state"
        state.mkdir()
        sandbox = generated_name
        metadata = dict(openshell="codex-v1", harness="codex", backend="herdr", kind="ship",
                        mode="no-mistakes", openshell_providers="codex", openshell_gateway="local",
                        openshell_name=sandbox, worktree=str(base), tasktmp="/tmp/fm-task", branch="task")
        for fields in [{}, {"openshell_workspace": "team"},
                       {"openshell_workspace": "team", "openshell_workspace_id": ""}]:
            (state / "task.meta").write_text("".join(k + "=" + v + "\n" for k, v in {**metadata, **fields}.items()))
            with patch.dict(os.environ, FM_HOME=str(base), FM_STATE_OVERRIDE=str(state)):
                refuses(lambda: runner.load_context("task"))
print("ok - workspace identity binds commands and recovery; Codex defaults preserve overrides")

with tempfile.TemporaryDirectory(dir=root / "tests", prefix="openshell-fixes-") as tmp:
    base = Path(tmp)
    fake = base / "openshell"
    fake.write_text("""#!/usr/bin/env python3
import json, os, pathlib, re, shutil, subprocess, sys, time
args = sys.argv[1:]
if 'workspace' in args and 'get' in args:
    name = args[args.index('--workspace') + 1]
    print('Workspace:\\n\\n  Name: ' + name + '\\n  Id: exact-id')
elif 'sandbox' in args and 'get' in args:
    print('sandbox not found', file=sys.stderr)
    sys.exit(1)
elif 'sandbox' in args and 'download' in args:
    remote = pathlib.Path(os.environ['DOWNLOAD_SOURCE'])
    source = args[-2]
    try:
        relative = pathlib.PurePosixPath(source).relative_to('/sandbox')
        if '..' in relative.parts:
            raise ValueError('noncanonical source')
        (remote / relative).resolve().relative_to(remote.resolve())
    except ValueError:
        sys.exit('download source is outside sandbox workspace')
    source_path = remote / relative
    if source_path.is_dir():
        shutil.copytree(source_path, pathlib.Path(args[-1]), symlinks=True)
        transferred = [str(relative / p.relative_to(source_path)) for p in source_path.rglob('*') if p.is_file()]
    else:
        source_file = remote / relative
        if os.environ.get('FAIL_ARCHIVE_DOWNLOAD') == '1':
            sys.exit('injected archive download failure')
        shutil.copy2(source_file, pathlib.Path(args[-1]) / source_file.name)
        import tarfile
        with tarfile.open(source_file) as archive:
            transferred = archive.getnames()
    with open(os.environ['DOWNLOAD_LOG'], 'a') as output:
        output.write(json.dumps(transferred) + '\\n')
elif '--' in args and args[args.index('--') + 1] == 'python3':
    command = args[args.index('--') + 1:]
    if len(command) == 5:
        remote = pathlib.Path(os.environ['DOWNLOAD_SOURCE'])
        command[3] = str(remote)
        command[4] = str(remote / pathlib.PurePosixPath(command[4]).relative_to('/sandbox'))
        subprocess.run(command, check=True)
    elif len(command) == 4:
        remote = pathlib.Path(os.environ['DOWNLOAD_SOURCE'])
        command[3] = str(remote / pathlib.PurePosixPath(command[3]).relative_to('/sandbox'))
        directory = pathlib.Path(command[3])
        if os.environ.get('FAIL_SNAPSHOT_CLEANUP') == '1' and any(re.fullmatch(r'[.]fm-openshell-snapshot-[0-9a-f]{32}[.]tar', p.name) and p.is_file() for p in directory.iterdir()):
            sys.exit('injected cleanup transport failure')
        subprocess.run(command, check=True)
elif '--' in args and args[args.index('--') + 1] == 'git':
    command = args[args.index('--') + 1:]
    remote = os.environ['DOWNLOAD_SOURCE']
    command = [arg.replace('/sandbox', remote) if arg.startswith(('--git-dir=', '--work-tree=')) else arg for arg in command]
    subprocess.run(command, check=True)
elif '--' in args and args[args.index('--') + 1] == 'codex':
    time.sleep(20)
""")
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ["PATH"])
    def make_repo(name, directory_index=False):
        area = base / name
        area.mkdir()
        wt = area / "host"
        wt.mkdir()
        runner.run(["git", "init", "-q", "-b", "task", str(wt)], env=runner.cli_env())
        if directory_index:
            (wt / "index").mkdir()
            (wt / "index" / "payload").write_text("original index directory")
        else:
            (wt / "index").write_text("original project index")
        (wt / "payload").write_text("original payload")
        runner.git(wt, "add", ".")
        runner.git(wt, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "baseline")
        stage_root = area / "stage-root"
        stage_root.mkdir()
        stage = stage_root / "workspace"
        runner.run(["git", "clone", "-q", "--no-hardlinks", str(wt), str(stage)], env=runner.cli_env())
        state = area / "state"
        state.mkdir()
        responses = area / "responses"
        responses.mkdir()
        ctx = dict(id="task", root=root, home=area, state=state, config=area / "config", values={"project": str(wt)},
                   gateway="local", workspace="team", workspace_id="exact-id", branch="task", sandbox="task-sandbox", image="localhost/fm-codex:test", providers=["codex"],
                   worktree=wt, stage_root=stage_root, stage=stage, journal=area / "journal.json",
                   policy=area / "policy.yaml", bridge_dir=area / "bridge", responses=responses,
                   validation=state / "task.openshell-validation.json", processed_requests=set())
        paths = runner.git_paths(wt)
        journal = dict(phase="snapshot-downloaded", base_head=runner.git(wt, "rev-parse", "HEAD"),
                       base_index_tree=runner.git(wt, "write-tree"), base_paths=paths,
                       base_files=runner.snapshot(wt, paths), object_format="sha1", origin="")
        runner.write_journal(ctx, journal)
        return ctx, journal
    with patch.dict(os.environ, env):
        for mode in [0o600, 0o400, 0o700, 0o500, 0o644, 0o755, 0o4700]:
            ctx, journal = make_repo("new-mode-" + oct(mode))
            private = ctx["stage"] / "new-file"
            private.write_text("sandbox-created content")
            private.chmod(mode)
            runner.git(ctx["stage"], "add", "new-file")
            runner.git(ctx["stage"], "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "new file")
            runner.sync_workspace(ctx, journal)
            assert (ctx["worktree"] / "new-file").stat().st_mode & 0o7777 == mode & 0o777
        ctx, journal = make_repo("existing-private-mode")
        (ctx["worktree"] / "payload").chmod(0o600)
        journal["base_files"] = runner.snapshot(ctx["worktree"], journal["base_paths"])
        runner.write_journal(ctx, journal)
        (ctx["stage"] / "payload").write_text("changed private content")
        (ctx["stage"] / "payload").chmod(0o666)
        runner.git(ctx["stage"], "add", "payload")
        runner.git(ctx["stage"], "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "change private file")
        runner.sync_workspace(ctx, journal)
        assert (ctx["worktree"] / "payload").stat().st_mode & 0o777 == 0o600
        for original_mode, concurrent_mode in [(0o644, 0o600), (0o755, 0o700), (0o600, 0o400)]:
            ctx, journal = make_repo("concurrent-mode-" + oct(original_mode))
            wt, stage = ctx["worktree"], ctx["stage"]
            (wt / "payload").chmod(original_mode)
            journal["base_files"] = runner.snapshot(wt, journal["base_paths"])
            (stage / "payload").write_text("incoming payload")
            original_apply = runner.apply_files
            def concurrent_chmod(source, dest, *args):
                if source == stage:
                    (wt / "payload").chmod(concurrent_mode)
                return original_apply(source, dest, *args)
            with patch.object(runner, "apply_files", concurrent_chmod):
                refuses(lambda: runner.sync_workspace(ctx, journal))
            assert (wt / "payload").read_text() == "original payload"
            assert (wt / "payload").stat().st_mode & 0o7777 == concurrent_mode
            assert journal["phase"] == "syncing"
        ctx, journal = make_repo("rollback-concurrent-mode")
        wt, stage = ctx["worktree"], ctx["stage"]
        (wt / "payload").chmod(0o644)
        journal["base_files"] = runner.snapshot(wt, journal["base_paths"])
        (stage / "payload").write_text("incoming payload")
        original_copy = runner.copy_path
        def chmod_after_copy(source, dest, rel, baseline=None):
            original_copy(source, dest, rel, baseline)
            if source == stage and rel == "payload":
                (dest / rel).chmod(0o600)
                raise runner.Refusal("injected concurrent chmod before rollback")
        with patch.object(runner, "copy_path", chmod_after_copy):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert (wt / "payload").read_text() == "incoming payload"
        assert (wt / "payload").stat().st_mode & 0o7777 == 0o600
        assert journal["phase"] == "syncing"
        with patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"):
            refuses(lambda: runner.recover_task("task"))
        assert (wt / "payload").stat().st_mode & 0o7777 == 0o600
        for new_file in [False, True]:
            ctx, journal = make_repo("rollback-installed-mode-" + str(new_file))
            wt, stage = ctx["worktree"], ctx["stage"]
            leaf = "new-file" if new_file else "payload"
            if not new_file:
                (wt / leaf).chmod(0o600)
                journal["base_files"] = runner.snapshot(wt, journal["base_paths"])
            (stage / leaf).write_text("incoming payload")
            (stage / leaf).chmod(0o4700 if new_file else 0o666)
            runner.git(stage, "add", leaf)
            original_copy = runner.copy_path
            def fail_installed_copy(source, dest, rel, baseline=None):
                original_copy(source, dest, rel, baseline)
                if source == stage and rel == leaf:
                    assert (dest / rel).stat().st_mode & 0o7777 == (0o700 if new_file else 0o600)
                    raise runner.Refusal("injected failure after normalized mode copy")
            with patch.object(runner, "copy_path", fail_installed_copy):
                refuses(lambda: runner.sync_workspace(ctx, journal))
            assert journal["phase"] == "snapshot-downloaded"
            if new_file:
                assert not (wt / leaf).exists()
            else:
                assert (wt / leaf).read_text() == "original payload"
                assert (wt / leaf).stat().st_mode & 0o7777 == 0o600
            runner.sync_workspace(ctx, journal)
            assert (wt / leaf).stat().st_mode & 0o7777 == (0o700 if new_file else 0o600)
        for failure in ["clone", "copy", "hooks", "inbox"]:
            ctx, journal = make_repo("prepare-failure-" + failure)
            shutil.rmtree(ctx["stage_root"])
            ctx["journal"].unlink()
            ctx["responses"] = ctx["bridge_dir"] / "responses"
            ctx["channel"] = ctx["bridge_dir"] / "inbox"
            (ctx["state"] / "task.inbox").mkdir()
            original_run = runner.run
            def refuse_clone(argv, **kwargs):
                if argv[:2] == ["git", "clone"]:
                    raise runner.Refusal("injected clone failure")
                return original_run(argv, **kwargs)
            def refuse_preparation(*args, **kwargs):
                raise runner.Refusal("injected preparation failure")
            target, replacement = {
                "clone": ("run", refuse_clone), "copy": ("copy_path", refuse_preparation),
                "hooks": ("copy_project_hooks", refuse_preparation),
                "inbox": ("refresh_inbox_mirror", refuse_preparation),
            }[failure]
            with patch.object(runner, target, replacement):
                refuses(lambda: runner.prepare_workspace(ctx))
            assert runner.read_journal(ctx)["phase"] == "preparing"
            assert runner.git(ctx["worktree"], "rev-parse", "HEAD") == journal["base_head"]
            assert runner.snapshot(ctx["worktree"], journal["base_paths"]) == journal["base_files"]
            with patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"):
                with patch.object(runner, "sandbox_get", return_value=True), patch.object(runner, "delete_sandbox") as deletion:
                    refuses(lambda: runner.recover_task("task"))
                    deletion.assert_not_called()
                assert runner.read_journal(ctx)["phase"] == "preparing"
                runner.recover_task("task")
            assert not ctx["stage_root"].exists() and not ctx["journal"].exists()
            assert not ctx["bridge_dir"].exists()
            prepared = runner.prepare_workspace(ctx)
            assert prepared["phase"] == "prepared"
            assert runner.git(ctx["stage"], "write-tree") == journal["base_index_tree"]
        for directory in [False, True]:
            ctx, journal = make_repo("backup-" + str(directory), directory)
            backup = runner.backup_host(ctx, journal)
            assert (backup / "index").read_bytes() == runner.task_index_path(ctx["worktree"]).read_bytes()
            target = ctx["worktree"] / ("index/payload" if directory else "index")
            target.write_text("incoming replacement")
            journal["sync_files"] = runner.snapshot(ctx["worktree"], journal["base_paths"])
            runner.restore_host(ctx, journal, backup)
            assert runner.snapshot(ctx["worktree"], journal["base_paths"]) == journal["base_files"]
            assert runner.git(ctx["worktree"], "write-tree") == journal["base_index_tree"]
        ctx, journal = make_repo("sync-retry")
        (ctx["stage"] / "payload").write_text("committed incoming payload")
        runner.git(ctx["stage"], "add", ".")
        runner.git(ctx["stage"], "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "incoming")
        copy = runner.copy_path
        def fail_incoming(source, *args):
            if source == ctx["stage"]:
                raise runner.Refusal("injected sync copy failure")
            return copy(source, *args)
        with patch.object(runner, "copy_path", fail_incoming):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert runner.read_journal(ctx)["phase"] == "snapshot-downloaded"
        assert not (ctx["stage_root"] / "host-backup").exists()
        assert (ctx["worktree"] / "payload").read_text() == "original payload"
        runner.backup_host(ctx, journal)
        runner.sync_workspace(ctx, journal)
        assert (ctx["worktree"] / "payload").read_text() == "committed incoming payload"
        assert runner.read_journal(ctx)["phase"] == "synced"
        ctx, journal = make_repo("interrupted-sync")
        backup = runner.backup_host(ctx, journal)
        (ctx["worktree"] / "payload").write_text("partially synchronized payload")
        journal.update(phase="syncing", sync_head=journal["base_head"], sync_paths=journal["base_paths"],
                       sync_files=runner.snapshot(ctx["worktree"], journal["base_paths"]))
        runner.write_journal(ctx, journal)
        def fail_download(ctx, journal):
            assert (ctx["worktree"] / "payload").read_text() == "original payload"
            assert runner.read_journal(ctx)["phase"] == "snapshot-downloaded"
            assert not backup.exists()
            raise runner.Refusal("injected download failure")
        with patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"), patch.object(runner, "sandbox_get", return_value=True), patch.object(runner, "stop_then_start_sandbox"), patch.object(runner, "download_workspace", fail_download):
            refuses(lambda: runner.recover_task("task"))
        assert runner.read_journal(ctx)["phase"] == "snapshot-downloaded"
        runner.sync_workspace(ctx, runner.read_journal(ctx))
        assert runner.read_journal(ctx)["phase"] == "synced"
        def transition_case(name, direction, leaf_kind="file", representation="committed"):
            ctx, old = make_repo(name)
            wt, stage = ctx["worktree"], ctx["stage"]
            if direction == "to-directory":
                if leaf_kind == "symlink":
                    (wt / "a").symlink_to("payload")
                else:
                    (wt / "a").write_text("old leaf")
            else:
                (wt / "a" / "deep").mkdir(parents=True)
                (wt / "a" / "deep" / "b").write_text("old child")
            runner.git(wt, "add", ".")
            runner.git(wt, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "transition baseline")
            shutil.rmtree(stage)
            runner.run(["git", "clone", "-q", "--no-hardlinks", str(wt), str(stage)], env=runner.cli_env())
            paths = runner.git_paths(wt)
            old.update(base_head=runner.git(wt, "rev-parse", "HEAD"), base_index_tree=runner.git(wt, "write-tree"),
                       base_paths=paths, base_files=runner.snapshot(wt, paths))
            if direction == "to-directory":
                (stage / "a").unlink()
                (stage / "a" / "deep").mkdir(parents=True)
                (stage / "a" / "deep" / "b").write_text("new child")
            else:
                shutil.rmtree(stage / "a")
                if leaf_kind == "symlink":
                    (stage / "a").symlink_to("payload")
                else:
                    (stage / "a").write_text("new leaf")
            runner.git(stage, "add", "-A")
            if representation == "committed":
                runner.git(stage, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "transition incoming")
            runner.write_journal(ctx, old)
            return ctx, old
        for representation in ["committed", "staged"]:
            for direction in ["to-directory", "to-leaf"]:
                for kind in ["file", "symlink"]:
                    for interrupted in [False, True]:
                        ctx, journal = transition_case("transition-" + direction + kind + str(interrupted) + representation, direction, kind, representation)
                        if interrupted:
                            original_copy = runner.copy_path
                            copied = []
                            def interrupt_copy(source, dest, rel, baseline=None):
                                result = original_copy(source, dest, rel, baseline)
                                if source == ctx["stage"]:
                                    copied.append(rel)
                                    if rel == ("a/deep/b" if direction == "to-directory" else "a"):
                                        raise runner.Refusal("injected failure after transition copy")
                                return result
                            with patch.object(runner, "copy_path", interrupt_copy):
                                refuses(lambda: runner.sync_workspace(ctx, journal))
                            assert copied
                            assert runner.git(ctx["worktree"], "rev-parse", "HEAD") == journal["base_head"]
                            assert runner.snapshot(ctx["worktree"], journal["base_paths"]) == journal["base_files"]
                            assert journal["phase"] == "snapshot-downloaded"
                        runner.sync_workspace(ctx, journal)
                        assert runner.git(ctx["worktree"], "rev-parse", "HEAD") == runner.git(ctx["stage"], "rev-parse", "HEAD")
                        assert runner.git(ctx["worktree"], "status", "--porcelain") == runner.git(ctx["stage"], "status", "--porcelain")
                        target = ctx["worktree"] / "a"
                        if direction == "to-directory":
                            assert (target / "deep" / "b").read_text() == "new child"
                        elif kind == "symlink":
                            assert os.readlink(target) == "payload"
                        else:
                            assert target.read_text() == "new leaf"
        for representation in ["unstaged", "staged", "committed"]:
            for recovery in [False, True]:
                ctx, journal = make_repo("deletion-" + representation + str(recovery))
                (ctx["stage"] / "payload").unlink()
                if representation != "unstaged":
                    runner.git(ctx["stage"], "add", "-u")
                if representation == "committed":
                    runner.git(ctx["stage"], "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "delete payload")
                (ctx["worktree"] / "unrelated").write_text("host-only data")
                if recovery:
                    with patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"), patch.object(runner, "sandbox_get", return_value=True), patch.object(runner, "stop_then_start_sandbox"), patch.object(runner, "download_workspace"), patch.object(runner, "delete_sandbox"), patch.object(runner, "cleanup_artifacts"):
                        runner.recover_task("task")
                else:
                    runner.sync_workspace(ctx, journal)
                assert not (ctx["worktree"] / "payload").exists()
                assert runner.git(ctx["worktree"], "status", "--porcelain", "--untracked-files=no") == runner.git(ctx["stage"], "status", "--porcelain", "--untracked-files=no")
                assert (ctx["worktree"] / "unrelated").read_text() == "host-only data"
        ctx, journal = make_repo("removed-from-index")
        runner.git(ctx["stage"], "rm", "--cached", "payload")
        (ctx["stage"] / "payload").write_text("now-untracked sandbox data")
        runner.sync_workspace(ctx, journal)
        assert not (ctx["worktree"] / "payload").exists()
        assert (ctx["stage"] / "payload").read_text() == "now-untracked sandbox data"
        ctx, journal = make_repo("deletion-rollback")
        (ctx["stage"] / "payload").unlink()
        original_remove = runner.remove_leaf
        def fail_after_deletion(dest, rel):
            original_remove(dest, rel)
            if dest == ctx["worktree"] and rel == "payload":
                raise runner.Refusal("injected failure after deletion")
        with patch.object(runner, "remove_leaf", fail_after_deletion):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert (ctx["worktree"] / "payload").read_text() == "original payload"
        assert journal["phase"] == "snapshot-downloaded"
        runner.sync_workspace(ctx, journal)
        assert not (ctx["worktree"] / "payload").exists()
        ctx, journal = make_repo("symlink-siblings")
        wt, stage = ctx["worktree"], ctx["stage"]
        (wt / "a").symlink_to("payload")
        (wt / ".a.fm-openshell-tmp").write_text("tracked sibling")
        runner.git(wt, "add", ".")
        runner.git(wt, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "symlink baseline")
        shutil.rmtree(ctx["stage_root"])
        ctx["journal"].unlink()
        ctx["channel"] = ctx["bridge_dir"] / "inbox"
        ctx["responses"] = ctx["bridge_dir"] / "responses"
        (ctx["state"] / "task.inbox").mkdir()
        journal = runner.prepare_workspace(ctx)
        assert (stage / ".a.fm-openshell-tmp").read_text() == "tracked sibling"
        assert os.readlink(stage / "a") == "payload"
        (wt / ".b.fm-openshell-tmp").mkdir()
        (wt / ".b.fm-openshell-tmp" / "secret").write_text("unrelated sibling")
        (stage / "a").unlink()
        (stage / "a").symlink_to("index")
        (stage / "b").symlink_to("payload")
        runner.git(stage, "add", "a", "b")
        original_copy = runner.copy_path
        def fail_after_link(source, dest, rel, baseline=None):
            original_copy(source, dest, rel, baseline)
            if source == stage and rel == "b":
                raise runner.Refusal("injected failure after symlink replacement")
        with patch.object(runner, "copy_path", fail_after_link):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert os.readlink(wt / "a") == "payload"
        assert not (wt / "b").is_symlink()
        assert (wt / ".a.fm-openshell-tmp").read_text() == "tracked sibling"
        assert (wt / ".b.fm-openshell-tmp" / "secret").read_text() == "unrelated sibling"
        runner.sync_workspace(ctx, journal)
        assert os.readlink(wt / "a") == "index"
        assert os.readlink(wt / "b") == "payload"
        assert (wt / ".a.fm-openshell-tmp").read_text() == "tracked sibling"
        assert (wt / ".b.fm-openshell-tmp" / "secret").read_text() == "unrelated sibling"
        for ignored in [False, True]:
            ctx, journal = make_repo("matching-collision-" + str(ignored))
            wt, stage = ctx["worktree"], ctx["stage"]
            if ignored:
                runner.git(wt, "config", "core.excludesFile", str(ctx["home"] / "excludes"))
                (ctx["home"] / "excludes").write_text("new-file\n")
            (wt / "new-file").write_text("matching data")
            (stage / "new-file").write_text("matching data")
            runner.git(stage, "add", "new-file")
            refuses(lambda: runner.sync_workspace(ctx, journal))
            assert (wt / "new-file").read_text() == "matching data"
            assert journal["phase"] == "snapshot-downloaded"
            assert not (ctx["stage_root"] / "host-backup").exists()
            assert runner.git(wt, "write-tree") == journal["base_index_tree"]
        ctx, journal = make_repo("late-matching-collision")
        wt, stage = ctx["worktree"], ctx["stage"]
        (stage / "new-file").write_text("matching data")
        runner.git(stage, "add", "new-file")
        original_apply = runner.apply_files
        def late_collision(source, dest, *args):
            if source == stage:
                (wt / "new-file").write_text("matching data")
            return original_apply(source, dest, *args)
        with patch.object(runner, "apply_files", late_collision):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert (wt / "new-file").read_text() == "matching data"
        assert journal["phase"] == "snapshot-downloaded"
        assert runner.git(wt, "write-tree") == journal["base_index_tree"]
        ctx, journal = make_repo("interrupted-unclaimed-collision")
        wt, stage = ctx["worktree"], ctx["stage"]
        (stage / "new-file").write_text("matching data")
        runner.git(stage, "add", "new-file")
        runner.backup_host(ctx, journal)
        journal.update(phase="syncing", sync_head=journal["base_head"], sync_paths=[],
                       sync_files=runner.snapshot(stage, runner.git_paths(stage)))
        runner.write_journal(ctx, journal)
        (wt / "new-file").write_text("matching data")
        with patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"):
            refuses(lambda: runner.recover_task("task"))
        assert (wt / "new-file").read_text() == "matching data"
        assert runner.read_journal(ctx)["phase"] == "snapshot-downloaded"
        assert runner.git(wt, "write-tree") == journal["base_index_tree"]
        ctx, journal = make_repo("tracked-hooks")
        wt = ctx["worktree"]
        hooks = wt / ".hooks"
        hooks.mkdir()
        (hooks / "pre-commit").write_text("#!/bin/sh\nprintf 'hook executed' > hook-ran\n")
        (hooks / "pre-commit").chmod(0o755)
        (wt / ".gitignore").write_text(".hooks/private-config\n")
        runner.git(wt, "add", ".hooks/pre-commit", ".gitignore")
        runner.git(wt, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "tracked hook")
        runner.git(wt, "config", "core.hooksPath", ".hooks")
        (hooks / "private-config").write_text("ignored secret")
        (hooks / "untracked-config").write_text("untracked secret")
        shutil.rmtree(ctx["stage_root"])
        ctx["journal"].unlink()
        ctx["channel"] = ctx["bridge_dir"] / "inbox"
        ctx["responses"] = ctx["bridge_dir"] / "responses"
        (ctx["state"] / "task.inbox").mkdir()
        journal = runner.prepare_workspace(ctx)
        private_hooks = ctx["stage"] / ".git" / "fm-openshell" / "project-hooks"
        assert (private_hooks / "pre-commit").exists()
        assert not (private_hooks / "private-config").exists()
        assert not (private_hooks / "untracked-config").exists()
        (ctx["stage"] / "injected-untracked").write_text("must not upload")
        archive = runner.workspace_archive(ctx)
        with tarfile.open(archive) as uploaded:
            names = {member.name.removeprefix("./") for member in uploaded.getmembers()}
            assert ".hooks/pre-commit" in names
            assert ".git/fm-openshell/project-hooks/pre-commit" in names
            assert not {".hooks/private-config", ".hooks/untracked-config", "injected-untracked"} & names
            assert ".git/fm-openshell/project-hooks/private-config" not in names
            assert ".git/fm-openshell/project-hooks/untracked-config" not in names
        archive.unlink()
        runner.run(["git", "-C", str(ctx["stage"]), "-c", "core.hooksPath=" + str(private_hooks),
                    "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "--allow-empty", "-qm", "exercise hook"], env=runner.cli_env())
        assert (ctx["stage"] / "hook-ran").read_text() == "hook executed"
        for failure in ["packing", "download", "cleanup"]:
            ctx, journal = make_repo("snapshot-retry-" + failure)
            remote = ctx["home"] / "remote"
            shutil.copytree(ctx["stage"], remote)
            (remote / "untracked").write_text("excluded project data")
            (remote / ".gitignore").write_text("ignored\n")
            (remote / "ignored").write_text("excluded ignored data")
            channel = remote / ".git" / "fm-openshell" / "channel" / "outbox"
            channel.mkdir(parents=True)
            (channel / "keep").write_text("task channel")
            unrelated = remote / ".git" / ".fm-openshell-snapshot-unrelated.tar"
            unrelated.write_text("unrelated Git data")
            preserved_dir = remote / ".git" / (".fm-openshell-snapshot-" + "c" * 32 + ".tar")
            preserved_dir.mkdir()
            (preserved_dir / "keep").write_text("unrelated directory")
            if failure != "cleanup":
                abandoned = remote / ".git" / (".fm-openshell-snapshot-" + "a" * 32 + ".tar")
                abandoned.write_bytes(b"abandoned snapshot")
            if failure == "packing":
                (remote / "payload").unlink()
                os.mkfifo(remote / "payload")
            log = ctx["home"] / "transport.jsonl"
            flags = {"FAIL_ARCHIVE_DOWNLOAD": "1" if failure != "packing" else "0",
                     "FAIL_SNAPSHOT_CLEANUP": "1" if failure == "cleanup" else "0"}
            with patch.dict(os.environ, DOWNLOAD_SOURCE=str(remote), DOWNLOAD_LOG=str(log), **flags):
                refuses(lambda: runner.download_workspace(ctx, journal))
            snapshots = [p for p in (remote / ".git").iterdir()
                         if re.fullmatch(r"[.]fm-openshell-snapshot-[0-9a-f]{32}[.]tar", p.name) and p.is_file()]
            assert bool(snapshots) == (failure == "cleanup")
            assert (ctx["stage"] / "payload").read_text() == "original payload"
            assert (remote / ".git" / "HEAD").is_file()
            assert unrelated.read_text() == "unrelated Git data"
            assert (preserved_dir / "keep").read_text() == "unrelated directory"
            assert (channel / "keep").read_text() == "task channel"
            if failure == "packing":
                (remote / "payload").unlink()
                (remote / "payload").write_text("incoming payload")
            with patch.dict(os.environ, DOWNLOAD_SOURCE=str(remote), DOWNLOAD_LOG=str(log)):
                runner.download_workspace(ctx, journal)
                link = remote / ".git" / (".fm-openshell-snapshot-" + "d" * 32 + ".tar")
                link.symlink_to("HEAD")
                runner.retire_remote_snapshots(ctx)
                assert link.is_symlink()
                link.unlink()
            assert journal["phase"] == "snapshot-downloaded"
            transported = [path for line in log.read_text().splitlines() for path in json.loads(line)]
            assert not any(re.fullmatch(r"[.]git/[.]fm-openshell-snapshot-[0-9a-f]{32}[.]tar", path) for path in transported)
            assert not {"untracked", "ignored", ".gitignore"} & set(transported)
            assert (ctx["stage"] / ".git" / "fm-openshell" / "channel" / "outbox" / "keep").read_text() == "task channel"
            assert (ctx["stage"] / ".git" / ".fm-openshell-snapshot-unrelated.tar").read_text() == "unrelated Git data"
        ctx, journal = make_repo("outbox-layout")
        ctx["bridge_dir"].mkdir()
        remote = ctx["stage"]
        channel = remote / ".git" / "fm-openshell" / "channel"
        outbox = channel / "outbox"
        outbox.mkdir(parents=True)
        request_id = "a" * 32
        request = {"op": "inbox.ack", "name": "0001.msg"}
        (outbox / (request_id + ".json")).write_text(json.dumps(request))
        (outbox / "keep").write_text("task channel")
        (outbox / ("b" * 32 + ".tmp")).write_text("pending request")
        (channel / "inbox").mkdir()
        (channel / "inbox" / "0001.msg").write_text("unrelated inbox data")
        log = ctx["home"] / "outbox-transport.jsonl"
        with patch.dict(os.environ, DOWNLOAD_SOURCE=str(remote), DOWNLOAD_LOG=str(log)):
            assert runner.download_outbox(ctx) == {request_id: request}
            assert not list(ctx["bridge_dir"].iterdir())
            (outbox / "outbox").mkdir()
            (outbox / "outbox" / (request_id + ".json")).write_text(json.dumps(request))
            refuses(lambda: runner.download_outbox(ctx))
            assert not list(ctx["bridge_dir"].iterdir())
        transported = [path for line in log.read_text().splitlines() for path in json.loads(line)]
        assert all(path.startswith(".git/fm-openshell/channel/outbox/") for path in transported)
        assert (channel / "inbox" / "0001.msg").read_text() == "unrelated inbox data"
        ctx, journal = make_repo("tracked-transfer")
        wt = ctx["worktree"]
        (wt / ".gitignore").write_text("ignored\n")
        runner.git(wt, "add", ".gitignore")
        runner.git(wt, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "ignore rule")
        (wt / "staged-new").write_text("staged addition")
        runner.git(wt, "add", "staged-new")
        (wt / "untracked").write_text("host-only untracked")
        (wt / "ignored").write_text("host-only ignored")
        (wt / "payload").unlink()
        shutil.rmtree(ctx["stage_root"])
        ctx["journal"].unlink()
        ctx["channel"] = ctx["bridge_dir"] / "inbox"
        ctx["responses"] = ctx["bridge_dir"] / "responses"
        (ctx["state"] / "task.inbox").mkdir()
        journal = runner.prepare_workspace(ctx)
        assert set(journal["base_paths"]) == {".gitignore", "index", "payload", "staged-new"}
        archive = runner.workspace_archive(ctx)
        with tarfile.open(archive) as uploaded:
            names = {member.name.removeprefix("./") for member in uploaded.getmembers()}
            assert "staged-new" in names and "index" in names
            assert not {"untracked", "ignored", "payload"} & names
        archive.unlink()
        remote = ctx["home"] / "remote"
        shutil.copytree(ctx["stage"], remote, symlinks=True)
        (remote / "sandbox-untracked").write_text("excluded sandbox output")
        (remote / "ignored").write_text("excluded ignored output")
        (remote / "staged-new").write_text("changed tracked output")
        (remote / "sandbox-link").symlink_to("staged-new")
        runner.git(remote, "add", "sandbox-link")
        download_log = ctx["home"] / "download-log.jsonl"
        with patch.dict(os.environ, DOWNLOAD_SOURCE=str(remote), DOWNLOAD_LOG=str(download_log)):
            refuses(lambda: runner.openshell_run(ctx, "sandbox", "download", ctx["sandbox"], "/tmp/outside.tar", str(ctx["stage_root"])))
            runner.download_workspace(ctx, journal)
        assert (ctx["stage"] / ".git" / "HEAD").is_file()
        assert not (ctx["stage"] / "HEAD").exists()
        assert not list((remote / ".git").glob(".fm-openshell-snapshot-*.tar"))
        transported = {path for line in download_log.read_text().splitlines() for path in json.loads(line)}
        assert not {"sandbox-untracked", "ignored"} & transported
        assert not (ctx["stage"] / "sandbox-untracked").exists()
        assert not (ctx["stage"] / "ignored").exists()
        dirty_journal = {**journal, "validation_requested": True}
        with patch.dict(os.environ, DOWNLOAD_SOURCE=str(remote), DOWNLOAD_LOG=str(download_log)):
            refuses(lambda: runner.download_workspace(ctx, dirty_journal))
        _, _, paths, states = runner.verify_stage(ctx, journal)
        assert set(paths) == {".gitignore", "index", "payload", "staged-new", "sandbox-link"}
        assert "sandbox-untracked" not in states and "ignored" not in states
        runner.sync_workspace(ctx, journal)
        assert (wt / "staged-new").read_text() == "changed tracked output"
        assert os.readlink(wt / "sandbox-link") == "staged-new"
        assert not (wt / "sandbox-untracked").exists()
        assert (wt / "untracked").read_text() == "host-only untracked"
        assert (wt / "ignored").read_text() == "host-only ignored"
        assert not (wt / "payload").exists()
        ctx, journal = transition_case("ignored-transition", "to-leaf")
        runner.git(ctx["worktree"], "config", "--local", "core.excludesFile", str(ctx["home"] / "excludes"))
        (ctx["home"] / "excludes").write_text("a/secret\n")
        secret = ctx["worktree"] / "a" / "secret"
        secret.write_text("ignored host data")
        refuses(lambda: runner.sync_workspace(ctx, journal))
        assert secret.read_text() == "ignored host data"
        assert (ctx["worktree"] / "a" / "deep" / "b").read_text() == "old child"
        ctx, journal = transition_case("concurrent-transition", "to-directory")
        original_apply = runner.apply_files
        def concurrent_change(source, dest, *args):
            if source == ctx["stage"]:
                (dest / "a").write_text("concurrent host data")
            return original_apply(source, dest, *args)
        with patch.object(runner, "apply_files", concurrent_change):
            refuses(lambda: runner.sync_workspace(ctx, journal))
        assert (ctx["worktree"] / "a").read_text() == "concurrent host data"
        assert journal["phase"] == "syncing"
        assert (ctx["stage_root"] / "host-backup").exists()
        ctx, journal = make_repo("archive")
        journal["phase"] = "prepared"
        with patch.object(runner, "refresh_inbox_mirror", return_value="snapshot"):
            runner.create_sandbox(ctx, journal)
        assert journal["phase"] == "workspace-uploaded"
        assert not list(ctx["stage_root"].glob(".fm-openshell-workspace-*.tar"))
        ctx, journal = make_repo("handoff")
        journal["phase"] = "agent-running"
        runner.write_journal(ctx, journal)
        def request_handoff(ctx):
            runner.channel_request(ctx, "a" * 32, {"op": "validation.request"})
        with patch.object(runner, "sync_channels", request_handoff):
            assert runner.run_codex(ctx, journal, "brief", "default", "default") == 0
        assert runner.read_journal(ctx)["validation_requested"] is True
        runner.channel_request(ctx, "b" * 32, {"op": "status.append", "line": "done [at=1]: premature"})
        assert json.loads((ctx["responses"] / ("b" * 32 + ".json")).read_text())["ok"] is False
        refuses(lambda: runner.publish_validation_handoff(ctx, journal))
        (ctx["stage"] / "untracked").write_text("uncommitted")
        refuses(lambda: runner.sync_workspace(ctx, journal))
        assert not ctx["validation"].exists()
        (ctx["stage"] / "untracked").unlink()
        runner.sync_workspace(ctx, journal)
        runner.publish_validation_handoff(ctx, journal)
        record = json.loads(ctx["validation"].read_text())
        assert record["head"] == runner.git(ctx["worktree"], "rev-parse", "HEAD")
        assert "ready for host validation" in (ctx["state"] / "task.status").read_text()
        intent = base / "intent.txt"
        intent.write_text("authoritative task intent")
        nm = base / "no-mistakes"
        nm.write_text("""#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
helper = subprocess.check_output(['git', 'config', '--global', '--get', 'credential.helper'], text=True).strip()
auth = {key: os.environ.get(key) for key in ('SSH_AUTH_SOCK', 'GIT_SSH_COMMAND', 'GIT_CONFIG_GLOBAL')}
Path(os.environ['NM_LOG']).write_text(json.dumps({'argv':sys.argv[1:], 'cwd':os.getcwd(), 'auth':auth, 'helper':helper}))
""")
        nm.chmod(0o755)
        nm_log = base / "nm-log.json"
        data = ctx["home"] / "data"
        data.mkdir()
        registry = data / "projects.md"
        registry.write_text("- host [no-mistakes] - test project (added 2026-10-02)\n")
        host_config = base / "host-gitconfig"
        host_config.write_text("[credential]\n\thelper = host-test-helper\n")
        auth = dict(SSH_AUTH_SOCK=str(base / "host-agent.sock"), GIT_SSH_COMMAND="host-ssh-command",
                    GIT_CONFIG_GLOBAL=str(host_config))
        real_git = shutil.which("git")
        git_probe = base / "git"
        git_probe.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['PROBE_AUTH_LOG']).write_text(json.dumps({key: os.environ.get(key) for key in ('SSH_AUTH_SOCK', 'GIT_SSH_COMMAND', 'GIT_CONFIG_GLOBAL')}))
os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT'], *sys.argv[1:]])
""")
        git_probe.chmod(0o755)
        git_auth_log = base / "git-auth.json"
        with patch.dict(os.environ, **auth, REAL_GIT=real_git, PROBE_AUTH_LOG=str(git_auth_log), NM_LOG=str(nm_log), FM_DATA_OVERRIDE=str(data)), patch.object(runner, "load_context", return_value=ctx), patch.object(runner, "endpoint_agent_free"):
            for invoke in (runner.git, runner.git_bytes):
                invoke(ctx["stage"], "rev-parse", "HEAD")
                assert json.loads(git_auth_log.read_text()) == {
                    "SSH_AUTH_SOCK": None, "GIT_SSH_COMMAND": None, "GIT_CONFIG_GLOBAL": "/dev/null"}
            assert runner.git(ctx["stage"], "config", "--global", "--get", "credential.helper", check=False) == ""
            assert runner.validate_task("task", str(intent)) == 0
            delivered = json.loads(nm_log.read_text())
            assert delivered == {"argv": ["axi", "run", "--intent", intent.read_text()], "cwd": str(ctx["worktree"]), "auth": auth, "helper": "host-test-helper"}
            nm_log.unlink()
            registry.write_text("- host [no-mistakes forge=gerrit] - test project (added 2026-10-02)\n")
            assert runner.validate_task("task", str(intent)) == 0
            delivered = json.loads(nm_log.read_text())
            assert delivered == {"argv": ["axi", "run", "--intent", intent.read_text(), "--skip", "push,pr,ci"], "cwd": str(ctx["worktree"]), "auth": auth, "helper": "host-test-helper"}
            nm_log.unlink()
            registry.write_text("- host [no-mistakes forge=unknown] - test project (added 2026-10-02)\n")
            refuses(lambda: runner.validate_task("task", str(intent)))
            assert not nm_log.exists()
            registry.write_text("- host [no-mistakes] - test project (added 2026-10-02)\n")
            record["workspace_id"] = "other"
            ctx["validation"].write_text(json.dumps(record))
            refuses(lambda: runner.validate_task("task", str(intent)))
            assert not nm_log.exists()
        git_probe.unlink()
        capability = base / "capability" / "fm-task-capability"
        capability.parent.mkdir()
        shutil.copy2(root / "bin/fm-openshell-capability.py", capability)
        outbox = capability.parent / "channel" / "outbox"
        responses = capability.parent / "channel" / "responses"
        proc = subprocess.Popen([sys.executable, str(capability), "validation", "request"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        requests = []
        while time.monotonic() < deadline:
            requests = list(outbox.glob("*.json"))
            if requests:
                break
            time.sleep(0.01)
        assert len(requests) == 1
        assert json.loads(requests[0].read_text()) == {"op": "validation.request"}
        (responses / requests[0].name).write_text(json.dumps({"ok": True, "text": "accepted"}))
        stdout, stderr = proc.communicate(timeout=5)
        assert proc.returncode == 0, stderr
        assert stdout == b"accepted\n"
        missing_id = "retired-" + base.name
        state = base / "retired-state"
        state.mkdir()
        missing_worktree = base / "retired-worktree"
        sandbox = generated_sandbox(base, missing_id)
        metadata = dict(openshell="codex-v1", harness="codex", backend="herdr", kind="ship", mode="no-mistakes",
                        openshell_providers="codex", openshell_gateway="local", openshell_workspace="team",
                        openshell_workspace_id="exact-id", openshell_image="localhost/fm-codex:test", openshell_name=sandbox,
                        worktree=str(missing_worktree), tasktmp="/tmp/fm-" + missing_id, branch="task")
        (state / (missing_id + ".meta")).write_text("".join(k + "=" + v + "\n" for k, v in metadata.items()))
        with patch.dict(os.environ, FM_HOME=str(base), FM_STATE_OVERRIDE=str(state)):
            refuses(lambda: runner.load_context(missing_id))
            for wrong_name in [generated_sandbox(base, "another-task"),
                               generated_sandbox(base / "another-home", missing_id),
                               "fm-codex-" + hashlib.sha256(os.fsencode(str(base)) + b"\0" + missing_id.encode()).hexdigest()[:24]]:
                bad_metadata = dict(metadata, openshell_name=wrong_name)
                (state / (missing_id + ".meta")).write_text("".join(k + "=" + v + "\n" for k, v in bad_metadata.items()))
                refuses(lambda: runner.load_context(missing_id, require_live=False))
            (state / (missing_id + ".meta")).write_text("".join(k + "=" + v + "\n" for k, v in metadata.items()))
            runner.guard_task(missing_id)
            retired = runner.load_context(missing_id, require_live=False)
            assert retired["sandbox"] == sandbox
            assert retired["image"] == "localhost/fm-codex:test"
            runner.cleanup_artifacts(retired)
            runner.cleanup_artifacts(retired)
        assert not missing_worktree.exists()
print("ok - archive ownership, backup isolation, rollback retries, retired cleanup, and host handoff")

PY
