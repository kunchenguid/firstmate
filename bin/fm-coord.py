#!/usr/bin/env python3
"""Local SQLite authority for the advisory coordination protocol in docs/coordination.md."""

import hashlib
import fcntl
import hmac
import json
import os
from pathlib import Path
import pwd
import re
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote
import uuid
from datetime import datetime, timezone


SCHEMA_DIR = Path(__file__).with_name("fm-coord-migrations")
MUTATIONS = {"enroll", "session", "area-set", "migration-seed", "submit", "claim", "amend", "renew", "release", "reserve", "publish-head", "attach-pr", "ack", "manifest-set", "predecessors-set", "queue-ready", "queue-next", "queue-synced", "queue-validated", "queue-checks", "queue-attempt", "queue-result", "queue-reconcile", "queue-abort", "queue-operator-abort", "queue-wrapper-exited", "pulse-batch", "ci-capacity-set", "ci-complete"}
PATH_KINDS = {"file", "directory", "dependency-manifest", "generated-output"}
NAMED_KINDS = {"issue", "schema-object", "migration-sequence", "integration"}
OID = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)\Z")
RECOVERY_GAP = 10
CI_SLOT_TTL_SECONDS = 3600


class Refusal(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def boot_id():
    linux = Path("/proc/sys/kernel/random/boot_id")
    if linux.exists():
        return linux.read_text(encoding="ascii").strip()
    if sys.platform == "darwin":
        result = subprocess.run(["sysctl", "-n", "kern.bootsessionuuid"], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    raise Refusal("boot identity unavailable; only macOS and Linux are supported")


def local_host_id():
    linux = Path("/etc/machine-id")
    if linux.exists():
        value = linux.read_text(encoding="ascii", errors="replace").strip()
        require(re.fullmatch(r"[0-9a-f]{32}", value) is not None, "machine identity unavailable; /etc/machine-id is empty, uninitialized, or malformed")
        return "machine:" + value
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, check=True)
        except (OSError, subprocess.CalledProcessError):
            raise Refusal("machine identity unavailable; ioreg failed")
        match = re.search(r'"IOPlatformUUID" = "([0-9A-Fa-f-]+)"', result.stdout)
        require(match is not None, "machine identity unavailable")
        return "machine:" + match.group(1)
    raise Refusal("machine identity unavailable; /etc/machine-id or macOS IOPlatformUUID is required")


def process_start(pid):
    if Path("/proc/self/stat").exists():
        try:
            return Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()[19]
        except FileNotFoundError:
            return None
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True)
    start = result.stdout.strip()
    require(result.returncode == 0 or not start and not result.stderr.strip(), "process identity cannot be checked")
    return start or None


def token(value, field):
    require(isinstance(value, str) and 0 < len(value) <= 256 and not any(ord(c) < 32 for c in value), f"{field} must be a nonempty printable string")
    return value


def authority_hash():
    value = os.environ.get("FM_COORD_AUTHORITY_TOKEN")
    if value is None:
        return None
    token(value, "FM_COORD_AUTHORITY_TOKEN")
    require(len(value) >= 32, "FM_COORD_AUTHORITY_TOKEN must be at least 32 characters")
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def authority_identity():
    uid = os.geteuid()
    try:
        account = pwd.getpwuid(uid).pw_name
    except KeyError:
        account = "uid"
    return f"@authority:{account}:{uid}"


def authority_actor(db, payload):
    require("home_id" not in payload, "operator abort requires the @authority actor")
    require("operator" not in payload, "operator identity comes from the authenticated actor")
    credential = authority_hash()
    enrolled = db.execute("SELECT value FROM meta WHERE key='authority_token_sha256'").fetchone()
    require(credential is not None and enrolled is not None and hmac.compare_digest(credential, enrolled[0]), "enrolled authority credential required")
    return authority_identity()


def path(value):
    token(value, "path")
    require(not value.startswith("/") and "\\" not in value and "\x00" not in value, "path must be repository-relative POSIX syntax")
    parts = [part for part in value.split("/") if part not in ("", ".")]
    require(parts and all(part != ".." for part in parts), "path cannot escape repository root")
    return "/".join(parts)


def pr_url(value, repo):
    match = PR_URL.fullmatch(token(value, "pr_url"))
    require(match is not None, "pr_url must be https://github.com/<owner>/<repo>/pull/<number>")
    require(match.group(1) == repo, "pr_url must belong to the intent repository")
    return value


def resources(db, repo, declared):
    require(isinstance(declared, list) and declared, "resources must be a nonempty array")
    result = set()
    for item in declared:
        require(isinstance(item, dict) and isinstance(item.get("type"), str), "resource must have a type")
        kind = item["type"]
        if kind == "rename":
            result.add(("directory", path(item.get("from"))))
            result.add(("directory", path(item.get("to"))))
        elif kind == "area":
            alias = token(item.get("name"), "area name")
            row = db.execute("SELECT name FROM area_aliases WHERE repo=? AND alias=?", (repo, alias)).fetchone()
            require(row is not None, f"unknown area alias: {alias}")
            name = row[0]
            result.add(("area", name))
            definition = db.execute("SELECT paths_json FROM areas WHERE repo=? AND name=?", (repo, name)).fetchone()
            for prefix in json.loads(definition[0]):
                result.add(("directory", prefix))
        elif kind in PATH_KINDS:
            result.add(("file" if kind in {"dependency-manifest", "generated-output"} else kind, path(item.get("name"))))
        elif kind in NAMED_KINDS:
            result.add((kind, token(item.get("name"), "resource name")))
        else:
            raise Refusal(f"unsupported resource type: {kind}")
    return sorted(result)


def overlap(a, b):
    ak, av = a
    bk, bv = b
    if ak in {"file", "directory"} and bk in {"file", "directory"}:
        if av == bv:
            return True
        return (ak == "directory" and bv.startswith(av + "/")) or (bk == "directory" and av.startswith(bv + "/"))
    return ak == bk and av == bv


def emit(db, event_type, request_id, payload):
    event_id = str(uuid.uuid4())
    db.execute("INSERT INTO events(event_id,event_type,request_id,payload_json,created_at) VALUES(?,?,?,?,?)", (event_id, event_type, request_id, compact(payload), stamp()))
    db.execute("INSERT INTO outbox(event_id) VALUES(?)", (event_id,))
    return event_id


def authority_seq(db):
    return db.execute("SELECT COALESCE(MAX(seq),0) FROM events").fetchone()[0]


def check_authority(db, identity, anchor_path):
    require(anchor_path.is_file(), "authority recovery marker is absent; manual fenced recovery required")
    anchor = json.loads(anchor_path.read_text(encoding="utf-8"))
    require(anchor.get("authority_id") == identity and type(anchor.get("highwater_seq")) is int, "authority recovery marker disagrees with database")
    require(anchor.get("pending") is not True, "authority marker records an interrupted transaction; manual fenced recovery required")
    require(authority_seq(db) >= anchor["highwater_seq"], "restored database is older than authority marker; manual fenced recovery required")


def highwater(db):
    return {"generations": {row["home_id"]: row["generation"] for row in db.execute("SELECT home_id,generation FROM participants")},
            "allocation_counters": [list(row) for row in db.execute("SELECT repo,namespace,next_number FROM allocation_counters ORDER BY repo,namespace")],
            "integration_generations": [list(row) for row in db.execute("SELECT repo,base_ref,generation FROM integration_generations ORDER BY repo,base_ref")],
            "ci_batches": [list(row) for row in db.execute("SELECT repo,base_ref,batch_id FROM ci_batches UNION SELECT repo,base_ref,batch_id FROM fenced_ci_batches ORDER BY 1,2,3")]}


def seal_authority(db, db_path, identity, anchor_path, force=False, pending=False):
    if anchor_path.exists():
        if not force:
            check_authority(db, identity, anchor_path)
        prior = json.loads(anchor_path.read_text(encoding="utf-8"))
    else:
        prior = {}
    marker = {"authority_id": identity, "highwater_seq": authority_seq(db), **highwater(db), "pending": pending}
    if not force and marker == prior:
        return
    write_marker(db_path, anchor_path, marker)


