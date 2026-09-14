#!/usr/bin/env python3
"""Authenticated main-side response contract, version fm-whatsapp-response.v1.

Only the live lock-owning main can invoke dispatch. Operations accept JSON data:
  pending: list request ids and transport state, including already-claimed work.
  claim: request + note_id; returns fresh_claim plus bounded conversation context.
  emit: event, request, kind, body; task={home,id,revision} is required for
    started, progress and decision, optional for other kinds. completed requires
    a nonempty evidence array. decision also requires action and expires (epoch,
    within 24h). Allowed kinds are enumerated below.
  consume-decision: id, request, home, task, revision, action (exact tuple).
    Returns new_consumption=true ONCE; repeat is a receipt, not a new grant.
All events and outbox chunks commit together. No terminal scraping, task
dispatch, merge, cancellation, or permission expansion occurs here. Main uses
its existing intake/task/decision owners before emitting an outcome.
"""

import hashlib
import json
from pathlib import Path

from fm_whatsapp_bridge import auth, TERMINAL
from fm_whatsapp_store import BridgeError, digest, token

KINDS = ("reply", "started", "progress", "blocked", "decision", "completed", "failed")


def task_binding(task):
    if not isinstance(task, dict):
        raise BridgeError("task binding must be an object")
    home = Path(task["home"])
    if not home.is_absolute():
        raise BridgeError("task home must be absolute")
    home = home.resolve()
    task_id, revision = token(task["id"], "task id"), token(task["revision"], "revision")
    path = home / "state" / (task_id + ".meta")
    if path.is_symlink() or not path.is_file():
        raise BridgeError("canonical task metadata is unavailable")
    return str(home), task_id, revision, hashlib.sha256(path.read_bytes()).hexdigest()


def context(store, request):
    row = store.request(request)
    raw = json.loads(row["raw"])
    quote = raw.get("context")
    related = None
    # Only verified local message identity is useful; never pass quote text as
    # a fresh instruction, and never let context.from authenticate the sender.
    if isinstance(quote, dict) and isinstance(quote.get("id"), str):
        matches = store.rows("SELECT request FROM outbox WHERE wamid=? UNION SELECT request FROM inbound WHERE wamid=? AND sender=?",
                             (quote["id"], quote["id"], store.config.creator))
        if len(matches) == 1:
            related = matches[0]["request"]
    attachment = store.db.execute("SELECT kind,mime,path,caption,filename,voice,transcript,extracted FROM attachments WHERE request=? AND status='ready'",
                                  (request,)).fetchone()
    attachment = dict(attachment) if attachment else None
    if attachment:
        attachment["voice"] = bool(attachment["voice"])
        attachment["extracted_text"] = attachment.pop("extracted")
        details = store.db.execute("SELECT details FROM attachment_details WHERE request=?", (request,)).fetchone()
        if details:
            attachment.update(json.loads(details["details"]))
    return {"schema": "fm-whatsapp-context.v1", "request": request,
            "text": row["body"], "state": row["state"], "related_request": related,
            "attachment": attachment,
            "input_scope": "interpret_attachment" if attachment else "text",
            "history": store.rows("SELECT request,body,state,kind FROM inbound WHERE sender=? AND kind IN ('text','image','audio','document','video') AND state NOT IN ('historical','quarantined','invalid','media_pending') ORDER BY received DESC,rowid DESC LIMIT 10",
                                  (store.config.creator,)),
            "responses": store.rows("SELECT request,kind,body,actor FROM responses ORDER BY at DESC,rowid DESC LIMIT 10"),
            "tasks": store.rows("SELECT * FROM task_refs"),
            "decisions": store.rows("SELECT id,request,home,task,revision,action,expires,state,answer_wamid FROM decisions WHERE state!='consumed'")}


