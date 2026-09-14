#!/usr/bin/env python3
"""Exercise public bridge interfaces with a real inbox and fixture-only main.

The harness fixture uses an executable named codex to exercise the existing
session-lock classifier, not to prove vendor UI behavior. It calls the public
main CLI, executes no LLM, and is killed only by its owning test. No live home,
network client, token, service registration or Herdr lifecycle is used.
"""

from http.client import IncompleteRead
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import zlib
import plistlib
import runpy
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
from fm_whatsapp_bridge import Bridge, singleton
from fm_whatsapp_store import BridgeError, Config, Store, encode
from fm_whatsapp_transport import Reply, Simulator, HTTP, NoRedirect, read_secret, classify, delay

MEDIA_TOOLS = all(importlib.util.find_spec(name) is not None for name in ("PIL", "pypdfium2")) and bool(shutil.which("ffmpeg"))
media_tools = unittest.skipUnless(MEDIA_TOOLS, "optional media dependencies: bin/requirements-whatsapp-media.txt and ffmpeg")


def poll(messages=(), statuses=(), offset=1, contacts=()):
    return Reply(200, {"object": "whatsapp_agent_platform", "entry": [
        {"id": "123", "changes": [{"field": "messages", "value": {
            "messaging_product": "whatsapp", "messages": list(messages),
            "statuses": list(statuses), "contacts": list(contacts)}}]}], "next_offset": offset})


class Sequence:
    def __init__(self, replies):
        self.replies, self.calls = list(replies), []

    def call(self, endpoint, payload):
        self.calls.append((endpoint, payload))
        return self.replies.pop(0)


class WhatsAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-whatsapp-test-")
        self.dir = Path(self.temp.name)
        self.home = self.dir / "home"
        for directory in ("state", "data", "config"):
            (self.home / directory).mkdir(parents=True)
        self.path = self.home / "config" / "whatsapp.json"
        self.state = self.home / "state" / "whatsapp"
        self.values = {"fm_home": str(self.home), "state_dir": str(self.state),
                       "mode": "simulated", "agent_id": "123", "creator_id": "user:owner",
                       "enabled": True, "outbound_authorized": True, "poll_timeout": 0,
                       "token_file": str(self.dir / "must-not-read-token")}
        self.path.write_text(json.dumps(self.values))
        self.config = Config(self.path)
        self.now = time.time()
        self.store = Store(self.config, clock=lambda: self.now)
        self.store.activate()
        self.fixture = self.dir / "sim.json"
        self.fixture.write_text("[]")
        self.bridge = Bridge(self.store, Simulator(self.store, self.fixture))
        self.counter = 0
        # Structural fixture only: no vendor executable or model invocation.
        harness = self.dir / "codex"
        harness.mkdir()
        helper = harness / "fixture-main.py"
        helper.write_text('''import json, os, subprocess, sys
from pathlib import Path
home, cli, config = sys.argv[1:]
Path(home, "state", ".lock").write_text(str(os.getpid()))
print("ready", flush=True)
for line in sys.stdin:
    data = json.loads(line)
    result = subprocess.run([sys.executable, cli, "--config", config, "main"],
                            input=json.dumps(data), text=True, capture_output=True)
    print(json.dumps({"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}), flush=True)
''')
        self.harness = subprocess.Popen([sys.executable, str(helper), str(self.home),
                                         str(ROOT / "bin/fm-whatsapp.py"), str(self.path)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.config.environment())
        self.assertEqual(self.harness.stdout.readline().strip(), "ready")

    def tearDown(self):
        self.bridge.finish_media()
        self.harness.stdin.close()
        self.harness.wait(timeout=10)
        self.harness.stdout.close()
        self.harness.stderr.close()
        self.store.db.close()
        self.temp.cleanup()

    def main(self, data, ok=True):
        self.harness.stdin.write(json.dumps(data) + "\n")
        self.harness.stdin.flush()
        result = json.loads(self.harness.stdout.readline())
        self.assertEqual(result["code"], 0 if ok else 1, result)
        self.now = max(self.now, time.time() + 1)
        return json.loads(result["stdout"] if ok else result["stderr"])

    def cli(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(ROOT / "bin/fm-whatsapp.py"),
                                 "--config", str(self.path), *args],
                                capture_output=True, text=True, env=self.config.environment())
        self.assertEqual(result.returncode, 0 if ok else 1, result)
        return json.loads(result.stdout if ok else result.stderr)

    def message(self, body="Analise o arquivo local", **extra):
        self.counter += 1
        return {"id": f"wamid.input.{self.counter}", "from": "user:owner",
                "timestamp": str(int(self.now) + 2), "type": "text", "text": {"body": body}, **extra}

    def receive(self, message=None, offset=None):
        self.bridge.availability()
        message = message or self.message()
        self.bridge.ingest(poll([message], offset=offset or int(self.store.get("cursor")) + 1))
        return self.store.rows("SELECT * FROM inbound WHERE wamid=?", (message["id"],))[0]

    def claim(self, row=None):
        row = row or self.receive()
        self.bridge.forward()
        row = self.store.request(row["request"])
        result = self.main({"op": "claim", "request": row["request"], "note_id": row["note_id"]})
        return row, result

    def task(self, id="analysis", revision="v1"):
        (self.home / "state" / (id + ".meta")).write_text("kind=scout\nrepo=fixture\n")
        return {"home": str(self.home), "id": id, "revision": revision}

    def emit(self, row, kind="reply", body="Resultado local", **extra):
        event = extra.pop("event", "event-" + str(time.time_ns()))
        return self.main({"op": "emit", "event": event, "request": row["request"],
                          "kind": kind, "body": body, **extra})

    def test_real_inbox_main_result_and_delivery(self):
        source = self.dir / "sample.txt"
        source.write_text("one\ntwo\nthree\n")
        row, claimed = self.claim(self.receive(self.message("Conte as linhas do arquivo local")))
        self.assertTrue(claimed["fresh_claim"])
        self.assertEqual(len(list((self.home / "state/inbox").glob("*.note"))), 1)
        self.emit(row, "started", "Análise iniciada", task=self.task())
        result = len(source.read_text().splitlines())
        self.emit(row, "completed", f"O arquivo tem {result} linhas.", evidence=[str(source)], task=self.task())
        while self.bridge.send_one():
            pass
        outputs = self.store.rows("SELECT payload FROM sim_sends ORDER BY seq")
        self.assertEqual(json.loads(outputs[-1]["payload"])["text"]["body"], "O arquivo tem 3 linhas.")
        self.assertTrue(all(r["state"] == "accepted" for r in self.store.snapshot()["outbox"]))
        self.assertEqual(self.store.request(row["request"])["state"], "completed")

    def test_explicit_status_during_long_task(self):
        first, _ = self.claim()
        self.emit(first, "started", "Analisando formulário", task=self.task())
        for command in ("/status", "/tarefas"):
            row = self.receive(self.message(command))
            self.assertEqual(row["state"], "answered")
            self.assertIsNone(row["note_id"])
            self.assertEqual(self.store.snapshot()["responses"][-1]["body"], "Iniciado: Analisando formulário")

    def test_failed_main_event_can_be_replayed_after_restart_without_new_outcome(self):
        row, _ = self.claim()
        operation = {"op": "emit", "event": "failed-stable-event", "request": row["request"],
                     "kind": "failed", "body": "Não foi possível concluir a análise."}
        self.assertTrue(self.main(operation)["new_event"])
        self.store.db.close()
        self.store = Store(self.config, clock=lambda: self.now)
        self.bridge = Bridge(self.store, Simulator(self.store, self.fixture))
        self.assertFalse(self.main(operation)["new_event"])
        self.main({**operation, "event": "different-terminal-event"}, ok=False)
        self.assertEqual(len(self.store.rows("SELECT * FROM outbox WHERE event=?", (operation["event"],))), 1)
        self.assertEqual(self.store.request(row["request"])["state"], "failed")

    def test_natural_status_preserves_completed_task_context_with_another_active(self):
        first, _ = self.claim(self.receive(self.message("Analise o formulário da tarefa A")))
        self.emit(first, "completed", "Tarefa A concluída", evidence=["fixture"], task=self.task("task-a"))
        second, _ = self.claim(self.receive(self.message("Investigue o login da tarefa B")))
        self.emit(second, "started", "Tarefa B em andamento", task=self.task("task-b"))
        for text in ("e aquela tarefa?", "e aquela tarefa", "como está o andamento?",
                     "qual o andamento?", "como estão as tarefas?"):
            with self.subTest(text=text):
                row = self.receive(self.message(text))
                self.assertEqual(row["state"], "received")
                self.assertEqual(self.store.rows("SELECT kind,actor FROM responses WHERE request=?", (row["request"],)),
                                 [{"kind": "received", "actor": "bridge"}])
                _, result = self.claim(row)
                self.assertTrue(result["fresh_claim"])
                self.assertEqual(result["text"], text)
                self.assertIsNone(result["related_request"])
                history = {r["request"]: r for r in result["history"]}
                self.assertEqual(history[first["request"]]["state"], "completed")
                self.assertEqual(history[first["request"]]["body"], first["body"])
                self.assertEqual(history[second["request"]]["state"], "started")
                self.assertEqual({r["request"] for r in result["tasks"]}, {first["request"], second["request"]})
                if text == "e aquela tarefa?":
                    responses = {r["request"]: r for r in result["responses"] if r["actor"] != "bridge"}
                    self.assertEqual(responses[first["request"]]["body"], "Tarefa A concluída")
                    self.assertEqual(responses[second["request"]]["body"], "Tarefa B em andamento")
                self.emit(row, "reply", "Você se refere ao formulário da tarefa A ou ao login da tarefa B?")

    def test_ambiguous_queued_status_reaches_main_durably_without_numbered_dialogue(self):
        first = self.receive(self.message("Analise o formulário"))
        second = self.receive(self.message("Investigue o login"))
        self.bridge.forward()
        for text in ("/status", "/tarefas", "e aquela tarefa?", "a segunda"):
            with self.subTest(text=text):
                message = self.message(text)
                row = self.receive(message)
                self.assertEqual(row["state"], "received")
                self.bridge.forward()
                stored = self.store.request(row["request"])
                self.assertEqual(stored["state"], "queued")
                reopened = Store(self.config, clock=lambda: self.now)
                try:
                    bridge = Bridge(reopened, Simulator(reopened, self.fixture))
                    bridge.recover()
                    bridge.ingest(poll([message], offset=int(reopened.get("cursor")) + 1))
                    bridge.forward()
                    self.assertEqual(reopened.request(row["request"])["envelope"], stored["envelope"])
                    self.assertEqual(reopened.rows("SELECT kind,actor FROM responses WHERE request=?", (row["request"],)),
                                     [{"kind": "received", "actor": "bridge"}])
                finally:
                    reopened.db.close()
                notes = self.home / "state/inbox"
                self.assertEqual(len(list(notes.glob(stored["note_id"] + ".note"))), 1)
                _, result = self.claim(row)
                self.assertTrue(result["fresh_claim"])
                self.assertEqual(result["text"], text)
                self.assertIsNone(result["related_request"])
                history = {r["request"]: r for r in result["history"]}
                for candidate in (first, second):
                    self.assertEqual(history[candidate["request"]]["state"], "queued")
                    self.assertEqual(history[candidate["request"]]["body"], candidate["body"])
                _, replay = self.claim(row)
                self.assertFalse(replay["fresh_claim"])
                answer = "Você se refere ao formulário ou ao login?"
                event = self.emit(row, "reply", answer)["event"]
                while self.bridge.send_one():
                    pass
                outbound = self.store.rows("SELECT * FROM outbox WHERE event=?", (event,))
                self.assertEqual(len(outbound), 1)
                self.assertEqual(outbound[0]["state"], "accepted")
                self.assertEqual(outbound[0]["body"], answer)

    def test_status_selects_active_state_before_history_limit(self):
        active, _ = self.claim()
        self.emit(active, "started", "Análise longa original", task=self.task())
        for i in range(11):
            finished, _ = self.claim(self.receive(self.message(f"Pedido breve {i}")))
            self.emit(finished, "completed", f"Concluído breve {i}", evidence=["fixture"])
        answered, _ = self.claim()
        self.emit(answered, "reply", "Resposta conversacional encerrada")
        self.receive(self.message("/status"))
        body = self.store.snapshot()["responses"][-1]["body"]
        self.assertIn("Análise longa original", body)
        self.assertNotIn("Qual deles?", body)
        queued = self.receive(self.message("Outro pedido aguardando"))
        self.bridge.forward()
        self.assertEqual(self.store.request(queued["request"])["state"], "queued")
        row = self.receive(self.message("/status"))
        self.assertEqual(row["state"], "received")
        _, result = self.claim(row)
        self.assertEqual(result["text"], "/status")
        self.assertIn(active["request"], {r["request"] for r in result["tasks"]})
        self.assertIn(queued["request"], {r["request"] for r in result["history"]})

    def test_status_includes_received_queued_and_claimed_requests(self):
        row = self.receive()
        for expected in ("Recebido e preservado", "Enfileirado", "Reivindicado, início não confirmado"):
            self.receive(self.message("/status"))
            body = self.store.snapshot()["responses"][-1]["body"]
            self.assertEqual(body, expected)
            if expected == "Recebido e preservado":
                self.bridge.forward()
            elif expected == "Enfileirado":
                self.claim(row)

    def test_status_after_maximum_result_advances_cursor_and_preserves_result(self):
        row, _ = self.claim()
        result = "x" * 200000
        event = self.emit(row, "completed", result, evidence=["fixture"])["event"]
        query = self.message("/status")
        following = self.message("Novo pedido após consultar")
        self.bridge.ingest(poll([query, following], offset=50))
        self.assertEqual(self.store.get("cursor"), "50")
        status = self.store.rows("SELECT * FROM inbound WHERE wamid=?", (query["id"],))[0]
        self.assertEqual(status["state"], "answered")
        summary = self.store.rows("SELECT body FROM responses WHERE event=?", (status["request"] + ".status",))[0]["body"]
        self.assertLessEqual(len(summary), 180)
        self.assertTrue(summary.startswith("Concluído: "))
        self.assertTrue(summary.endswith("…"))
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE wamid=?", (following["id"],)),
                         [{"state": "received"}])
        reopened = Store(self.config, clock=lambda: self.now)
        try:
            Bridge(reopened, Sequence([poll([query], offset=51)])).poll()
            self.assertEqual(reopened.get("cursor"), "51")
            self.assertEqual(len(reopened.rows("SELECT * FROM responses WHERE event=?", (status["request"] + ".status",))), 1)
            self.assertEqual(reopened.rows("SELECT body FROM responses WHERE event=?", (event,))[0]["body"], result)
            self.assertEqual("".join(r["body"] for r in reopened.rows(
                "SELECT body FROM outbox WHERE event=? ORDER BY part", (event,))), result)
        finally:
            reopened.db.close()

    def test_quoted_status_reaches_main_with_exact_correlation(self):
        first, _ = self.claim()
        self.emit(first, "reply", "Resposta da tarefa A")
        while self.bridge.send_one():
            pass
        mid = self.store.rows("SELECT wamid FROM outbox WHERE request=? ORDER BY seq DESC", (first["request"],))[0]["wamid"]
        second, _ = self.claim()
        self.emit(second, "started", "Tarefa B em andamento", task=self.task())
        for text in ("e aquela tarefa?", "/status", "/tarefas"):
            for quoted, related in ((mid, first["request"]), ("wamid.unknown", None)):
                row = self.receive(self.message(text, context={"id": quoted, "from": "agent:123"}))
                self.assertEqual(row["state"], "received")
                _, result = self.claim(row)
                self.assertEqual(result["related_request"], related)
                self.assertEqual(result["text"], text)
                self.assertFalse(self.store.rows("SELECT * FROM responses WHERE event=?", (row["request"] + ".status",)))

    def test_note_gap_recovery_dedup_and_ack(self):
        message = self.message("texto literal $(touch NEVER) `whoami` ; fim")
        row = self.receive(message)
        self.bridge.forward()
        stored = self.store.request(row["request"])
        # Simulate parent death after note return but before its final DB update.
        self.store.db.execute("UPDATE inbound SET state='received' WHERE request=?", (row["request"],))
        note = self.home / "state/inbox" / (stored["note_id"] + ".note")
        subprocess.run([str(ROOT / "bin/fm-inbox.sh"), "drain", "--ack", stored["note_id"]],
                       env=self.config.environment(), check=True, capture_output=True)
        self.bridge.forward()
        self.bridge.ingest(poll([message], offset=2))
        self.assertFalse(note.exists())
        self.assertEqual(len(list(note.parent.glob("handled/*.note"))), 1)
        self.assertEqual(len(self.store.rows("SELECT * FROM inbound")), 1)
        claimed = self.main({"op": "claim", "request": row["request"], "note_id": stored["note_id"]})
        self.assertTrue(claimed["fresh_claim"])
        again = self.main({"op": "claim", "request": row["request"], "note_id": stored["note_id"]})
        self.assertFalse(again["fresh_claim"])
        self.assertIn("$(touch NEVER)", claimed["text"])
        self.assertFalse((ROOT / "NEVER").exists())

    def test_key_receipt_prepublication_gap_and_conflict(self):
        from fm_inbox_key import prepare
        inbox = self.home / "state/inbox"
        mid = prepare(inbox, "receipt-gap", "same")
        (inbox / (mid + ".note")).unlink()  # fixture crash before publication
        self.assertEqual(prepare(inbox, "receipt-gap", "same"), mid)
        with self.assertRaises(ValueError):
            prepare(inbox, "receipt-gap", "changed")

    def test_cursor_empty_receipts_profiles_and_integer(self):
        cursor = 9223372036854775000
        self.bridge.ingest(poll(offset=cursor, contacts=[{"wa_id": "user:owner", "profile": {"name": "Rodrigo"}}]))
        self.bridge.ingest(Reply(204, None))
        self.assertEqual(int(self.store.get("cursor")), cursor)
        self.bridge.ingest(poll(offset=cursor, contacts=[{"wa_id": "user:owner"}], statuses=[
            {"id": "wamid.receipt", "status": "read", "timestamp": "1", "recipient_id": "user:owner"},
            {"id": "wamid.receipt", "status": "delivered", "timestamp": "2", "recipient_id": "user:owner"}]))
        self.assertEqual(self.store.rows("SELECT name FROM contacts")[0]["name"], "Rodrigo")
        self.assertEqual(len(self.store.rows("SELECT * FROM receipts")), 2)
        self.assertEqual(len(self.store.rows("SELECT * FROM inbound")), 0)
        transport = Sequence([Reply(204)])
        Bridge(self.store, transport).poll()
        self.assertEqual(transport.calls[0][1]["offset"], cursor)
        with self.assertRaises(BridgeError):
            self.bridge.ingest(poll(offset=float(cursor)))
        self.assertEqual(int(self.store.get("cursor")), cursor)

    def test_old_backlog_and_restart_identity(self):
        old = self.message(timestamp=str(int(self.now) - 86400))
        self.receive(old)
        self.assertEqual(self.store.rows("SELECT state FROM inbound")[0]["state"], "historical")
        self.bridge.forward()
        self.assertEqual(self.store.rows("SELECT * FROM outbox"), [])
        reopened = Store(self.config)
        self.assertEqual(reopened.get("cursor"), "1")
        reopened.db.close()
        changed = dict(self.values, creator_id="user:other")
        self.path.write_text(json.dumps(changed))
        with self.assertRaises(BridgeError):
            Store(Config(self.path))

    def test_diagnostics_do_not_activate_and_first_poll_preserves_boundary(self):
        self.values.update(state_dir=str(self.dir / "delayed-state"), enabled=False)
        self.path.write_text(json.dumps(self.values))
        self.cli("doctor")
        self.cli("status")
        self.cli("run", "--once", "--fixture", str(self.fixture), ok=False)
        self.values["enabled"] = True
        self.path.write_text(json.dumps(self.values))
        self.cli("doctor")
        self.cli("status")
        config = Config(self.path)
        activated = self.now + 4 * 86400
        store = Store(config, clock=lambda: activated)
        self.addCleanup(store.db.close)
        self.assertIsNone(store.get("activated"))
        old = self.message(timestamp=str(int(self.now) + 86400))
        recent = self.message(timestamp=str(int(activated) + 2))
        transport = Sequence([poll([old, recent], offset=7)])
        bridge = Bridge(store, transport)
        original = transport.call
        with patch.object(transport, "call", wraps=transport.call) as call:
            def activated_call(endpoint, payload):
                self.assertEqual(float(store.get("activated")), activated)
                return original(endpoint, payload)

            call.side_effect = activated_call
            bridge.poll()
        self.assertEqual(transport.calls[0][1]["offset"], 0)
        self.assertEqual([r["state"] for r in store.rows("SELECT state FROM inbound ORDER BY rowid")],
                         ["historical", "received"])
        bridge.forward()
        self.assertEqual(len(list((self.home / "state/inbox").glob("*.note"))), 1)
        reopened = Store(config, clock=lambda: activated + 86400)
        self.addCleanup(reopened.db.close)
        next_transport = Sequence([Reply(204)])
        Bridge(reopened, next_transport).poll()
        self.assertEqual(float(reopened.get("activated")), activated)
        self.assertEqual(next_transport.calls[0][1]["offset"], 7)
        self.assertEqual(len(reopened.rows("SELECT * FROM inbound")), 2)

    def test_replay_configuration_is_rejected_without_executing_history(self):
        self.receive(self.message(timestamp=str(int(self.now) - 86400)))
        self.values["startup_policy"] = "replay"
        self.path.write_text(json.dumps(self.values))
        self.assertIn("unsupported", self.cli("run", "--once", "--fixture", str(self.fixture), ok=False)["error"])
        self.assertEqual(self.store.get("cursor"), "1")
        self.assertEqual(self.store.rows("SELECT state FROM inbound"), [{"state": "historical"}])
        self.assertEqual(self.store.rows("SELECT * FROM outbox"), [])
        self.assertFalse(list((self.home / "state/inbox").glob("*.note")))

    def test_singleton_and_persistent_conflict_halt(self):
        with singleton(self.config):
            with self.assertRaises(BridgeError):
                with singleton(self.config):
                    self.fail("duplicate lock admitted")
        transport = Sequence([Reply(409, {"error": {"code": 1752041}})])
        bridge = Bridge(self.store, transport)
        bridge.poll()
        bridge.poll()
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual(self.store.get("halt"), "poll_conflict")
        self.assertEqual(self.store.get("cursor"), "0")

    def test_unicode_split_order_rolling_window_restart(self):
        row, _ = self.claim()
        body = "a😀é\u0301" * 7000
        self.emit(row, body=body)
        chunks = self.store.rows("SELECT body FROM outbox WHERE event NOT LIKE '%.received' ORDER BY seq")
        self.assertEqual("".join(c["body"] for c in chunks), body)
        self.assertTrue(all(len(c["body"]) <= 4096 for c in chunks))
        for _ in range(12):
            self.assertEqual(self.store.reserve("messages"), 0)
        self.assertGreater(self.store.reserve("messages"), 0)
        for _ in range(15):
            self.assertEqual(self.store.reserve("updates"), 0)
        self.assertGreater(self.store.reserve("updates"), 0)
        self.assertEqual(self.store.reserve("statuses"), 0)
        self.now += 60.01
        self.assertEqual(self.store.reserve("messages"), 0)
        while self.bridge.send_one():
            pass
        sent = self.store.rows("SELECT payload FROM sim_sends ORDER BY seq")
        self.assertEqual("".join(json.loads(r["payload"])["text"]["body"] for r in sent[1:]), body)
        reopened = Store(self.config, clock=lambda: self.now)
        self.assertEqual(len(reopened.rows("SELECT * FROM rates WHERE endpoint='messages'")), len(sent) + 1)
        reopened.db.close()

    def test_send_policies_and_unknown_blocks_following(self):
        for reply, expected in [(Reply(200), "accepted"), (Reply(201), "accepted"),
                                (Reply(429), "retry"), (Reply(503, {"error": {"code": 131016}}), "retry"),
                                (Reply(500), "delivery_unknown"), (Reply(fault="reset"), "delivery_unknown"),
                                (Reply(fault="timeout"), "delivery_unknown"), (Reply(400, {"error": {"code": 131009}}), "permanent"),
                                (Reply(401), "auth_failed")]:
            self.assertEqual(classify("messages", reply), expected)
        self.assertEqual(classify("statuses", Reply(500)), "retry")
        self.assertEqual(classify("updates", Reply(400, {"error": {"code": 100}})), "auth_failed")
        self.assertEqual(classify("messages", Reply(400, {"error": {"code": 100}})), "permanent")
        row, _ = self.claim()
        self.emit(row, body="x" * 6000)
        unknown = Sequence([Reply(500)])
        bridge = Bridge(self.store, unknown)
        bridge.send_one()
        bridge.send_one()
        bridge.recover()
        bridge.send_one()
        self.assertEqual(len(unknown.calls), 1)
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "delivery_unknown")
        self.assertGreaterEqual(delay(1, {"Retry-After": "75"}, self.now, lambda: 0), 75)

    def test_429_and_503_retry_then_accept_receipts_do_not_regress(self):
        row, _ = self.claim()
        seq = Sequence([Reply(429, headers={"Retry-After": "65"}),
                        Reply(503, {"error": {"code": 131016}}),
                        Reply(200, {"messaging_product": "whatsapp", "contacts": [
                            {"input": "user:owner", "wa_id": "user:owner"}], "messages": [{"id": "wamid.sent"}]})])
        bridge = Bridge(self.store, seq)
        self.assertFalse(bridge.send_one())
        self.now += 64
        self.assertFalse(bridge.send_one())
        self.now += 2
        self.assertFalse(bridge.send_one())
        self.now += 30
        self.assertTrue(bridge.send_one())
        self.assertEqual(len(seq.calls), 3)
        for status in ("read", "delivered", "read"):
            self.bridge.ingest(poll(offset=2, statuses=[{"id": "wamid.sent", "status": status,
                                                       "timestamp": "1", "recipient_id": "user:owner"}]))
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "read")

    def test_crash_after_send_preparation_becomes_unknown(self):
        self.receive()
        self.store.db.execute("UPDATE outbox SET state='sending'")
        self.bridge.recover()
        self.assertFalse(self.bridge.send_one())
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "delivery_unknown")

    def test_terminal_redelivery_requires_resolution_and_deduplicates_authorization(self):
        row, _ = self.claim()
        self.assertTrue(self.bridge.send_one())
        body = "Resultado persistido. " * 300
        result = self.emit(row, "completed", body, evidence=["fixture"], event="terminal-result")
        event = result["event"]
        uncertain = Bridge(self.store, Sequence([Reply(500)]))
        self.assertFalse(uncertain.send_one())
        self.cli("redeliver", "--event", event, "--key", "authorized-1", ok=False)
        blocked = self.store.rows("SELECT seq FROM outbox WHERE event=? ORDER BY seq", (event,))[0]["seq"]
        self.cli("resolve-send", "--seq", str(blocked), "--disposition", "abandoned")
        self.cli("redeliver", "--event", event, "--key", "authorized-1", ok=False)
        while self.bridge.send_one():
            pass
        self.assertFalse(self.emit(row, "completed", body, evidence=["fixture"], event=event)["new_event"])
        responses = self.store.snapshot()["responses"]
        notes = list((self.home / "state/inbox").glob("*.note"))
        delivery = self.cli("redeliver", "--event", event, "--key", "authorized-1")
        self.assertTrue(delivery["new_delivery"])
        repeat = self.cli("redeliver", "--event", event, "--key", "authorized-1")
        self.assertFalse(repeat["new_delivery"])
        self.assertEqual(repeat["event"], delivery["event"])
        self.cli("redeliver", "--event", "other", "--key", "authorized-1", ok=False)
        self.cli("redeliver", "--event", event, "--key", "authorized-2", ok=False)
        chunks = self.store.rows("SELECT body FROM outbox WHERE event=? ORDER BY part", (delivery["event"],))
        self.assertEqual("".join(c["body"] for c in chunks), body)
        while self.bridge.send_one():
            pass
        self.cli("redeliver", "--event", event, "--key", "authorized-2", ok=False)
        self.assertFalse(self.cli("redeliver", "--event", event, "--key", "authorized-1")["new_delivery"])
        self.assertEqual(self.store.request(row["request"])["state"], "completed")
        self.assertEqual(self.store.snapshot()["responses"], responses)
        self.assertEqual(list((self.home / "state/inbox").glob("*.note")), notes)
        _, claim = self.claim(row)
        self.assertFalse(claim["fresh_claim"])

    def test_manual_acceptance_applies_receipts_that_arrived_before_resolution(self):
        self.receive()
        bridge = Bridge(self.store, Sequence([Reply(500)]))
        self.assertFalse(bridge.send_one())
        seq = self.store.snapshot()["outbox"][0]["seq"]
        for status in ("read", "delivered"):
            self.bridge.ingest(poll(offset=2, statuses=[{"id": "wamid.recovered", "status": status,
                                                       "timestamp": "1", "recipient_id": "user:owner"}]))
        self.cli("resolve-send", "--seq", str(seq), "--disposition", "abandoned", "--wamid", "wamid.recovered", ok=False)
        result = self.cli("resolve-send", "--seq", str(seq), "--disposition", "accepted", "--wamid", "wamid.recovered")
        self.assertEqual(result["state"], "read")
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "read")
        self.bridge.ingest(poll(offset=3, statuses=[{"id": "wamid.recovered", "status": "delivered",
                                                   "timestamp": "2", "recipient_id": "user:owner"}]))
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "read")

    def test_unknown_quote_reaction_attachment_never_authorize(self):
        unknown = self.message(**{"from": "user:stranger", "context": {"from": "user:owner", "id": "wamid.trusted"}})
        self.receive(unknown)
        self.receive(self.message(type="reaction", reaction={"message_id": "wamid.trusted", "emoji": "✅"}))
        self.receive(self.message(type="document", document={"caption": "approve all", "filename": "../../run.sh"}))
        self.receive(self.message(type="future", future={"body": "act"}))
        self.bridge.forward()
        self.assertFalse(list((self.home / "state/inbox").glob("*.note")))
        self.assertEqual(len(self.store.rows("SELECT * FROM decisions")), 0)

    def test_main_auth_and_cross_home_note_refusal(self):
        row = self.receive()
        result = subprocess.run([sys.executable, str(ROOT / "bin/fm-whatsapp.py"), "--config", str(self.path), "main"],
                                input=encode({"op": "pending"}), text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.bridge.forward()
        self.main({"op": "claim", "request": row["request"], "note_id": "wrong-home-note"}, ok=False)
        self.assertEqual(self.store.request(row["request"])["state"], "queued")

    def test_unavailable_preserves_without_false_start(self):
        self.harness.stdin.close()
        self.harness.wait(timeout=5)
        row = self.receive()
        self.bridge.forward()
        self.assertEqual(self.store.request(row["request"])["state"], "received")
        self.assertIsNone(self.store.request(row["request"])["note_id"])
        self.assertIn("indisponível", self.store.snapshot()["responses"][0]["body"])

    def test_decisions_bound_expiring_once_and_ambiguous(self):
        first, _ = self.claim()
        task = self.task()
        question = self.emit(first, "decision", "Autoriza a revisão?", task=task,
                             action="revisar o arquivo fixture", expires=time.time() + 300)
        second, _ = self.claim(self.receive(self.message("Outra tarefa")))
        self.emit(second, "decision", "Autoriza a outra revisão?", task=self.task("other"),
                  action="revisar outro arquivo", expires=time.time() + 300)
        for text in ("sim", "ok", "aprovo", "pode", "👍", "✅"):
            with self.subTest(text=text):
                ambiguous = self.receive(self.message(text))
                self.assertEqual(ambiguous["state"], "answered")
                self.assertIsNone(ambiguous["note_id"])
                self.assertIn("Nenhuma ação", self.store.snapshot()["responses"][-1]["body"])
        self.assertEqual(len(self.store.rows("SELECT * FROM decisions WHERE state='answered'")), 0)
        self.receive(self.message("aprovar " + question["decision"], **{"from": "user:stranger"}))
        self.assertEqual(len(self.store.rows("SELECT * FROM decisions WHERE state='answered'")), 0)
        answer = self.receive(self.message("aprovar " + question["decision"]))
        args = {"op": "consume-decision", "id": question["decision"], "request": first["request"],
                "home": str(self.home), "task": "analysis", "revision": "v1", "action": "revisar o arquivo fixture"}
        self.main({**args, "revision": "v2"}, ok=False)
        self.assertTrue(self.main(args)["new_consumption"])
        self.assertFalse(self.main(args)["new_consumption"])
        self.assertEqual(len(self.store.rows("SELECT * FROM decisions WHERE state='pending'")), 1)
        self.assertEqual(self.store.request(answer["request"])["state"], "received")

    def test_terminal_evidence_and_event_idempotency(self):
        row, _ = self.claim()
        data = {"op": "emit", "event": "once", "request": row["request"], "kind": "completed", "body": "Counted 3"}
        self.main(data, ok=False)
        data["evidence"] = ["fixture analysis"]
        self.assertTrue(self.main(data)["new_event"])
        self.assertFalse(self.main(data)["new_event"])
        self.main({**data, "body": "different"}, ok=False)

    def test_expired_and_changed_decisions_fail_closed(self):
        row, _ = self.claim()
        task = self.task()
        question = self.emit(row, "decision", "Revisar?", task=task,
                             action="revisar fixture", expires=time.time() + 300)
        self.receive(self.message("aprovar " + question["decision"]))
        args = {"op": "consume-decision", "id": question["decision"], "request": row["request"],
                "home": str(self.home), "task": "analysis", "revision": "v1", "action": "revisar fixture"}
        (self.home / "state/analysis.meta").write_text("kind=scout\nrevision=changed\n")
        self.assertIn("changed", self.main(args, ok=False)["error"])
        self.store.db.execute("UPDATE decisions SET expires=0")
        self.assertIn("expired", self.main(args, ok=False)["error"])
        self.receive(self.message("aprovar " + question["decision"]))
        self.assertIn("Nenhuma ação", self.store.snapshot()["responses"][-1]["body"])

    def test_expired_pending_decision_preserves_conversational_confirmations(self):
        row, _ = self.claim()
        expires = self.now + 300
        question = self.emit(row, "decision", "Autoriza a revisão?", task=self.task(),
                             action="revisar fixture", expires=expires)
        self.now = expires
        boundary = self.receive(self.message("sim"))
        self.assertEqual(boundary["state"], "answered")
        self.now = expires + 1
        conversation, _ = self.claim(self.receive(self.message("Explique o resultado")))
        self.emit(conversation, "reply", "Quer um resumo?")
        for text in ("sim", "ok", "aprovo", "pode", "👍", "✅"):
            with self.subTest(text=text):
                answer = self.receive(self.message(text))
                self.assertEqual(answer["state"], "received")
                self.assertEqual(self.store.rows("SELECT kind FROM responses WHERE request=?",
                                                 (answer["request"],)), [{"kind": "received"}])
                _, claimed = self.claim(answer)
                self.assertTrue(claimed["fresh_claim"])
                self.assertEqual(claimed["text"], text)
        explicit = self.receive(self.message("aprovar " + question["decision"]))
        self.assertEqual(explicit["state"], "answered")
        self.bridge.forward()
        self.assertIsNone(self.store.request(explicit["request"])["note_id"])
        self.assertIn("Nenhuma ação", self.store.snapshot()["responses"][-1]["body"])
        self.assertEqual(self.store.rows("SELECT state,answer_wamid FROM decisions WHERE id=?",
                                         (question["decision"],)), [{"state": "pending", "answer_wamid": None}])

    def test_atomic_ingest_rollback_and_retry_cursor(self):
        incoming = self.message()
        original = self.bridge.receive

        def crash(message):
            original(message)
            raise RuntimeError("fixture crash before commit")

        with patch.object(self.bridge, "receive", side_effect=crash):
            with self.assertRaises(RuntimeError):
                self.bridge.ingest(poll([incoming], offset=10))
        self.assertEqual(self.store.get("cursor"), "0")
        self.assertEqual(self.store.rows("SELECT * FROM inbound"), [])
        self.bridge.ingest(poll([incoming], offset=10))
        self.assertEqual(len(self.store.rows("SELECT * FROM inbound")), 1)

    def test_http_request_shape_redaction_redirect_and_private_token_fixture(self):
        # Synthetic fixture sentinel only; never real account credentials.
        secret = self.dir / "synthetic-secret"
        secret.write_text("SYNTHETIC_TEST_CREDENTIAL")
        secret.chmod(0o600)
        self.values.update(mode="live", token_file=str(secret))
        self.path.write_text(json.dumps(self.values))
        config = Config(self.path)
        http = HTTP(config)

        class Response:
            code, headers = 204, {}

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, size):
                raise AssertionError("204 must not parse a body")

        with patch.object(http.opener, "open", return_value=Response()) as opened:
            self.assertEqual(http.call("updates", {"offset": 9223372036854775000}).http, 204)
            request = opened.call_args.args[0]
            self.assertIn("offset=9223372036854775000", request.full_url)
            self.assertEqual(request.get_header("Authorization"), "Bearer SYNTHETIC_TEST_CREDENTIAL")
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://untrusted.invalid"))
        secret.chmod(0o644)
        with self.assertRaises(BridgeError):
            read_secret(secret)
        secret.chmod(0o600)
        link = self.dir / "secret-link"
        link.symlink_to(secret)
        with self.assertRaises(OSError):
            read_secret(link)
        self.values.update(mode="simulated", token_file=str(self.dir / "must-not-read-token"))
        self.path.write_text(json.dumps(self.values))
        row, _ = self.claim()
        self.main({"op": "emit", "event": "secret", "request": row["request"], "kind": "reply",
                   "body": "Authorization: Bearer SYNTHETIC_TEST_CREDENTIAL"}, ok=False)
        self.assertNotIn("SYNTHETIC_TEST_CREDENTIAL", encode(self.store.snapshot()))

    def test_transport_service_stops_and_restarts_without_touching_main(self):
        cmd = [sys.executable, str(ROOT / "bin/fm-whatsapp.py"), "--config", str(self.path),
               "run", "--fixture", str(self.fixture)]
        for _ in range(2):
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(0.2)
            self.assertIsNone(proc.poll())
            proc.terminate()
            stdout, stderr = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertTrue(json.loads(stdout)["stopped"])
            self.assertIsNone(self.harness.poll())
        self.assertEqual(self.store.get("cursor"), "0")

    def test_slow_large_outbox_allows_status_and_receipts_between_chunks(self):
        row, _ = self.claim()
        self.assertTrue(self.bridge.send_one())
        event = self.emit(row, "completed", "x" * 200000, evidence=["fixture"])["event"]
        query = self.message("/status")
        calls = []
        original = self.bridge.transport.call

        def slow_transport(endpoint, payload):
            calls.append(endpoint)
            if endpoint == "messages":
                self.now += 6
                return original(endpoint, payload)
            if calls.count("updates") == 2:
                sent = self.store.rows("SELECT wamid FROM outbox WHERE event=? AND part=0", (event,))[0]["wamid"]
                return poll([query], statuses=[{"id": sent, "status": "read", "timestamp": str(int(self.now)),
                                               "recipient_id": "user:owner"}], offset=50)
            return Reply(204)

        with patch.object(self.bridge.transport, "call", side_effect=slow_transport):
            self.bridge.tick()
            self.assertEqual(calls, ["updates", "messages"])
            self.assertEqual(len(self.store.rows("SELECT * FROM outbox WHERE event=? AND state='pending'", (event,))), 48)
            self.bridge.tick()
        self.assertEqual(calls, ["updates", "messages", "updates", "messages"])
        self.assertEqual(self.store.get("cursor"), "50")
        status = self.store.rows("SELECT request,state FROM inbound WHERE wamid=?", (query["id"],))[0]
        self.assertEqual(status["state"], "answered")
        self.assertTrue(self.store.rows("SELECT body FROM responses WHERE event=?", (status["request"] + ".status",)))
        parts = self.store.rows("SELECT state FROM outbox WHERE event=? ORDER BY part", (event,))
        self.assertEqual([p["state"] for p in parts[:2]], ["read", "accepted"])
        self.assertTrue(all(p["state"] == "pending" for p in parts[2:]))

    def test_ready_multipart_output_avoids_long_poll_and_keeps_idle_timeout(self):
        row, _ = self.claim()
        self.assertTrue(self.bridge.send_one())
        event = self.emit(row, "completed", "x" * 200000, evidence=["fixture"])["event"]
        self.config.timeout = 25
        query = self.message("/status")
        calls = []
        original = self.bridge.transport.call
        started = self.now

        def timed_transport(endpoint, payload):
            calls.append((endpoint, self.now, dict(payload)))
            if endpoint == "messages":
                self.now += 0.01
                return original(endpoint, payload)
            if sum(c[0] == "updates" for c in calls) == 2:
                mid = self.store.rows("SELECT wamid FROM outbox WHERE event=? AND part=0", (event,))[0]["wamid"]
                return poll([query], statuses=[{"id": mid, "status": "read", "timestamp": str(int(self.now)),
                                               "recipient_id": "user:owner"}], offset=50)
            self.now += payload["timeout"]
            return Reply(204)

        with patch.object(self.bridge.transport, "call", side_effect=timed_transport):
            for cycle in range(100):
                before = sum(c[0] == "messages" for c in calls)
                self.bridge.tick()
                self.assertLessEqual(sum(c[0] == "messages" for c in calls) - before, 1)
                if cycle == 1:
                    self.assertEqual(self.store.get("cursor"), "50")
                    self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE wamid=?", (query["id"],)),
                                     [{"state": "answered"}])
                    parts = self.store.rows("SELECT state FROM outbox WHERE event=? ORDER BY part", (event,))
                    self.assertEqual(parts[0]["state"], "read")
                    self.assertTrue(any(p["state"] == "pending" for p in parts))
                self.now += 1
                if all(p["state"] in ("accepted", "delivered", "read") for p in self.store.snapshot()["outbox"]):
                    break
            else:
                self.fail("multipart output did not finish within bounded cycles")
            self.assertLess(self.now - started, 360)
            sends = [c for c in calls if c[0] == "messages"]
            polls = [c for c in calls if c[0] == "updates"]
            self.assertLess(sends[10][1] - started, 12)
            self.assertTrue(all(c[2]["timeout"] == 0 for c in polls[:11]))
            for endpoint, limit in (("updates", 15), ("messages", 12)):
                times = [c[1] for c in calls if c[0] == endpoint]
                for at in times:
                    self.assertLessEqual(sum(at - 60 < stamp <= at for stamp in times), limit)
            self.now += 61
            self.bridge.tick()
            self.assertEqual(calls[-1][0], "updates")
            self.assertEqual(calls[-1][2]["timeout"], 25)
            self.assertEqual(sum(c[0] == "messages" for c in calls), len(sends))
        self.assertEqual("".join(json.loads(r["payload"])["text"]["body"] for r in self.store.rows(
            "SELECT payload FROM sim_sends ORDER BY seq")[1:-1]), "x" * 200000)

    def test_poll_uses_idle_timeout_unless_ordered_head_is_sendable(self):
        for case in ("empty", "denied", "blocked", "future", "quota", "halted", "stopped"):
            with self.subTest(case=case):
                path = self.dir / f"readiness-{case}.json"
                values = dict(self.values, state_dir=str(self.dir / f"readiness-state-{case}"),
                              poll_timeout=25, outbound_authorized=case != "denied")
                path.write_text(json.dumps(values))
                store = Store(Config(path), clock=lambda: self.now)
                try:
                    if case != "empty":
                        with store.tx():
                            store.emit("fixture-response", "fixture-request", "notice", "x" * 8000, "bridge")
                            if case == "blocked":
                                store.db.execute("UPDATE outbox SET state='delivery_unknown' WHERE part=0")
                            if case == "future":
                                store.db.execute("UPDATE outbox SET due=? WHERE part=0", (self.now + 1000,))
                    if case == "quota":
                        for _ in range(12):
                            self.assertEqual(store.reserve("messages"), 0)
                    if case == "halted":
                        store.put("halt", "poll_conflict")
                    transport = Sequence([Reply(204), Reply(204)])
                    bridge = Bridge(store, transport)
                    bridge.stopping = case == "stopped"
                    before = store.rows("SELECT * FROM rates WHERE endpoint='messages'")
                    bridge.poll()
                    self.assertEqual(store.rows("SELECT * FROM rates WHERE endpoint='messages'"), before)
                    if case in ("halted", "stopped"):
                        self.assertEqual(transport.calls, [])
                    else:
                        self.assertEqual(transport.calls[0][1]["timeout"], 25)
                    if case == "quota":
                        self.now -= 10
                        bridge.poll()
                        self.assertEqual(transport.calls[-1][1]["timeout"], 25)
                finally:
                    store.db.close()

    def test_stop_during_forward_finishes_current_note_only(self):
        first, second = self.receive(), self.receive()
        original = subprocess.run

        def stop_after_note(args, **kwargs):
            result = original(args, **kwargs)
            if args[0] == str(ROOT / "bin/fm-inbox.sh"):
                self.bridge.stopping = True
            return result

        with patch("subprocess.run", side_effect=stop_after_note):
            self.bridge.tick()
        self.assertEqual(self.store.request(first["request"])["state"], "queued")
        self.assertEqual(self.store.request(second["request"])["state"], "received")
        self.assertEqual(len(list((self.home / "state/inbox").glob("*.note"))), 1)
        self.assertEqual(self.store.rows("SELECT * FROM attempts"), [])
        with patch("subprocess.run", side_effect=AssertionError("stopped bridge started a subprocess")), \
                patch.object(self.bridge.transport, "call", side_effect=AssertionError("stopped bridge called transport")):
            self.bridge.tick()
            self.bridge.forward()
            self.bridge.poll()
            self.assertFalse(self.bridge.send_one())

    def test_service_stop_handler_prevents_operations_after_poll_or_send(self):
        row, _ = self.claim()
        self.emit(row, "completed", "x" * 200000, evidence=["fixture"])
        entrypoint = runpy.run_path(str(ROOT / "bin/fm-whatsapp.py"))["main"]
        original = Simulator.call
        for stop_at in ("updates", "messages"):
            with self.subTest(stop_at=stop_at):
                calls, handlers = [], {}

                def stop_during_transport(transport, endpoint, payload):
                    calls.append(endpoint)
                    reply = original(transport, endpoint, payload)
                    if endpoint == stop_at:
                        handlers[signal.SIGTERM](signal.SIGTERM, None)
                    return reply

                with patch.object(sys, "argv", ["fm-whatsapp.py", "--config", str(self.path),
                                                "run", "--fixture", str(self.fixture)]), \
                        patch("signal.signal", side_effect=lambda number, handler: handlers.update({number: handler})), \
                        patch.object(Simulator, "call", new=stop_during_transport):
                    result = entrypoint()
                self.assertEqual(result, {"stopped": True, "agents": "untouched"})
                self.assertEqual(calls, ["updates"] if stop_at == "updates" else ["updates", "messages"])
                self.assertIsNone(self.harness.poll())
        self.assertEqual(len(self.store.rows("SELECT * FROM attempts")), 1)
        self.assertEqual(self.store.snapshot()["outbox"][0]["state"], "accepted")
        self.assertTrue(all(p["state"] == "pending" for p in self.store.snapshot()["outbox"][1:]))

    def test_http_non_json_responses_preserve_status_policy_and_retry_after(self):
        config = Config(self.path)
        config.mode = "live"
        http = HTTP(config)
        cases = [(429, b"rate limited", "pending"), (400, b"bad request", "permanent"),
                 (403, b"forbidden", "permanent"), (401, b"unauthorized", "auth_failed"),
                 (500, b"server error", "delivery_unknown"), (503, b"unavailable", "delivery_unknown"),
                 (200, b"malformed success", "delivery_unknown"),
                 (200, b'{}', "delivery_unknown"),
                 (503, b'{"error":{"code":131016}}', "pending")]
        for index, (status, raw, expected) in enumerate(cases):
            with self.subTest(status=status, raw=raw):
                values = dict(self.values, state_dir=str(self.dir / f"http-state-{index}"))
                path = self.dir / f"http-{index}.json"
                path.write_text(json.dumps(values))
                store = Store(Config(path), clock=lambda: self.now)
                try:
                    with store.tx():
                        store.emit("fixture-response", "fixture-request", "notice", "Mensagem de fixture", "bridge")
                    error = urllib.error.HTTPError("https://api.whatsapp.com/agent/v1/messages", status,
                                                   "fixture", {"Retry-After": "75"}, io.BytesIO(raw))
                    with patch("fm_whatsapp_transport.read_secret", return_value="SYNTHETIC_TEST_CREDENTIAL"), \
                            patch.object(http.opener, "open", side_effect=error if status >= 400 else None,
                                         return_value=error) as opened:
                        bridge = Bridge(store, http)
                        self.assertFalse(bridge.send_one())
                        row = store.rows("SELECT * FROM outbox")[0]
                        self.assertEqual(row["state"], expected)
                        bridge.recover()
                        self.assertFalse(bridge.send_one())
                        self.assertEqual(opened.call_count, 1)
                    if expected == "pending":
                        self.assertGreaterEqual(row["due"], self.now + 75)
                    self.assertEqual(store.rows("SELECT http FROM attempts"), [{"http": status}])
                finally:
                    store.db.close()
        for status, expected in ((429, None), (403, "permanent"), (401, "auth_failed")):
            with self.subTest(endpoint="updates", status=status):
                self.store.put("halt", "")
                self.store.put("poll_due", 0)
                error = urllib.error.HTTPError("https://api.whatsapp.com/agent/v1/updates", status,
                                               "fixture", {"Retry-After": "75"}, io.BytesIO(b"not json"))
                with patch("fm_whatsapp_transport.read_secret", return_value="SYNTHETIC_TEST_CREDENTIAL"), \
                        patch.object(http.opener, "open", side_effect=error):
                    Bridge(self.store, http).poll()
                self.assertEqual(self.store.get("halt") or None, expected)
                self.assertEqual(self.store.get("cursor"), "0")
                if status == 429:
                    self.assertGreaterEqual(float(self.store.get("poll_due")), self.now + 75)

    def test_http_interrupted_reads_keep_decisive_status_backoff_and_redaction(self):
        config = Config(self.path)
        config.mode = "live"
        http = HTTP(config)
        sentinel = "PRIVATE_HTTP_FAILURE_SENTINEL"
        failures = [TimeoutError(sentinel), ConnectionResetError(sentinel),
                    IncompleteRead(sentinel.encode(), 1000)]
        for index, failure in enumerate(failures):
            for status, expected in ((0, "delivery_unknown"), (200, "delivery_unknown"),
                                     (400, "permanent"), (401, "auth_failed"), (429, "pending"),
                                     (500, "delivery_unknown"), (503, "delivery_unknown")):
                with self.subTest(failure=type(failure).__name__, status=status):
                    path = self.dir / f"read-failure-{index}-{status}.json"
                    path.write_text(json.dumps(dict(self.values, state_dir=str(self.dir / f"read-state-{index}-{status}"))))
                    store = Store(Config(path), clock=lambda: self.now)
                    try:
                        with store.tx():
                            store.emit("fixture-response", "fixture-request", "notice", "Mensagem de fixture", "bridge")
                        response = urllib.error.HTTPError("https://api.whatsapp.com/agent/v1/messages", status,
                                                          sentinel, {"Retry-After": "75"}, io.BytesIO())
                        replies = []
                        original = http.call

                        def capture(endpoint, payload):
                            reply = original(endpoint, payload)
                            replies.append(reply)
                            return reply

                        with patch("fm_whatsapp_transport.read_secret", return_value="SYNTHETIC_TEST_CREDENTIAL"), \
                                patch.object(response, "read", side_effect=failure), \
                                patch.object(http.opener, "open", side_effect=failure if status == 0 else
                                             response if status >= 400 else None, return_value=response) as opened, \
                                patch.object(http, "call", side_effect=capture):
                            bridge = Bridge(store, http)
                            self.assertFalse(bridge.send_one())
                            self.assertEqual(store.snapshot()["outbox"][0]["state"], expected)
                            self.assertEqual(replies[0].http, status)
                            self.assertEqual(replies[0].headers, {"Retry-After": "75"} if status else {})
                            self.assertIsNone(replies[0].body)
                            self.assertNotIn(sentinel, encode(replies[0].__dict__) + encode(store.snapshot()) +
                                             encode(store.rows("SELECT * FROM attempts")))
                            bridge.recover()
                            self.assertFalse(bridge.send_one())
                            self.assertEqual(opened.call_count, 1)
                            if status == 429:
                                due = store.rows("SELECT due FROM outbox")[0]["due"]
                                self.assertGreaterEqual(due, self.now + 75)
                                self.now += 74
                                self.assertFalse(bridge.send_one())
                                self.assertEqual(opened.call_count, 1)
                                self.now += 2
                                opened.side_effect = urllib.error.HTTPError(
                                    "https://api.whatsapp.com/agent/v1/messages", 429, "fixture",
                                    {"Retry-After": "75"}, io.BytesIO(b"rate limited"))
                                self.assertFalse(bridge.send_one())
                                self.assertEqual(opened.call_count, 2)
                    finally:
                        store.db.close()

    def test_scripted_poll_cli_disabled_service_and_backup(self):
        script = [{"endpoint": "updates", "http": 200, "body": poll([self.message()]).body}]
        fixture = self.dir / "cli-script.json"
        fixture.write_text(json.dumps(script))
        # Use fresh state for this script, leaving the public interface to own setup.
        self.values["state_dir"] = str(self.dir / "cli-state")
        self.path.write_text(json.dumps(self.values))
        cmd = [sys.executable, str(ROOT / "bin/fm-whatsapp.py"), "--config", str(self.path)]
        result = subprocess.run(cmd + ["run", "--once", "--fixture", str(fixture)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["cursor"], 1)
        result = subprocess.run(cmd + ["run", "--once", "--fixture", str(fixture)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["requests"]), 1)
        target = self.dir / "backup.sqlite3"
        result = subprocess.run(cmd + ["backup", "--output", str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(target.exists())
        if sys.platform == "darwin":
            self.values["simulator_file"] = str(fixture)
            self.path.write_text(json.dumps(self.values))
            plist = self.dir / "bridge.plist"
            result = subprocess.run(cmd + ["service-render", "--output", str(plist)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = plistlib.loads(plist.read_bytes())
            self.assertTrue(rendered["Disabled"])
            self.assertEqual(rendered["ProgramArguments"][0], str(Path(sys.executable).resolve()))
            self.assertFalse(any("herdr" in p for p in rendered["ProgramArguments"]))
            subprocess.run(["/usr/bin/plutil", "-lint", str(plist)], check=True, capture_output=True)

    def png_bytes(self):
        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")

    def ogg_bytes(self):
        if not shutil.which("ffmpeg"):
            self.skipTest("optional local media validation requires ffmpeg")
        result = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=1", "-ac", "1", "-c:a", "libopus", "-f", "ogg", "pipe:1"],
            capture_output=True, check=True)
        return result.stdout

    def pdf_bytes(self, text="Hello PDF", compressed=False):
        stream = f"BT /F1 12 Tf 10 100 Td ({text}) Tj ET".encode()
        filter_entry = b""
        if compressed:
            stream = zlib.compress(stream)
            filter_entry = b" /Filter /FlateDecode"
        objects = [
            b"1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n",
            b"2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n",
            b"3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>endobj\n",
            b"4 0 obj<< /Length %d" % len(stream) + filter_entry + b" >>stream\n" + stream + b"\nendstream\nendobj\n",
            b"5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj\n",
        ]
        header = b"%PDF-1.1\n"
        offsets = []
        body = b""
        for item in objects:
            offsets.append(len(header) + len(body))
            body += item
        xref_at = len(header) + len(body)
        xref = b"xref\n0 6\n0000000000 65535 f \n" + b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
        start = header + body + xref + b"trailer<< /Size 6 /Root 1 0 R >>\nstartxref\n" + str(xref_at).encode() + b"\n%%EOF\n"
        return start

    def enable_media(self, transcriber=None, stt_command=None):
        self.values["media"] = True
        if stt_command is not None:
            self.values["media_stt_command"] = str(stt_command)
        self.path.write_text(json.dumps(self.values))
        self.config = Config(self.path)
        self.store.db.close()
        self.store = Store(self.config, clock=lambda: self.now)
        self.bridge = Bridge(self.store, Sequence([]), transcriber=transcriber)

    def attachment_message(self, kind, payload, **extra):
        self.counter += 1
        sender = extra.pop("sender", "user:owner")
        return {"id": extra.pop("id", f"wamid.input.{self.counter}"), "from": sender,
                "timestamp": str(int(self.now) + 2), "type": kind, kind: payload, **extra}

    def media_replies(self, media_id, data, mime, url="https://lookaside.fbsbx.com/agent/v1/media/x/content"):
        meta = {"url": url, "mime_type": mime, "sha256": hashlib.sha256(data).hexdigest(),
                "file_size": len(data), "id": media_id, "messaging_product": "whatsapp"}
        return [Reply(200, meta), Reply(200, data)]

    def process_attachment(self, kind, payload, data, mime, transcriber=None, url=None):
        self.enable_media(transcriber=transcriber)
        media_id = payload["id"]
        replies = self.media_replies(media_id, data, mime, url or "https://lookaside.fbsbx.com/agent/v1/media/x/content")
        self.bridge.transport = Sequence(replies)
        row = self.receive(self.attachment_message(kind, payload))
        self.bridge.process_media()
        return self.store.rows("SELECT * FROM inbound WHERE request=?", (row["request"],))[0]

    def test_media_false_keeps_attachments_unsupported(self):
        png = self.png_bytes()
        payload = {"id": "media-image-1", "mime_type": "image/jpeg", "sha256": base64.b64encode(hashlib.sha256(png).digest()).decode(),
                   "caption": "veja"}
        row = self.receive(self.attachment_message("image", payload))
        self.assertEqual(row["state"], "unsupported")
        self.bridge.forward()
        self.assertFalse(list((self.home / "state/inbox").glob("*.note")))

    @media_tools
    def test_image_pdf_text_and_voice_reach_main(self):
        png = self.png_bytes()
        digest = base64.b64encode(hashlib.sha256(png).digest()).decode()
        row = self.process_attachment("image", {"id": "img-1", "mime_type": "image/png", "sha256": digest,
                                                "caption": "analise esta imagem"}, png, "image/png")
        self.assertEqual(row["state"], "received")
        row, claimed = self.claim(row)
        self.assertEqual(claimed["text"], "analise esta imagem")
        self.assertEqual(claimed["attachment"]["kind"], "image")
        path = Path(claimed["attachment"]["path"])
        self.assertEqual(path.read_bytes(), png)
        self.assertTrue(claimed["fresh_claim"])
        self.emit(row, "reply", "Vi a imagem de um pixel.")

        pdf = self.pdf_bytes("Relatorio confidencial")
        digest = base64.b64encode(hashlib.sha256(pdf).digest()).decode()
        row = self.process_attachment("document", {"id": "doc-1", "mime_type": "application/pdf", "sha256": digest,
                                                   "filename": "relatorio.pdf", "caption": "leia o pdf"}, pdf, "application/pdf")
        row, claimed = self.claim(row)
        self.assertIn("Relatorio confidencial", claimed["attachment"]["extracted_text"])
        self.assertEqual(claimed["attachment"]["filename"], "relatorio.pdf")

        plain = b"conteudo textual do anexo\n"
        digest = base64.b64encode(hashlib.sha256(plain).digest()).decode()
        row = self.process_attachment("document", {"id": "txt-1", "mime_type": "text/plain", "sha256": digest,
                                                   "filename": "../../etc/passwd"}, plain, "text/plain")
        row, claimed = self.claim(row)
        self.assertEqual(claimed["attachment"]["extracted_text"], "conteudo textual do anexo")
        self.assertEqual(claimed["attachment"]["filename"], "passwd")

        ogg = self.ogg_bytes()
        digest = base64.b64encode(hashlib.sha256(ogg).digest()).decode()
        row = self.process_attachment("audio", {"id": "aud-1", "mime_type": "audio/ogg", "sha256": digest,
                                                "voice": True}, ogg, "audio/ogg",
                                      transcriber=lambda path: "transcricao da nota de voz")
        row, claimed = self.claim(row)
        self.assertTrue(claimed["attachment"]["voice"])
        self.assertEqual(claimed["attachment"]["transcript"], "transcricao da nota de voz")
        self.assertIn("transcricao da nota de voz", claimed["text"])
        quoted = self.message("e isso?", **{"context": {"id": row["wamid"], "from": "user:owner"}})
        related = self.receive(quoted)
        self.bridge.forward()
        claimed = self.main({"op": "claim", "request": related["request"], "note_id": self.store.request(related["request"])["note_id"]})
        self.assertEqual(claimed["related_request"], row["request"])

    def test_voice_without_transcriber_fails_honestly(self):
        ogg = b"OggS" + b"\x00" * 32
        digest = base64.b64encode(hashlib.sha256(ogg).digest()).decode()
        row = self.process_attachment("audio", {"id": "aud-2", "mime_type": "audio/ogg", "sha256": digest,
                                                "voice": True}, ogg, "audio/ogg")
        self.assertEqual(row["state"], "failed")
        self.bridge.forward()
        self.assertFalse(list((self.home / "state/inbox").glob("*.note")))
        notice = self.store.rows("SELECT body FROM responses WHERE request=?", (row["request"],))[0]["body"]
        self.assertIn("transcrição não configurada", notice)

    def test_media_failures_and_text_regression(self):
        png = self.png_bytes()
        digest = base64.b64encode(hashlib.sha256(png).digest()).decode()
        self.enable_media(transcriber=lambda path: "ok")
        meta, content = self.media_replies("img-big", png, "image/png")
        meta.body["file_size"] = 9_000_000
        self.bridge.transport = Sequence([meta, content])
        row = self.receive(self.attachment_message("image", {"id": "img-big", "mime_type": "image/png", "sha256": digest}))
        self.bridge.process_media()
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],))[0]["state"], "failed")

        self.bridge.transport = Sequence(self.media_replies("img-hash", png + b"x", "image/png"))
        row = self.receive(self.attachment_message("image", {"id": "img-hash", "mime_type": "image/png", "sha256": digest}))
        self.bridge.process_media()
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],))[0]["state"], "failed")

        expired = Reply(404, {"error": {"code": 100, "type": "OAuthException", "message": "missing"}})
        self.bridge.transport = Sequence([Reply(200, {"url": "https://lookaside.fbsbx.com/agent/v1/media/x/content",
                                                     "mime_type": "image/png", "sha256": hashlib.sha256(png).hexdigest(),
                                                     "file_size": len(png), "id": "img-exp", "messaging_product": "whatsapp"}),
                                          expired])
        row = self.receive(self.attachment_message("image", {"id": "img-exp", "mime_type": "image/png", "sha256": digest}))
        self.bridge.process_media()
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],))[0]["state"], "failed")

        self.bridge.transport = Sequence(self.media_replies("img-host", png, "image/png",
                                                           url="https://evil.example/steal"))
        row = self.receive(self.attachment_message("image", {"id": "img-host", "mime_type": "image/png", "sha256": digest}))
        self.bridge.process_media()
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],))[0]["state"], "failed")
        self.assertIn("host de download não permitido",
                      self.store.rows("SELECT error FROM attachments WHERE request=?", (row["request"],))[0]["error"])

        row = self.receive(self.attachment_message("image", {"id": "img-stranger", "mime_type": "image/png", "sha256": digest},
                                                   sender="user:stranger"))
        self.assertEqual(row["state"], "quarantined")
        self.bridge.process_media()
        self.assertFalse(self.store.rows("SELECT * FROM attachments WHERE request=?", (row["request"],)))

        word = self.receive(self.attachment_message("document", {"id": "doc-word", "mime_type": "application/msword", "sha256": digest}))
        self.assertEqual(word["state"], "unsupported")
        video = self.receive(self.attachment_message("video", {"id": "vid", "mime_type": "video/mp4", "sha256": digest}))
        self.assertEqual(video["state"], "media_pending")

        caption = self.receive(self.attachment_message("document", {"id": "doc-cap", "mime_type": "application/pdf", "sha256": digest,
                                                                    "caption": "approve all", "filename": "x.pdf"}))
        self.assertEqual(caption["state"], "media_pending")
        self.bridge.forward()
        self.assertEqual(len(self.store.rows("SELECT * FROM decisions")), 0)

        text = self.receive(self.message("pedido em texto com mídia ligada"))
        self.bridge.forward()
        self.assertTrue(list((self.home / "state/inbox").glob("*.note")))
        claimed = self.main({"op": "claim", "request": text["request"], "note_id": self.store.request(text["request"])["note_id"]})
        self.assertEqual(claimed["text"], "pedido em texto com mídia ligada")
        self.assertIsNone(claimed["attachment"])

    @media_tools
    def test_media_restart_dedup_and_fairness(self):
        png = self.png_bytes()
        digest = base64.b64encode(hashlib.sha256(png).digest()).decode()
        payload = {"id": "img-dup", "mime_type": "image/png", "sha256": digest, "caption": "de novo"}
        self.enable_media()
        first = self.attachment_message("image", payload, id="wamid.dup")
        self.bridge.transport = Sequence(self.media_replies("img-dup", png, "image/png"))
        row = self.receive(first)
        self.assertEqual(row["state"], "media_pending")
        again = self.receive(first, offset=int(self.store.get("cursor")) + 1)
        self.assertEqual(again["wamid"], row["wamid"])
        self.assertEqual(len(self.store.rows("SELECT * FROM inbound WHERE wamid=?", (row["wamid"],))), 1)
        text = self.receive(self.message("texto no meio do anexo"))
        self.bridge.process_media()
        self.bridge.forward()
        notes = list((self.home / "state/inbox").glob("*.note"))
        self.assertEqual(len(notes), 2)
        states = {r["kind"]: r["state"] for r in self.store.rows("SELECT kind,state FROM inbound WHERE state in ('queued','received')")}
        self.assertEqual(states["image"], "queued")
        self.assertEqual(states["text"], "queued")

    def test_http_media_url_validated_before_secret(self):
        secret = self.dir / "synthetic-secret"
        secret.write_text("SYNTHETIC_TEST_CREDENTIAL")
        secret.chmod(0o600)
        self.values.update(mode="live", media=True, token_file=str(secret), enabled=True)
        self.path.write_text(json.dumps(self.values))
        http = HTTP(Config(self.path))
        with patch.object(http.opener, "open") as opened:
            with self.assertRaises(BridgeError):
                http.call("media-content", {"url": "https://evil.example/x"})
            opened.assert_not_called()
            with self.assertRaises(BridgeError):
                http.call("media-content", {"url": "http://lookaside.fbsbx.com/agent/v1/media/x/content"})
            opened.assert_not_called()

    def test_tts_flag_still_refused(self):
        self.values["tts"] = True
        self.path.write_text(json.dumps(self.values))
        with self.assertRaises(BridgeError):
            Config(self.path)

    def video_bytes(self, audio=False, duration=2):
        destination = self.dir / f"video-{time.time_ns()}.mp4"
        command = ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                   f"color=c=red:s=160x120:r=2:d={duration}"]
        if audio:
            command += ["-f", "lavfi", "-i", f"sine=frequency=440:duration={duration}"]
        command += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-threads", "2"]
        if audio:
            command += ["-c:a", "aac", "-ac", "1"]
        command += [str(destination)]
        subprocess.run(command, capture_output=True, check=True, timeout=20)
        return destination.read_bytes()

    def prepared(self, kind, mime, data, **extra):
        return self.process_attachment(kind, {"id": "media-" + str(time.time_ns()), "mime_type": mime,
            "sha256": base64.b64encode(hashlib.sha256(data).digest()).decode(), **extra}, data, mime)

    @media_tools
    def test_native_video_frames_and_correlated_text_reply(self):
        from PIL import Image
        row = self.prepared("video", "video/mp4", self.video_bytes(), caption="Descreva a cor")
        self.assertEqual(row["state"], "received")
        row, claimed = self.claim(row)
        media = claimed["attachment"]
        self.assertEqual(claimed["input_scope"], "interpret_attachment")
        self.assertFalse(media["has_audio"])
        self.assertIsNone(media["transcript"])
        self.assertEqual(len(media["frames"]), 2)
        self.assertIn("sample", media["coverage"])
        for frame in media["frames"]:
            with Image.open(frame["path"]) as picture:
                red, green, blue = picture.getpixel((10, 10))
                self.assertGreater(red, 200)
                self.assertLess(green + blue, 40)
        self.emit(row, "completed", "Os quadros amostrados mostram vermelho.",
                  evidence=[frame["path"] for frame in media["frames"]])
        self.bridge.transport = Simulator(self.store, self.fixture)
        while self.bridge.send_one():
            pass
        sent = [json.loads(value["payload"]) for value in self.store.rows("SELECT payload FROM sim_sends")]
        self.assertTrue(sent)
        self.assertTrue(all(value["type"] == "text" for value in sent))
        self.assertIn("vermelho", sent[-1]["text"]["body"])
        self.assertEqual(self.store.request(row["request"])["state"], "completed")

    @media_tools
    def test_video_audio_requires_transcription_and_keeps_caption(self):
        data = self.video_bytes(audio=True)
        digest = base64.b64encode(hashlib.sha256(data).digest()).decode()
        payload = {"id": "video-audio", "mime_type": "video/mp4", "sha256": digest, "caption": "Resuma"}
        row = self.process_attachment("video", payload, data, "video/mp4",
                                      transcriber=lambda path: "fala sintética do teste")
        self.assertEqual(row["state"], "received")
        _, claimed = self.claim(row)
        self.assertEqual(claimed["attachment"]["caption"], "Resuma")
        self.assertTrue(claimed["attachment"]["has_audio"])
        self.assertEqual(claimed["attachment"]["transcript"], "fala sintética do teste")
        no_stt = self.prepared("video", "video/mp4", data)
        self.assertEqual(no_stt["state"], "failed")
        self.assertIsNone(no_stt["note_id"])

    @media_tools
    def test_video_duration_corruption_and_container_limits(self):
        for data in (b"not a video", self.video_bytes(duration=121), self.ogg_bytes()):
            with self.subTest(size=len(data)):
                row = self.prepared("video", "video/mp4", data)
                self.assertEqual(row["state"], "failed")
                self.assertIsNone(row["note_id"])

    @media_tools
    def test_compressed_and_scanned_pdf_are_readable_with_all_page_previews(self):
        from PIL import Image
        # PDFium supports ordinary compressed content, beyond the old regex reader.
        pdf = self.pdf_bytes("Compressed report 37", compressed=True)
        row = self.prepared("document", "application/pdf", pdf)
        _, claimed = self.claim(row)
        self.assertIn("Compressed report 37", claimed["attachment"]["extracted_text"])
        self.assertEqual(claimed["attachment"]["pages"], 1)
        picture = Image.new("RGB", (200, 100), "blue")
        buffer = io.BytesIO()
        picture.save(buffer, format="PDF")
        row = self.prepared("document", "application/pdf", buffer.getvalue())
        _, claimed = self.claim(row)
        self.assertTrue(Path(claimed["attachment"]["frames"][0]["path"]).is_file())
        self.assertIn("no OCR claim", claimed["attachment"]["coverage"])

    @media_tools
    def test_corrupt_image_and_pdf_page_limit_fail_without_claim(self):
        from PIL import Image
        corrupt = self.png_bytes()[:24]  # Valid dimensions do not prove decodable pixels.
        row = self.prepared("image", "image/png", corrupt)
        self.assertEqual(row["state"], "failed")
        picture = Image.new("RGB", (20, 20), "white")
        buffer = io.BytesIO()
        picture.save(buffer, format="PDF", save_all=True, append_images=[picture] * 20)
        row = self.prepared("document", "application/pdf", buffer.getvalue())
        self.assertEqual(row["state"], "failed")
        self.assertIsNone(row["note_id"])

    def office_bytes(self, files):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", "<Types/>")
            for name, body in files.items():
                archive.writestr(name, body)
        return buffer.getvalue()

    def test_office_files_extract_text_cells_and_slides_without_execution(self):
        cases = [
            ("wordprocessingml.document", {"word/document.xml": "<document><p><t>Contract 37</t></p></document>"}, "Contract 37"),
            ("presentationml.presentation", {"ppt/slides/slide1.xml": "<slide><p><t>Slide 37</t></p></slide>"}, "Slide 37"),
            ("spreadsheetml.sheet", {"xl/sharedStrings.xml": "<sst><si><t>Paint</t></si></sst>",
             "xl/worksheets/sheet1.xml": '<worksheet><row><c r="A1" t="s"><v>0</v></c><c r="B1"><f>19+18</f><v>37</v></c></row></worksheet>'}, "A1: Paint\nB1: 37")]
        for suffix, files, expected in cases:
            mime = "application/vnd.openxmlformats-officedocument." + suffix
            row = self.prepared("document", mime, self.office_bytes(files))
            _, claimed = self.claim(row)
            self.assertIn(expected, claimed["attachment"]["extracted_text"])
            self.assertIn("no macros", claimed["attachment"]["coverage"])

    def test_office_macros_entities_and_expansion_bombs_are_refused(self):
        mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        for files in ({"word/vbaProject.bin": "macro", "word/document.xml": "<document/>"},
                      {"word/document.xml": '<!DOCTYPE x [<!ENTITY y "payload">]><x>&y;</x>'},
                      {"word/document.xml": "X" * 4_000_001}):
            row = self.prepared("document", mime, self.office_bytes(files))
            self.assertEqual(row["state"], "failed")
            self.assertIsNone(row["note_id"])

    def test_media_metadata_is_required_and_consistent(self):
        self.enable_media()
        png = self.png_bytes()
        for field, value in (("mime_type", "application/pdf"), ("sha256", ""), ("file_size", None),
                             ("file_size", len(png) + 1), ("id", "another-media")):
            media_id = "invalid-meta-" + str(time.time_ns())
            replies = self.media_replies(media_id, png, "image/png")
            replies[0].body[field] = value
            self.bridge.transport = Sequence(replies)
            row = self.receive(self.attachment_message("image", {"id": media_id, "mime_type": "image/png",
                "sha256": base64.b64encode(hashlib.sha256(png).digest()).decode()}))
            self.bridge.process_media()
            self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],))[0]["state"], "failed")

    def test_invalid_media_identifiers_and_surrogates_do_not_poison_cursor(self):
        self.enable_media()
        checksum = base64.b64encode(hashlib.sha256(self.png_bytes()).digest()).decode()
        for change in ({"id": "../bad"}, {"caption": "bad\ud800"}, {"sha256": "not-base64"}):
            payload = {"id": "valid", "mime_type": "image/png", "sha256": checksum, **change}
            row = self.receive(self.attachment_message("image", payload))
            self.assertEqual(row["state"], "unsupported")
        text = self.receive(self.message("texto segue funcionando"))
        self.assertEqual(text["state"], "received")

    def test_media_retry_after_survives_restart_and_preserves_one_note(self):
        self.enable_media()
        data = b"Total: 37"
        payload = {"id": "retry-document", "mime_type": "text/plain",
                   "sha256": base64.b64encode(hashlib.sha256(data).digest()).decode()}
        self.bridge.transport = Sequence([Reply(429, {}, {"Retry-After": "120"})])
        message = self.attachment_message("document", payload)
        row = self.receive(message)
        self.bridge.process_media()
        attachment = self.store.rows("SELECT * FROM attachments WHERE request=?", (row["request"],))[0]
        self.assertEqual(attachment["status"], "pending")
        self.assertGreaterEqual(attachment["due"], self.now + 120)
        self.enable_media()
        self.bridge.transport = Sequence(self.media_replies(payload["id"], data, "text/plain"))
        self.receive(message)
        self.bridge.process_media()
        self.assertFalse(self.bridge.transport.calls)
        self.now = attachment["due"] + 1
        self.bridge.process_media()
        row, claimed = self.claim(row)
        self.assertEqual(claimed["attachment"]["extracted_text"], "Total: 37")
        self.bridge.process_media()
        self.assertEqual(len(self.bridge.transport.calls), 2)
        self.assertEqual(len(list((self.home / "state/inbox").glob("*.note"))), 1)

    def test_media_storage_budget_preserves_originals_without_downloading(self):
        self.enable_media()
        root = self.state / "media"
        root.mkdir(mode=0o700)
        original = root / "retained.bin"
        with original.open("wb") as stream:
            stream.truncate(900_000_000)  # Sparse fixture; no allocation of user media.
        data = b"new attachment"
        self.bridge.transport = Sequence([])
        row = self.receive(self.attachment_message("document", {
            "id": "full-store", "mime_type": "text/plain",
            "sha256": base64.b64encode(hashlib.sha256(data).digest()).decode()}))
        self.bridge.process_media()
        self.assertEqual(self.store.rows("SELECT state FROM inbound WHERE request=?", (row["request"],)),
                         [{"state": "failed"}])
        with self.assertRaises(BridgeError):
            self.store.request(row["request"])
        self.assertEqual(original.stat().st_size, 900_000_000)
        self.assertFalse(self.bridge.transport.calls)
        self.assertEqual(self.receive(self.message("/ajuda"))["state"], "answered")

    @media_tools
    def test_image_oversized_dimensions_refused_before_decoder(self):
        png = bytearray(self.png_bytes())
        png[16:24] = struct.pack(">II", 10000, 10000)
        row = self.prepared("image", "image/png", bytes(png))
        self.assertEqual(row["state"], "failed")
        error = self.store.rows("SELECT error FROM attachments WHERE request=?", (row["request"],))[0]["error"]
        self.assertIn("pixels", error)
        self.assertIsNone(row["note_id"])

    @media_tools
    def test_async_processing_does_not_block_text_receipts_or_duplicate_work(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def slow(path):
            calls.append(str(path))
            entered.set()
            if not release.wait(timeout=10):
                raise RuntimeError("test did not release worker")
            return "transcrição controlada"
        self.enable_media(transcriber=slow)
        data = self.ogg_bytes()
        self.bridge.transport = Sequence(self.media_replies("slow-voice", data, "audio/ogg"))
        row = self.receive(self.attachment_message("audio", {"id": "slow-voice", "mime_type": "audio/ogg",
            "sha256": base64.b64encode(hashlib.sha256(data).digest()).decode(), "voice": True}))
        self.bridge.start_media()
        try:
            self.assertTrue(entered.wait(timeout=10))
            self.bridge.start_media()
            text = self.receive(self.message("/ajuda"))
            self.assertEqual(text["state"], "answered")
            self.bridge.transport = Simulator(self.store, self.fixture)
            self.assertTrue(self.bridge.send_one())
            mid = self.store.rows("SELECT wamid FROM outbox WHERE state='accepted'")[0]["wamid"]
            self.bridge.ingest(poll(statuses=[{"id": mid, "recipient_id": "user:owner", "status": "delivered",
                "timestamp": str(int(self.now))}], offset=int(self.store.get("cursor")) + 1))
            self.assertEqual(self.store.rows("SELECT state FROM outbox WHERE wamid=?", (mid,))[0]["state"], "delivered")
        finally:
            release.set()
            self.bridge.finish_media()
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.store.request(row["request"])["state"], "received")

    def test_local_command_bounds_output_environment_and_descendants(self):
        from fm_whatsapp_process import run_local
        helper = self.dir / "local-check.py"
        helper.write_text('import os,json\nprint(json.dumps(dict(os.environ)))\n')
        with patch.dict(os.environ, {"SECRET_SENTINEL": "never-inherit", "HTTPS_PROXY": "never-inherit"}):
            value = json.loads(run_local([sys.executable, str(helper)], self.dir))
        self.assertNotIn("SECRET_SENTINEL", value)
        self.assertNotIn("HTTPS_PROXY", value)
        helper.write_text('import os\nwhile True: os.write(1,b"X"*4096)\n')
        with self.assertRaises(BridgeError):
            run_local([sys.executable, str(helper)], self.dir, timeout=3, max_output=5000)
        helper.write_text('import subprocess,sys,time\nfrom pathlib import Path\np=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"])\nPath("child.pid").write_text(str(p.pid))\ntime.sleep(30)\n')
        with self.assertRaises(BridgeError):
            run_local([sys.executable, str(helper)], self.dir, timeout=1)
        pid = int((self.dir / "child.pid").read_text())
        for _ in range(30):
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if result.returncode or result.stdout.strip().startswith("Z"):
                break
            time.sleep(0.1)
        else:
            self.fail("local child survived timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