def write_marker(db_path, anchor_path, marker):
    fd, name = tempfile.mkstemp(prefix=".authority-", dir=Path(db_path).parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(compact(marker) + "\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, anchor_path)
        directory = os.open(Path(db_path).parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def revoke(db, claim, state, reason):
    item = db.execute("SELECT * FROM queue_items WHERE intent_id=?", (claim["intent_id"],)).fetchone()
    if item is not None and item["state"] in {"ready", "syncing", "validating", "awaiting-checks", "sync-needed", "repair-needed"}:
        slot = db.execute("SELECT * FROM integration_slots WHERE repo=? AND base_ref=? AND intent_id=?", (item["repo"], item["base_ref"], item["intent_id"])).fetchone()
        if slot is not None:
            require(slot["state"] in {"syncing", "validating", "awaiting-checks"}, "cannot revoke an unsettled merge slot")
            db.execute("DELETE FROM integration_slots WHERE repo=? AND base_ref=? AND intent_id=?", (item["repo"], item["base_ref"], item["intent_id"]))
            emit(db, "slot-claim-revoked", None, {"intent_id": item["intent_id"], "claim_id": claim["claim_id"], "generation": slot["generation"], "prior_state": item["state"], "reason": reason})
        db.execute("UPDATE queue_items SET state='repair-needed',base_oid=NULL,validation_id=NULL,manifest_version=NULL,updated_at=? WHERE intent_id=?", (stamp(), item["intent_id"]))
    db.execute("UPDATE claims SET state=? WHERE claim_id=? AND state='active'", (state, claim["claim_id"]))
    db.execute("DELETE FROM branch_owners WHERE claim_id=?", (claim["claim_id"],))
    db.execute("UPDATE intents SET state=? WHERE intent_id=?", (state, claim["intent_id"]))
    emit(db, "lease-" + state, None, {"claim_id": claim["claim_id"], "fence": claim["fence"], "reason": reason})


def reconcile_clock(db, current_boot):
    stored = db.execute("SELECT value FROM meta WHERE key='boot_id'").fetchone()[0]
    if stored != current_boot:
        for claim in db.execute("SELECT * FROM claims WHERE state='active'").fetchall():
            revoke(db, claim, "revoked", "coordinator reboot")
        db.execute("UPDATE participants SET generation=generation+1, boot_id=NULL, session_id=NULL")
        db.execute("UPDATE meta SET value=? WHERE key='boot_id'", (current_boot,))
        emit(db, "authority-boot-changed", None, {"boot_id": current_boot})
    now = time.monotonic_ns()
    for claim in db.execute("SELECT * FROM claims WHERE state='active' AND expires_mono_ns<=?", (now,)).fetchall():
        revoke(db, claim, "expired", "lease deadline")


def participant(db, payload, repo=None):
    home = token(payload.get("home_id"), "home_id")
    row = db.execute("SELECT * FROM participants WHERE home_id=?", (home,)).fetchone()
    require(row is not None, "home is not enrolled")
    require(row["generation"] > 0 and row["boot_id"] == boot_id() and row["generation"] == payload.get("generation"), "expired session generation")
    if repo is not None:
        require(repo in json.loads(row["repos_json"]), "repository outside participant scope")
    return row


def active_claim(db, payload, intent=None):
    row = db.execute("SELECT * FROM claims WHERE claim_id=?", (token(payload.get("claim_id"), "claim_id"),)).fetchone()
    require(row is not None and row["state"] == "active", "claim is not active")
    require(row["fence"] == payload.get("fence"), "expired claim fence")
    require(row["home_id"] == payload.get("home_id") and row["generation"] == payload.get("generation"), "claim holder or generation mismatch")
    require(row["boot_id"] == boot_id() and row["expires_mono_ns"] > time.monotonic_ns(), "claim lease expired")
    participant(db, payload)
    if intent is not None:
        require(row["intent_id"] == intent["intent_id"] and row["version"] == intent["version"], "intent version mismatch")
    return row


def conflicts(db, repo, candidate, exclude=None):
    found = []
    rows = db.execute("SELECT c.claim_id,c.intent_id,c.home_id,r.kind,r.name FROM claims c JOIN intents i ON i.intent_id=c.intent_id JOIN claim_resources r ON r.claim_id=c.claim_id WHERE c.state='active' AND i.repo=?", (repo,)).fetchall()
    for row in rows:
        if row["claim_id"] != exclude and any(overlap(item, (row["kind"], row["name"])) for item in candidate):
            owner = {"claim_id": row["claim_id"], "intent_id": row["intent_id"], "predecessor_intent_id": row["intent_id"], "home_id": row["home_id"], "resource": {"type": row["kind"], "name": row["name"]}}
            if owner not in found:
                found.append(owner)
    return found


def oid(value, field):
    require(isinstance(value, str) and OID.fullmatch(value) is not None, f"{field} must be a full Git object ID")
    return value.lower()


def predecessors(db, intent, values):
    require(isinstance(values, list) and all(isinstance(value, str) for value in values), "predecessors must be a string array")
    require(len(values) == len(set(values)), "predecessors must be a unique array")
    for predecessor in values:
        token(predecessor, "predecessor")
        require(predecessor != intent["intent_id"], "dependency cycle")
        row = db.execute("SELECT repo,base_ref FROM intents WHERE intent_id=?", (predecessor,)).fetchone()
        require(row is not None and row["repo"] == intent["repo"] and row["base_ref"] == intent["base_ref"], "predecessor must exist on the same repository and base")
        stack = [predecessor]
        visited = set()
        while stack:
            current = stack.pop()
            if current == intent["intent_id"]:
                raise Refusal("dependency cycle")
            if current in visited:
                continue
            visited.add(current)
            prior = db.execute("SELECT predecessors_json FROM intents WHERE intent_id=?", (current,)).fetchone()
            stack.extend(json.loads(prior[0]))
    return sorted(values)


def queue_item(db, p, owner=True):
    intent_id = token(p.get("intent_id"), "intent_id")
    item = db.execute("SELECT * FROM queue_items WHERE intent_id=?", (intent_id,)).fetchone()
    require(item is not None, "intent is not queued")
    intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
    if owner:
        participant(db, p, intent["repo"])
        require(intent["home_id"] == p["home_id"] and intent["generation"] == p["generation"], "intent holder or generation mismatch")
        active_claim(db, p, intent)
    return item, intent


def occupied_slot(db, item):
    slot = db.execute("SELECT * FROM integration_slots WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"])).fetchone()
    require(slot is not None and slot["intent_id"] == item["intent_id"], "integration slot is not held by this intent")
    return slot


def invalidate(db, item, request_id, reason, repair=False):
    state = "repair-needed" if repair else "sync-needed"
    db.execute("DELETE FROM integration_slots WHERE repo=? AND base_ref=? AND intent_id=?", (item["repo"], item["base_ref"], item["intent_id"]))
    db.execute("UPDATE queue_items SET state=?,base_oid=NULL,validation_id=NULL,manifest_version=NULL,attempt_event_id=NULL,updated_at=? WHERE intent_id=?", (state, stamp(), item["intent_id"]))
    event_id = emit(db, "validation-invalidated", request_id, {"intent_id": item["intent_id"], "reason": reason, "state": state})
    return {"ok": False, "state": state, "reason": reason, "event_id": event_id}


def evidence_fresh(db, item, p, request_id):
    current_head = oid(p.get("current_head_oid"), "current_head_oid")
    current_base = oid(p.get("current_base_oid"), "current_base_oid")
    latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (item["intent_id"],)).fetchone()
    if latest is None or latest[0] != item["head_oid"] or current_head != item["head_oid"]:
        return invalidate(db, item, request_id, "head changed")
    if item["base_oid"] is not None and current_base != item["base_oid"]:
        return invalidate(db, item, request_id, "base advanced")
    return None


def terminal_outcome(db, item, request_id, outcome, p):
    attempt = item["attempt_event_id"]
    require(attempt is not None, "no recorded merge attempt")
    prior = db.execute("SELECT * FROM merge_outcomes WHERE attempt_event_id=?", (attempt,)).fetchone()
    require(prior is None, "merge attempt already has a terminal outcome")
    observed_base = oid(p.get("observed_base_oid"), "observed_base_oid")
    merge_oid = None
    forge = p.get("_forge_outcome")
    if forge is not None:
        require(forge == outcome and p.get("pr_url") == db.execute("SELECT pr_url FROM intents WHERE intent_id=?", (item["intent_id"],)).fetchone()[0] and p.get("base") == item["base_ref"], "forge observation is for a different PR or base")
    if outcome == "merged":
        require(forge == "merged" and p.get("merged_head_oid") == item["head_oid"], "live forge read must prove the exact head landed")
        merge_oid = oid(p.get("merge_oid"), "merge_oid")
        require(observed_base != item["base_oid"], "merged base must advance")
    else:
        require(forge == "refused", "live forge read must prove the attempted head did not land")
        require(p.get("_unlanded_head_oid") == item["head_oid"], "live forge read must prove the attempted head is not on base")
        require(p.get("_settled_attempt") == item["attempt_event_id"], "merge wrapper was not proven gone before the forge reads")
    db.execute("INSERT INTO merge_outcomes(attempt_event_id,intent_id,outcome,merge_oid,observed_base_oid,recorded_at) VALUES(?,?,?,?,?,?)", (attempt, item["intent_id"], outcome, merge_oid, observed_base, stamp()))
    db.execute("DELETE FROM integration_slots WHERE repo=? AND base_ref=? AND intent_id=?", (item["repo"], item["base_ref"], item["intent_id"]))
    db.execute("UPDATE queue_items SET state=?,updated_at=? WHERE intent_id=?", (outcome, stamp(), item["intent_id"]))
    event_id = emit(db, "merge-" + outcome, request_id, {"intent_id": item["intent_id"], "attempt_event_id": attempt, "merge_oid": merge_oid, "observed_base_oid": observed_base})
    return {"ok": True, "state": outcome, "attempt_event_id": attempt, "event_id": event_id}


