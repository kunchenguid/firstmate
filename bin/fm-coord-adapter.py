#!/usr/bin/env python3
"""Best-effort local lifecycle adapter for the advisory coordination store.

The config and on-disk request journal are described in docs/configuration.md;
the lifecycle is described in docs/coordination.md.
Every central mutation is journaled before invocation so a lost reply is replayed
with the same request ID. This adapter never treats an offline request as a grant.
"""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent
OID = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")


def coord_module():
    spec = importlib.util.spec_from_file_location("fm_coord", ROOT / "fm-coord.py")
    coord = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(coord)
    return coord


def machine_host_id():
    coord = coord_module()
    try:
        return coord.local_host_id()
    except coord.Refusal as exc:
        raise ValueError(str(exc))


def process_start(pid):
    """Start time of a process on this host, using the coordinator's own reader."""
    coord = coord_module()
    if type(pid) is not int or pid <= 0:
        raise ValueError("wrapper_pid must be a positive integer")
    try:
        return coord.process_start(pid)
    except coord.Refusal as exc:
        raise ValueError(str(exc))


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
    if not isinstance(parsed, list):
        raise ValueError("brief coordination resources must be a JSON array")
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
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(self.lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise ValueError("adapter journal is busy; checkpoint skipped, no grant assumed")
                time.sleep(0.1)
        self.reset = self.reenrolled = False
        self.state = json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else {"requests": {}, "tasks": {}}

    def save(self):
        atomic_write(self.path, self.state)

    def call(self, op, payload):
        self.last_error = ""
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
                if "expired session generation" in result.stderr:
                    self.reset_session()
                elif "participant host_id must be enrolled" in result.stderr and not self.reenrolled:
                    # A migration can clear a cached enrollment's host binding; enroll again once and retry the command.
                    self.state["requests"].pop("enroll", None)
                    self.reenrolled = self.reset = True
                    self.save()
                self.last_error = result.stderr
                warn(f"central {op} unavailable or refused: {result.stderr.strip() or result.returncode}; request remains local")
                return None
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            warn(f"central {op} unavailable: {exc}; request remains local")
            return None

    def reset_task(self, task_id):
        task = self.state["tasks"][task_id]
        for key in [k for k in self.state["requests"] if k.startswith(f"{task_id}:")]:
            del self.state["requests"][key]
        for field in ("claim", "version", "resources", "published_head", "renew_key"):
            task.pop(field, None)
        task["epoch"] = task.get("epoch", 0) + 1
        task["intent_id"] = f"{self.config['home_id']}:{task['repo']}:{task_id}#{task['epoch']}"
        self.reset = True
        self.save()

    def reset_session(self):
        self.state["requests"].pop("session", None)
        # A coordinator reboot revokes every claim, so queued releases have nothing left to release.
        for key in [k for k, v in self.state["requests"].items() if v["op"] == "release"]:
            del self.state["requests"][key]
        for task_id in self.state["tasks"]:
            self.reset_task(task_id)

    def send(self, key, op, payload):
        requests = self.state["requests"]
        if key not in requests:
            item = {"op": op, "payload": {**payload, "request_id": str(uuid.uuid4())}}
            requests[key] = item
            self.save()
        item = requests[key]
        if item["op"] != op or {k: v for k, v in item["payload"].items() if k != "request_id"} != payload:
            raise ValueError(f"local request key changed payload: {key}")
        if "reply" in item:
            return item["reply"]
        reply = self.call(op, item["payload"])
        if reply is not None:
            if reply.get("ok") is False:
                del requests[key]
            else:
                item["reply"] = reply
            self.save()
        return reply

    def setup(self):
        home_id = self.config["home_id"]
        if "enroll" in self.state["requests"]:
            enroll = {k: v for k, v in self.state["requests"]["enroll"]["payload"].items() if k != "request_id"}
        else:
            enroll = {"home_id": home_id, "repos": self.config["repos"]}
            if self.config.get("remote") is not None:
                # The coordinator binds its own machine identity when host_id is absent, which would make this home's merge wrapper look local.
                try:
                    enroll["host_id"] = machine_host_id()
                except ValueError as exc:
                    warn(f"remote enrollment needs this home's machine identity: {exc}")
                    return None
        if self.send("enroll", "enroll", enroll) is None:
            return None
        session = self.send("session", "session", {"home_id": home_id})
        return session["generation"] if session else None

    def ensure_task(self, task_id):
        task = self.state["tasks"].get(task_id)
        if task is None:
            warn(f"{task_id}: no local intent record; checkpoint skipped, no grant assumed")
            return None
        if task["base_oid"] is None:
            warn(f"{task_id}: no base recorded; intent recorded locally as unclaimed")
            return task
        if not task["declared"]:
            warn(f"{task_id}: brief declares no coordination resources; intent recorded locally as unclaimed")
            return task
        if not self.settle_release(task_id):
            return task
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
        if claim is not None and task.pop("pending_dispatch", None):
            self.save()
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

    def dispatch(self, task_id, project, worktree, brief, branch, harness):
        if harness not in {"claude", "codex", "omp", "opencode"}:
            warn(f"{task_id}: {harness} has no coordination adapter; dispatch continues without a grant")
            return
        resources, issue = declared(brief)
        repo = self.config.get("project_repos", {}).get(str(Path(project).resolve())) or repo_name(project)
        if repo not in self.config["repos"]:
            raise ValueError(f"{repo} is outside coordination enrollment")
        base = self.config.get("base", "main")
        if subprocess.run(["git", "-C", str(worktree), "rev-parse", "--verify", "--quiet", f"origin/{base}^{{commit}}"], capture_output=True, check=False).returncode:
            warn(f"{task_id}: origin/{base} is missing; intent has no base and is not submitted")
            base_oid = None
        else:
            base_oid = git(worktree, "rev-parse", "HEAD")
            if not OID.fullmatch(base_oid):
                raise ValueError("worker start commit is not a full Git OID")
        key = f"{repo}:{task_id}"
        task = self.state["tasks"].get(task_id)
        if task is not None and (task["repo"], task["branch"], task["declared"], task["issue"], task["base_oid"]) != (repo, branch, resources, issue, base_oid):
            if (task["repo"], task["branch"], task["declared"], task["issue"]) != (repo, branch, resources, issue) and "reply" in self.state["requests"].get(f"{task_id}:submit", {}):
                raise ValueError(f"{task_id}: coordination declaration changed after submission")
            # A fresh spawn starts a new attempt: drop the prior attempt's claim before submitting the new start commit.
            self.release(task_id)
            task.update({"repo": repo, "base": base, "base_oid": base_oid, "branch": branch, "declared": resources, "issue": issue, "harness": harness, "pending_dispatch": bool(resources and base_oid)})
            self.save()
        if task is None:
            task = {"intent_id": f"{self.config['home_id']}:{key}", "repo": repo, "base": base, "base_oid": base_oid, "branch": branch, "goal": task_id, "declared": resources, "issue": issue, "harness": harness, "pending_paths": [], "pending_dispatch": bool(resources and base_oid)}
            self.state["tasks"][task_id] = task
            self.save()
        self.ensure_task(task_id)

    def live_claim(self, task_id):
        task = self.ensure_task(task_id)
        if task is None:
            return None
        claim = task.get("claim")
        if not claim:
            warn(f"{task_id}: branch writer has no confirmed claim")
            return None
        payload = {"home_id": self.config["home_id"], "generation": self.state["requests"]["session"]["reply"]["generation"], "claim_id": claim["claim_id"], "fence": claim["fence"]}
        checked = self.call("check", payload)
        if checked is None:
            if "claim is not active" in self.last_error:
                self.reset_task(task_id)
            warn(f"{task_id}: branch writer generation cannot be checked; no grant assumed")
            return None
        # The central head chain is authoritative; a lost publish-head reply leaves the local cache behind it.
        if checked["head_oid"] != task.get("published_head"):
            task["published_head"] = checked["head_oid"]
            self.save()
        return payload

    def ci_ready(self, task_id, worktree):
        if not self.live_claim(task_id):
            return False
        head = git(worktree, "rev-parse", "HEAD")
        if head != self.state["tasks"][task_id].get("published_head"):
            warn(f"{task_id}: HEAD {head} is not the published head; run pre-push before requesting CI")
            return False
        return True

    def changed_paths(self, task, worktree):
        output = subprocess.run(["git", "-C", str(worktree), "diff", "--name-only", "--no-renames", "-z", f"origin/{task['base']}...HEAD"], check=True, capture_output=True).stdout
        return sorted({x.decode("utf-8", "surrogateescape") for x in output.split(b"\0") if x})

    def scope(self, task_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            warn(f"{task_id}: no local intent record for scope check")
            return
        live = self.live_claim(task_id)
        paths = self.changed_paths(task, worktree)
        covered = lambda name: any((kind == "file" and value == name) or (kind == "directory" and (name == value or name.startswith(value + "/"))) for kind, value in task.get("resources", []))
        undeclared = sorted(p for p in set(task.get("pending_paths", [])) | set(paths) if not covered(p))
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
        if task["pending_paths"]:
            warn(f"{task_id}: head not published; changed paths have no confirmed claim: {', '.join(task['pending_paths'])}")
            return
        head = git(worktree, "rev-parse", "HEAD")
        for key, item in list(self.state["requests"].items()):
            if item["op"] != "publish-head" or not key.startswith(f"{task_id}:") or "reply" in item:
                continue
            stale = item["payload"]
            if stale["expected_previous_oid"] != task.get("published_head"):
                del self.state["requests"][key]
                self.save()
            elif stale["head_oid"] != head:
                if not self.send(key, "publish-head", {k: v for k, v in stale.items() if k != "request_id"}):
                    return
                task["published_head"] = stale["head_oid"]
                del self.state["requests"][key]
                self.save()
        if head != task.get("published_head"):
            previous = task.get("published_head")
            key = f"{task_id}:head:{previous}:{head}"
            reply = self.send(key, "publish-head", {**live, "intent_id": task["intent_id"], "head_oid": head, "expected_previous_oid": previous})
            if reply:
                task["published_head"] = head
                task.pop("pending_head", None)
                self.save()
            elif "UNIQUE constraint failed: heads" in self.last_error:
                warn(f"{task_id}: head {head} was already published for this intent; central head remains {previous}")
                del self.state["requests"][key]
                task.pop("pending_head", None)
                self.save()
        else:
            task.pop("pending_head", None)
            self.save()

    def replay(self):
        for key, item in list(self.state["requests"].items()):
            if self.reset:
                return
            if "reply" not in item and item["op"] not in {"publish-head", "release", "queue-attempt"}:
                self.send(key, item["op"], {k: v for k, v in item["payload"].items() if k != "request_id"})
        for task_id, task in list(self.state["tasks"].items()):
            if self.reset:
                return
            self.settle_release(task_id)
            if task.get("pending_dispatch"):
                self.ensure_task(task_id)
            if "claim" not in task:
                continue
            if (task.get("pending_paths") or task.get("pending_head")) and task.get("worktree"):
                self.scope(task_id, task["worktree"])
            if task.get("pending_ci"):
                if not task.get("worktree"):
                    warn(f"{task_id}: pending pre-ci has no recorded worktree; rerun pre-ci TASK WORKTREE")
                elif self.ci_ready(task_id, task["worktree"]):
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

    def release(self, task_id):
        task = self.state["tasks"].get(task_id)
        if not task:
            return
        claim = task.get("claim")
        if claim:
            # Journal the release and link it to the task in the same save that drops the old attempt.
            key = f"release:{claim['claim_id']}"
            self.state["requests"][key] = {"op": "release", "payload": {"request_id": str(uuid.uuid4()), "home_id": self.config["home_id"], "generation": self.state["requests"]["session"]["reply"]["generation"], "claim_id": claim["claim_id"], "fence": claim["fence"]}}
            task["releasing"] = key
        self.reset_task(task_id)
        for flag in ("pending_dispatch", "pending_head", "pending_ci", "pending_paths"):
            task.pop(flag, None)
        self.save()
        self.reset = False
        self.settle_release(task_id)

    def settle_release(self, task_id):
        """Send the prior attempt's queued claim release; False while it is still unrecorded centrally."""
        task = self.state["tasks"][task_id]
        key = task.get("releasing")
        item = self.state["requests"].get(key)
        if item and "reply" not in item and self.send(key, "release", {k: v for k, v in item["payload"].items() if k != "request_id"}) is None:
            if key in self.state["requests"] and "claim is not active" not in self.last_error:
                warn(f"{task_id}: prior claim release queued; replay resends it before any new attempt is submitted")
                return False
        if key:
            self.state["requests"].pop(key, None)
            task.pop("releasing", None)
            self.save()
        return True

    def attempt(self, task_id, fields):
        live = self.live_claim(task_id)
        if not live:
            return
        start = process_start(fields.get("wrapper_pid"))
        if start is None:
            raise ValueError(f"{task_id}: wrapper process is not running on this host")
        payload = {**fields, **live, "intent_id": self.state["tasks"][task_id]["intent_id"], "wrapper_start": start}
        reply = self.send(f"{task_id}:attempt:{fields.get('slot_generation')}:{fields['wrapper_pid']}", "queue-attempt", payload)
        if reply:
            print(json.dumps(reply, sort_keys=True))

    def wrapper_exited(self, task_id, fields):
        task = self.state["tasks"].get(task_id)
        if task is None:
            warn(f"{task_id}: no local intent record; wrapper exit not reported")
            return
        # Attest only after this host proves the exact wrapper process is gone.
        if process_start(fields.get("wrapper_pid")) == fields.get("wrapper_start"):
            raise ValueError(f"{task_id}: wrapper process is still running")
        generation = self.setup()
        if generation is None:
            warn(f"{task_id}: wrapper exit pending; slot stays outcome-unknown")
            return
        payload = {**fields, "intent_id": task["intent_id"], "home_id": self.config["home_id"], "generation": generation, "exit_verified_host_id": self.state["requests"]["enroll"]["payload"].get("host_id")}
        reply = self.send(f"{task_id}:exit:{fields.get('attempt_event_id')}", "queue-wrapper-exited", payload)
        if reply:
            print(json.dumps(reply, sort_keys=True))

    def view(self):
        central = self.call("view", {})
        pending = [{"key": key, "operation": item["op"], "request_id": item["payload"]["request_id"]} for key, item in self.state["requests"].items() if "reply" not in item]
        pending.extend({"key": task_id, "operation": action} for task_id, task in self.state["tasks"].items() for action, flag in (("dispatch", task.get("pending_dispatch")), ("pre-push", task.get("pending_head")), ("pre-ci", task.get("pending_ci")), ("scope-amend", task.get("pending_paths")), ("heartbeat", task.get("renew_key"))) if flag)
        print(json.dumps({"mode": self.config["mode"], "central": central, "local_pending": pending, "local_tasks": self.state["tasks"]}, sort_keys=True))


def run(adapter, command):
    if command == "dispatch" and len(sys.argv) == 8:
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
    elif command == "pre-ci" and len(sys.argv) in {3, 4}:
        task = adapter.state["tasks"].get(sys.argv[2])
        worktree = sys.argv[3] if len(sys.argv) == 4 else (task or {}).get("worktree")
        if task and not worktree:
            raise ValueError(f"{sys.argv[2]}: pre-ci needs a WORKTREE argument; this task has no recorded worktree")
        if task:
            task["worktree"] = worktree
            task["pending_ci"] = True
            adapter.save()
        if adapter.ci_ready(sys.argv[2], worktree) and task:
            task.pop("pending_ci", None)
            adapter.save()
    elif command in {"attempt", "wrapper-exited"} and len(sys.argv) == 4:
        fields = json.loads(sys.argv[3])
        if not isinstance(fields, dict):
            raise ValueError(f"{command} fields must be a JSON object")
        (adapter.attempt if command == "attempt" else adapter.wrapper_exited)(sys.argv[2], fields)
    elif command == "release" and len(sys.argv) == 3:
        adapter.release(sys.argv[2])
    elif command == "replay" and len(sys.argv) == 2:
        adapter.replay()
    elif command == "view" and len(sys.argv) == 2:
        adapter.view()
    else:
        raise ValueError("wrong adapter arguments")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in {"dispatch", "pre-push", "pre-ci", "heartbeat", "attempt", "wrapper-exited", "release", "replay", "view"}:
        print("usage: fm-coord-adapter.py <dispatch TASK PROJECT WORKTREE BRIEF BRANCH HARNESS|pre-push TASK WORKTREE|pre-ci TASK [WORKTREE]|heartbeat TASK|attempt TASK JSON|wrapper-exited TASK JSON|release TASK|replay|view>", file=sys.stderr)
        return 2
    home = os.environ.get("FM_HOME")
    if not home:
        warn("FM_HOME is required")
        return 1
    try:
        adapter = Adapter(Path(home))
        if not adapter.enabled:
            return 0
        for _ in range(3):
            adapter.reset = False
            run(adapter, sys.argv[1])
            if not adapter.reset:
                break
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        warn(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
