#!/usr/bin/env python3
"""Best-effort local lifecycle adapter for the advisory coordination store.

The config and on-disk request journal are described in docs/coordination.md.
Every central mutation is journaled before invocation so a lost reply is replayed
with the same request ID. This adapter never treats an offline request as a grant.
"""

import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent
OID = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")


def warn(message):
    print(f"fm-coord advisory: {message}", file=sys.stderr)


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".fm-coord-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(value, out, sort_keys=True)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def git(project, *args):
    return subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True, text=True).stdout.strip()


def repo_name(project):
    remote = git(project, "remote", "get-url", "origin")
    match = re.search(r"(?:github\.com[:/])([^/\s]+)/([^/\s]+?)(?:\.git)?$", remote)
    if not match:
        raise ValueError(f"cannot identify GitHub owner/repo from origin: {remote}")
    return f"{match[1]}/{match[2]}"


def declared(brief):
    lines = Path(brief).read_text(encoding="utf-8").splitlines()
    resources = [line.split(":", 1)[1].strip() for line in lines if line.startswith("Coordination resources:")]
    issues = [line.split(":", 1)[1].strip() for line in lines if line.startswith("Coordination issue:")]
    if len(resources) != 1:
        raise ValueError("brief must declare exactly one 'Coordination resources:' JSON line")
    parsed = json.loads(resources[0])
    if not isinstance(parsed, list) or not parsed:
        raise ValueError("brief coordination resources must be a nonempty JSON array")
    if len(issues) > 1:
        raise ValueError("brief has duplicate coordination issue lines")
    return parsed, issues[0] if issues else None