def queue_operation(db, op, p):
    request_id = p.get("request_id")
    if op == "manifest-set":
        repo, base = token(p.get("repo"), "repo"), token(p.get("base"), "base")
        checks = p.get("checks")
        require(isinstance(checks, list) and checks and all(isinstance(x, str) and x.strip() == x and x for x in checks) and len(checks) == len(set(checks)), "required checks must be a nonempty unique name array")
        require(db.execute("SELECT 1 FROM integration_slots WHERE repo=? AND base_ref=?", (repo, base)).fetchone() is None, "cannot change checks while slot is held")
        row = db.execute("SELECT version FROM check_manifests WHERE repo=? AND base_ref=?", (repo, base)).fetchone()
        version = row[0] + 1 if row else 1
        db.execute("INSERT INTO check_manifests(repo,base_ref,version,checks_json) VALUES(?,?,?,?) ON CONFLICT(repo,base_ref) DO UPDATE SET version=excluded.version,checks_json=excluded.checks_json", (repo, base, version, compact(sorted(checks))))
        event_id = emit(db, "check-manifest-set", request_id, {"repo": repo, "base": base, "version": version})
        return {"ok": True, "version": version, "event_id": event_id}
    if op == "predecessors-set":
        intent_id = token(p.get("intent_id"), "intent_id")
        intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
        require(intent is not None, "intent does not exist")
        participant(db, p, intent["repo"])
        require(intent["home_id"] == p["home_id"] and intent["generation"] == p["generation"], "intent holder or generation mismatch")
        require(db.execute("SELECT 1 FROM queue_items WHERE intent_id=?", (intent_id,)).fetchone() is None, "queued dependencies are immutable")
        values = predecessors(db, intent, p.get("predecessors"))
        db.execute("UPDATE intents SET predecessors_json=? WHERE intent_id=?", (compact(values), intent_id))
        event_id = emit(db, "predecessors-set", request_id, {"intent_id": intent_id, "predecessors": values})
        return {"ok": True, "predecessors": values, "event_id": event_id}
    if op == "queue-ready":
        intent_id = token(p.get("intent_id"), "intent_id")
        intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
        require(intent is not None and intent["state"] == "claimed" and intent["pr_url"], "intent needs a live claim and attached PR")
        pr_url(intent["pr_url"], intent["repo"])
        participant(db, p, intent["repo"])
        require(intent["home_id"] == p["home_id"] and intent["generation"] == p["generation"], "intent holder or generation mismatch")
        active_claim(db, p, intent)
        head = oid(p.get("head_oid"), "head_oid")
        latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (intent_id,)).fetchone()
        require(latest is not None and latest[0] == head, "ready head is not the latest published head")
        existing = db.execute("SELECT state FROM queue_items WHERE intent_id=?", (intent_id,)).fetchone()
        require(existing is None or existing[0] in {"sync-needed", "repair-needed", "refused"}, "intent is already queued")
        priority = p.get("priority", 0)
        require(type(priority) is int and 0 <= priority <= 9, "priority must be 0..9")
        require(predecessors(db, intent, json.loads(intent["predecessors_json"])) == sorted(json.loads(intent["predecessors_json"])), "invalid predecessors")
        db.execute("INSERT INTO queue_items(intent_id,repo,base_ref,head_oid,state,priority,ready_epoch,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(intent_id) DO UPDATE SET head_oid=excluded.head_oid,state='ready',priority=excluded.priority,ready_epoch=excluded.ready_epoch,base_oid=NULL,validation_id=NULL,manifest_version=NULL,attempt_event_id=NULL,attempt_epoch=NULL,wrapper_pid=NULL,wrapper_start=NULL,wrapper_boot=NULL,wrapper_home_id=NULL,wrapper_host_id=NULL,wrapper_local=NULL,wrapper_exit_attested_at=NULL,updated_at=excluded.updated_at", (intent_id, intent["repo"], intent["base_ref"], head, "ready", priority, int(time.time()), stamp()))
        event_id = emit(db, "queue-ready", request_id, {"intent_id": intent_id, "head_oid": head, "priority": priority})
        return {"ok": True, "state": "ready", "event_id": event_id}
    if op == "queue-next":
        repo, base = token(p.get("repo"), "repo"), token(p.get("base"), "base")
        require(db.execute("SELECT 1 FROM integration_slots WHERE repo=? AND base_ref=?", (repo, base)).fetchone() is None, "integration slot is occupied")
        now = int(time.time())
        candidates = db.execute("SELECT q.*,i.predecessors_json,i.home_id,i.generation AS owner_generation,i.version FROM queue_items q JOIN intents i ON i.intent_id=q.intent_id WHERE q.repo=? AND q.base_ref=? AND q.state='ready'", (repo, base)).fetchall()
        ready = []
        for candidate in candidates:
            claim = db.execute("SELECT 1 FROM claims WHERE intent_id=? AND state='active' AND version=? AND generation=? AND expires_mono_ns>? AND boot_id=?", (candidate["intent_id"], candidate["version"], candidate["owner_generation"], time.monotonic_ns(), boot_id())).fetchone()
            latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (candidate["intent_id"],)).fetchone()
            if claim is None or latest is None or latest[0] != candidate["head_oid"]:
                continue
            if all(db.execute("SELECT state FROM queue_items WHERE intent_id=?", (dep,)).fetchone() and db.execute("SELECT state FROM queue_items WHERE intent_id=?", (dep,)).fetchone()[0] == "merged" for dep in json.loads(candidate["predecessors_json"])):
                ready.append(candidate)
        if not ready:
            return {"ok": False, "reason": "no dependency-safe ready item"}
        aging_seconds = int(os.environ.get("FM_COORD_AGING_SECONDS", "60"))
        require(aging_seconds > 0, "aging interval must be positive")
        chosen = min(ready, key=lambda x: (-(x["priority"] + max(0, now - x["ready_epoch"]) // aging_seconds), x["ready_epoch"], x["intent_id"]))
        row = db.execute("SELECT generation FROM integration_generations WHERE repo=? AND base_ref=?", (repo, base)).fetchone()
        generation = row[0] + 1 if row else 1
        db.execute("INSERT INTO integration_generations(repo,base_ref,generation) VALUES(?,?,?) ON CONFLICT(repo,base_ref) DO UPDATE SET generation=excluded.generation", (repo, base, generation))
        db.execute("INSERT INTO integration_slots(repo,base_ref,intent_id,generation,state) VALUES(?,?,?,?,'syncing')", (repo, base, chosen["intent_id"], generation))
        db.execute("UPDATE queue_items SET state='syncing',updated_at=? WHERE intent_id=?", (stamp(), chosen["intent_id"]))
        event_id = emit(db, "sync-requested", request_id, {"intent_id": chosen["intent_id"], "generation": generation, "head_oid": chosen["head_oid"]})
        return {"ok": True, "intent_id": chosen["intent_id"], "generation": generation, "state": "syncing", "event_id": event_id}
    item, intent = queue_item(db, p, owner=op not in {"queue-result", "queue-reconcile", "queue-abort", "queue-operator-abort", "queue-wrapper-exited"})
    slot = occupied_slot(db, item)
    require(p.get("generation") == slot["generation"] if op in {"queue-result", "queue-reconcile", "queue-operator-abort"} else p.get("slot_generation") == slot["generation"], "integration generation mismatch")
    if op == "queue-abort":
        require(item["state"] in {"syncing", "validating", "awaiting-checks"}, "forge attempt cannot be aborted")
        reason = token(p.get("reason"), "reason")
        return invalidate(db, item, request_id, reason, repair=p.get("repair_needed") is True)
    if op == "queue-operator-abort":
        require(item["state"] == "outcome-unknown", "operator abort is limited to an unknown forge outcome")
        reason = token(p.get("reason"), "reason")
        db.execute("DELETE FROM integration_slots WHERE repo=? AND base_ref=? AND intent_id=?", (item["repo"], item["base_ref"], item["intent_id"]))
        db.execute("UPDATE queue_items SET state='repair-needed',updated_at=? WHERE intent_id=?", (stamp(), item["intent_id"]))
        event_id = emit(db, "slot-operator-aborted", request_id, {"intent_id": item["intent_id"], "attempt_event_id": item["attempt_event_id"], "operator": p["_authority_actor"], "reason": reason})
        return {"ok": True, "state": "repair-needed", "event_id": event_id}
    if op == "queue-wrapper-exited":
        require(item["state"] in {"attempting", "outcome-unknown"} and item["wrapper_local"] == 0, "remote wrapper exit attestation requires an unsettled remote attempt")
        participant(db, p, intent["repo"])
        require(p.get("home_id") == item["wrapper_home_id"], "wrapper exit must come from the owning participant session")
        owner = db.execute("SELECT host_id FROM participants WHERE home_id=?", (p["home_id"],)).fetchone()
        require(owner is not None and owner["host_id"] == item["wrapper_host_id"], "participant host changed")
        require(p.get("attempt_event_id") == item["attempt_event_id"], "wrapper exit attempt identity mismatch")
        require(p.get("wrapper_host_id") == item["wrapper_host_id"] and p.get("wrapper_pid") == item["wrapper_pid"] and p.get("wrapper_start") == item["wrapper_start"], "wrapper exit process identity mismatch")
        require(item["wrapper_exit_attested_at"] is None, "wrapper exit is already attested")
        exited_at = int(time.time())
        db.execute("UPDATE queue_items SET wrapper_exit_attested_at=?,updated_at=? WHERE intent_id=?", (exited_at, stamp(), item["intent_id"]))
        event_id = emit(db, "wrapper-exit-attested", request_id, {"intent_id": item["intent_id"], "attempt_event_id": item["attempt_event_id"], "home_id": p["home_id"], "host_id": item["wrapper_host_id"], "pid": item["wrapper_pid"], "start": item["wrapper_start"], "exited_at": exited_at})
        return {"ok": True, "state": item["state"], "event_id": event_id}
    if op == "queue-synced":
        require(item["state"] == "syncing", "slot is not syncing")
        current_head = oid(p.get("current_head_oid"), "current_head_oid")
        current_base = oid(p.get("current_base_oid"), "current_base_oid")
        latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (item["intent_id"],)).fetchone()
        if current_head != item["head_oid"] or latest[0] != item["head_oid"]:
            return invalidate(db, item, request_id, "head changed")
        require(p.get("head_contains_base") is True, "current head must contain current base")
        db.execute("UPDATE queue_items SET state='validating',base_oid=?,updated_at=? WHERE intent_id=?", (current_base, stamp(), item["intent_id"]))
        db.execute("UPDATE integration_slots SET state='validating' WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"]))
        event_id = emit(db, "sync-completed", request_id, {"intent_id": item["intent_id"], "base_oid": current_base, "head_oid": current_head})
        return {"ok": True, "state": "validating", "event_id": event_id}
    if op in {"queue-validated", "queue-checks", "queue-attempt"}:
        require(item["state"] == {"queue-validated": "validating", "queue-checks": "awaiting-checks", "queue-attempt": "awaiting-checks"}[op], "slot is in the wrong phase")
        stale = evidence_fresh(db, item, p, request_id)
        if stale:
            return stale
    if op == "queue-validated":
        require(p.get("validation_passed") is True, "final validation has not passed")
        validation_id = token(p.get("validation_id"), "validation_id")
        db.execute("UPDATE queue_items SET state='awaiting-checks',validation_id=?,updated_at=? WHERE intent_id=?", (validation_id, stamp(), item["intent_id"]))
        db.execute("UPDATE integration_slots SET state='awaiting-checks' WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"]))
        event_id = emit(db, "validation-passed", request_id, {"intent_id": item["intent_id"], "validation_id": validation_id})
        return {"ok": True, "state": "awaiting-checks", "event_id": event_id}
    if op == "queue-checks":
        manifest = db.execute("SELECT * FROM check_manifests WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"])).fetchone()
        require(manifest is not None, "repo-owned required-check manifest is absent")
        require(type(p.get("protection_available")) is bool, "forge protection visibility must be explicit")
        forge_required = p.get("forge_required_checks", []) if p["protection_available"] else []
        require(isinstance(forge_required, list) and all(isinstance(x, str) for x in forge_required), "forge required checks are unreadable")
        required = set(json.loads(manifest["checks_json"])) | set(forge_required)
        rollup = p.get("checks")
        require(isinstance(rollup, list), "check rollup is unreadable")
        require(all(isinstance(check, dict) and isinstance(check.get("name"), str) for check in rollup), "check rollup contains an unreadable check")
        names = [check["name"] for check in rollup]
        require(len(names) == len(set(names)), "check rollup must contain one current result per check name")
        green = {check["name"] for check in rollup if check.get("head_oid") == item["head_oid"] and check.get("conclusion") == "success"}
        missing = sorted(required - green)
        require(not missing, "required checks missing or non-green: " + ", ".join(missing))
        db.execute("UPDATE queue_items SET manifest_version=?,updated_at=? WHERE intent_id=?", (manifest["version"], stamp(), item["intent_id"]))
        event_id = emit(db, "checks-passed", request_id, {"intent_id": item["intent_id"], "manifest_version": manifest["version"], "required": sorted(required)})
        return {"ok": True, "state": "awaiting-checks", "manifest_version": manifest["version"], "event_id": event_id}
    if op == "queue-attempt":
        manifest = db.execute("SELECT version FROM check_manifests WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"])).fetchone()
        require(manifest is not None and item["manifest_version"] == manifest[0], "required-check evidence is absent or stale")
        require(p.get("captain_hold_released") is True and p.get("away_merge_allowed") is True and p.get("merge_authorized") is True, "captain hold, away posture, or merge authority refuses attempt")
        require(p.get("head_contains_base") is True, "current head no longer contains current base")
        wrapper_pid = p.get("wrapper_pid")
        require(type(wrapper_pid) is int and wrapper_pid > 0, "wrapper_pid must be a positive integer")
        owner = db.execute("SELECT host_id FROM participants WHERE home_id=?", (intent["home_id"],)).fetchone()
        require(owner is not None and owner["host_id"] is not None, "participant host_id must be enrolled before a merge attempt")
        wrapper_host_id = owner["host_id"]
        local_wrapper = wrapper_host_id == local_host_id()
        if local_wrapper:
            wrapper_start = process_start(wrapper_pid)
            require(wrapper_start is not None, "wrapper process is not running")
            require(p.get("wrapper_start") is None or p["wrapper_start"] == wrapper_start, "wrapper start time mismatch")
        else:
            wrapper_start = token(p.get("wrapper_start"), "wrapper_start")
        event_id = emit(db, "merge-attempted", request_id, {"intent_id": item["intent_id"], "head_oid": item["head_oid"], "base_oid": item["base_oid"], "pr_url": intent["pr_url"], "wrapper": "bin/fm-pr-merge.sh", "wrapper_home_id": intent["home_id"], "wrapper_host_id": wrapper_host_id, "wrapper_pid": wrapper_pid, "wrapper_start": wrapper_start})
        db.execute("UPDATE queue_items SET state='attempting',attempt_event_id=?,attempt_epoch=?,wrapper_pid=?,wrapper_start=?,wrapper_boot=?,wrapper_home_id=?,wrapper_host_id=?,wrapper_local=?,wrapper_exit_attested_at=NULL,updated_at=? WHERE intent_id=?", (event_id, int(time.time()), wrapper_pid, wrapper_start, boot_id() if local_wrapper else None, intent["home_id"], wrapper_host_id, 1 if local_wrapper else 0, stamp(), item["intent_id"]))
        db.execute("UPDATE integration_slots SET state='attempting' WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"]))
        return {"ok": True, "state": "attempting", "attempt_event_id": event_id, "event_id": event_id, "merge_command": ["bin/fm-pr-merge.sh", intent["task_id"], intent["pr_url"]]}
    if op == "queue-result":
        require(item["state"] == "attempting", "slot is not attempting")
        require(p.get("outcome") in {"unknown", "refused"}, "merged outcome requires live queue-reconcile")
        db.execute("UPDATE queue_items SET state='outcome-unknown',updated_at=? WHERE intent_id=?", (stamp(), item["intent_id"]))
        db.execute("UPDATE integration_slots SET state='outcome-unknown' WHERE repo=? AND base_ref=?", (item["repo"], item["base_ref"]))
        event_id = emit(db, "merge-outcome-unknown", request_id, {"intent_id": item["intent_id"], "attempt_event_id": item["attempt_event_id"], "reported_outcome": p["outcome"]})
        return {"ok": True, "state": "outcome-unknown", "event_id": event_id}
    if op == "queue-reconcile":
        require(item["state"] == "outcome-unknown" or (item["state"] == "attempting" and p["_forge_outcome"] == "merged"), "only a proven landing can settle an attempting slot")
        return terminal_outcome(db, item, request_id, p["_forge_outcome"], p)
    raise Refusal("unknown queue operation")


