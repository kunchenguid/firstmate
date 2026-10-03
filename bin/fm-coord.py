#!/usr/bin/env python3
"""Local SQLite authority for the advisory coordination protocol in docs/coordination.md."""

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid
from datetime import datetime, timezone


SCHEMA = Path(__file__).with_name("fm-coord-migrations") / "001.sql"
MUTATIONS = {"enroll", "session", "area-set", "migration-seed", "submit", "claim", "amend", "renew", "release", "reserve", "publish-head", "attach-pr", "ack"}
PATH_KINDS = {"file", "directory", "dependency-manifest", "generated-output"}
NAMED_KINDS = {"issue", "schema-object", "migration-sequence", "integration"}
OID = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")


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


def token(value, field):
    require(isinstance(value, str) and 0 < len(value) <= 256 and not any(ord(c) < 32 for c in value), f"{field} must be a nonempty printable string")
    return value


def path(value):
    token(value, "path")
    require(not value.startswith("/") and "\\" not in value and "\x00" not in value, "path must be repository-relative POSIX syntax")
    parts = [part for part in value.split("/") if part not in ("", ".")]
    require(parts and all(part != ".." for part in parts), "path cannot escape repository root")
    return "/".join(parts)


def pr_url(value, repo):
    token(value, "pr_url")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and parsed.path and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and " " not in value, "pr_url must be a canonical full HTTPS URL")
    owner = repo.split("/")
    segments = parsed.path.split("/")[1:]
    tail = segments[len(owner):]
    require(segments[:len(owner)] == owner and tail[:-1] in (["pull"], ["-", "merge_requests"]) and tail[-1].isdigit(), "pr_url must be a pull or merge request of the intent repository")
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


def revoke(db, claim, state, reason):
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


def run_operation(db, op, p):
    request_id = p.get("request_id")
    if op == "enroll":
        home = token(p.get("home_id"), "home_id")
        repos = p.get("repos")
        require(isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos), "repos must be a nonempty string array")
        require(len(repos) == len(set(repos)), "duplicate repository scope")
        existing = db.execute("SELECT * FROM participants WHERE home_id=?", (home,)).fetchone()
        if existing:
            require(json.loads(existing["repos_json"]) == sorted(repos), "existing enrollment has different repository scope")
        else:
            db.execute("INSERT INTO participants(home_id,repos_json) VALUES(?,?)", (home, compact(sorted(repos))))
        event_id = emit(db, "participant-enrolled", request_id, {"home_id": home, "repos": sorted(repos)})
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
        canonical = resources(db, repo, p.get("resources"))
        issue = p.get("issue")
        if issue is not None:
            canonical = sorted(set(canonical + [("issue", token(issue, "issue"))]))
        url = pr_url(p["pr_url"], repo) if p.get("pr_url") is not None else None
        db.execute("INSERT INTO intents(intent_id,home_id,generation,repo,base_ref,base_oid,branch,task_id,issue,pr_url,goal,resources_json,read_dependencies_json,predecessors_json,expected_artifacts_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (intent_id, p["home_id"], p["generation"], repo, token(p.get("base"), "base"), base_oid.lower(), token(p.get("branch"), "branch"), token(p.get("task_id"), "task_id"), issue, url, token(p.get("goal"), "goal"), compact(canonical), compact(p.get("read_dependencies", [])), compact(p.get("predecessors", [])), compact(p.get("expected_artifacts", [])), stamp()))
        event_id = emit(db, "intent-submitted", request_id, {"intent_id": intent_id, "home_id": p["home_id"], "repo": repo, "version": 1})
        return {"ok": True, "intent_id": intent_id, "version": 1, "resources": canonical, "event_id": event_id}
    if op in {"claim", "amend", "reserve", "publish-head", "attach-pr"}:
        intent_id = token(p.get("intent_id"), "intent_id")
        intent = db.execute("SELECT * FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
        require(intent is not None, "intent does not exist")
        participant(db, p, intent["repo"])
        require(intent["home_id"] == p["home_id"] and intent["generation"] == p["generation"], "intent holder or generation mismatch")
        if op == "claim":
            require(intent["version"] == p.get("version"), "intent version mismatch")
            require(intent["state"] == "submitted", "intent cannot be claimed in current state")
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
            db.execute("UPDATE intents SET state='claimed' WHERE intent_id=?", (intent_id,))
            event_id = emit(db, "claim-granted", request_id, {"intent_id": intent_id, "claim_id": claim_id, "fence": fence, "expires_mono_ns": expires})
            return {"ok": True, "claim_id": claim_id, "fence": fence, "expires_mono_ns": expires, "event_id": event_id}
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
            return {"ok": True, "claim_id": claim["claim_id"], "fence": claim["fence"], "expires_mono_ns": claim["expires_mono_ns"]}
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
        return {"ok": True, "schema_version": db.execute("PRAGMA user_version").fetchone()[0], "participants": [dict(r) for r in db.execute("SELECT home_id,repos_json,generation,session_id FROM participants ORDER BY home_id")], "intents": [dict(r) for r in db.execute("SELECT intent_id,home_id,repo,branch,pr_url,version,state FROM intents ORDER BY created_at")], "claims": [dict(r) for r in db.execute("SELECT claim_id,intent_id,home_id,generation,fence,version,state,expires_mono_ns FROM claims ORDER BY fence")], "allocations": [dict(r) for r in db.execute("SELECT allocation_id,repo,namespace,number,intent_id,state FROM allocations ORDER BY repo,namespace,number")]}
    raise Refusal("unknown operation")


def main():
    db_path, op, raw = sys.argv[1:4]
    try:
        payload = json.loads(raw)
        require(isinstance(payload, dict), "JSON payload must be an object")
        if op == "init":
            Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        else:
            require(Path(db_path).is_file(), "database is absent; run init first")
        db = sqlite3.connect(db_path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("PRAGMA foreign_keys=ON")
        if op == "init":
            version = db.execute("PRAGMA user_version").fetchone()[0]
            require(version <= 1, f"unsupported future schema version: {version}")
            if version == 0:
                db.execute("BEGIN IMMEDIATE")
                try:
                    for statement in SCHEMA.read_text(encoding="utf-8").split(";"):
                        if statement.strip():
                            db.execute(statement)
                    db.execute("INSERT INTO meta(key,value) VALUES('boot_id',?)", (boot_id(),))
                    db.execute("PRAGMA user_version=1")
                    db.execute("COMMIT")
                except Exception:
                    db.execute("ROLLBACK")
                    raise
            print(compact({"ok": True, "schema_version": 1, "db": db_path, "mode": "shadow-advisory"}))
            return
        require(db.execute("PRAGMA user_version").fetchone()[0] == 1, "unsupported or uninitialized schema version")
        db.execute("BEGIN IMMEDIATE")
        try:
            reconcile_clock(db, boot_id())
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise
        db.execute("BEGIN IMMEDIATE")
        try:
            if op in MUTATIONS:
                request_id = token(payload.get("request_id"), "request_id")
                actor = payload.get("home_id", "@authority")
                token(actor, "actor")
                require("home_id" not in payload or not actor.startswith("@"), "home_id cannot use the reserved administrative @ namespace")
                digest = hashlib.sha256(compact({"operation": op, "payload": payload}).encode()).hexdigest()
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
            raise
        print(compact(result))
    except (Refusal, ValueError, sqlite3.Error, OSError, subprocess.CalledProcessError) as exc:
        print(f"fm-coord: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
