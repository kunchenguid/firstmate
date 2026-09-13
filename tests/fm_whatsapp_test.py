#!/usr/bin/env python3
"""Exercise public bridge interfaces with a real inbox and fixture-only main.

The harness fixture uses an executable named codex to exercise the existing
session-lock classifier, not to prove vendor UI behavior. It calls the public
main CLI, executes no LLM, and is killed only by its owning test. No live home,
network client, token, service registration or Herdr lifecycle is used.
"""

from http.client import IncompleteRead
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
from fm_whatsapp_bridge import Bridge, singleton
from fm_whatsapp_store import BridgeError, Config, Store, encode
from fm_whatsapp_transport import Reply, Simulator, HTTP, NoRedirect, read_secret, classify, delay


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

    def test_status_during_long_task_and_ambiguity(self):
        first, _ = self.claim()
        self.emit(first, "started", "Analisando formulário", task=self.task())
        self.receive(self.message("e aquela tarefa?"))
        self.assertIn("Analisando formulário", self.store.snapshot()["responses"][-1]["body"])
        second, _ = self.claim(self.receive(self.message("Investigue o outro problema")))
        self.emit(second, "started", "Analisando login", task=self.task("login"))
        self.receive(self.message("e aquela tarefa?"))
        self.assertIn("Qual deles?", self.store.snapshot()["responses"][-1]["body"])

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
        self.receive(self.message("/status"))
        body = self.store.snapshot()["responses"][-1]["body"]
        self.assertIn("Qual deles?", body)
        self.assertIn("Enfileirado", body)
        self.assertIn("Análise longa original", body)

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
        for quoted, related in ((mid, first["request"]), ("wamid.unknown", None)):
            row = self.receive(self.message("e aquela tarefa?", context={"id": quoted, "from": "agent:123"}))
            self.assertEqual(row["state"], "received")
            _, result = self.claim(row)
            self.assertEqual(result["related_request"], related)
            self.assertEqual(result["text"], "e aquela tarefa?")
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
        self.receive(self.message("sim"))
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