def wrapper_settled(item):
    quiet = int(os.environ.get("FM_COORD_QUIET_SECONDS", "600"))
    require(quiet >= 0, "quiet period must be nonnegative")
    if item["wrapper_local"] == 0:
        exited_at = item["wrapper_exit_attested_at"]
        return exited_at is not None and int(time.time()) - max(item["attempt_epoch"], exited_at) >= quiet
    gone = item["wrapper_pid"] is not None and (item["wrapper_boot"] != boot_id() or process_start(item["wrapper_pid"]) != item["wrapper_start"])
    return gone and int(time.time()) - item["attempt_epoch"] >= quiet


def forge_landing(p):
    """Read only, before entering the state transition transaction."""
    match = PR_URL.fullmatch(token(p.get("pr_url"), "pr_url"))
    require(match is not None, "queue-reconcile requires a GitHub PR URL")
    repo, number = match.groups()
    base = token(p.get("base"), "base")
    def read(path, template, method="GET", *fields):
        result = subprocess.run(["gh-axi", "api", method, path, *fields, "--template", template, "--full"], capture_output=True, text=True, timeout=30, check=True)
        lines = result.stdout.strip().splitlines()
        require(len(lines) == 3 and lines[0] == "api_response:" and lines[1].startswith("  body: ") and lines[2] == "  truncated: false", "forge response is unreadable or truncated")
        raw_body = lines[1][8:]
        body = json.loads(raw_body) if raw_body.startswith('"') else raw_body
        require(isinstance(body, str), "forge response body is unreadable")
        return body
    pull_path = f"repos/{repo}/pulls/{number}"
    pull_template = "{{.html_url}}|{{.state}}|{{.merged}}|{{.head.sha}}|{{.base.ref}}|{{.merge_commit_sha}}"
    fields = read(pull_path, pull_template).split("|")
    require(len(fields) == 6 and fields[0] == p["pr_url"] and fields[4] == base, "forge observation is for a different PR or base")
    observed_base = oid(read(f"repos/{repo}/git/ref/heads/{quote(base, safe='/')}", "{{.object.sha}}"), "current forge base")
    p["observed_base_oid"] = observed_base
    if fields[1] == "closed" and fields[2] == "true":
        p["_forge_outcome"] = "merged"
        p["merged_head_oid"] = oid(fields[3], "forge head")
        p["merge_oid"] = oid(fields[5], "forge merge commit")
        return
    require(fields[1] in {"open", "closed"} and fields[2] == "false", "forge does not prove whether this PR landed")
    require(p.get("_settled_attempt") is not None, "merge wrapper is not proven to have exited after the quiet period")
    owner, name = repo.split("/")
    pending = read("graphql", "{{with .data.repository.pullRequest}}{{.isInMergeQueue}}|{{if .autoMergeRequest}}armed{{else}}none{{end}}{{end}}", "POST", "--field", f'query=query{{repository(owner:"{owner}",name:"{name}"){{pullRequest(number:{number}){{isInMergeQueue autoMergeRequest{{enabledAt}}}}}}}}')
    require(pending == "false|none", "PR merge is still pending in the merge queue or auto-merge")
    head = oid(p.get("head_oid"), "head_oid")
    status = read(f"repos/{repo}/compare/{observed_base}...{head}", "{{.status}}")
    require(status in {"ahead", "diverged"}, "forge does not prove the attempted head is off base")
    require(read(pull_path, pull_template).split("|")[1:5] == fields[1:5], "PR changed during reconciliation")
    p["_forge_outcome"] = "refused"
    p["_unlanded_head_oid"] = head


def queue_position(db, row):
    return db.execute("SELECT COUNT(*) FROM ci_heads WHERE repo=? AND state='queued' AND seq<=?", (row["repo"], row["seq"])).fetchone()[0]


def authorize_ci(db, request_id, key, batch_id, intent_id, head):
    event_id = emit(db, "ci-pulse-authorized", request_id, {"repo": key[0], "base": key[1], "batch_id": batch_id, "intent_id": intent_id, "head_oid": head})
    db.execute("INSERT INTO ci_batches(repo,base_ref,batch_id,intent_id,head_oid,event_id) VALUES(?,?,?,?,?,?)", (*key, batch_id, intent_id, head, event_id))
    return event_id


def complete_ci(db, request_id, row, conclusion):
    db.execute("DELETE FROM ci_heads WHERE seq=?", (row["seq"],))
    return emit(db, "ci-completed", request_id, {"repo": row["repo"], "base": row["base_ref"], "batch_id": row["batch_id"], "head_oid": row["head_oid"], "conclusion": conclusion})