def dispatch(store, data):
    actor = auth(store.config, "owned")
    operation = data.get("op")
    if operation == "pending":
        return store.rows("SELECT request,note_id,state FROM inbound WHERE state IN ('queued','claimed','started','decision','blocked','received') AND sender=?",
                          (store.config.creator,))
    if operation == "claim":
        request = data["request"]
        with store.tx():
            row = store.request(request)
            if not row["note_id"] or row["note_id"] != data["note_id"]:
                raise BridgeError("note/request binding mismatch")
            note = store.config.home / "state" / "inbox" / (row["note_id"] + ".note")
            handled = note.parent / "handled" / note.name
            path = note if note.exists() else handled
            if not path.is_file() or path.is_symlink():
                raise BridgeError("canonical note missing; restore it before claiming")
            record = path.read_text()
            header, _, body = record.partition("\n--\n")
            if "external_key=" + request not in header.splitlines() or body.rstrip("\n") != row["envelope"]:
                raise BridgeError("canonical note content mismatch")
            fresh = row["state"] in ("received", "queued")
            if fresh:
                store.db.execute("UPDATE inbound SET state='claimed' WHERE request=?", (request,))
        result = context(store, request)
        result["fresh_claim"] = fresh
        return result
    if operation == "consume-decision":
        if not Path(data.get("home", "")).is_absolute():
            raise BridgeError("decision home must be absolute")
        data = {**data, "home": str(Path(data["home"]).resolve())}
        with store.tx():
            row = store.db.execute("SELECT * FROM decisions WHERE id=?", (data["id"],)).fetchone()
            if row is None:
                raise BridgeError("unknown decision")
            fields = ("request", "home", "task", "revision", "action")
            if any(data.get(k) != row[k] for k in fields):
                raise BridgeError("decision tuple mismatch")
            if row["state"] == "consumed":
                return {"id": row["id"], "new_consumption": False, "consumed_at": row["consumed"]}
            if row["state"] != "answered" or row["expires"] < store.now():
                raise BridgeError("decision is unanswered, stale or expired")
            binding = task_binding({"home": row["home"], "id": row["task"], "revision": row["revision"]})
            if binding[3] != row["fingerprint"]:
                raise BridgeError("canonical task changed; issue a fresh decision")
            answer = store.db.execute("SELECT * FROM inbound WHERE wamid=?", (row["answer_wamid"],)).fetchone()
            if not answer or answer["sender"] != store.config.creator or answer["kind"] != "text":
                raise BridgeError("decision lacks authenticated owner text")
            store.db.execute("UPDATE decisions SET state='consumed',consumed=? WHERE id=?", (store.now(), row["id"]))
            return {"id": row["id"], "new_consumption": True, "request": row["request"],
                    "task": row["task"], "revision": row["revision"], "action": row["action"],
                    "answer_request": answer["request"]}
    if operation != "emit":
        raise BridgeError("unknown main operation")
    request, event, kind, body = data["request"], data["event"], data["kind"], data["body"]
    if kind not in KINDS:
        raise BridgeError("invalid typed response kind")
    payload = {"schema": "fm-whatsapp-response.v1", **data}
    with store.tx():
        row = store.request(request)
        old = store.db.execute("SELECT payload FROM responses WHERE event=?", (event,)).fetchone()
        if old:
            from fm_whatsapp_store import encode
            if old["payload"] != encode(payload):
                raise BridgeError("event id reused with different response")
            return {"event": event, "new_event": False}
        if row["state"] in ("received", "queued", "answered"):
            raise BridgeError("claim canonical request before reporting work")
        if row["state"] in TERMINAL:
            raise BridgeError("terminal request cannot receive another outcome")
        binding = task_binding(data["task"]) if data.get("task") else None
        if kind in ("started", "progress", "decision") and binding is None:
            raise BridgeError("work event requires a canonical task reference")
        if kind == "completed" and (not isinstance(data.get("evidence"), list) or
                                    not data["evidence"] or not all(isinstance(x, str) and x.strip() for x in data["evidence"])):
            raise BridgeError("completion requires explicit result evidence")
        if binding:
            store.db.execute("INSERT OR REPLACE INTO task_refs VALUES(?,?,?,?,?)", (request, *binding))
        decision_id = None
        if kind == "decision":
            action = data["action"]
            if not isinstance(action, str) or not action.strip() or len(action) > 4000:
                raise BridgeError("decision requires a concrete action")
            expires = data["expires"]
            now = store.now()
            if type(expires) not in (int, float) or not now < expires <= now + 86400:
                raise BridgeError("decision validity must be within 24 hours")
            decision_id = digest([event, request, binding, action, expires])[:16]
            store.db.execute("UPDATE decisions SET state='superseded' WHERE request=? AND home=? AND task=? AND state IN ('pending','answered')",
                              (request, binding[0], binding[1]))
            store.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                              (decision_id, request, binding[0], binding[1], binding[2], action,
                               binding[3], expires, "pending", None, None))
            body += f"\nAção: {action}\nRevisão: {binding[2]}\nPara autorizar esta ação, responda: aprovar {decision_id}"
        store.emit(event, request, kind, body, actor, payload)
        next_state = {"progress": "started", "reply": "answered"}.get(kind, kind)
        if next_state in TERMINAL:
            store.db.execute("UPDATE decisions SET state='superseded' WHERE request=? AND state IN ('pending','answered')",
                              (request,))
        store.db.execute("UPDATE inbound SET state=? WHERE request=?", (next_state, request))
    return {"event": event, "new_event": True, "decision": decision_id}
