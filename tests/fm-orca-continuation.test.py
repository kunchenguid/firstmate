#!/usr/bin/env python3
"""Black-box isolated continuation cases; invoked by the Bash behavior suite."""
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(sys.argv[1]).resolve()
TMP = pathlib.Path(sys.argv[2]).resolve()
sys.argv[1:] = []
ADAPTER = ROOT / "bin/fm-codex-orca-continuation.py"

ORCA = r'''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys,time
h=pathlib.Path(os.environ['FM_HOME']); a=sys.argv[1:]
mode=(h/'mode').read_text().strip() if (h/'mode').exists() else 'started'
runtime='runtime-moved' if mode=='runtime-moved' else 'runtime-1'
inc='incarnation-moved' if mode=='incarnation-moved' else 'incarnation-1'
if a[:2]==['terminal','show']:
 print(json.dumps({'ok':True,'result':{'terminal':{'handle':'term-primary','incarnationId':inc,'worktreeId':'repo::'+str(h),'connected':True,'writable':True,'orphaned':False,'agentIdentity':'codex'}},'_meta':{'runtimeId':runtime}}))
elif a[:2]==['terminal','create']:
 with (h/'creates').open('a') as f: f.write('create\n')
 if mode=='create-ambiguous':
  print('fixture creation receipt unavailable',file=sys.stderr);sys.exit(1)
 with (h/'owner.log').open('a') as out:
  p=subprocess.Popen(['bash','-c',a[a.index('--command')+1]],stdin=subprocess.DEVNULL,stdout=out,stderr=out,start_new_session=True)
 (h/'app-pid').write_text(str(p.pid))
 print(json.dumps({'ok':True,'result':{'terminal':{'handle':'term-owner'}}}))
elif a[:2]==['terminal','send']:
 root=os.environ['FM_ROOT_OVERRIDE']
 health=subprocess.run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$STATE" "$1/bin/fm-watch.sh" 300 "$FM_HOME" || exit 1; printf "%s" "$FM_WATCHER_HEALTHY_PID"','fake',root],capture_output=True,text=True)
 payload=a[a.index('--text')+1]
 retry=a[a.index('--retry-request')+1] if '--retry-request' in a else None
 with (h/'sends').open('a') as f: f.write(json.dumps({'argv':a,'payload':payload,'retry':retry,'healthy':health.returncode==0,'watcher':health.stdout})+'\n')
 if mode=='timeout': time.sleep(20)
 if mode=='held':
  deadline=time.monotonic()+12
  while not (h/'release-send').exists() and time.monotonic()<deadline: time.sleep(.05)
 if mode=='reject':
  print(json.dumps({'ok':False,'error':{'message':'fixture rejection'}}));sys.exit(1)
 if mode=='ambiguous' and not retry:
  print(json.dumps({'ok':False,'warnings':['resume exact command with --retry-request request-stable']}));sys.exit(1)
 stages=['input_accepted'] if mode=='accepted' else ['input_accepted','turn_started']
 print(json.dumps({'ok':True,'result':{'send':{'handle':'wrong-handle' if mode=='receipt-handle' else 'term-primary','accepted':True,'prompt':{'requestId':'' if mode=='receipt-request' else ('request-stable' if retry else 'request-'+str(time.time_ns())),'processIncarnation':'wrong-incarnation' if mode=='receipt-incarnation' else inc,'provider':'old-host' if mode=='receipt-provider' else 'codex','stages':stages}}},'_meta':{'runtimeId':'wrong-runtime' if mode=='receipt-runtime' else runtime}}))
else: sys.exit(2)
'''