def promote_ci(db, request_id, repo):
    """Free the repository's CI slots whose lease lapsed, then admit the oldest queued live heads, each exactly once."""
    capacity = db.execute("SELECT capacity,ttl_seconds FROM ci_capacity WHERE repo=?", (repo,)).fetchone()
    if capacity is None:
        return []
    for row in db.execute("SELECT * FROM ci_heads WHERE repo=? AND state='active' AND admitted_at<=?", (repo, int(time.time()) - capacity["ttl_seconds"])).fetchall():
        complete_ci(db, request_id, row, "lease-expired")
    admitted = []
    while db.execute("SELECT COUNT(*) FROM ci_heads WHERE repo=? AND state='active'", (repo,)).fetchone()[0] < capacity["capacity"]:
        row = db.execute("SELECT * FROM ci_heads WHERE repo=? AND state='queued' ORDER BY seq LIMIT 1", (repo,)).fetchone()
        if row is None:
            break
        latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (row["intent_id"],)).fetchone()
        if latest is None or latest[0] != row["head_oid"] or db.execute("SELECT 1 FROM claims WHERE intent_id=? AND state='active'", (row["intent_id"],)).fetchone() is None:
            # A queued head whose writer lost its claim or moved on is never admitted.
            db.execute("DELETE FROM ci_heads WHERE seq=?", (row["seq"],))
            emit(db, "ci-pulse-dropped", request_id, {"repo": repo, "base": row["base_ref"], "batch_id": row["batch_id"], "head_oid": row["head_oid"]})
            continue
        event_id = authorize_ci(db, request_id, (repo, row["base_ref"]), row["batch_id"], row["intent_id"], row["head_oid"])
        db.execute("UPDATE ci_heads SET state='active',event_id=?,admitted_at=? WHERE seq=?", (event_id, int(time.time()), row["seq"]))
        admitted.append(row["batch_id"])
    return admitted


