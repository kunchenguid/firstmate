#!/usr/bin/env python3
"""Executable-level remote Orca tests, invoked by fm-backend-orca.test.sh.

The fake SSH server executes the actual transport protocol in a distinct task
workspace. Git repositories are independent temporary clones. No real SSH,
Orca endpoint, account store, or Firstmate home is contacted.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "bin/fm-orca-worker.py"
SELECT = ROOT / "bin/fm-orca-machines.py"


class Transport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-orca-transport-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.state = self.home / "state"
        self.data = self.home / "data"
        self.config = self.home / "config"
        self.code = self.root / "code"
        self.fakebin = self.root / "fakebin"
        for path in (self.state, self.data / "task", self.config, self.code / "bin", self.fakebin):
            path.mkdir(parents=True)
        self.env = os.environ.copy()
        # The fake remote worker strips FM_* (including the test harness's
        # FM_GATE_REFUSE_BYPASS) like production, so a gate run's marker would
        # make the staged fm-spawn.sh refuse inside this temporary fixture.
        self.env.pop("NO_MISTAKES_GATE", None)
        self.env["PATH"] = str(self.fakebin) + ":" + os.environ["PATH"]
        self.env["HOME"] = str(self.root)
        self.env["ORCA_TEST_ROOT"] = str(self.root)
        self.local = self.root / "project"
        self.git("init", "-q", "-b", "main", str(self.local))
        self.git("-C", str(self.local), "config", "user.name", "Test")
        self.git("-C", str(self.local), "config", "user.email", "test@example.invalid")
        self.git("-C", str(self.local), "commit", "-qm", "initial", "--allow-empty")
        self.remote_project = self.root / "remote-project"
        self.git("clone", "-q", str(self.local), str(self.remote_project))
        self.git("-C", str(self.remote_project), "branch", "fm/task")
        shutil.copyfile(ROOT / "bin/fm-tasks-axi-lib.sh", self.code / "bin/fm-tasks-axi-lib.sh")
        tasks = self.fakebin / "tasks-axi"
        tasks.write_text("#!/bin/sh\ncase \"$*\" in\n"
                         "'--version') echo 0.2.6;;\n"
                         "'update --help') echo --archive-body;;\n"
                         "'mv --help') echo '[<id>...]';;\n"
                         "'hold --help') echo '--kind captain';;\n"
                         "*) exit 1;;\nesac\n")
        tasks.chmod(0o700)
        for name in ("jq", "lsof"):
            if not shutil.which(name, path=self.env["PATH"]):
                tool = self.fakebin / name
                tool.write_text("#!/bin/sh\nexit 0\n")
                tool.chmod(0o700)
        self.ssh = self.fakebin / "ssh"
        self.ssh.write_text("""#!/usr/bin/env python3
import json, os, pathlib, shlex, subprocess, sys
root = pathlib.Path(os.environ['ORCA_TEST_ROOT'])
with (root/'ssh-calls').open('a') as out: out.write(sys.argv[-2]+'\\n')
if shlex.split(sys.argv[-1])[3] == '--fm-orca-load-probe':
    host = sys.argv[-2]
    if host == 'offline': sys.exit(255)
    head = subprocess.check_output(['git','-C',str(root/'project'),'rev-parse','HEAD'], text=True).strip()
    print(json.dumps(dict(load=20 if host == 'busy' else 1, cores=10, runtime_id='runtime-test',
                         head=None if host == 'missing' else head)))
else:
    if sys.argv[-2] == 'offline': sys.exit(255)
    payload = sys.stdin.buffer.read()
    request = json.loads(payload)
    if request['op'] == 'stage' and (root/'fail-stage').exists():
        print('error: remote Orca worker: cannot create workspace', file=sys.stderr); sys.exit(1)
    result = subprocess.run(sys.argv[-1], shell=True, input=payload, capture_output=True)
    lost = root/'lose-launch-reply'
    if lost.exists() and request['op'] == 'run' and request['script'] == 'fm-spawn.sh':
        lost.unlink(); sys.exit(255)
    lost = root/'lose-teardown-reply'
    if lost.exists() and request['op'] == 'run' and request['script'] == 'fm-teardown.sh':
        lost.unlink(); sys.exit(255)
    sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
