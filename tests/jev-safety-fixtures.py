import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

kind = sys.argv[1]
path = Path(__file__).resolve().parent.parent / "bin" / f"fm-jev-{kind}.py"
spec = importlib.util.spec_from_file_location("subject", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    if kind == "privacy-guard":
        def quarantine(*args):
            with patch.object(mod, "datetime") as clock:
                clock.now.return_value = datetime(2026, 9, 21, tzinfo=timezone.utc)
                return mod.execute_quarantine(*args)
        sources = [root / "a" / "same.txt", root / "b" / "same.txt"]
        saved = []
        for index, source in enumerate(sources):
            source.parent.mkdir()
            source.write_text(f"fixture-{index}")
            saved.append(quarantine(source, "", root / "quarantine", "fixture", "reason", "tier1"))
        assert saved[0] != saved[1]
        for index, dest in enumerate(saved):
            assert dest.read_text() == f"fixture-{index}"
            meta = json.loads(Path(str(dest) + ".meta.json").read_text())
            assert meta["source_path"] == str(sources[index])
            assert not sources[index].exists()
        one = quarantine(None, "first", root / "quarantine", "fixture", "reason", "tier1")
        two = quarantine(None, "second", root / "quarantine", "fixture", "reason", "tier1")
        assert one != two and one.read_text() == "first" and two.read_text() == "second"
    elif kind == "stall-guard":
        seat = "fixture-" + root.name
        env = dict(os.environ, HOME=str(root), FM_HOME=str(root))
        args = [sys.executable, str(path), "--seat", seat, "--worktree", str(root), "--suppress", "--json"]
        idle = subprocess.run(args, capture_output=True, text=True, env=env)
        assert idle.returncode == 1, idle.stdout
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", seat])
        try:
            busy = subprocess.run(args, capture_output=True, text=True, env=env)
            assert busy.returncode == 0, busy.stdout
        finally:
            child.terminate()
            child.wait()
    elif kind == "worker-reaper":
        state = root / "state"
        state.mkdir()
        for name in ("first", "second"):
            (state / f"{name}.meta").write_text(f"kind=ship\nherdr_session={name}\nherdr_pane_id=pane-{name}\nworktree={root}\n")
        def unavailable(cmd, **kwargs):
            return SimpleNamespace(returncode=1, stdout="", stderr="fixture unavailable")
        with patch.object(mod.subprocess, "run", side_effect=unavailable):
            assert mod.scan_dead_workers([state]) == []
        sessions = []
        def panes(cmd, **kwargs):
            if cmd[-2:] == ["pane", "list"]:
                session = cmd[2]
                sessions.append(session)
                return SimpleNamespace(returncode=0, stdout=json.dumps({"result": {"panes": [{"pane_id": f"pane-{session}"}]}}), stderr="")
            return SimpleNamespace(returncode=0, stdout="Working", stderr="")
        with patch.object(mod.subprocess, "run", side_effect=panes):
            assert mod.scan_dead_workers([state]) == []
        assert set(sessions) == {"first", "second"}
        with patch.object(mod.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout='{"result":{"panes":[]}}', stderr="")):
            assert len(mod.scan_dead_workers([state])) == 2
        (root / "bin").mkdir()
        (root / "bin" / "fm-teardown.sh").touch()
        worker = {"home_dir": str(root), "task_id": "first", "session": "first", "pane_id": "pane-first", "meta_path": str(state / "first.meta"), "worktree": str(root)}
        with patch.object(mod.subprocess, "run", side_effect=unavailable) as run:
            assert mod.reap_worker(worker)["reclaimed"] is False
            assert run.call_count == 1
        assert (state / "first.meta").exists()
    elif kind == "rebase-healer":
        (root / ".git").mkdir()
        lock = root / ".git" / "index.lock"
        lock.write_text("lock")
        os.utime(lock, (1, 1))
        for failure in (FileNotFoundError("fixture missing fuser"), subprocess.TimeoutExpired("fuser", 1)):
            with patch.object(mod.subprocess, "run", side_effect=failure):
                report = mod.run_audit([str(root)], 1, heal=True)
                assert report["summary"]["healed_count"] == 0
                assert lock.exists()
        with patch.object(mod.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="")):
            assert mod.run_audit([str(root)], 1, heal=True)["summary"]["healed_count"] == 1
        assert not lock.exists()
    elif kind == "worktree-pruner":
        git(root, "init", "-b", "main")
        git(root, "config", "user.name", "Fixture")
        git(root, "config", "user.email", "fixture@example.invalid")
        git(root, "commit", "--allow-empty", "-m", "base")
        git(root, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(root, "checkout", "-b", "feature/a")
        git(root, "commit", "--allow-empty", "-m", "unmerged")
        git(root, "checkout", "-b", "feature/b")
        assert "feature/a" not in mod.get_merged_branches(root)
        git(root, "update-ref", "refs/remotes/origin/main", "HEAD")
        assert "feature/a" in mod.get_merged_branches(root)
    elif kind == "worktree-reaper":
        repo = root / "repo"
        repo.mkdir()
        git(repo, "init", "-b", "main")
        git(repo, "config", "user.name", "Fixture")
        git(repo, "config", "user.email", "fixture@example.invalid")
        git(repo, "commit", "--allow-empty", "-m", "base")
        landed = root / "landed"
        git(repo, "worktree", "add", "-b", "feature/landed", str(landed))
        (landed / "feature").write_text("landed content")
        git(landed, "add", ".")
        git(landed, "commit", "-m", "feature")
        pr_head = git(landed, "rev-parse", "HEAD")
        newer = root / "newer"
        git(repo, "worktree", "add", "-b", "feature/newer", str(newer), pr_head)
        git(newer, "commit", "--allow-empty", "-m", "unlanded work")
        git(repo, "merge", "--squash", "feature/landed")
        git(repo, "commit", "-m", "squash merge")
        merge_sha = git(repo, "rev-parse", "HEAD")
        real_run = subprocess.run
        def run(cmd, **kwargs):
            if cmd[0] == "gh":
                return SimpleNamespace(returncode=0, stdout=json.dumps({"state": "MERGED", "headRefOid": pr_head, "mergeCommit": {"oid": merge_sha}}))
            return real_run(cmd, **kwargs)
        with patch.object(mod.subprocess, "run", side_effect=run):
            report = mod.reap_worktrees(str(repo), base_branch="main")
        assert newer.exists()
        assert not landed.exists()
        assert report["unmerged_preserved"] == 1
    elif kind == "seat-reconciler":
        def run(cmd, **kwargs):
            fields = cmd[cmd.index("--json") + 1].split(",")
            assert set(fields) == {"state", "title"}
            return SimpleNamespace(returncode=0, stdout='{"state":"MERGED","title":"fixture"}')
        with patch.object(mod.shutil, "which", return_value=sys.executable), patch.object(mod.subprocess, "run", side_effect=run):
            assert mod.check_github_pr_state("1", "fixture/repo")["state"] == "MERGED"
    else:
        raise ValueError(kind)
print(f"PASS: {kind} regression fixtures")
