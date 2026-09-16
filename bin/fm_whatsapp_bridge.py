#!/usr/bin/env python3
"""Persistent input forwarding and ordered outbound delivery.

An exclusive agent lock covers run/recovery, including outstanding subprocesses.
fm-inbox's keyed capture closes the note-write/return gap. Main-side 'claim'
and typed response commands own task execution acknowledgement, never transport.
Local status/help and decision-answer handling precede main intake; other
natural-language messages go to the owning main with bounded history.
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
import threading
import time

from fm_whatsapp_media import (LIMITS, MediaError, display_text, hex_digest,
                               image_pixels, inbound_payload, match_checksum, sanitize_filename,
                               sniff, store_bytes, prepare_local, normalize_mime, validate_download_url, check_storage_budget)
from fm_whatsapp_store import BridgeError, Store, digest, encode, integer
from fm_whatsapp_transport import HTTP, Simulator, classify, delay

ROOT = Path(__file__).resolve().parent
TERMINAL = ("completed", "failed")


class MediaRetry(BridgeError):
    def __init__(self, message, wait):
        super().__init__(message)
        self.wait = wait


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
    def __init__(self, store, transport, transcriber=None):
        self.s, self.c, self.transport = store, store.config, transport
        self.transcriber = transcriber
        self.stopping = False
        self.media_thread = None

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
        raw = json.dumps(message, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        if not isinstance(message, dict):
            message = {}
        mid = message.get("id")
        if (not isinstance(mid, str) or not mid or len(mid) > 1024
                or any(0xD800 <= ord(char) <= 0xDFFF for char in mid)):
            mid = "invalid-" + digest(raw)
        if self.s.db.execute("SELECT 1 FROM inbound WHERE wamid=?", (mid,)).fetchone():
            return
        sender = message.get("from") if isinstance(message.get("from"), str) else ""
        kind = message.get("type") if isinstance(message.get("type"), str) else "unknown"
        if any(0xD800 <= ord(char) <= 0xDFFF for char in sender + kind):
            sender, kind = "", "unknown"
        stamp = message.get("timestamp")
        stamp = int(stamp) if isinstance(stamp, str) and re.fullmatch(r"[0-9]{1,12}", stamp) else None
        text = message.get("text")
        body = text.get("body") if isinstance(text, dict) else None
        media = None
        if kind == "text":
            valid = (isinstance(body, str) and body.strip()
                     and 0 < len(body) <= 200000 and "\x00" not in body
                     and not any(0xD800 <= ord(char) <= 0xDFFF for char in body))
        elif self.c.media and kind in ("image", "audio", "document", "video"):
            try:
                media = inbound_payload(kind, message.get(kind))
                body = media["caption"] or None
                valid = True
            except MediaError:
                valid = False
        else:
            valid = False
        state = "received"
        if sender != self.c.creator:
            state = "quarantined"
        elif stamp is None or mid.startswith("invalid-"):
            state = "invalid"
        elif stamp < float(self.s.get("activated")):
            state = "historical"
        elif not valid:
            state = "unsupported"
        elif media is not None:
            state = "media_pending"
        request = "wa-" + digest([self.c.agent, mid])[:32]
        self.s.db.execute("INSERT INTO inbound VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                          (mid, request, sender, stamp, kind, body if valid else None, raw,
                           state, None, None, self.s.now()))
        if media is not None and state == "media_pending":
            self.s.db.execute(
                "INSERT INTO attachments VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (request, media["id"], kind, media["mime"], media["sha256"], media["caption"],
                 media["filename"], 1 if media["voice"] else 0, None, None, None, "pending", None,
                 0, self.s.now()))
        if state == "unsupported" and sender == self.c.creator:
            self.s.emit(request + ".unsupported", request, "notice",
                        "Esta etapa não processa esse tipo de anexo. Reações e formatos não suportados "
                        "ficam registrados sem executar conteúdo.", "bridge")
        if state != "received":
            return
        if self.decision_answer(request, mid, body):
            return
        quote = message.get("context")
        if body.strip().lower() in ("/status", "/tarefas") and not (isinstance(quote, dict) and isinstance(quote.get("id"), str)):
            if self.status_answer(request):
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
        active = self.s.rows(query + """i.state IN ('media_pending','received','queued','claimed','started','decision','blocked')
          ORDER BY i.received DESC,i.rowid DESC LIMIT 2""", (self.c.creator, request))
        if len(active) > 1:
            return False
        names = {"media_pending": "Processando anexo localmente", "received": "Recebido e preservado", "queued": "Enfileirado", "claimed": "Reivindicado, início não confirmado",
                 "started": "Iniciado", "decision": "Aguardando decisão", "completed": "Concluído",
                 "failed": "Falhou", "answered": "Resposta", "blocked": "Bloqueado"}

        def describe(row):
            summary = f"{names[row['state']]}: {row['body']}" if row["body"] else names[row["state"]]
            return summary[:179] + "…" if len(summary) > 180 else summary

        if active:
            body = describe(active[0])
        else:
            latest = self.s.rows(query + """i.state IN ('answered','completed','failed') AND r.rowid IS NOT NULL
              ORDER BY r.rowid DESC LIMIT 1""", (self.c.creator, request))
            body = describe(latest[0]) if latest else "Nenhum pedido em andamento ou resultado confirmado pelo Firstmate."
        self.s.emit(request + ".status", request, "notice", body, "bridge")
        self.s.db.execute("UPDATE inbound SET state='answered' WHERE request=?", (request,))
        return True

    def decision_answer(self, request, mid, body):
        match = re.fullmatch(r"(?:aprovar|aprovo) ([A-Fa-f0-9]{16})", body.strip(), re.IGNORECASE)
        ambiguous = body.strip().lower() in ("sim", "ok", "aprovo", "pode", "👍", "✅")
        pending = self.s.rows("SELECT * FROM decisions WHERE state='pending' AND expires>=?", (self.s.now(),))
        if not match and not (ambiguous and pending):
            return False
        decision = next((d for d in pending if match and d["id"] == match[1].lower()), None)
        if decision:
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
                envelope = encode(self.envelope(row))
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

    def tick(self, asynchronous_media=False):
        for operation in (self.availability, self.poll, self.forward, self.send_one):
            if self.stopping:
                return
            operation()
        if asynchronous_media:
            self.start_media()
        else:
            self.process_media()
            self.forward()

    def start_media(self):
        if self.stopping or not self.c.media or (self.media_thread and self.media_thread.is_alive()):
            return
        if not self.s.rows("SELECT 1 FROM attachments WHERE status='pending' AND due<=? LIMIT 1", (self.s.now(),)):
            return

        def work():
            # The worker has its own SQLite connection and never polls updates,
            # forwards inbox notes, claims requests, or sends responses.
            store = Store(self.c, clock=self.s.clock)
            try:
                transport = (HTTP(self.c) if isinstance(self.transport, HTTP) else
                             Simulator(store, self.transport.path) if isinstance(self.transport, Simulator)
                             else self.transport)
                Bridge(store, transport, self.transcriber).process_media()
            finally:
                store.db.close()
        self.media_thread = threading.Thread(target=work, name="whatsapp-inbound-media")
        self.media_thread.start()

    def finish_media(self):
        # Keep the singleton until this one bounded worker and its children exit.
        if self.media_thread:
            self.media_thread.join()

    def envelope(self, row):
        payload = {"schema": "fm-whatsapp-input.v1", "request": row["request"],
                   "config": str(self.c.path), "home": str(self.c.home), "text": row["body"]}
        attachment = self.s.db.execute("SELECT * FROM attachments WHERE request=? AND status='ready'",
                                       (row["request"],)).fetchone()
        if attachment:
            payload["attachment"] = {
                "kind": attachment["kind"], "mime": attachment["mime"], "path": attachment["path"],
                "caption": attachment["caption"] or "", "filename": attachment["filename"],
                "voice": bool(attachment["voice"]), "sha256": hex_digest(Path(attachment["path"]).read_bytes())
                if attachment["path"] else None, "transcript": attachment["transcript"],
                "extracted_text": attachment["extracted"]}
            details = self.s.db.execute("SELECT details FROM attachment_details WHERE request=?", (row["request"],)).fetchone()
            if details:
                payload["attachment"].update(json.loads(details["details"]))
        return payload

    def process_media(self):
        if self.stopping or not self.c.media or self.s.get("halt"):
            return
        rows = self.s.rows("""SELECT i.*, a.media_id, a.mime, a.sha256 AS inbound_sha, a.caption,
          a.filename, a.voice, a.attempts, a.due AS media_due FROM inbound i
          JOIN attachments a ON a.request=i.request
          WHERE i.state='media_pending' AND a.status='pending' AND a.due<=?
          ORDER BY i.received,i.rowid LIMIT 1""", (self.s.now(),))
        if not rows:
            return
        row = rows[0]
        try:
            self._prepare_attachment(row)
        except (MediaError, BridgeError, OSError, TypeError, ValueError, KeyError) as error:
            message = str(error) if isinstance(error, BridgeError) else "falha ao processar o anexo"
            with self.s.tx():
                attempts = row["attempts"] + 1
                permanent = isinstance(error, MediaError) or attempts >= 3
                if permanent:
                    self.s.db.execute("UPDATE attachments SET status='failed', error=?, attempts=? WHERE request=?",
                                      (message[:500], attempts, row["request"]))
                    self.s.db.execute("UPDATE inbound SET state='failed' WHERE request=? AND state='media_pending'",
                                      (row["request"],))
                    self.s.emit(row["request"] + ".media-failed", row["request"], "notice",
                                "Não foi possível processar o anexo: " + message + ".", "bridge")
                else:
                    due = self.s.now() + max(min(60, 2 ** attempts), getattr(error, "wait", 0))
                    self.s.db.execute("UPDATE attachments SET attempts=?, due=?, error=? WHERE request=?",
                                      (attempts, due, message[:500], row["request"]))

    def _prepare_attachment(self, row):
        media_root = self.c.state / "media"
        media_root.mkdir(mode=0o700, exist_ok=True)
        if media_root.is_symlink() or media_root.stat().st_uid != os.getuid() or media_root.stat().st_mode & 0o077:
            raise MediaError("diretório de mídia inseguro")
        check_storage_budget(media_root)
        # Conservatively charge metadata AND content to the manual's GET quota.
        wait = self.s.reserve("media-metadata", units=2)
        if wait:
            self.s.db.execute("UPDATE attachments SET due=? WHERE request=?", (self.s.now() + wait, row["request"]))
            return
        meta = self.transport.call("media-metadata", {"id": row["media_id"]})
        policy = classify("media-metadata", meta)
        if policy != "accepted" or not isinstance(meta.body, dict):
            if policy == "auth_failed":
                self.s.put("halt", policy)
            if policy == "permanent":
                raise MediaError("metadados de mídia indisponíveis")
            raise MediaRetry("metadados de mídia temporariamente indisponíveis", delay(row["attempts"] + 1, meta.headers, self.s.now()))
        body = meta.body
        if body.get("id") != row["media_id"] or body.get("messaging_product") != "whatsapp":
            raise MediaError("metadados de mídia recusados")
        url = validate_download_url(body.get("url"))
        size = body.get("file_size")
        limit = LIMITS[row["kind"]]
        if type(size) is not int or size <= 0 or size > limit:
            raise MediaError("anexo excede o limite de tamanho")
        if (normalize_mime(body.get("mime_type")) != row["mime"]
                or not isinstance(body.get("sha256"), str) or not re.fullmatch(r"[a-fA-F0-9]{64}", body["sha256"])):
            raise MediaError("tipo ou checksum dos metadados recusado")
        # The second reserved slot is charged at the content request's actual
        # start, so a metadata round trip cannot shorten its rolling window.
        self.s.db.execute("UPDATE rates SET at=? WHERE rowid=(SELECT MAX(rowid) FROM rates WHERE endpoint='media-metadata')", (self.s.now(),))
        content = self.transport.call("media-content", {"url": url, "limit": limit})
        policy = classify("media-content", content)
        if policy != "accepted" or not isinstance(content.body, (bytes, bytearray)):
            if policy == "auth_failed":
                self.s.put("halt", policy)
            if policy == "permanent":
                raise MediaError("download de mídia indisponível")
            if content.fault == "oversized_response":
                raise MediaError("anexo excede o limite de download")
            raise MediaRetry("download de mídia temporariamente indisponível", delay(row["attempts"] + 1, content.headers, self.s.now()))
        data = bytes(content.body)
        if not data or len(data) > limit or len(data) != size:
            raise MediaError("anexo excede o limite de tamanho")
        content_type = next((value for key, value in content.headers.items() if key.lower() == "content-type"), None)
        if content_type and normalize_mime(content_type) != row["mime"]:
            raise MediaError("tipo do download difere dos metadados")
        match_checksum(data, row["inbound_sha"], body.get("sha256") if isinstance(body.get("sha256"), str) else None)
        sniff(data, row["mime"])
        if row["kind"] == "image":
            image_pixels(data, row["mime"])
        directory = media_root / row["request"]
        path = store_bytes(directory, row["mime"], data)
        details = prepare_local(self.c, path, row["kind"], row["mime"], self.transcriber)
        transcript = details.pop("transcript", None)
        extracted = details.pop("extracted_text", None)
        text = display_text(row["kind"], row["caption"], bool(row["voice"]))
        if transcript:
            text = text + "\n\n" + transcript
        elif extracted:
            text = text + "\n\n" + extracted
        filename = sanitize_filename(row["filename"], row["mime"])
        with self.s.tx():
            self.s.db.execute("INSERT OR REPLACE INTO attachment_details VALUES(?,?)", (row["request"], encode(details)))
            self.s.db.execute("""UPDATE attachments SET path=?, transcript=?, extracted=?, filename=?,
              status='ready', error=NULL WHERE request=?""",
                              (str(path), transcript, extracted, filename, row["request"]))
            self.s.db.execute("UPDATE inbound SET body=?, state='received' WHERE request=? AND state='media_pending'",
                              (text, row["request"]))
            state = self.s.get("supervision")
            message = ("Pedido recebido e preservado. O Firstmate está disponível apenas em checkpoints; "
                       "o início da execução ainda não foi confirmado." if state == "checkpoint" else
                       "Pedido recebido e preservado. O Firstmate está indisponível; a execução ainda não começou.")
            self.s.emit(row["request"] + ".received", row["request"], "received", message, "bridge")