def run_operation(db, op, p):
    request_id = p.get("request_id")
    if op == "pulse-batch":
        intent_id = token(p.get("intent_id"), "intent_id")
        intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
        require(intent is not None, "intent does not exist")
        active_claim(db, p, intent)
        batch_id = token(p.get("batch_id"), "batch_id")
        head = oid(p.get("head_oid"), "head_oid")
        latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (intent_id,)).fetchone()
        require(latest is not None and latest[0] == head, "CI pulse requires the current published writer head")
        key = (intent["repo"], intent["base_ref"])
        promote_ci(db, request_id, key[0])
        held = db.execute("SELECT * FROM ci_heads WHERE repo=? AND base_ref=? AND batch_id=?", (*key, batch_id)).fetchone()
        if held is not None:
            require(held["intent_id"] == intent_id and held["head_oid"] == head, "batch is bound to another head")
            if held["state"] == "queued":
                return {"ok": True, "admitted": False, "batch_id": batch_id, "position": queue_position(db, held)}
            if not held["delivered"]:
                # The first request after promotion carries the one authorization to the worker.
                db.execute("UPDATE ci_heads SET delivered=1 WHERE seq=?", (held["seq"],))
                return {"ok": True, "admitted": True, "batch_id": batch_id, "event_id": held["event_id"]}
        existing = db.execute("SELECT event_id FROM ci_batches WHERE repo=? AND base_ref=? AND batch_id=? UNION ALL SELECT NULL FROM fenced_ci_batches WHERE repo=? AND base_ref=? AND batch_id=?", (*key, batch_id) * 2).fetchone()
        if existing:
            return {"ok": False, "reason": "batch-already-pulsed", "event_id": existing[0]}
        capacity = db.execute("SELECT capacity FROM ci_capacity WHERE repo=?", (key[0],)).fetchone()
        if capacity is not None:
            # A head runs one batch at a time; once that batch completes, a new batch ID is its next attempt.
            if db.execute("SELECT 1 FROM ci_heads WHERE repo=? AND head_oid=?", (key[0], head)).fetchone():
                return {"ok": False, "reason": "head-batch-in-flight"}
            if db.execute("SELECT COUNT(*) FROM ci_heads WHERE repo=? AND state='active'", (key[0],)).fetchone()[0] >= capacity[0]:
                emit(db, "ci-pulse-queued", request_id, {"repo": key[0], "base": key[1], "batch_id": batch_id, "intent_id": intent_id, "head_oid": head})
                db.execute("INSERT INTO ci_heads(repo,base_ref,batch_id,intent_id,head_oid,state) VALUES(?,?,?,?,?,'queued')", (*key, batch_id, intent_id, head))
                row = db.execute("SELECT * FROM ci_heads WHERE repo=? AND base_ref=? AND batch_id=?", (*key, batch_id)).fetchone()
                return {"ok": True, "admitted": False, "batch_id": batch_id, "position": queue_position(db, row)}
        event_id = authorize_ci(db, request_id, key, batch_id, intent_id, head)
        if capacity is not None:
            db.execute("INSERT INTO ci_heads(repo,base_ref,batch_id,intent_id,head_oid,state,delivered,event_id,admitted_at) VALUES(?,?,?,?,?,'active',1,?,?)", (*key, batch_id, intent_id, head, event_id, int(time.time())))
        return {"ok": True, "admitted": True, "batch_id": batch_id, "event_id": event_id}
    if op == "ci-capacity-set":
        repo = token(p.get("repo"), "repo")
        capacity, ttl = p.get("capacity"), p.get("ttl_seconds", CI_SLOT_TTL_SECONDS)
        require(type(capacity) is int and capacity > 0, "capacity must be a positive integer")
        require(type(ttl) is int and ttl > 0, "ttl_seconds must be a positive integer")
        db.execute("INSERT INTO ci_capacity(repo,capacity,ttl_seconds) VALUES(?,?,?) ON CONFLICT(repo) DO UPDATE SET capacity=excluded.capacity,ttl_seconds=excluded.ttl_seconds", (repo, capacity, ttl))
        event_id = emit(db, "ci-capacity-set", request_id, {"repo": repo, "capacity": capacity, "ttl_seconds": ttl})
        return {"ok": True, "capacity": capacity, "ttl_seconds": ttl, "admitted": promote_ci(db, request_id, repo), "event_id": event_id}
    if op == "ci-complete":
        repo = token(p.get("repo"), "repo")
        head = oid(p.get("head_oid"), "head_oid")
        batch_id = token(p.get("batch_id"), "batch_id")
        require(p.get("conclusion") in {"success", "failure", "cancelled", "timed_out"}, "conclusion must be a terminal CI state")
        # A batch is identified by (repo, base, batch_id); without a base, only a single matching active batch is completed.
        base = token(p["base"], "base") if "base" in p else None
        rows = db.execute("SELECT * FROM ci_heads WHERE repo=? AND head_oid=? AND batch_id=? AND state='active' AND (? IS NULL OR base_ref=?)", (repo, head, batch_id, base, base)).fetchall()
        require(rows, "batch holds no active CI slot")
        require(len(rows) == 1, "batch is active under several base refs; ci-complete requires base")
        row = rows[0]
        event_id = complete_ci(db, request_id, row, p["conclusion"])
        return {"ok": True, "released": row["batch_id"], "admitted": promote_ci(db, request_id, repo), "event_id": event_id}
    if op == "merge-guard":
        url = token(p.get("pr_url"), "pr_url")
        head = oid(p.get("head_oid"), "head_oid")
        rows = db.execute("SELECT q.head_oid,q.state,s.state AS slot_state,s.generation AS slot_generation,i.intent_id,i.repo,i.branch,i.home_id,i.generation AS writer_generation,c.claim_id,c.fence,c.expires_mono_ns,c.boot_id,p.generation AS current_generation,p.boot_id AS participant_boot,b.claim_id AS branch_claim FROM intents i JOIN queue_items q ON q.intent_id=i.intent_id JOIN integration_slots s ON s.intent_id=i.intent_id AND s.repo=i.repo AND s.base_ref=i.base_ref JOIN claims c ON c.intent_id=i.intent_id AND c.state='active' JOIN participants p ON p.home_id=i.home_id JOIN branch_owners b ON b.repo=i.repo AND b.branch=i.branch WHERE i.pr_url=?", (url,)).fetchall()
        valid = [row for row in rows if row["head_oid"] == head and row["state"] == "attempting" and row["slot_state"] == "attempting" and row["writer_generation"] == row["current_generation"] and row["participant_boot"] == boot_id() and row["boot_id"] == boot_id() and row["expires_mono_ns"] > time.monotonic_ns() and row["claim_id"] == row["branch_claim"]]
        require(len(valid) == 1, "current integration slot and branch writer generation are required for merge")
        return {"ok": True, "intent_id": valid[0]["intent_id"], "slot_generation": valid[0]["slot_generation"]}
    if op.startswith("queue-") or op in {"manifest-set", "predecessors-set"}:
        return queue_operation(db, op, p)
    if op == "enroll":
        home = token(p.get("home_id"), "home_id")
        repos = p.get("repos")
        require(isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos), "repos must be a nonempty string array")
        require(len(repos) == len(set(repos)), "duplicate repository scope")
        requested_host = p.get("host_id")
        if requested_host is not None:
            requested_host = token(requested_host, "host_id")
        existing = db.execute("SELECT * FROM participants WHERE home_id=?", (home,)).fetchone()
        if existing:
            previous_repos = json.loads(existing["repos_json"])
            require(previous_repos == [] or previous_repos == sorted(repos), "existing enrollment has different repository scope")
            if previous_repos == []:
                db.execute("UPDATE participants SET repos_json=? WHERE home_id=?", (compact(sorted(repos)), home))
            require(requested_host is None or existing["host_id"] is None or existing["host_id"] == requested_host, "enrolled host_id cannot change")
            host_id = requested_host or existing["host_id"] or local_host_id()
            if existing["host_id"] is None:
                db.execute("UPDATE participants SET host_id=? WHERE home_id=?", (host_id, home))
        else:
            host_id = requested_host or local_host_id()
            db.execute("INSERT INTO participants(home_id,repos_json,host_id) VALUES(?,?,?)", (home, compact(sorted(repos)), host_id))
        event_id = emit(db, "participant-enrolled", request_id, {"home_id": home, "repos": sorted(repos), "host_id": host_id})
        return {"ok": True, "home_id": home, "event_id": event_id}
    if op == "session":
        home = token(p.get("home_id"), "home_id")
        row = db.execute("SELECT * FROM participants WHERE home_id=?", (home,)).fetchone()
        require(row is not None, "home is not enrolled")
        for claim in db.execute("SELECT * FROM claims WHERE home_id=? AND state='active'", (home,)).fetchall():
            revoke(db, claim, "revoked", "new participant session")
        generation = row["generation"] + 1
        session_id = str(uuid.uuid4())
        db.execute("UPDATE participants SET generation=?,boot_id=?,session_id=? WHERE home_id=?", (generation, boot_id(), session_id, home))
        event_id = emit(db, "session-started", request_id, {"home_id": home, "generation": generation, "session_id": session_id})
        return {"ok": True, "home_id": home, "generation": generation, "session_id": session_id, "event_id": event_id}
    if op == "area-set":
        repo = token(p.get("repo"), "repo")
        name = token(p.get("name"), "area name")
        prefixes = p.get("paths")
        aliases = p.get("aliases", [])
        require(isinstance(prefixes, list) and prefixes and isinstance(aliases, list), "area paths and aliases must be arrays")
        prefixes = sorted(set(path(x) for x in prefixes))
        aliases = sorted(set([name] + [token(x, "area alias") for x in aliases]))
        require(not db.execute("SELECT 1 FROM claims c JOIN intents i ON i.intent_id=c.intent_id WHERE c.state='active' AND i.repo=? LIMIT 1", (repo,)).fetchone(), "area registry cannot change while repository claims are active")
        existing = db.execute("SELECT paths_json FROM areas WHERE repo=? AND name=?", (repo, name)).fetchone()
        require(existing is None or json.loads(existing[0]) == prefixes, "area definition is immutable")
        db.execute("INSERT OR IGNORE INTO areas(repo,name,paths_json) VALUES(?,?,?)", (repo, name, compact(prefixes)))
        for alias in aliases:
            row = db.execute("SELECT name FROM area_aliases WHERE repo=? AND alias=?", (repo, alias)).fetchone()
            require(row is None or row[0] == name, "area alias already belongs to another area")
            db.execute("INSERT OR IGNORE INTO area_aliases(repo,alias,name) VALUES(?,?,?)", (repo, alias, name))
        event_id = emit(db, "area-defined", request_id, {"repo": repo, "name": name, "paths": prefixes, "aliases": aliases})
        return {"ok": True, "event_id": event_id}
    if op == "migration-seed":
        repo = token(p.get("repo"), "repo")
        namespace = token(p.get("namespace"), "namespace")
        next_number = p.get("next_number")
        require(isinstance(next_number, int) and next_number >= 1, "next_number must be positive")
        require(db.execute("SELECT 1 FROM allocation_counters WHERE repo=? AND namespace=?", (repo, namespace)).fetchone() is None, "migration namespace already seeded")
        db.execute("INSERT INTO allocation_counters(repo,namespace,next_number) VALUES(?,?,?)", (repo, namespace, next_number))
        event_id = emit(db, "migration-seeded", request_id, {"repo": repo, "namespace": namespace, "next_number": next_number})
        return {"ok": True, "next_number": next_number, "event_id": event_id}
    if op == "submit":
        repo = token(p.get("repo"), "repo")
        participant(db, p, repo)
        intent_id = token(p.get("intent_id"), "intent_id")
        require(db.execute("SELECT 1 FROM intents WHERE intent_id=?", (intent_id,)).fetchone() is None, "intent_id already exists")
        base_oid = token(p.get("base_oid"), "base_oid")
        require(OID.fullmatch(base_oid) is not None, "base_oid must be a full Git object ID")
        for field in ("read_dependencies", "predecessors", "expected_artifacts"):
            require(isinstance(p.get(field, []), list), f"{field} must be an array")
        base_ref = token(p.get("base"), "base")
        declared_predecessors = predecessors(db, {"intent_id": intent_id, "repo": repo, "base_ref": base_ref}, p.get("predecessors", []))
        canonical = resources(db, repo, p.get("resources"))
        issue = p.get("issue")
        if issue is not None:
            canonical = sorted(set(canonical + [("issue", token(issue, "issue"))]))
        url = pr_url(p["pr_url"], repo) if p.get("pr_url") is not None else None
        db.execute("INSERT INTO intents(intent_id,home_id,generation,repo,base_ref,base_oid,branch,task_id,issue,pr_url,goal,resources_json,read_dependencies_json,predecessors_json,expected_artifacts_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (intent_id, p["home_id"], p["generation"], repo, base_ref, base_oid.lower(), token(p.get("branch"), "branch"), token(p.get("task_id"), "task_id"), issue, url, token(p.get("goal"), "goal"), compact(canonical), compact(p.get("read_dependencies", [])), compact(declared_predecessors), compact(p.get("expected_artifacts", [])), stamp()))
        event_id = emit(db, "intent-submitted", request_id, {"intent_id": intent_id, "home_id": p["home_id"], "repo": repo, "version": 1})
        return {"ok": True, "intent_id": intent_id, "version": 1, "resources": canonical, "event_id": event_id}
    if op in {"claim", "amend", "reserve", "publish-head", "attach-pr"}:
        intent_id = token(p.get("intent_id"), "intent_id")
        intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
        require(intent is not None, "intent does not exist")
        participant(db, p, intent["repo"])
        require(intent["home_id"] == p["home_id"], "intent holder mismatch")
        if op == "claim":
            require(intent["version"] == p.get("version"), "intent version mismatch")
            require(intent["state"] in {"submitted", "expired", "released", "revoked"}, "intent cannot be claimed in current state")
            if intent["state"] == "submitted":
                require(intent["generation"] == p["generation"], "intent generation mismatch")
            else:
                require(intent["generation"] <= p["generation"], "intent generation is newer than claimant")
            queued = db.execute("SELECT state FROM queue_items WHERE intent_id=?", (intent_id,)).fetchone()
            require(queued is None or queued[0] not in {"attempting", "outcome-unknown", "merged"}, "unsettled or landed intent cannot be reclaimed")
            ttl = p.get("ttl_seconds", 900)
            require(isinstance(ttl, int) and 1 <= ttl <= 86400, "ttl_seconds must be 1..86400")
            candidate = [tuple(x) for x in json.loads(intent["resources_json"])]
            found = conflicts(db, intent["repo"], candidate)
            owner = db.execute("SELECT b.claim_id,b.home_id,c.intent_id FROM branch_owners b JOIN claims c ON c.claim_id=b.claim_id WHERE b.repo=? AND b.branch=?", (intent["repo"], intent["branch"])).fetchone()
            if owner:
                found.append({"claim_id": owner["claim_id"], "home_id": owner["home_id"], "intent_id": owner["intent_id"], "predecessor_intent_id": owner["intent_id"], "resource": {"type": "branch", "name": intent["branch"]}})
            if found:
                event_id = emit(db, "claim-denied", request_id, {"intent_id": intent_id, "conflicts": found})
                return {"ok": False, "reason": "scope-conflict", "conflicts": found, "event_id": event_id}
            claim_id = str(uuid.uuid4())
            expires = time.monotonic_ns() + ttl * 1_000_000_000
            cursor = db.execute("INSERT INTO claims(claim_id,intent_id,home_id,generation,version,state,expires_mono_ns,boot_id) VALUES(?,?,?,?,?,'active',?,?)", (claim_id, intent_id, p["home_id"], p["generation"], intent["version"], expires, boot_id()))
            fence = cursor.lastrowid
            for kind, name in candidate:
                db.execute("INSERT INTO claim_resources(claim_id,kind,name) VALUES(?,?,?)", (claim_id, kind, name))
            db.execute("INSERT INTO branch_owners(repo,branch,claim_id,fence,home_id,generation) VALUES(?,?,?,?,?,?)", (intent["repo"], intent["branch"], claim_id, fence, p["home_id"], p["generation"]))
            db.execute("UPDATE intents SET state='claimed',generation=? WHERE intent_id=?", (p["generation"], intent_id))
            event_id = emit(db, "claim-granted", request_id, {"intent_id": intent_id, "claim_id": claim_id, "fence": fence, "expires_mono_ns": expires})
            return {"ok": True, "claim_id": claim_id, "fence": fence, "expires_mono_ns": expires, "event_id": event_id}
        require(intent["generation"] == p["generation"], "intent generation mismatch")
        claim = active_claim(db, p, intent)
        if op == "attach-pr":
            url = pr_url(p.get("pr_url"), intent["repo"])
            require(intent["pr_url"] is None or intent["pr_url"] == url, "PR URL cannot change for this intent")
            db.execute("UPDATE intents SET pr_url=? WHERE intent_id=?", (url, intent_id))
            event_id = emit(db, "pr-attached", request_id, {"intent_id": intent_id, "pr_url": url})
            return {"ok": True, "pr_url": url, "event_id": event_id}
        if op == "amend":
            require(intent["version"] == p.get("version"), "intent version mismatch")
            old = set(tuple(x) for x in json.loads(intent["resources_json"]))
            updated = set(resources(db, intent["repo"], p.get("resources")))
            if intent["issue"] is not None:
                updated.add(("issue", intent["issue"]))
            require(old.issubset(updated), "scope amendment cannot silently drop resources")
            found = conflicts(db, intent["repo"], updated, claim["claim_id"])
            if found:
                event_id = emit(db, "scope-denied", request_id, {"intent_id": intent_id, "conflicts": found})
                return {"ok": False, "reason": "scope-conflict", "conflicts": found, "event_id": event_id}
            version = intent["version"] + 1
            db.execute("UPDATE intents SET resources_json=?,version=? WHERE intent_id=?", (compact(sorted(updated)), version, intent_id))
            db.execute("UPDATE claims SET version=? WHERE claim_id=?", (version, claim["claim_id"]))
            for kind, name in updated - old:
                db.execute("INSERT INTO claim_resources(claim_id,kind,name) VALUES(?,?,?)", (claim["claim_id"], kind, name))
            event_id = emit(db, "scope-expanded", request_id, {"intent_id": intent_id, "version": version, "claim_id": claim["claim_id"]})
            return {"ok": True, "version": version, "event_id": event_id}
        if op == "reserve":
            namespace = token(p.get("namespace"), "namespace")
            require(("migration-sequence", namespace) in [tuple(x) for x in json.loads(intent["resources_json"])], "migration namespace is not claimed")
            row = db.execute("SELECT next_number FROM allocation_counters WHERE repo=? AND namespace=?", (intent["repo"], namespace)).fetchone()
            require(row is not None, "migration namespace must be seeded from existing main before reservation")
            number = row[0]
            db.execute("UPDATE allocation_counters SET next_number=? WHERE repo=? AND namespace=?", (number + 1, intent["repo"], namespace))
            allocation_id = str(uuid.uuid4())
            db.execute("INSERT INTO allocations(allocation_id,repo,namespace,number,intent_id,created_at) VALUES(?,?,?,?,?,?)", (allocation_id, intent["repo"], namespace, number, intent_id, stamp()))
            event_id = emit(db, "migration-reserved", request_id, {"allocation_id": allocation_id, "repo": intent["repo"], "namespace": namespace, "number": number, "intent_id": intent_id})
            return {"ok": True, "allocation_id": allocation_id, "number": number, "event_id": event_id}
        head_oid = token(p.get("head_oid"), "head_oid")
        require(OID.fullmatch(head_oid) is not None, "head_oid must be a full Git object ID")
        latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (intent_id,)).fetchone()
        previous = latest[0] if latest else None
        require(previous == p.get("expected_previous_oid"), "expected previous head mismatch")
        head_id = str(uuid.uuid4())
        db.execute("INSERT INTO heads(head_id,intent_id,head_oid,expected_previous_oid,claim_id,fence,created_at) VALUES(?,?,?,?,?,?,?)", (head_id, intent_id, head_oid.lower(), previous, claim["claim_id"], claim["fence"], stamp()))
        event_id = emit(db, "head-published", request_id, {"intent_id": intent_id, "head_id": head_id, "head_oid": head_oid.lower(), "claim_id": claim["claim_id"]})
        return {"ok": True, "head_id": head_id, "event_id": event_id}
    if op in {"renew", "release", "check"}:
        claim = active_claim(db, p)
        if op == "check":
            latest = db.execute("SELECT head_oid FROM heads WHERE intent_id=? ORDER BY rowid DESC LIMIT 1", (claim["intent_id"],)).fetchone()
            return {"ok": True, "claim_id": claim["claim_id"], "fence": claim["fence"], "expires_mono_ns": claim["expires_mono_ns"], "head_oid": latest[0] if latest else None}
        if op == "renew":
            ttl = p.get("ttl_seconds", 900)
            require(isinstance(ttl, int) and 1 <= ttl <= 86400, "ttl_seconds must be 1..86400")
            expires = time.monotonic_ns() + ttl * 1_000_000_000
            db.execute("UPDATE claims SET expires_mono_ns=? WHERE claim_id=?", (expires, claim["claim_id"]))
            event_id = emit(db, "lease-renewed", request_id, {"claim_id": claim["claim_id"], "fence": claim["fence"], "expires_mono_ns": expires})
            return {"ok": True, "expires_mono_ns": expires, "event_id": event_id}
        revoke(db, claim, "released", "holder release")
        return {"ok": True, "claim_id": claim["claim_id"]}
    if op == "outbox":
        limit = p.get("limit", 100)
        require(isinstance(limit, int) and 1 <= limit <= 1000, "limit must be 1..1000")
        after = p.get("after_seq", 0)
        require(isinstance(after, int) and after >= 0, "after_seq must be nonnegative")
        rows = db.execute("SELECT e.seq,e.event_id,e.event_type,e.request_id,e.payload_json,e.created_at FROM events e JOIN outbox o ON o.event_id=e.event_id WHERE o.acknowledged_at IS NULL AND e.seq>? ORDER BY e.seq LIMIT ?", (after, limit)).fetchall()
        return {"ok": True, "events": [{"seq": r["seq"], "event_id": r["event_id"], "type": r["event_type"], "request_id": r["request_id"], "payload": json.loads(r["payload_json"]), "created_at": r["created_at"]} for r in rows]}
    if op == "ack":
        event_id = token(p.get("event_id"), "event_id")
        row = db.execute("SELECT 1 FROM outbox WHERE event_id=?", (event_id,)).fetchone()
        require(row is not None, "event does not exist")
        db.execute("UPDATE outbox SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE event_id=?", (stamp(), event_id))
        return {"ok": True, "event_id": event_id}
    if op == "inspect":
        return {"ok": True, "schema_version": db.execute("PRAGMA user_version").fetchone()[0], "participants": [dict(r) for r in db.execute("SELECT home_id,repos_json,host_id,generation,session_id FROM participants ORDER BY home_id")], "intents": [dict(r) for r in db.execute("SELECT intent_id,home_id,repo,branch,pr_url,version,state FROM intents ORDER BY created_at")], "claims": [dict(r) for r in db.execute("SELECT claim_id,intent_id,home_id,generation,fence,version,state,expires_mono_ns FROM claims ORDER BY fence")], "allocations": [dict(r) for r in db.execute("SELECT allocation_id,repo,namespace,number,intent_id,state FROM allocations ORDER BY repo,namespace,number")], "queue": [dict(r) for r in db.execute("SELECT * FROM queue_items ORDER BY ready_epoch,intent_id")], "slots": [dict(r) for r in db.execute("SELECT * FROM integration_slots ORDER BY repo,base_ref")], "outcomes": [dict(r) for r in db.execute("SELECT * FROM merge_outcomes ORDER BY recorded_at")], "ci_capacity": [dict(r) for r in db.execute("SELECT * FROM ci_capacity ORDER BY repo")], "ci_heads": [dict(r) for r in db.execute("SELECT * FROM ci_heads ORDER BY seq")]}
    if op == "view":
        return {"ok": True,
                "intents": [dict(r) for r in db.execute("SELECT intent_id,home_id,repo,base_ref,branch,task_id,issue,state,version FROM intents WHERE state IN ('submitted','claimed') ORDER BY created_at,intent_id")],
                "claims": [dict(r) for r in db.execute("SELECT claim_id,intent_id,home_id,generation,fence,version,expires_mono_ns FROM claims WHERE state='active' ORDER BY fence")],
                "conflicts": [{"seq": r["seq"], "type": r["event_type"], "payload": json.loads(r["payload_json"])} for r in db.execute("SELECT seq,event_type,payload_json FROM events WHERE event_type IN ('claim-denied','scope-denied') ORDER BY seq DESC LIMIT 100")],
                "queue": [dict(r) for r in db.execute("SELECT * FROM queue_items ORDER BY ready_epoch,intent_id")],
                "outbox": [dict(r) for r in db.execute("SELECT e.seq,e.event_id,e.event_type FROM events e JOIN outbox o ON o.event_id=e.event_id WHERE o.acknowledged_at IS NULL ORDER BY e.seq LIMIT 100")]}
    raise Refusal("unknown operation")