class Fixture:
    def __init__(self, name, mode="started", code=None):
        self.home = TMP / name
        self.code = code or ROOT
        self.home.mkdir()
        for d in ("state", "data", "config"):
            (self.home / d).mkdir()
        (self.home / "AGENTS.md").write_text("Primary fixture only.\n")
        (self.home / "bin").symlink_to(self.code / "bin", target_is_directory=True)
        subprocess.run(["git", "init", "-q", str(self.home)], check=True)
        (self.home / "state/.lock").write_text(str(os.getppid()))
        (self.home / "mode").write_text(mode)
        cli = self.home / "orca"
        cli.write_text(ORCA)
        cli.chmod(0o700)
        self.env = dict(os.environ, ORCA_CLI_COMMAND=str(cli), ORCA_TERMINAL_HANDLE="term-primary",
                        FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(self.code),
                        FM_STATE_OVERRIDE=str(self.home / "state"), FM_POLL="1", FM_SIGNAL_GRACE="1",
                        FM_CHECK_INTERVAL="1", FM_HEARTBEAT="999999", FM_CHECK_TIMEOUT="2")
        self.env.pop("ORCA_DEV_REPO_ROOT", None)
        check = self.home / "state/probe.check.sh"
        check.write_text('#!/usr/bin/env bash\nif [ -f "$FM_HOME/trigger" ]; then rm "$FM_HOME/trigger"; echo "continuity regression wake"; fi\n')
        check.chmod(0o700)
        subprocess.run(["bash", str(self.code / "bin/fm-check-register.sh"), "probe"],
                       env=self.env, check=True, capture_output=True)

    def call(self, mode, *extra, input_text=None, env=None, timeout=25):
        return subprocess.run([sys.executable, str(ADAPTER), mode, "--home", str(self.home),
                               "--code-root", str(self.code), *extra], env=env or self.env,
                              input=input_text, capture_output=True, text=True, timeout=timeout)

    def record(self):
        p = self.home / "state/.codex-orca-continuation.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def wait(self, fn, message):
        for _ in range(200):
            if fn():
                return
            time.sleep(0.1)
        log = self.home / "owner.log"
        raise AssertionError(message + "\n" + (log.read_text() if log.exists() else ""))

    def ensure(self):
        p = self.call("ensure", "--seconds", "90")
        if p.returncode:
            raise AssertionError(p.stderr + p.stdout)
        result = json.loads(p.stdout)
        if not result.get("owner_pid"):
            raise AssertionError("ensure did not establish an owner: " + p.stdout)
        return result

    def sends(self):
        p = self.home / "sends"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def trigger(self):
        (self.home / "trigger").touch()

    def note(self, text):
        p = subprocess.run(["bash", str(self.code / "bin/fm-inbox.sh"), "note", text],
                           env=self.env, capture_output=True, text=True, check=True)
        match = re.search(r"^queued (\S+)$", p.stdout, re.M)
        if not match:
            raise AssertionError("public inbox note receipt missing: " + p.stdout + p.stderr)
        return match.group(1)

    def drain(self):
        return subprocess.run(["bash", str(self.code / "bin/fm-wake-drain.sh")], env=self.env,
                              capture_output=True, text=True, check=True)

    def ack(self, presented=None):
        p = presented or self.drain()
        command = next(x.split(" run ", 1)[1] for x in p.stderr.splitlines()
                       if "WAKE_ACK_REQUIRED: " in x)
        tokens = shlex.split(command)
        subprocess.run(["bash", str(self.code / "bin/fm-wake-drain.sh"),
                        *tokens[tokens.index("--ack-through"):]], env=self.env, check=True, capture_output=True)
        return p.stdout

    def close(self):
        record = self.record()
        pid = record.get("owner_pid")
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            for _ in range(100):
                p = self.call("status")
                if not json.loads(p.stdout).get("ready"):
                    break
                time.sleep(0.1)
        if pid:
            for _ in range(200):
                if subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode != 0:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("fixture owner remained after bounded cleanup: " + str(pid))
            record = self.record()
            for child in (record.get("arm"), record.get("transport")):
                if child and subprocess.run(["ps", "-p", str(child["pid"])], capture_output=True).returncode == 0:
                    raise AssertionError("fixture child remained after cleanup: " + str(child["pid"]))
            if (self.home / "state/.watch.lock/pid").exists():
                raise AssertionError("fixture watcher lock remained after cleanup")
            print("cleanup: " + self.home.name + " owner/arm/transport absent; watcher lock absent", flush=True)
        else:
            # No owner was published. Recover only this disposable home after
            # a failed bootstrap; never race the owner's own TERM cleanup.
            subprocess.run(["bash", str(self.code / "bin/fm-watch-arm.sh"), "--stop"], env=self.env,
                           capture_output=True, timeout=10)


