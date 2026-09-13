#!/usr/bin/env python3
"""Persistent input forwarding and ordered outbound delivery.

An exclusive agent lock covers run/recovery, including outstanding subprocesses.
fm-inbox's keyed capture closes the note-write/return gap. Main-side 'claim'
and typed response commands own task execution acknowledgement, never transport.
The only automatic status answers are snapshots of this bridge's typed events;
all other natural-language messages go to the owning main with bounded history.
"""

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from fm_whatsapp_store import BridgeError, digest, encode, integer
from fm_whatsapp_transport import classify, delay

ROOT = Path(__file__).resolve().parent
TERMINAL = ("completed", "failed")


@contextmanager
def singleton(config):
    # All live homes on this machine/user share one agent lock, even if state
    # paths differ. Simulations are intentionally isolated under their fixtures.
    directory = (Path(tempfile.gettempdir()) / ("fm-whatsapp-" + str(os.getuid()))
                 if config.mode == "live" else config.state / "locks")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
        raise BridgeError("unsafe singleton directory")
    fd = os.open(directory / (digest(config.agent) + ".lock"),
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BridgeError("another local consumer owns this agent") from None
        yield
    finally:
        os.close(fd)


def auth(config, operation):
    result = subprocess.run([str(ROOT / "fm-whatsapp-auth.sh"), str(config.home), operation],
                            env=config.environment(), capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise BridgeError("operation requires the live lock-owning main of this FM_HOME")
    return result.stdout.strip()


class Bridge:
    def __init__(self, store, transport):
        self.s, self.c, self.transport = store, store.config, transport
        self.stopping = False

    def recover(self):
        with self.s.tx():
            self.s.db.execute("UPDATE outbox SET state='delivery_unknown' WHERE state='sending'")
            self.s.db.execute("UPDATE attempts SET outcome='delivery_unknown' WHERE outcome IS NULL")

    def availability(self):
        try:
            result = auth(self.c, "probe")
        except (BridgeError, OSError, subprocess.TimeoutExpired):
            result = "unavailable"
        if result not in ("checkpoint", "unavailable"):
            result = "unavailable"
        self.s.put("supervision", result)
        return result

    def ingest(self, reply):
        if self.s.get("activated") is None:
            raise BridgeError("activate the enabled bridge before ingesting updates")
        if reply.http == 204:
            return
        payload = reply.body
        try:
            if payload["object"] != "whatsapp_agent_platform" or len(payload["entry"]) != 1:
                raise ValueError()
            entry = payload["entry"][0]
            if entry["id"] != self.c.agent or len(entry["changes"]) != 1:
                raise ValueError()
            change = entry["changes"][0]
            value = change["value"]
            if change["field"] != "messages" or value["messaging_product"] != "whatsapp":
                raise ValueError()
            cursor = integer(payload["next_offset"], 0, 2**63 - 1, "next_offset")
            if cursor < int(self.s.get("cursor")):
                raise ValueError()
            if not isinstance(value["messages"], list) or not isinstance(value["statuses"], list):
                raise ValueError()
        except (KeyError, TypeError, ValueError, IndexError):
            raise BridgeError("invalid poll envelope; durable cursor retained") from None
        with self.s.tx():
            for contact in value.get("contacts", []):
                if not isinstance(contact, dict) or contact.get("wa_id") != self.c.creator:
                    continue
                profile = contact.get("profile")
                if isinstance(profile, dict) and isinstance(profile.get("name"), str):
                    self.s.db.execute("INSERT OR REPLACE INTO contacts VALUES(?,?)",
                                      (self.c.creator, profile["name"][:200]))
            for message in value["messages"]:
                self.receive(message)
            for receipt in value["statuses"]:
                self.receipt(receipt)
            self.s.put("cursor", cursor)

    def receive(self, message):
        # Unknown shapes are retained by digest so a future type cannot wedge
        # the consumer. No raw body from one becomes an executable request.
        raw = encode(message)
        if not isinstance(message, dict):
            message = {}
        mid = message.get("id")
        if not isinstance(mid, str) or not mid or len(mid) > 1024:
            mid = "invalid-" + digest(raw)
        if self.s.db.execute("SELECT 1 FROM inbound WHERE wamid=?", (mid,)).fetchone():
            return
        sender = message.get("from") if isinstance(message.get("from"), str) else ""
        kind = message.get("type") if isinstance(message.get("type"), str) else "unknown"
        stamp = message.get("timestamp")
        stamp = int(stamp) if isinstance(stamp, str) and re.fullmatch(r"[0-9]{1,12}", stamp) else None
        text = message.get("text")
        body = text.get("body") if isinstance(text, dict) else None
        valid = (kind == "text" and isinstance(body, str) and body.strip()
                 and 0 < len(body) <= 200000 and "\x00" not in body
                 and not any(0xD800 <= ord(char) <= 0xDFFF for char in body))
        state = "received"
        if sender != self.c.creator:
            state = "quarantined"
        elif stamp is None or mid.startswith("invalid-"):
            state = "invalid"
        elif stamp < float(self.s.get("activated")):
            state = "historical"
        elif not valid:
            state = "unsupported"
        request = "wa-" + digest([self.c.agent, mid])[:32]
        self.s.db.execute("INSERT INTO inbound VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                          (mid, request, sender, stamp, kind, body if valid else None, raw,
                           state, None, None, self.s.now()))
        if state == "unsupported" and sender == self.c.creator:
            self.s.emit(request + ".unsupported", request, "notice",
                        "Esta etapa aceita texto. Anexos e reações ficam registrados sem executar conteúdo.", "bridge")
        if state != "received":
            return
        if self.decision_answer(request, mid, body):
            return
        status_words = ("/status", "/tarefas", "como está o andamento?", "qual o andamento?",
                        "e aquela tarefa?", "e aquela tarefa", "como estão as tarefas?")
        quote = message.get("context")
        if body.strip().lower() in status_words and not (isinstance(quote, dict) and isinstance(quote.get("id"), str)):
            self.status_answer(request)
            return
        if body.strip().lower() in ("/ajuda", "ajuda"):
            self.s.emit(request + ".help", request, "notice",
                        "Envie seu pedido em português. /status consulta registros de andamento. "
                        "Execução e decisões seguem as regras do Firstmate; cancelar exige identificar a tarefa.", "bridge")
            self.s.db.execute("UPDATE inbound SET state='answered' WHERE request=?", (request,))
            return
        state = self.s.get("supervision")
        message = ("Pedido recebido e preservado. O Firstmate está disponível apenas em checkpoints; "
                   "o início da execução ainda não foi confirmado." if state == "checkpoint" else
                   "Pedido recebido e preservado. O Firstmate está indisponível; a execução ainda não começou.")
        self.s.emit(request + ".received", request, "received", message, "bridge")

    def status_answer(self, request):
        query = """SELECT i.request,i.state,r.kind,r.body FROM inbound i
          LEFT JOIN responses r ON r.rowid=(SELECT MAX(x.rowid) FROM responses x
          WHERE x.request=i.request AND x.actor!='bridge')
          WHERE i.sender=? AND i.request!=? AND """
        active = self.s.rows(query + """i.state IN ('received','queued','claimed','started','decision','blocked')
          ORDER BY i.received DESC,i.rowid DESC LIMIT 11""", (self.c.creator, request))
        names = {"received": "Recebido e preservado", "queued": "Enfileirado", "claimed": "Reivindicado, início não confirmado",
                 "started": "Iniciado", "decision": "Aguardando decisão", "completed": "Concluído",
                 "failed": "Falhou", "answered": "Resposta", "blocked": "Bloqueado"}

        def describe(row):
            summary = f"{names[row['state']]}: {row['body']}" if row["body"] else names[row["state"]]
            return summary[:179] + "…" if len(summary) > 180 else summary

        if len(active) > 1:
            body = "Há mais de um pedido em andamento. Qual deles?\n" + "\n".join(
                f"{i+1}. {describe(r)}" for i, r in enumerate(active[:10]))
            if len(active) > 10:
                body += "\nHá outros pedidos em andamento além destes."
        elif active:
            body = describe(active[0])
        else:
            latest = self.s.rows(query + """i.state IN ('answered','completed','failed') AND r.rowid IS NOT NULL
              ORDER BY r.rowid DESC LIMIT 1""", (self.c.creator, request))
            body = describe(latest[0]) if latest else "Nenhum pedido em andamento ou resultado confirmado pelo Firstmate."
        self.s.emit(request + ".status", request, "notice", body, "bridge")
        self.s.db.execute("UPDATE inbound SET state='answered' WHERE request=?", (request,))

    def decision_answer(self, request, mid, body):
        match = re.fullmatch(r"(?:aprovar|aprovo) ([A-Fa-f0-9]{16})", body.strip(), re.IGNORECASE)
        ambiguous = body.strip().lower() in ("sim", "ok", "aprovo", "pode", "👍", "✅")
        pending = self.s.rows("SELECT * FROM decisions WHERE state='pending'")
        if not match and not (ambiguous and pending):
            return False
        decision = next((d for d in pending if match and d["id"] == match[1].lower()), None)
        if decision and decision["expires"] >= self.s.now():
            self.s.db.execute("UPDATE decisions SET state='answered',answer_wamid=? WHERE id=?",
                              (mid, decision["id"]))
            # Main consumes this exact binding once, using its ordinary decision
            # owner. The transport never writes 'resolved' or executes the action.
            self.s.db.execute("UPDATE inbound SET state='received' WHERE request=?", (request,))
            self.s.emit(request + ".decision-answer", request, "received",
                        "Resposta de decisão registrada para a ação indicada; o Firstmate ainda precisa validá-la.", "bridge")
            return True
        self.s.emit(request + ".clarify", request, "notice",
                    "Nenhuma ação foi aprovada. Responda com o código da pergunta vigente: aprovar CÓDIGO. "
                    "Uma confirmação genérica não escolhe entre tarefas.", "bridge")
        self.s.db.execute("UPDATE inbound SET state='answered' WHERE request=?", (request,))
        return True

    def receipt(self, receipt):
        if not isinstance(receipt, dict) or receipt.get("recipient_id") != self.c.creator:
            return
        mid, status, stamp = receipt.get("id"), receipt.get("status"), receipt.get("timestamp")
        if not isinstance(mid, str) or status not in ("delivered", "read") or not isinstance(stamp, str):
            return
        self.s.db.execute("INSERT OR IGNORE INTO receipts VALUES(?,?,?)", (mid, status, stamp))
        if status == "read":
            self.s.db.execute("UPDATE outbox SET state='read' WHERE wamid=?", (mid,))
        else:
            self.s.db.execute("UPDATE outbox SET state='delivered' WHERE wamid=? AND state!='read'", (mid,))

    def forward(self):
        if self.stopping or self.availability() == "unavailable":
            return
        for row in self.s.rows("SELECT * FROM inbound WHERE state='received' ORDER BY received,rowid"):
            if self.stopping:
                return
            request = row["request"]
            # Persist the exact envelope BEFORE invoking note, so retry never
            # changes the body attached to an idempotency key.
            if row["envelope"] is None:
                envelope = encode({"schema": "fm-whatsapp-input.v1", "request": request,
                                   "config": str(self.c.path), "home": str(self.c.home),
                                   "text": row["body"]})
                with self.s.tx():
                    self.s.db.execute("UPDATE inbound SET envelope=? WHERE request=?", (envelope, request))
            else:
                envelope = row["envelope"]
            note_id = "key-" + hashlib.sha256(request.encode()).hexdigest()
            # Mark expected note identity first; a main that drains immediately
            # can claim it while this subprocess is still returning.
            with self.s.tx():
                self.s.db.execute("UPDATE inbound SET note_id=? WHERE request=?", (note_id, request))
            try:
                result = subprocess.run([str(ROOT / "fm-inbox.sh"), "note", "--key", request, "-"],
                                        input=envelope, text=True, capture_output=True,
                                        env=self.c.environment(), timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                self.s.put("forward_error", "note call interrupted; retry same key")
                return
            if result.returncode:
                self.s.put("forward_error", "note saved or pending; same-key recovery required")
                return
            if not result.stdout.startswith("queued " + note_id + "\n"):
                raise BridgeError("unexpected note acknowledgement; preserve state")
            with self.s.tx():
                self.s.db.execute("UPDATE inbound SET state='queued' WHERE request=? AND state='received'", (request,))
                self.s.put("forward_error", "")

    def poll(self):
        if self.stopping:
            return
        self.s.activate()
        if self.s.get("halt") or float(self.s.get("poll_due") or 0) > self.s.clock():
            return
        if self.s.reserve("updates"):
            return
        timeout = 0 if self.ready_send() else self.c.timeout
        reply = self.transport.call("updates", {"offset": int(self.s.get("cursor")),
                                                "limit": self.c.limit, "timeout": timeout})
        policy = classify("updates", reply)
        if policy != "accepted":
            error = reply.body.get("error", {}) if isinstance(reply.body, dict) else {}
            error = error if isinstance(error, dict) else {}
            trace = error.get("fbtrace_id", "")
            trace = trace if isinstance(trace, str) and re.fullmatch(r"[A-Za-z0-9_-]{0,100}", trace) else ""
            self.s.put("poll_diagnostic", encode({"http": reply.http, "policy": policy,
                       "code": error.get("code") if type(error.get("code")) is int else None,
                       "trace": trace}))
        if policy == "accepted":
            self.ingest(reply)
            self.s.put("poll_attempts", 0)
        elif policy == "retry":
            attempts = int(self.s.get("poll_attempts") or 0) + 1
            self.s.put("poll_attempts", attempts)
            self.s.put("poll_due", self.s.clock() + delay(attempts, reply.headers, self.s.clock()))
        else:
            # 409 is a persistent diagnostic halt, even across launchd restarts.
            self.s.put("halt", policy)

    def ready_send(self):
        if self.stopping or self.s.get("halt") or not self.c.outbound:
            return None
        # Global sequence blocks behind unknown/permanent sends until an operator
        # resolves the exact row; later parts never overtake the uncertain part.
        rows = self.s.rows("SELECT * FROM outbox WHERE state NOT IN ('accepted','delivered','read','abandoned') ORDER BY seq LIMIT 1")
        if not rows:
            return None
        row = rows[0]
        if row["state"] != "pending" or row["due"] > self.s.clock() or self.s.rate_wait("messages", self.s.now()):
            return None
        return row

    def send_one(self):
        row = self.ready_send()
        if row is None or self.s.reserve("messages"):
            return False
        payload = {"messaging_product": "whatsapp", "to": self.c.creator, "type": "text",
                   "text": {"body": row["body"], "preview_url": False}}
        with self.s.tx():
            self.s.db.execute("UPDATE outbox SET state='sending',attempts=attempts+1 WHERE seq=?", (row["seq"],))
            attempt = self.s.db.execute("INSERT INTO attempts(seq,at) VALUES(?,?)", (row["seq"], self.s.now())).lastrowid
        reply = self.transport.call("messages", payload)
        policy = classify("messages", reply)
        mid = None
        if policy == "accepted":
            try:
                result = reply.body
                assert result["messaging_product"] == "whatsapp"
                assert len(result["contacts"]) == len(result["messages"]) == 1
                assert result["contacts"][0]["input"] == self.c.creator
                assert result["contacts"][0]["wa_id"] == self.c.creator
                mid = result["messages"][0]["id"]
                assert isinstance(mid, str) and mid.startswith("wamid.")
                assert not self.s.db.execute("SELECT 1 FROM outbox WHERE wamid=?", (mid,)).fetchone()
            except (TypeError, KeyError, IndexError, AssertionError):
                policy, mid = "delivery_unknown", None
        error = reply.body.get("error", {}) if isinstance(reply.body, dict) else {}
        error = error if isinstance(error, dict) else {}
        code = error.get("code") if type(error.get("code")) is int else None
        trace = error.get("fbtrace_id", "")
        trace = trace if isinstance(trace, str) and re.fullmatch(r"[A-Za-z0-9_-]{0,100}", trace) else ""
        with self.s.tx():
            due = self.s.now()
            state = policy
            if policy == "retry":
                due += delay(row["attempts"] + 1, reply.headers, due)
                state = "pending"
            if policy == "auth_failed":
                self.s.put("halt", "auth_failed")
            self.s.db.execute("UPDATE outbox SET state=?,wamid=?,due=? WHERE seq=?", (state, mid, due, row["seq"]))
            self.s.db.execute("UPDATE attempts SET outcome=?,http=?,code=?,trace=? WHERE id=?",
                              (policy, reply.http, code, trace, attempt))
            if mid:
                state = self.s.accept_send(row["seq"], mid)
        return state in ("accepted", "read", "delivered")

    def tick(self):
        for operation in (self.availability, self.poll, self.forward, self.send_one):
            if self.stopping:
                return
            operation()
