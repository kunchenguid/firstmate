#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import sys
import tempfile
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
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as f:
    f.write(json.dumps(args) + "\\n")
workspace = args[args.index("--workspace") + 1] if "--workspace" in args else os.environ.get("OPENSHELL_WORKSPACE", "default")
if "workspace" in args and "get" in args:
    print("Workspace:\\n\\n  Name: " + workspace + "\\n  Id: " + pathlib.Path(os.environ["WORKSPACE_ID_FILE"]).read_text())
''')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ["PATH"],
               COMMAND_LOG=str(log), WORKSPACE_ID_FILE=str(identity), OPENSHELL_WORKSPACE="other",
               SSH_AUTH_SOCK=str(base / "host-agent.sock"), GIT_SSH_COMMAND="host-ssh-command",
               GIT_CONFIG_GLOBAL=str(base / "host-gitconfig"))
    ctx = dict(id="task", home=base, state=base, gateway="local", workspace="team",
               workspace_id="workspace-original", journal=base / "journal.json", worktree=base,
               sandbox="task-sandbox", values={})
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
        for model, effort, expected_model, expected_effort in [
            ("default", "default", "gpt-6.1-sol", "medium"),
            ("", "", "gpt-6.1-sol", "medium"),
            ("custom-model", "high", "custom-model", "high"),
            ("gpt-5.6-luna", "max", "gpt-5.6-luna", "max")]:
            with patch.object(runner, "sync_channels", lambda ctx: None):
                assert runner.run_codex(ctx, {}, "task brief", model, effort) == 0
            args = commands()[-1]
            codex = args[args.index("--") + 1:]
            assert codex[codex.index("--model") + 1] == expected_model
            assert 'model_reasoning_effort="' + expected_effort + '"' in codex
            assert "--dangerously-bypass-approvals-and-sandbox" in codex
            assert "CODEX_HOME=/tmp/fm-codex-home" in args
            forwarded = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg == "--env")
            assert "SSH_AUTH_SOCK" not in forwarded
            assert "GIT_SSH_COMMAND" not in forwarded
            assert forwarded["GIT_CONFIG_GLOBAL"] == "/dev/null"
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
        sandbox = "fm-codex-" + hashlib.sha256(os.fsencode(str(base)) + b"\0task").hexdigest()[:24]
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
import os, sys, time
args = sys.argv[1:]
if 'workspace' in args and 'get' in args:
    name = args[args.index('--workspace') + 1]
    print('Workspace:\\n\\n  Name: ' + name + '\\n  Id: exact-id')
elif 'sandbox' in args and 'get' in args:
    print('sandbox not found', file=sys.stderr)
    sys.exit(1)
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
                   gateway="local", workspace="team", workspace_id="exact-id", branch="task", sandbox="task-sandbox", providers=["codex"],
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
            if representation != "unstaged":
                runner.git(stage, "add", "-A")
            if representation == "committed":
                runner.git(stage, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-qm", "transition incoming")
            runner.write_journal(ctx, old)
            return ctx, old
        for representation in ["committed", "staged", "unstaged"]:
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
        sandbox = "fm-codex-" + hashlib.sha256(os.fsencode(str(base)) + b"\0" + missing_id.encode()).hexdigest()[:24]
        metadata = dict(openshell="codex-v1", harness="codex", backend="herdr", kind="ship", mode="no-mistakes",
                        openshell_providers="codex", openshell_gateway="local", openshell_workspace="team",
                        openshell_workspace_id="exact-id", openshell_name=sandbox,
                        worktree=str(missing_worktree), tasktmp="/tmp/fm-" + missing_id, branch="task")
        (state / (missing_id + ".meta")).write_text("".join(k + "=" + v + "\n" for k, v in metadata.items()))
        with patch.dict(os.environ, FM_HOME=str(base), FM_STATE_OVERRIDE=str(state)):
            refuses(lambda: runner.load_context(missing_id))
            runner.guard_task(missing_id)
            retired = runner.load_context(missing_id, require_live=False)
            runner.cleanup_artifacts(retired)
            runner.cleanup_artifacts(retired)
        assert not missing_worktree.exists()
print("ok - archive ownership, backup isolation, rollback retries, retired cleanup, and host handoff")

PY