class ContinuationTests(unittest.TestCase):
    def setUp(self):
        self.fixtures = []

    def fixture(self, suffix="", **kwargs):
        f = Fixture(self._testMethodName + suffix, **kwargs)
        self.fixtures.append(f)
        return f

    def tearDown(self):
        for f in self.fixtures:
            f.close()

    def test_repeated_wake_ack_successor_before_notify(self):
        f = self.fixture()
        first = f.ensure()
        self.assertEqual(f.ensure()["owner_pid"], first["owner_pid"])
        self.assertEqual((f.home / "creates").read_text().count("create"), 1)
        self.assertEqual(first["bootstrap"]["owner_terminal"], "term-owner")
        last_pid = first["watcher"][0]
        for n in range(3):
            f.trigger()
            f.wait(lambda: len(f.sends()) == n + 1 and f.record().get("episode", {}).get("phase") == "turn-started", "wake was not delivered")
            row = f.sends()[-1]
            self.assertTrue(row["healthy"], "notification preceded verified successor")
            self.assertNotEqual(row["watcher"], last_pid)
            last_pid = row["watcher"]
            p1 = subprocess.run(["bash", str(ROOT / "bin/fm-wake-drain.sh")], env=f.env, capture_output=True, text=True, check=True)
            p2 = subprocess.run(["bash", str(ROOT / "bin/fm-wake-drain.sh")], env=f.env, capture_output=True, text=True, check=True)
            self.assertIn("continuity regression wake", p1.stdout)
            self.assertIn("continuity regression wake", p2.stdout)
            f.ack()
            self.assertEqual((f.home / "state/.wake-queue").read_text(), "")
        duplicate = f.call("run", "--generation", f.record()["generation"], "--seconds", "2")
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("owns this home", duplicate.stderr)

    def test_acceptance_is_distinct_and_no_resend(self):
        f = self.fixture(mode="accepted")
        f.ensure(); f.trigger()
        f.wait(lambda: f.record().get("episode", {}).get("phase") == "input-accepted-unproven", "accepted receipt missing")
        self.assertEqual(len(f.sends()), 1)
        self.assertEqual(f.record()["episode"]["stages"], ["input_accepted"])
        self.assertTrue(f.call("status").returncode == 0)

    def test_external_inbox_repeated_ack_and_interrupted_replay(self):
        f = self.fixture()
        first = f.ensure()
        previous = first["watcher"][0]
        generations = []
        for n in range(2):
            token = f.note("external continuation note " + str(n))
            f.wait(lambda: len(f.sends()) == n + 1 and f.record().get("episode", {}).get("phase") == "turn-started",
                   "public inbox append did not notify")
            row = f.sends()[-1]
            self.assertTrue(row["healthy"], "external input preceded a verified successor")
            self.assertNotEqual(row["watcher"], previous)
            previous = row["watcher"]
            generations.append(f.record()["episode"]["generation"])
            presented = f.drain()
            self.assertIn(token, presented.stdout)
            # An interrupted handler has presented but not acknowledged. Both
            # its durable row and the notification ownership must survive.
            time.sleep(2.6)
            repeated = f.drain()
            self.assertIn(token, repeated.stdout)
            self.assertEqual(len(f.sends()), n + 1)
            self.assertEqual(f.ensure()["owner_pid"], first["owner_pid"])
            f.ack(presented)
            self.assertEqual((f.home / "state/.wake-queue").read_text(), "")
        self.assertNotEqual(generations[0], generations[1])
        self.assertEqual((f.home / "creates").read_text().count("create"), 1)

    def test_external_inbox_rejection_and_owner_replacement(self):
        f = self.fixture(mode="reject")
        first = f.ensure()
        note = f.note("external rejected continuation")
        f.wait(lambda: f.record().get("episode", {}).get("phase") == "delivery-rejected", "external rejection missing")
        generation = f.record()["episode"]["generation"]
        self.assertEqual(len(f.sends()), 1)
        self.assertNotEqual(f.call("ensure").returncode, 0)
        os.kill(first["owner_pid"], signal.SIGKILL)
        f.wait(lambda: not json.loads(f.call("status").stdout)["ready"], "dead external owner remained ready")
        replacement = f.ensure()
        self.assertNotEqual(replacement["generation"], first["generation"])
        time.sleep(2.6)
        self.assertEqual(len(f.sends()), 1)
        self.assertEqual(f.record()["episode"]["generation"], generation)
        self.assertIn(note, f.drain().stdout)
        f.ack()
        self.assertEqual(f.call("ensure").returncode, 0)
        (f.home / "mode").write_text("started")
        f.note("external continuation after exact acknowledgement")
        f.wait(lambda: len(f.sends()) == 2 and f.record().get("episode", {}).get("phase") == "turn-started",
               "new external episode after ACK was not delivered")
        self.assertNotEqual(f.record()["episode"]["generation"], generation)
        self.assertTrue(f.sends()[-1]["healthy"])
        f.ack()

    def test_external_inbox_during_predecessor_close(self):
        f = self.fixture()
        check = f.home / "state/probe.check.sh"
        check.write_text('#!/usr/bin/env bash\nif [ -f "$FM_HOME/trigger" ]; then\n'
                         '  rm "$FM_HOME/trigger"\n'
                         '  bash "$FM_ROOT_OVERRIDE/bin/fm-inbox.sh" note "external during predecessor close" > "$FM_HOME/note-token"\n'
                         '  echo "continuity regression wake"\nfi\n')
        subprocess.run(["bash", str(ROOT / "bin/fm-check-register.sh"), "probe"],
                       env=f.env, check=True, capture_output=True)
        first = f.ensure()
        f.trigger()
        f.wait(lambda: len(f.sends()) == 1 and f.record().get("episode", {}).get("phase") == "turn-started",
               "predecessor-close append did not notify")
        row = f.sends()[0]
        self.assertTrue(row["healthy"])
        self.assertNotEqual(row["watcher"], first["watcher"][0])
        token = re.search(r"^queued (\S+)$", (f.home / "note-token").read_text(), re.M).group(1)
        self.assertIn(token, f.drain().stdout)
        time.sleep(2.6)
        self.assertEqual(len(f.sends()), 1)
        f.ack()
        self.assertEqual((f.home / "state/.wake-queue").read_text(), "")

    def test_external_inbox_endpoint_replacement_never_rebinds(self):
        f = self.fixture()
        f.ensure()
        (f.home / "mode").write_text("incarnation-moved")
        note = f.note("external note after endpoint replacement")
        f.wait(lambda: f.record().get("phase") == "failed", "external changed endpoint was ignored")
        self.assertEqual(f.sends(), [])
        self.assertIn(note, (f.home / "state/.wake-queue").read_text())
        f.wait(lambda: not (f.home / "state/.watch.lock/pid").exists(), "endpoint replacement leaked watcher")

    def test_external_inbox_attached_peer_is_preserved(self):
        f = self.fixture()
        with (f.home / "peer.log").open("w+") as output:
            peer = subprocess.Popen(["bash", str(ROOT / "bin/fm-watch-arm.sh")],
                                    env=dict(f.env, FM_WATCH_HANDLING_SUCCESSOR="1"),
                                    stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            try:
                f.wait(lambda: "watcher: started" in (f.home / "peer.log").read_text(), "peer watcher did not start")
                first = f.ensure()
                watcher = first["watcher"][0]
                parent = subprocess.run(["ps", "-p", watcher, "-o", "ppid="],
                                        capture_output=True, text=True, check=True).stdout.strip()
                self.assertEqual(parent, str(peer.pid), "fixture did not actually attach to a peer")
                token = f.note("external attached-peer continuation")
                f.wait(lambda: len(f.sends()) == 1 and f.record().get("episode", {}).get("phase") == "turn-started",
                       "attached peer suppressed public inbox append")
                self.assertTrue(f.sends()[0]["healthy"])
                self.assertEqual(f.sends()[0]["watcher"], watcher)
                self.assertNotEqual(f.record()["arm"]["pid"], first["arm"]["pid"])
                self.assertIsNone(peer.poll(), "adapter interrupted the foreign arm")
                self.assertIn(token, f.drain().stdout)
                f.ack()
                # Its ordinary close transfers watcher ownership to the app
                # owner, which must then replace it before the next input.
                f.trigger()
                f.wait(lambda: len(f.sends()) == 2 and f.record().get("episode", {}).get("phase") == "turn-started",
                       "peer close did not establish an owned successor")
                self.assertNotEqual(f.sends()[1]["watcher"], watcher)
                self.assertTrue(f.sends()[1]["healthy"])
                self.assertEqual(peer.wait(timeout=10), 0)
                f.ack()
            finally:
                if peer.poll() is None:
                    peer.send_signal(signal.SIGTERM)
                    try:
                        peer.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(peer.pid, signal.SIGKILL)
                        peer.wait(timeout=3)

    def test_external_inbox_ack_and_append_during_input(self):
        f = self.fixture(mode="held")
        first = f.ensure()
        one = f.note("external note acknowledged during input")
        f.wait(lambda: len(f.sends()) == 1, "held input did not start")
        self.assertIn(one, f.ack())
        two = f.note("external note appended before delivery confirmation")
        (f.home / "release-send").touch()
        f.wait(lambda: len(f.sends()) == 2 and f.record().get("episode", {}).get("phase") == "turn-started",
               "new generation during receipt/ACK race was not delivered")
        self.assertTrue(all(row["healthy"] for row in f.sends()))
        self.assertNotEqual(f.sends()[0]["payload"], f.sends()[1]["payload"])
        self.assertNotEqual(f.sends()[0]["watcher"], f.sends()[1]["watcher"])
        self.assertEqual(f.ensure()["owner_pid"], first["owner_pid"])
        self.assertIn(two, f.drain().stdout)
        f.ack()

    def test_exact_ambiguous_retry(self):
        f = self.fixture(mode="ambiguous")
        f.ensure(); f.trigger()
        f.wait(lambda: f.record().get("episode", {}).get("phase") == "turn-started", "exact retry did not complete")
        rows = f.sends()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["payload"], rows[1]["payload"])
        self.assertIsNone(rows[0]["retry"])
        self.assertEqual(rows[1]["retry"], "request-stable")
        self.assertTrue(all(x["healthy"] for x in rows))

    def test_rejection_and_timeout_preserve_queue(self):
        for mode in ("reject", "timeout"):
            f = self.fixture(mode, mode=mode)
            f.ensure(); f.trigger()
            wanted = "delivery-rejected" if mode == "reject" else "delivery-unknown"
            f.wait(lambda: f.record().get("episode", {}).get("phase") == wanted, "failure evidence missing")
            self.assertEqual(len(f.sends()), 1)
            self.assertIn("continuity regression wake", (f.home / "state/.wake-queue").read_text())
            self.assertTrue(json.loads(f.call("status").stdout)["ready"])
            self.assertNotEqual(f.call("ensure").returncode, 0)

    def test_runtime_and_incarnation_refuse_and_cleanup(self):
        for change in ("runtime-moved", "incarnation-moved"):
            f = self.fixture(change)
            f.ensure()
            (f.home / "mode").write_text(change)
            f.wait(lambda: f.record().get("phase") == "failed", "changed endpoint did not fail")
            self.assertEqual(f.sends(), [])
            f.wait(lambda: not (f.home / "state/.watch.lock/pid").exists(), "changed endpoint leaked watcher")

    def test_worker_foreign_lock_and_away_are_inapplicable(self):
        f = self.fixture()
        original = (f.home / "state/.lock").read_text()
        (f.home / "state/.lock").write_text(str(os.getpid()))
        self.assertFalse(json.loads(f.call("ensure").stdout)["applicable"])
        (f.home / "state/.lock").write_text(original)
        (f.home / "state/.afk").touch()
        self.assertFalse(json.loads(f.call("ensure").stdout)["applicable"])
        self.assertFalse((f.home / "creates").exists())

    def test_stop_preserves_second_stop_and_other_backend(self):
        f = self.fixture(mode="reject")
        f.ensure(); f.trigger()
        f.wait(lambda: f.record().get("episode", {}).get("phase") == "delivery-rejected", "rejection missing")
        first = subprocess.run(["bash", str(ROOT / "bin/fm-codex-orca-stop.sh")], env=f.env, capture_output=True, text=True, input='{"stop_hook_active":false}')
        second = subprocess.run(["bash", str(ROOT / "bin/fm-codex-orca-stop.sh")], env=f.env, capture_output=True, text=True, input='{"stop_hook_active":true}')
        self.assertEqual(first.returncode, 2)
        self.assertEqual(second.returncode, 0)
        both = subprocess.run(["bash", str(ROOT / "bin/fm-codex-orca-stop.sh")], env=f.env,
                              capture_output=True, text=True, input='{"stopHookActive":true,"stop_hook_active":false}')
        self.assertEqual(both.returncode, 0)
        env = dict(f.env); env.pop("ORCA_TERMINAL_HANDLE")
        self.assertFalse(json.loads(f.call("ensure", env=env).stdout)["applicable"])

    def test_owner_death_restart_keeps_one_watcher(self):
        f = self.fixture()
        old = f.ensure()
        os.kill(old["owner_pid"], signal.SIGKILL)
        f.wait(lambda: f.call("status").returncode == 0 and not json.loads(f.call("status").stdout)["ready"], "owner stayed live")
        new = f.ensure()
        self.assertNotEqual(new["owner_pid"], old["owner_pid"])
        self.assertNotEqual(new["generation"], old["generation"])
        f.trigger()
        f.wait(lambda: len(f.sends()) >= 1, "restart did not deliver")
        self.assertTrue(all(x["healthy"] for x in f.sends()))

    def test_owner_death_during_input_does_not_fresh_resend(self):
        f = self.fixture(mode="timeout")
        old = f.ensure(); f.trigger()
        f.wait(lambda: len(f.sends()) == 1, "first input attempt missing")
        transport = f.record()["transport"]
        os.kill(old["owner_pid"], signal.SIGKILL)
        f.wait(lambda: not json.loads(f.call("status").stdout)["ready"], "owner death not detected")
        new = f.ensure()
        self.assertNotEqual(new["generation"], old["generation"])
        time.sleep(1)
        self.assertEqual(len(f.sends()), 1)
        self.assertEqual(f.record()["episode"]["phase"], "sending")
        self.assertIsNone(f.record()["transport"])
        self.assertNotEqual(subprocess.run(["ps", "-p", str(transport["pid"])], capture_output=True).returncode, 0)
        self.assertNotEqual(f.call("ensure").returncode, 0)
        f.ack()
        self.assertEqual(f.call("ensure").returncode, 0)

    def test_wrong_receipts_never_claim_turn_started(self):
        for mode in ("receipt-handle", "receipt-runtime", "receipt-incarnation", "receipt-provider", "receipt-request"):
            f = self.fixture(mode, mode=mode)
            f.ensure(); f.trigger()
            f.wait(lambda: f.record().get("episode", {}).get("phase") == "delivery-unknown", "wrong receipt claimed success")
            self.assertEqual(len(f.sends()), 1)
            self.assertNotEqual(f.call("ensure").returncode, 0)
            self.assertTrue(json.loads(f.call("status").stdout)["ready"])

    def test_changed_primary_identity_fails_and_cleans(self):
        f = self.fixture()
        f.ensure()
        (f.home / "state/.lock").write_text(str(os.getpid()))
        f.wait(lambda: f.record().get("phase") == "failed", "changed primary lock was ignored")
        f.wait(lambda: not (f.home / "state/.watch.lock/pid").exists(), "changed primary leaked watcher")
        self.assertEqual(f.sends(), [])

    def test_successor_failure_never_notifies(self):
        code = TMP / (self._testMethodName + "-code")
        (code / "bin").mkdir(parents=True)
        for source in (ROOT / "bin").iterdir():
            if source.name != "fm-watch-arm.sh":
                (code / "bin" / source.name).symlink_to(source, target_is_directory=source.is_dir())
        arm = code / "bin/fm-watch-arm.sh"
        arm.write_text('#!/usr/bin/env bash\nif [ -f "$FM_HOME/fail-arm" ]; then echo "watcher: FAILED fixture successor"; exit 1; fi\n' + (ROOT / "bin/fm-watch-arm.sh").read_text())
        arm.chmod(0o700)
        f = self.fixture(code=code)
        f.ensure()
        (f.home / "fail-arm").touch(); f.trigger()
        f.wait(lambda: f.record().get("phase") == "failed", "successor failure not surfaced")
        self.assertEqual(f.sends(), [])
        self.assertIn("continuity regression wake", (f.home / "state/.wake-queue").read_text())
        f.wait(lambda: not (f.home / "state/.watch.lock/pid").exists(), "failed successor leaked watcher")

    def test_unconfirmed_create_never_repeats_and_renderer_is_scoped(self):
        f = self.fixture(mode="create-ambiguous")
        rendered = subprocess.run(["bash", str(ROOT / "bin/fm-supervision-instructions.sh"), "--harness", "codex"],
                                  env=f.env, capture_output=True, text=True, check=True)
        self.assertIn("Mode: Codex with an Orca-owned continuation", rendered.stdout)
        self.assertIn(shlex.quote(str(f.home)), rendered.stdout)
        other = subprocess.run(["bash", str(ROOT / "bin/fm-supervision-instructions.sh"), "--harness", "pi"],
                               env=f.env, capture_output=True, text=True, check=True)
        self.assertNotIn("Orca-owned continuation", other.stdout)
        self.assertNotEqual(f.call("ensure").returncode, 0)
        self.assertNotEqual(f.call("ensure").returncode, 0)
        self.assertEqual((f.home / "creates").read_text().count("create"), 1)

    def test_superseded_generation_cannot_overwrite_successor_record(self):
        f = self.fixture()
        old = f.ensure()
        replacement = dict(f.record(), generation="replaced-generation", sentinel="preserve-this-record")
        (f.home / "state/.codex-orca-continuation.json").write_text(json.dumps(replacement))
        f.wait(lambda: subprocess.run(["ps", "-p", str(old["owner_pid"])], capture_output=True).returncode != 0,
               "superseded owner remained")
        self.assertEqual(f.record()["generation"], "replaced-generation")
        self.assertEqual(f.record()["sentinel"], "preserve-this-record")
        self.assertEqual(f.sends(), [])
        self.assertFalse((f.home / "state/.watch.lock/pid").exists())


unittest.main(verbosity=2, defaultTest=os.environ.get("FM_ORCA_TEST_CASE"))