class Adapter:
    def __init__(self, home):
        self.home = home
        config_path = Path(os.environ.get("FM_COORD_CONFIG", home / "config/coordination.json"))
        self.enabled = config_path.exists()
        if not self.enabled:
            return
        self.config = json.loads(config_path.read_text(encoding="utf-8"))
        if self.config.get("mode") not in {"shadow", "advisory"}:
            raise ValueError("coordination mode must be shadow or advisory")
        if not isinstance(self.config.get("home_id"), str) or not self.config["home_id"]:
            raise ValueError("coordination home_id is required")
        if not isinstance(self.config.get("repos"), list) or not self.config["repos"]:
            raise ValueError("coordination repos must be nonempty")
        db = self.config.get("db")
        remote = self.config.get("remote")
        if bool(db) == bool(remote):
            raise ValueError("coordination requires exactly one direct db or remote transport")
        if db is not None and (not isinstance(db, str) or not Path(db).is_absolute()):
            raise ValueError("coordination db must be an absolute central path")
        if remote is not None:
            if not isinstance(remote, dict) or any(not isinstance(remote.get(k), str) for k in ("host", "command", "db")):
                raise ValueError("coordination remote requires host, command, and db strings")
            if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", remote["host"]):
                raise ValueError("coordination remote host is invalid")
            if not Path(remote["command"]).is_absolute() or not Path(remote["db"]).is_absolute():
                raise ValueError("coordination remote command and db must be absolute paths")
        self.path = home / "state/fm-coord-adapter.json"
        self.lock = home / "state/fm-coord-adapter.lock"
        self.lock.parent.mkdir(parents=True, exist_ok=True)
        self.lock_handle = self.lock.open("a+")
        fcntl.flock(self.lock_handle, fcntl.LOCK_EX)
        self.state = json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else {"requests": {}, "tasks": {}}

    def save(self):
        atomic_write(self.path, self.state)

    def call(self, op, payload):
        try:
            raw = json.dumps(payload, separators=(",", ":"))
            if self.config.get("remote") is not None:
                remote = self.config["remote"]
                command = " ".join(shlex.quote(x) for x in (remote["command"], "--db", remote["db"], op, raw))
                argv = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1", remote["host"], command]
                timeout = 8
            else:
                argv = [str(ROOT / "fm-coord.sh"), "--db", self.config["db"], op, raw]
                timeout = 5
            result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
            if result.returncode:
                warn(f"central {op} unavailable or refused: {result.stderr.strip() or result.returncode}; request remains local")
                return None
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            warn(f"central {op} unavailable: {exc}; request remains local")
            return None

    def send(self, key, op, payload):
        requests = self.state["requests"]
        if key not in requests:
            item = {"op": op, "payload": {**payload, "request_id": str(uuid.uuid4())}}
            requests[key] = item
            self.save()
        item = requests[key]
        if item["op"] != op or {k: v for k, v in item["payload"].items() if k != "request_id"} != payload:
            raise ValueError(f"local request key changed payload: {key}")
        if "reply" not in item:
            reply = self.call(op, item["payload"])
            if reply is not None:
                item["reply"] = reply
                self.save()
        return item.get("reply")

    def setup(self):
        home_id = self.config["home_id"]
        if self.send("enroll", "enroll", {"home_id": home_id, "repos": self.config["repos"]}) is None:
            return None
        session = self.send("session", "session", {"home_id": home_id})
        return session["generation"] if session else None

    def ensure_task(self, task_id):
        task = self.state["tasks"][task_id]
        generation = self.setup()
        if generation is None:
            warn(f"{task_id}: offline intent pending; no claim granted")
            return task
        common = {"intent_id": task["intent_id"], "home_id": self.config["home_id"], "generation": generation}
        submitted = self.send(f"{task_id}:submit", "submit", {**common, "repo": task["repo"], "base": task["base"], "base_oid": task["base_oid"], "branch": task["branch"], "task_id": task_id, "goal": task["goal"], "resources": task["declared"], **({"issue": task["issue"]} if task["issue"] else {})})
        if submitted is None:
            warn(f"{task_id}: intent pending; no claim granted")
            return task
        claim = self.send(f"{task_id}:claim", "claim", {**common, "version": submitted["version"]})
        if claim is None:
            warn(f"{task_id}: claim pending; no grant assumed")
        elif not claim["ok"]:
            for conflict in claim["conflicts"]:
                warn(f"{task_id}: scope conflict held by {conflict['home_id']} intent {conflict['intent_id']} on {conflict['resource']}")
        elif "claim" not in task:
            task["claim"] = claim
            task["version"] = submitted["version"]
            task["resources"] = submitted["resources"]
            self.save()
        return task

    def dispatch(self, task_id, project, brief, branch, harness):
        if harness not in {"claude", "codex", "omp", "opencode"}:
            warn(f"{task_id}: {harness} has no coordination adapter; dispatch continues without a grant")
            return
        resources, issue = declared(brief)
        repo = self.config.get("project_repos", {}).get(str(Path(project).resolve())) or repo_name(project)
        if repo not in self.config["repos"]:
            raise ValueError(f"{repo} is outside coordination enrollment")
        base = self.config.get("base", "main")
        base_oid = git(project, "rev-parse", base)
        if not OID.fullmatch(base_oid):
            raise ValueError("base does not resolve to a full Git OID")
        key = f"{repo}:{task_id}"
        task = self.state["tasks"].get(task_id)
        if task is None:
            task = {"intent_id": f"{self.config['home_id']}:{key}", "repo": repo, "base": base, "base_oid": base_oid, "branch": branch, "goal": task_id, "declared": resources, "issue": issue, "harness": harness, "pending_paths": []}
            self.state["tasks"][task_id] = task
            self.save()
        elif (task["repo"], task["branch"], task["declared"], task["issue"]) != (repo, branch, resources, issue):
            raise ValueError(f"{task_id}: coordination declaration changed after submission")
        self.ensure_task(task_id)

    def live_claim(self, task_id):
        task = self.ensure_task(task_id)
        claim = task.get("claim")
        if not claim:
            warn(f"{task_id}: branch writer has no confirmed claim")
            return None
        payload = {"home_id": self.config["home_id"], "generation": self.state["requests"]["session"]["reply"]["generation"], "claim_id": claim["claim_id"], "fence": claim["fence"]}
        checked = self.call("check", payload)
        if checked is None:
            warn(f"{task_id}: branch writer generation cannot be checked; no grant assumed")
            return None
        return payload

    def changed_paths(self, task, worktree):
        output = subprocess.run(["git", "-C", str(worktree), "diff", "--name-only", "--no-renames", "-z", task["base_oid"], "HEAD"], check=True, capture_output=True).stdout
        return sorted({x.decode("utf-8", "surrogateescape") for x in output.split(b"\0") if x})

    def scope(self, task_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            warn(f"{task_id}: no local intent record for scope check")
            return
        live = self.live_claim(task_id)
        paths = self.changed_paths(task, worktree)
        covered = lambda name: any((kind == "file" and value == name) or (kind == "directory" and (name == value or name.startswith(value + "/"))) for kind, value in task.get("resources", []))
        undeclared = sorted(set(task.get("pending_paths", [])) | {p for p in paths if not covered(p)})
        if undeclared:
            warn(f"{task_id}: undeclared changed paths: {', '.join(undeclared)}; amendment requested")
            task["pending_paths"] = undeclared
            self.save()
        if live and undeclared:
            payload = {**live, "intent_id": task["intent_id"], "version": task["version"], "resources": [{"type": kind, "name": value} for kind, value in task["resources"]] + [{"type": "file", "name": p} for p in undeclared if not covered(p)]}
            key = f"{task_id}:amend:{task['version']}"
            if key in self.state["requests"]:
                prior = self.state["requests"][key]["payload"]
                payload = {k: v for k, v in prior.items() if k != "request_id"}
            amended = self.send(key, "amend", payload)
            if amended and amended["ok"]:
                task["version"] = amended["version"]
                added = {r["name"] for r in payload["resources"] if r["type"] == "file"}
                task["resources"] = sorted({tuple(x) for x in task["resources"]} | {("file", p) for p in added})
                task["resources"] = [list(x) for x in task["resources"]]
                task["pending_paths"] = sorted(set(undeclared) - added)
                self.save()
            elif amended:
                for conflict in amended["conflicts"]:
                    warn(f"{task_id}: amendment conflict held by {conflict['home_id']} intent {conflict['intent_id']}")
        if not live:
            return
        head = git(worktree, "rev-parse", "HEAD")
        if head != task.get("published_head"):
            previous = task.get("published_head")
            reply = self.send(f"{task_id}:head:{head}", "publish-head", {**live, "intent_id": task["intent_id"], "head_oid": head, "expected_previous_oid": previous})
            if reply:
                task["published_head"] = head
                task.pop("pending_head", None)
                self.save()
        else:
            task.pop("pending_head", None)
            self.save()

    def replay(self):
        for key, item in list(self.state["requests"].items()):
            if "reply" not in item:
                self.send(key, item["op"], {k: v for k, v in item["payload"].items() if k != "request_id"})
        for task_id in list(self.state["tasks"]):
            self.ensure_task(task_id)
            task = self.state["tasks"][task_id]
            if (task.get("pending_paths") or task.get("pending_head")) and task.get("worktree"):
                self.scope(task_id, task["worktree"])
            if task.get("pending_ci") and self.live_claim(task_id):
                task.pop("pending_ci", None)
                self.save()
            if task.get("renew_key") and "reply" in self.state["requests"].get(task["renew_key"], {}):
                task.pop("renew_key", None)
                self.save()

    def heartbeat(self, task_id):
        task = self.state["tasks"].get(task_id)
        live = self.live_claim(task_id)
        if not task or not live:
            return
        key = task.get("renew_key")
        if not key:
            key = f"{task_id}:renew:{uuid.uuid4()}"
            task["renew_key"] = key
            self.save()
        if self.send(key, "renew", live):
            task.pop("renew_key", None)
            self.save()

    def view(self):
        central = self.call("view", {})
        pending = [{"key": key, "operation": item["op"], "request_id": item["payload"]["request_id"]} for key, item in self.state["requests"].items() if "reply" not in item]
        pending.extend({"key": task_id, "operation": action} for task_id, task in self.state["tasks"].items() for action, flag in (("pre-push", task.get("pending_head")), ("pre-ci", task.get("pending_ci")), ("scope-amend", task.get("pending_paths")), ("heartbeat", task.get("renew_key"))) if flag)
        print(json.dumps({"mode": self.config["mode"], "central": central, "local_pending": pending, "local_tasks": self.state["tasks"]}, sort_keys=True))


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in {"dispatch", "pre-push", "pre-ci", "heartbeat", "replay", "view"}:
        print("usage: fm-coord-adapter.py <dispatch TASK PROJECT BRIEF BRANCH HARNESS|pre-push TASK WORKTREE|pre-ci TASK|heartbeat TASK|replay|view>", file=sys.stderr)
        return 2
    home = os.environ.get("FM_HOME")
    if not home:
        warn("FM_HOME is required")
        return 1
    try:
        adapter = Adapter(Path(home))
        if not adapter.enabled:
            return 0
        command = sys.argv[1]
        if command == "dispatch" and len(sys.argv) == 7:
            adapter.dispatch(*sys.argv[2:])
        elif command == "pre-push" and len(sys.argv) == 4:
            task = adapter.state["tasks"].get(sys.argv[2])
            if task:
                task["worktree"] = sys.argv[3]
                task["pending_head"] = git(sys.argv[3], "rev-parse", "HEAD")
                adapter.save()
            adapter.scope(sys.argv[2], sys.argv[3])
        elif command == "heartbeat" and len(sys.argv) == 3:
            adapter.heartbeat(sys.argv[2])
        elif command == "pre-ci" and len(sys.argv) == 3:
            task = adapter.state["tasks"].get(sys.argv[2])
            if task:
                task["pending_ci"] = True
                adapter.save()
            if adapter.live_claim(sys.argv[2]) and task:
                task.pop("pending_ci", None)
                adapter.save()
        elif command == "replay" and len(sys.argv) == 2:
            adapter.replay()
        elif command == "view" and len(sys.argv) == 2:
            adapter.view()
        else:
            raise ValueError("wrong adapter arguments")
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        warn(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