""")
        self.ssh.chmod(0o700)
        orca = self.fakebin / "orca"
        orca.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"result":{"runtime":{"runtimeId":"runtime-test","reachable":true,"state":"ready"}}}\'\n')
        orca.chmod(0o700)
        (self.data / "task/brief.md").write_text(
            "# Task\n" + str(self.state / "task.inbox") +
            "\nFM_HOME='" + str(self.home) + "'\n" +
            str(self.code / ".agents/skills/captain-hold-lifecycle/SKILL.md"))
        spawn = self.code / "bin/fm-spawn.sh"
        spawn.write_text("""#!/usr/bin/env bash
set -eu
id=$1
mkdir -p "$FM_HOME/state/$id.inbox/handled" "$FM_HOME/data/$id"
cat > "$FM_HOME/state/$id.meta" <<EOF
backend=orca
window=fm-$id
endpoint_task_id=$id
terminal=term-1
orca_worktree_id=repo::REMOTE_PROJECT
worktree=REMOTE_PROJECT
project=REMOTE_PROJECT
branch=fm/task
kind=ship
mode=local-only
spawn_gen=test-generation
EOF
printf 'working [at=123]: running\\n' >> "$FM_HOME/state/$id.status"
printf 'proof\\n' > "$FM_HOME/data/$id/report.md"
""".replace("REMOTE_PROJECT", str(self.remote_project)))
        spawn.chmod(0o700)
        self.git("init", "-q", "-b", "main", str(self.code))
        self.git("-C", str(self.code), "config", "user.name", "Code Fixture")
        self.git("-C", str(self.code), "config", "user.email", "code@example.invalid")
        self.git("-C", str(self.code), "add", ".")
        self.git("-C", str(self.code), "commit", "-qm", "code root")
        self.code_root = self.git("-C", str(self.code), "rev-parse", "HEAD")
        self.git("-C", str(self.code), "commit", "--allow-empty", "-qm", "code tip")
        self.git("-C", str(self.code), "remote", "add", "origin", "https://example.invalid/firstmate.git")
        self.git("-C", str(self.local), "remote", "add", "origin", str(self.remote_project))
        self.machine = json.dumps(dict(environment="worker-mac", ssh="idle", max_load_per_core=0.8, runtime_id="runtime-test"))

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], env=self.env, stderr=subprocess.PIPE).decode().strip()

    def run_cli(self, script, *args, ok=True):
        result = subprocess.run([sys.executable, str(script), *map(str, args)], env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def spawn(self, ok=True, mode="local-only"):
        return self.run_cli(BRIDGE, "spawn", self.home, self.code, self.state, self.data,
                            self.config, "task", self.local, self.machine,
                            "task", self.local, "--mode", mode, ok=ok)

    def test_publishing_stages_real_lineage_and_preserves_script_overlay(self):
        shutil.copyfile(ROOT / "bin/fm-role-lib.sh", self.code / "bin/fm-role-lib.sh")
        spawn = self.code / "bin/fm-spawn.sh"
        spawn.write_text(spawn.read_text() + '''
source "$FM_ROOT/bin/fm-role-lib.sh"
rc=0
fm_role_gate_self_publish "$FM_HOME" "$FM_HOME/config" "$2" "$FM_ROOT" || rc=$?
test "$rc" = 2 || { echo "$FM_ROLE_PUB_DENIAL" >&2; exit 1; }
''')
        self.spawn(mode="no-mistakes")
        code = str(Path(self.route()["workspace"]) / "code")
        self.assertEqual(self.git("-C", code, "rev-parse", "--show-toplevel"), str(Path(code).resolve()))
        self.assertEqual(self.git("-C", code, "rev-parse", "--is-shallow-repository"), "false")
        self.assertEqual(self.git("-C", code, "rev-list", "--max-parents=0", "HEAD"), self.code_root)
        self.assertEqual(self.git("-C", code, "remote", "get-url", "origin"), "https://example.invalid/firstmate.git")
        # Self-repo authorization must still refuse, despite complete history.
        result = subprocess.run(["bash", "-c", '''
source "$1/bin/fm-role-lib.sh"
fm_role_gate_self_publish "$2" "$2/config" "$1" "$1"
''', "bash", code, str(self.home)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 1)

    def test_shallow_code_refuses_before_remote_staging(self):
        shallow = self.root / "shallow-code"
        self.git("clone", "-q", "--depth", "1", self.code.as_uri(), str(shallow))
        self.code = shallow
        result = self.spawn(ok=False, mode="no-mistakes")
        self.assertIn("full Git history required", result.stderr)
        self.assertFalse((self.state / "task.orca-route.json").exists())

    def test_local_only_accepts_shallow_code_without_publishing_context(self):
        shallow = self.root / "shallow-code"
        self.git("clone", "-q", "--depth", "1", self.code.as_uri(), str(shallow))
        self.code = shallow
        self.spawn()
        self.assertFalse((Path(self.route()["workspace"]) / "code/.git").exists())

    def test_publishing_requires_origin_before_staging(self):
        self.git("-C", str(self.local), "remote", "remove", "origin")
        self.spawn(mode="direct-PR", ok=False)
        self.assertFalse((self.state / "task.orca-route.json").exists())

    def test_credential_bearing_code_origin_is_not_transferred(self):
        self.git("-C", str(self.code), "remote", "set-url", "origin",
                 "https://user:fixture-secret@example.invalid/code.git")
        result = self.spawn(ok=False, mode="direct-PR")
        self.assertIn("credential-bearing origin", result.stderr)
        self.assertNotIn("fixture-secret", result.stderr)
        self.assertFalse((self.state / "task.orca-route.json").exists())

    def test_locked_git_crypt_refuses_before_staging(self):
        (self.local / ".gitattributes").write_text("secret filter=git-crypt\n")
        (self.local / "secret").write_bytes(b"\0GITCRYPT\0ciphertext")
        self.git("-C", str(self.local), "add", ".")
        self.git("-C", str(self.local), "commit", "-qm", "encrypted file")
        crypt = self.fakebin / "git-crypt"
        crypt.write_text("#!/bin/sh\nexit 1\n")
        crypt.chmod(0o700)
        result = self.spawn(mode="no-mistakes", ok=False)
        self.assertIn("git-crypt filter is locked", result.stderr)
        self.assertFalse((self.state / "task.orca-route.json").exists())

    def route(self):
        return json.loads((self.state / "task.orca-route.json").read_text())

    def test_selection_validates_all_rows_before_any_probe(self):
        path = self.config / "orca-machines"
        path.write_text(json.dumps([dict(environment="first", ssh="idle", max_load_per_core=1),
                                    dict(environment="invalid", ssh="-oProxyCommand=bad", max_load_per_core=1)]))
        self.run_cli(SELECT, "select", path, self.local, ok=False)
        self.assertFalse((self.root / "ssh-calls").exists())

    def test_selection_order_skips_busy_missing_and_offline(self):
        path = self.config / "orca-machines"
        path.write_text(json.dumps([dict(environment=host, ssh=host, max_load_per_core=0.8)
                                    for host in ("busy", "missing", "offline", "idle", "unused")]))
        result = self.run_cli(SELECT, "select", path, self.local)
        self.assertEqual(json.loads(result.stdout)["environment"], "idle")
        self.assertEqual((self.root / "ssh-calls").read_text().splitlines(), ["busy", "missing", "offline", "idle"])
        path.write_text(json.dumps([dict(environment="busy", ssh="busy", max_load_per_core=0.8)]))
        self.assertEqual(json.loads(self.run_cli(SELECT, "select", path, self.local).stdout), {"environment": "local"})

    def test_missing_harness_is_named_before_staging(self):
        missing = "fm-proof-missing-harness-73192"
        result = self.run_cli(BRIDGE, "spawn", self.home, self.code, self.state, self.data,
                              self.config, "task", self.local, self.machine,
                              "task", self.local, "--harness", missing, ok=False)
        self.assertIn("remote lifecycle tools missing: " + missing, result.stderr)
        self.assertFalse((self.state / "task.orca-route.json").exists())
        self.assertEqual(list((self.data / "task").glob("orca-*")), [])

    def test_incompatible_cleanup_tool_refuses_before_staging(self):
        (self.fakebin / "tasks-axi").write_text("#!/bin/sh\necho 0.0.0\n")
        result = self.spawn(ok=False)
        self.assertIn("tasks-axi is incompatible", result.stderr)
        self.assertFalse((self.state / "task.orca-route.json").exists())
        self.assertEqual(list((self.data / "task").glob("orca-*")), [])

    def test_cleanup_receipt_prevents_status_resurrection(self):
        teardown = self.code / "bin/fm-teardown.sh"
        teardown.write_text('#!/bin/sh\nrm "$FM_HOME/state/$1.meta" "$FM_HOME/state/$1.status"\n')
        teardown.chmod(0o700)
        self.spawn()
        remote_home = Path(self.route()["workspace"]) / "home"
        with (self.state / "task.status").open("a") as stream:
            stream.write("resolved [key=default] [at=124]: dependency installed\n")
        self.run_cli(BRIDGE, "run", self.state, "task", "fm-teardown.sh", "task")
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertFalse((remote_home / "state/task.status").exists())
        self.assertFalse((remote_home / "state/task.meta").exists())
        self.assertEqual(self.run_cli(BRIDGE, "receipt", self.state, "task").stdout.strip(), "complete")

    def test_explicit_base_is_preserved_for_delivery_bundles(self):
        initial = self.git("-C", str(self.local), "rev-parse", "HEAD")
        self.git("-C", str(self.local), "branch", "release")
        self.git("-C", str(self.local), "commit", "-qm", "main advanced", "--allow-empty")
        self.run_cli(BRIDGE, "spawn", self.home, self.code, self.state, self.data,
                     self.config, "task", self.local, self.machine,
                     "task", self.local, "--base-branch", "release")
        self.assertEqual(self.route()["base_head"], initial)

    def test_spawn_sync_acknowledgement_and_report(self):
        (self.config / "t3code-token").write_text("private-secret")
        (self.config / "codex-approval-mode").write_text("never")
        self.spawn()
        remote_home = Path(self.route()["workspace"]) / "home"
        staged = (remote_home / "data/task/brief.md").read_text()
        self.assertIn("FM_HOME='" + str(remote_home) + "'", staged)
        self.assertIn(str(Path(self.route()["workspace"]) / "code/.agents/skills/captain-hold-lifecycle/SKILL.md"), staged)
        self.assertFalse((remote_home / "config/t3code-token").exists())
        self.assertEqual((remote_home / "config/codex-approval-mode").read_text(), "never")
        self.assertIn(str(remote_home / "state/task.inbox"), (remote_home / "data/task/brief.md").read_text())
        self.assertIn("orca_environment=worker-mac", (self.state / "task.meta").read_text())
        self.assertEqual((self.data / "task/report.md").read_text(), "proof\n")
        inbox = self.state / "task.inbox"
        inbox.mkdir()
        message = inbox / "001.msg"
        message.write_text("schema=fm-task-inbox.v1\n--\nsteer\n")
        self.run_cli(BRIDGE, "sync", self.state, "task")
        remote_inbox = remote_home / "state/task.inbox"
        (remote_inbox / "001.msg").rename(remote_inbox / "handled/001.msg")
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertFalse(message.exists())
        self.assertTrue((inbox / "handled/001.msg").exists())
        self.assertFalse((remote_inbox / "001.msg").exists())
        self.assertEqual((self.state / "task.status").read_text().count("running"), 1)
        event = remote_home / "state/task.turn-ended"
        event.touch()
        self.run_cli(BRIDGE, "sync", self.state, "task")
        prior = (self.state / "task.turn-ended").stat().st_mtime_ns
        os.utime(event, ns=(prior + 2000000000, prior + 2000000000))
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertGreater((self.state / "task.turn-ended").stat().st_mtime_ns, prior)
        event.unlink()
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertFalse((self.state / "task.turn-ended").exists())
        self.spawn(ok=False)

    def test_head_import_and_dirty_refusal(self):
        self.spawn()
        self.git("-C", str(self.remote_project), "checkout", "-q", "fm/task")
        self.git("-C", str(self.remote_project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "remote work")
        result = self.run_cli(BRIDGE, "head", self.state, "task")
        self.assertEqual(result.stdout.strip(), self.git("-C", str(self.local), "rev-parse", "fm/task"))
        (self.remote_project / "dirty").write_text("uncommitted")
        self.run_cli(BRIDGE, "head", self.state, "task", ok=False)

    def test_acknowledgement_mismatch_preserves_local_message(self):
        self.spawn()
        inbox = self.state / "task.inbox"
        inbox.mkdir()
        (inbox / "001.msg").write_text("original\n")
        remote_home = Path(self.route()["workspace"]) / "home"
        (remote_home / "state/task.inbox/handled/001.msg").write_text("different\n")
        self.run_cli(BRIDGE, "sync", self.state, "task", ok=False)
        self.assertTrue((inbox / "001.msg").exists())

    def test_lost_launch_reply_retains_route_and_recovers_metadata(self):
        (self.root / "lose-launch-reply").touch()
        self.spawn(ok=False)
        self.assertTrue((self.state / "task.orca-route.json").exists())
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertIn("terminal=term-1", (self.state / "task.meta").read_text())
        self.spawn(ok=False)

    def test_definite_stage_failure_archives_route_for_redispatch(self):
        (self.root / "fail-stage").touch()
        self.spawn(ok=False)
        self.assertFalse((self.state / "task.orca-route.json").exists())
        self.assertEqual(len(list((self.data / "task/remote").glob("orca-route-*.failed.json"))), 1)
        (self.root / "fail-stage").unlink()
        self.spawn()
        self.assertIn("orca_environment=worker-mac", (self.state / "task.meta").read_text())

    def test_spawn_holds_route_lock_and_archives_unwound_launch(self):
        spawn = self.code / "bin/fm-spawn.sh"
        spawn.write_text(spawn.read_text() + """