def main():
    db_path, op, raw = sys.argv[1:4]
    try:
        db_path = str(Path(db_path).resolve())
        lock_path = Path(db_path + ".authority.lock")
        anchor_path = Path(db_path + ".authority.json")
        payload = json.loads(raw)
        require(isinstance(payload, dict), "JSON payload must be an object")
        require(not any(key.startswith("_") for key in payload), "payload fields starting with _ are reserved")
        request_payload = compact(payload)
        if op == "init":
            Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        else:
            require(Path(db_path).is_file(), "database is absent; run init first")
        with lock_path.open("a+") as lock:
            lock_wait = float(os.environ.get("FM_COORD_LOCK_WAIT_SECONDS", "2"))
            require(0 <= lock_wait <= 3, "lock wait must be 0..3 seconds")
            deadline = time.monotonic() + lock_wait
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError as exc:
                    if time.monotonic() >= deadline:
                        raise Refusal("coordinator host lock is held by another authority") from exc
                    time.sleep(0.05)
            run_locked(db_path, op, payload, request_payload, anchor_path)
    except (Refusal, ValueError, sqlite3.Error, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"fm-coord: {exc}", file=sys.stderr)
        sys.exit(1)


def run_locked(db_path, op, payload, request_payload, anchor_path):
    try:
        db = sqlite3.connect(db_path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("PRAGMA foreign_keys=ON")
        if op == "init":
            version = db.execute("PRAGMA user_version").fetchone()[0]
            require(version <= 9, f"unsupported future schema version: {version}")
            credential = authority_hash()
            if version < 9:
                db.execute("BEGIN IMMEDIATE")
                try:
                    # The step-3 lineage, and the step-4 head that followed it, rebound host IDs at version 5 and had no fenced CI batches before version 7.
                    hosts_rebound = version in (5, 6) and db.execute("SELECT 1 FROM sqlite_master WHERE name='fenced_ci_batches'").fetchone() is None
                    for target in range(version + 1, 10):
                        schema = SCHEMA_DIR / f"{target:03}.sql"
                        if target == 5:
                            expected = {"attempt_epoch": "INTEGER", "wrapper_pid": "INTEGER", "wrapper_start": "TEXT", "wrapper_boot": "TEXT"}
                            columns = {row["name"]: row["type"].upper() for row in db.execute("PRAGMA table_info(queue_items)")}
                            present = set(expected) & set(columns)
                            require(not present or present == set(expected), "partial v2 attempt columns; manual repair required")
                            for name in present:
                                require(columns[name] == expected[name], "incompatible v2 attempt column type")
                            if not present:
                                for statement in schema.read_text(encoding="utf-8").split(";"):
                                    if statement.strip():
                                        db.execute(statement)
                        elif target == 7 and hosts_rebound:
                            pass
                        else:
                            params = {"legacy_host": socket.gethostname(), "machine_host": local_host_id()} if target == 7 else {}
                            for statement in schema.read_text(encoding="utf-8").split(";"):
                                words = statement.split()
                                # Published migrations are append-only, so a later one may meet a column an earlier lineage already added.
                                if words[:2] == ["ALTER", "TABLE"] and words[3:5] == ["ADD", "COLUMN"] and any(row["name"] == words[5] for row in db.execute(f"PRAGMA table_info({words[2]})")):
                                    continue
                                if words:
                                    db.execute(statement, params)
                        if target == 1:
                            db.execute("INSERT INTO meta(key,value) VALUES('boot_id',?)", (boot_id(),))
                        db.execute(f"PRAGMA user_version={target}")
                    db.execute("COMMIT")
                except Exception:
                    db.execute("ROLLBACK")
                    raise
            if credential is not None:
                db.execute("BEGIN IMMEDIATE")
                try:
                    enrolled = db.execute("SELECT value FROM meta WHERE key='authority_token_sha256'").fetchone()
                    require(enrolled is None or hmac.compare_digest(credential, enrolled[0]), "authority credential mismatch")
                    if enrolled is None:
                        db.execute("INSERT INTO meta(key,value) VALUES('authority_token_sha256',?)", (credential,))
                        emit(db, "authority-enrolled", None, {"actor": authority_identity()})
                    db.execute("COMMIT")
                except Exception:
                    db.execute("ROLLBACK")
                    raise
            identity = db.execute("SELECT value FROM meta WHERE key='authority_id'").fetchone()
            if identity is None:
                identity = str(uuid.uuid4())
                db.execute("INSERT INTO meta(key,value) VALUES('authority_id',?)", (identity,))
                db.execute("INSERT INTO meta(key,value) VALUES('authority_path',?)", (db_path,))
            else:
                identity = identity[0]
                bound_path = db.execute("SELECT value FROM meta WHERE key='authority_path'").fetchone()
                require(bound_path is not None and bound_path[0] == db_path, "database authority is bound to another path")
                check_authority(db, identity, anchor_path)
            seal_authority(db, db_path, identity, anchor_path)
            print(compact({"ok": True, "schema_version": 9, "db": db_path, "mode": "shadow-advisory"}))
            return
        require(db.execute("PRAGMA user_version").fetchone()[0] == 9, "unsupported or uninitialized schema version; run init")
        identity = db.execute("SELECT value FROM meta WHERE key='authority_id'").fetchone()
        bound_path = db.execute("SELECT value FROM meta WHERE key='authority_path'").fetchone()
        require(identity is not None and bound_path is not None and bound_path[0] == db_path, "database has no authority binding for this path; manual fenced recovery required")
        if op == "recover":
            require(payload.get("confirm") == "FENCE_AND_REENROLL", "manual recovery requires confirm=FENCE_AND_REENROLL")
            require(anchor_path.is_file(), "authority recovery marker is absent")
            anchor = json.loads(anchor_path.read_text(encoding="utf-8"))
            require(anchor.get("authority_id") == identity[0] and type(anchor.get("highwater_seq")) is int, "authority marker does not match restored database")
            write_marker(db_path, anchor_path, {**anchor, "pending": True})
            db.execute("BEGIN IMMEDIATE")
            try:
                seq = max(anchor["highwater_seq"], authority_seq(db)) + RECOVERY_GAP
                if db.execute("UPDATE sqlite_sequence SET seq=? WHERE name='events'", (seq,)).rowcount == 0:
                    db.execute("INSERT INTO sqlite_sequence(name,seq) VALUES('events',?)", (seq,))
                for repo, namespace, number in anchor.get("allocation_counters", []):
                    db.execute("INSERT INTO allocation_counters(repo,namespace,next_number) VALUES(?,?,?) ON CONFLICT(repo,namespace) DO UPDATE SET next_number=MAX(next_number,excluded.next_number)", (repo, namespace, number))
                db.execute("UPDATE allocation_counters SET next_number=next_number+?", (RECOVERY_GAP,))
                for repo, base, generation in anchor.get("integration_generations", []):
                    db.execute("INSERT INTO integration_generations(repo,base_ref,generation) VALUES(?,?,?) ON CONFLICT(repo,base_ref) DO UPDATE SET generation=MAX(generation,excluded.generation)", (repo, base, generation))
                db.execute("UPDATE integration_generations SET generation=generation+?", (RECOVERY_GAP,))
                for repo, base, batch_id in anchor.get("ci_batches", []):
                    db.execute("INSERT OR IGNORE INTO fenced_ci_batches(repo,base_ref,batch_id) VALUES(?,?,?)", (repo, base, batch_id))
                # A head authorized after the backup was taken must never be promoted and pulsed again.
                db.execute("DELETE FROM ci_heads WHERE state='queued' AND (repo,base_ref,batch_id) IN (SELECT repo,base_ref,batch_id FROM fenced_ci_batches)")
                for claim in db.execute("SELECT * FROM claims WHERE state='active'").fetchall():
                    revoke(db, claim, "revoked", "manual coordinator recovery")
                for row in db.execute("SELECT home_id,generation FROM participants").fetchall():
                    generation = max(row["generation"], anchor.get("generations", {}).get(row["home_id"], 0)) + 1
                    db.execute("UPDATE participants SET generation=?,boot_id=NULL,session_id=NULL WHERE home_id=?", (generation, row["home_id"]))
                for home, generation in anchor.get("generations", {}).items():
                    db.execute("INSERT OR IGNORE INTO participants(home_id,repos_json,generation) VALUES(?,'[]',?)", (home, generation + 1))
                for item in db.execute("SELECT * FROM queue_items WHERE state IN ('syncing','validating','awaiting-checks')").fetchall():
                    invalidate(db, item, None, "manual coordinator recovery")
                db.execute("UPDATE queue_items SET state='outcome-unknown' WHERE state='attempting'")
                db.execute("UPDATE integration_slots SET state='outcome-unknown' WHERE state='attempting'")
                new_identity = str(uuid.uuid4())
                db.execute("UPDATE meta SET value=? WHERE key='authority_id'", (new_identity,))
                emit(db, "authority-manually-recovered", None, {"previous_authority_id": identity[0], "authority_id": new_identity})
                db.execute("COMMIT")
            except Exception:
                db.execute("ROLLBACK")
                write_marker(db_path, anchor_path, anchor)
                raise
            seal_authority(db, db_path, new_identity, anchor_path, force=True)
            print(compact({"ok": True, "authority_id": new_identity, "reenrollment_required": True}))
            return
        check_authority(db, identity[0], anchor_path)
        seal_authority(db, db_path, identity[0], anchor_path, pending=True)
        db.execute("BEGIN IMMEDIATE")
        try:
            reconcile_clock(db, boot_id())
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            seal_authority(db, db_path, identity[0], anchor_path, force=True)
            raise
        seal_authority(db, db_path, identity[0], anchor_path, force=True)
        if op in MUTATIONS:
            request_id = token(payload.get("request_id"), "request_id")
            if op == "queue-wrapper-exited":
                host_id = participant(db, payload)["host_id"]
                require(type(payload.get("wrapper_pid")) is int and payload["wrapper_pid"] > 0, "wrapper_pid must be a positive integer")
                if host_id == local_host_id():
                    require(process_start(payload["wrapper_pid"]) != payload.get("wrapper_start"), "wrapper process is still running")
                else:
                    # A foreign PID is never checked here; only the participant adapter's check on its own host counts.
                    require(host_id is not None and payload.get("exit_verified_host_id") == host_id, "remote wrapper exit requires the participant adapter's host attestation")
            actor = authority_actor(db, payload) if op == "queue-operator-abort" else payload.get("home_id", "@authority")
            if op == "queue-operator-abort":
                payload["_authority_actor"] = actor
            token(actor, "actor")
            require("home_id" not in payload or not actor.startswith("@"), "home_id cannot use the reserved administrative @ namespace")
            keyed = json.loads(request_payload)
            if op == "queue-wrapper-exited":
                # Replay is keyed to the attempt and exact wrapper identity, so a lost reply survives a new session.
                keyed.pop("generation", None)
            digest = hashlib.sha256(compact({"operation": op, "payload": keyed}).encode()).hexdigest()
        if op == "queue-reconcile":
            prior = db.execute("SELECT digest,result_json FROM requests WHERE actor=? AND request_id=?", (actor, request_id)).fetchone()
            if prior:
                require(prior["digest"] == digest, "idempotency key reused with different request")
                print(prior["result_json"])
                return
            item = db.execute("SELECT * FROM queue_items WHERE intent_id=?", (payload.get("intent_id"),)).fetchone()
            if item is not None and item["state"] == "outcome-unknown" and wrapper_settled(item):
                payload["_settled_attempt"] = item["attempt_event_id"]
            forge_landing(payload)
        seal_authority(db, db_path, identity[0], anchor_path, pending=True)
        db.execute("BEGIN IMMEDIATE")
        try:
            if op in MUTATIONS:
                prior = db.execute("SELECT digest,result_json FROM requests WHERE actor=? AND request_id=?", (actor, request_id)).fetchone()
                if prior:
                    require(prior["digest"] == digest, "idempotency key reused with different request")
                    result = json.loads(prior["result_json"])
                else:
                    result = run_operation(db, op, payload)
                    db.execute("INSERT INTO requests(actor,request_id,operation,digest,result_json) VALUES(?,?,?,?,?)", (actor, request_id, op, digest, compact(result)))
            else:
                result = run_operation(db, op, payload)
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            seal_authority(db, db_path, identity[0], anchor_path, force=True)
            raise
        seal_authority(db, db_path, identity[0], anchor_path, force=True)
        print(compact(result))
    finally:
        if 'db' in locals():
            db.close()


if __name__ == "__main__":
    main()