rc=0
python3 BRIDGE sync STATE task --poll 2>/dev/null || rc=$?
echo "$rc" > ROOT/poll-rc
printf 'failed [at=124]: launch was not consumed\\n' >> "$FM_HOME/state/$id.status"
rm "$FM_HOME/state/$id.meta"
exit 1
""".replace("BRIDGE", str(BRIDGE)).replace("STATE", str(self.state)).replace("ROOT", str(self.root)))
        self.spawn(ok=False)
        self.assertNotEqual((self.root / "poll-rc").read_text().strip(), "0")
        self.assertFalse((self.state / "task.meta").exists())
        self.assertFalse((self.state / "task.orca-route.json").exists())
        (self.code / "bin/fm-spawn.sh").write_text(spawn.read_text().split("\nrc=0\n")[0] + "\n")
        self.spawn()
        with (Path(self.route()["workspace"]) / "home/state/task.status").open("a") as stream:
            stream.write("done [at=125]: second attempt complete\n")
        self.run_cli(BRIDGE, "sync", self.state, "task")
        status = (self.state / "task.status").read_text()
        self.assertIn("launch was not consumed", status)
        self.assertIn("second attempt complete", status)

    def test_watcher_polls_an_unreachable_host_once_per_scan(self):
        if (self.fakebin / "jq").exists():
            self.skipTest("jq unavailable")
        for task in ("a", "b"):
            (self.state / (task + ".orca-route.json")).write_text(json.dumps(dict(
                id=task, ssh="offline", environment="worker-mac", runtime_id="runtime-test",
                workspace="/nonexistent/orca-x", token="x")))
        env = self.env.copy()
        env.update(FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.state))
        result = subprocess.run(["bash", "-c", '. "$1"; STATE=$2; scan_signals', "watch",
                                 str(ROOT / "bin/fm-watch.sh"), str(self.state)],
                                env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "ssh-calls").read_text().splitlines(), ["offline"])

    def test_landing_requires_parent_main_and_unchanged_remote_head(self):
        self.spawn()
        self.git("-C", str(self.remote_project), "checkout", "-q", "fm/task")
        self.git("-C", str(self.remote_project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "remote work")
        sha = self.run_cli(BRIDGE, "head", self.state, "task").stdout.strip()
        self.assertEqual(self.route()["accepted_head"], sha)
        self.run_cli(BRIDGE, "landing", self.state, "task", ok=False)
        self.git("-C", str(self.local), "merge", "--ff-only", "fm/task")
        self.run_cli(BRIDGE, "landing", self.state, "task")
        token = self.route()["token"]
        self.assertEqual(sha, self.git("-C", str(self.remote_project), "rev-parse",
                                      "refs/remotes/fm-parent-" + token + "/landed"))
        self.git("-C", str(self.remote_project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "later work")
        self.run_cli(BRIDGE, "landing", self.state, "task", ok=False)

    def test_status_rewrite_refuses_without_replacing_local_evidence(self):
        self.spawn()
        remote_home = Path(self.route()["workspace"]) / "home"
        before = (self.state / "task.status").read_bytes()
        (remote_home / "state/task.status").write_text("done: rewritten\n")
        self.run_cli(BRIDGE, "sync", self.state, "task", ok=False)
        self.assertEqual(before, (self.state / "task.status").read_bytes())

    def test_remote_done_pins_upstream_local_readiness_identity(self):
        self.spawn()
        self.git("-C", str(self.remote_project), "checkout", "-q", "fm/task")
        self.git("-C", str(self.remote_project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "ready remote work")
        script = '''
source "$1/bin/fm-dod-lib.sh"
fm_dod_accept_ship_done ship local-only "$2" "$2" 'done: ready in branch fm/task' "$3" task "$3/task.meta"
'''
        def accept():
            return subprocess.run(["bash", "-c", script, "test", str(ROOT), str(self.remote_project), str(self.state)],
                                  env=self.env, capture_output=True, text=True, timeout=60)
        sha = self.git("-C", str(self.remote_project), "rev-parse", "HEAD")
        for _ in range(2):
            result = accept()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        meta = (self.state / "task.meta").read_text()
        self.assertEqual([line for line in meta.splitlines() if line.startswith("local_done_head=")],
                         ["local_done_head=" + sha])
        self.assertEqual(sha, self.git("-C", str(self.local), "rev-parse", "fm/task"))
        self.git("-C", str(self.remote_project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "later unapproved work")
        self.assertNotEqual(accept().returncode, 0)
        self.assertEqual(meta, (self.state / "task.meta").read_text())

    def test_real_spawn_stages_and_records_remote_worker(self):
        self.real_spawn()

    def test_real_publishing_spawn_passes_both_publication_gates(self):
        self.real_spawn(mode="direct-PR")

    def test_real_spawn_preserves_dispatch_override(self):
        self.real_spawn(mode="direct-PR", override="Use the explicit task profile")

    def test_real_spawn_carries_registered_project_posture(self):
        (self.data / "projects.md").write_text(
            "- project [direct-PR forge=forgejo] - fixture (added 2026-01-01)\n")
        self.real_spawn(mode="direct-PR", contract="Delivery contract: mode=direct-PR forge=forgejo\n")

    def test_full_coordinator_can_route_remote(self):
        (self.config / "lane-capacity").write_text("1\nadmit-spawns\n")
        (self.state / "existing-local.meta").write_text("kind=ship\n")
        self.real_spawn(mode="direct-PR")

    def real_spawn(self, mode=None, override=None, contract=""):
        (self.config / "backlog-backend").write_text("manual\n")
        profile = dict(harness="codex", model="gpt-5" if override else None, effort=None)
        (self.config / "crew-dispatch.json").write_text(json.dumps(dict(default=profile)))
        decision = dict(task="task", status="clear", profile=profile)
        (self.data / "task/dispatch-resolution.json").write_text(json.dumps(decision))
        (self.config / "orca-machines").write_text(json.dumps([
            dict(environment="worker-mac", ssh="idle", max_load_per_core=0.8)]))
        (self.data / "task/brief.md").write_text(
            "# Task\n" + contract + "## Captain's intent\nExercise remote dispatch.\n\n"
            "## Firstmate spec\nCheck the task endpoint and isolated worktree.\n")
        codex = self.fakebin / "codex"
        codex.write_text("#!/bin/sh\nprintf 'codex-cli 0.999.0\\n'\n")
        codex.chmod(0o700)
        orca = self.fakebin / "orca"
        orca.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['ORCA_TEST_ROOT'])
args = sys.argv[1:]
kind = args[:2]
result = {}
if args[0] == 'status':
    if os.environ.get('FM_HOME') == str(root/'home') and '--environment' not in args:
        # Only the selected remote runtime is ready; checking the coordinator's
        # local runtime before selecting a machine would wrongly block spawn.
        sys.exit(1)
    result = dict(runtime=dict(runtimeId='runtime-test',reachable=True,state='ready'))
elif kind == ['repo','show']:
    result = dict(repo=dict(id='repo-test'))
elif kind == ['worktree','create']:
    wt = root/'isolated-orca-worktree'
    subprocess.run(['git','-C',str(root/'project'),'worktree','add','--detach',str(wt),'HEAD'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = dict(worktree=dict(id='repo-test::'+str(wt),path=str(wt)),terminal=dict(handle='term-test'))
elif kind == ['terminal','read']:
    result = dict(terminal=dict(tail=['ready']))
elif kind == ['worktree','show']:
    result = dict(worktree=dict(path=str(root/'isolated-orca-worktree')))
elif kind == ['worktree','rm']:
    subprocess.run(['git','-C',str(root/'project'),'worktree','remove','--force',str(root/'isolated-orca-worktree')], check=True)
print(json.dumps(dict(ok=True,result=result)))
""")
        orca.chmod(0o700)
        env = self.env.copy()
        env.update(FM_HOME=str(self.home), FM_ROOT_OVERRIDE="", FM_STATE_OVERRIDE=str(self.state),
                   FM_CONFIG_OVERRIDE=str(self.config), FM_DATA_OVERRIDE=str(self.data),
                   FM_PROJECTS_OVERRIDE=str(self.home / "projects"), FM_SPAWN_NO_GUARD="1")
        flags = ["--mode", mode, "--yolo", "off"] if mode else ["--scout"]
        if override:
            flags += ["--dispatch-override", override]
        result = subprocess.run(["bash", str(ROOT / "bin/fm-spawn.sh"), "task", str(self.local),
                                 "--backend", "orca", "--harness", "codex", *flags],
                                capture_output=True, text=True, env=env, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fields = (self.state / "task.meta").read_text()
        self.assertIn("orca_environment=worker-mac", fields)
        self.assertIn("orca_runtime_id=runtime-test", fields)
        self.assertIn("worktree=" + str(self.root / "isolated-orca-worktree"), fields)
        self.assertIn("terminal=term-test", fields)
        remote_home = Path(self.route()["workspace"]) / "home"
        self.assertEqual(json.loads((remote_home / "data/task/dispatch-resolution.json").read_text()), decision)
        if override:
            self.assertIn("dispatch_override=" + override, fields)
        if mode:
            self.assertIn("mode=" + mode, fields)
            return
        def fm(script, *args):
            result = subprocess.run(["bash", str(ROOT / "bin" / script), "task", *args],
                                    capture_output=True, text=True, env=env, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout
        self.assertIn("ready", fm("fm-peek.sh"))
        fm("fm-send.sh", "Write the report, then acknowledge this message.")
        remote_home = Path(self.route()["workspace"]) / "home"
        inbox = remote_home / "state/task.inbox"
        messages = list(inbox.glob("*.msg"))
        self.assertEqual(len(messages), 1)
        (inbox / "handled").mkdir(exist_ok=True)
        messages[0].rename(inbox / "handled" / messages[0].name)
        (remote_home / "data/task/report.md").write_text("Scout proof complete.\n")
        with (remote_home / "state/task.status").open("a") as stream:
            stream.write("done [at=123]: report complete\n")
        self.run_cli(BRIDGE, "sync", self.state, "task")
        self.assertTrue((self.state / "task.inbox/handled" / messages[0].name).exists())
        self.assertIn("source: pane", fm("fm-crew-state.sh"))
        inventory = subprocess.run(["bash", str(ROOT / "bin/fm-captain-hold.sh"), "complete", "task", "--none"],
                                   capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(inventory.returncode, 0, inventory.stdout + inventory.stderr)
        (self.root / "lose-teardown-reply").touch()
        lost = subprocess.run(["bash", str(ROOT / "bin/fm-teardown.sh"), "task"],
                              capture_output=True, text=True, env=env, timeout=180)
        self.assertNotEqual(lost.returncode, 0)
        self.assertTrue((self.state / "task.meta").exists())
        self.assertFalse((remote_home / "state/task.meta").exists())
        self.assertEqual(self.run_cli(BRIDGE, "receipt", self.state, "task").stdout.strip(), "complete")
        fm("fm-teardown.sh")
        self.assertFalse((self.state / "task.meta").exists())
        self.assertFalse((self.root / "isolated-orca-worktree").exists())
        self.assertTrue((self.data / "task/remote-state/task.meta").exists())


if __name__ == "__main__":
    unittest.main()
