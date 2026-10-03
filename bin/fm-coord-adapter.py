#!/usr/bin/env python3
"""Local lifecycle adapter for advisory and opt-in enforced coordination.

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
    print(f"fm-coord: {message}", file=sys.stderr)


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


def pull_repo(url):
    match = re.fullmatch(r"https://github\.com/([^/]+)/([^/]+)/pull/[0-9]+", url)
    return f"{match[1]}/{match[2]}" if match else None


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
        self.repo = None
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
        enforced = self.config.get("enforce_repos", [])
        if not isinstance(enforced, list) or any(repo not in self.config["repos"] for repo in enforced) or len(enforced) != len(set(enforced)):
            raise ValueError("enforce_repos must be a unique subset of repos")
        self.enforced_repos = set(enforced)
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

    def required(self, repo, condition, message):
        if not condition and repo in self.enforced_repos:
            raise ValueError(f"{repo}: enforcement paused: {message}")

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

    def session_key(self):
        epoch = self.state.get("session_epoch", 0)
        return f"session:{epoch}" if epoch else "session"

    def setup(self):
        home_id = self.config["home_id"]
        epoch = self.state.get("session_epoch", 0)
        if self.send(f"enroll:{epoch}" if epoch else "enroll", "enroll", {"home_id": home_id, "repos": self.config["repos"]}) is None:
            return None
        session = self.send(self.session_key(), "session", {"home_id": home_id})
        return session["generation"] if session else None

    def key(self, task_id, task):
        return f"{task_id}#{task['admission']}" if task.get("admission") else task_id

    def ensure_task(self, task_id):
        task = self.state["tasks"][task_id]
        generation = self.setup()
        if generation is None:
            warn(f"{task_id}: offline intent pending; no claim granted")
            return task
        common = {"intent_id": task["intent_id"], "home_id": self.config["home_id"], "generation": generation}
        submitted = self.send(f"{self.key(task_id, task)}:submit", "submit", {**common, "repo": task["repo"], "base": task["base"], "base_oid": task["base_oid"], "branch": task["branch"], "task_id": task_id, "goal": task["goal"], "resources": task["declared"], **({"issue": task["issue"]} if task["issue"] else {})})
        if submitted is None:
            warn(f"{task_id}: intent pending; no claim granted")
            return task
        attempt = task.get("claim_attempt", 0)
        claim = self.send(f"{self.key(task_id, task)}:claim" + (f":{attempt}" if attempt else ""), "claim", {**common, "version": submitted["version"]})
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

    def resolve_repo(self, project):
        return self.config.get("project_repos", {}).get(str(Path(project).resolve())) or repo_name(project)

    def dispatch(self, task_id, project, brief, branch, harness):
        self.state.setdefault("task_repos", {})[task_id] = None
        try:
            self.repo = self.resolve_repo(project)
        finally:
            self.state["task_repos"][task_id] = self.repo
            self.save()
        repo = self.repo
        if harness not in {"claude", "codex", "omp", "opencode"}:
            warn(f"{task_id}: {harness} has no coordination adapter; dispatch continues without a grant")
            self.required(repo, False, f"{harness} has no coordination adapter")
            return
        resources, issue = declared(brief)
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
        self.required(repo, bool(task.get("claim", {}).get("ok")), f"{task_id} has no admitted claim")

    def live_claim(self, task_id):
        task = self.ensure_task(task_id)
        claim = task.get("claim")
        if not claim:
            warn(f"{task_id}: branch writer has no confirmed claim")
            return None
        payload = {"home_id": self.config["home_id"], "generation": self.setup(), "claim_id": claim["claim_id"], "fence": claim["fence"]}
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
            raise ValueError(f"{task_id}: no local intent record for scope check")
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
            attempt = task.get("amend_attempt", 0)
            key = f"{self.key(task_id, task)}:amend:{task['version']}" + (f":{attempt}" if attempt else "")
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
        self.required(task["repo"], bool(live), f"{task_id} has no current branch writer generation")
        self.required(task["repo"], not task.get("pending_paths"), f"{task_id} has undeclared scope; re-admission required")
        if not live:
            return
        head = git(worktree, "rev-parse", "HEAD")
        if head != task.get("published_head"):
            previous = task.get("published_head")
            reply = self.send(f"{self.key(task_id, task)}:head:{head}", "publish-head", {**live, "intent_id": task["intent_id"], "head_oid": head, "expected_previous_oid": previous})
            if reply:
                task["published_head"] = head
                task.pop("pending_head", None)
                self.save()
            self.required(task["repo"], reply is not None, f"{task_id} head publication is unconfirmed")
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
            if task.get("pending_ci") and task["repo"] not in self.enforced_repos and self.live_claim(task_id):
                task.pop("pending_ci", None)
                self.save()
            if task.get("renew_key") and "reply" in self.state["requests"].get(task["renew_key"], {}):
                task.pop("renew_key", None)
                self.save()

    def readmit(self, task_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            raise ValueError(f"{task_id}: no local intent to readmit")
        claim = task.get("claim")
        central = self.call("inspect", {}) if claim else None
        if central is not None and not any(c["claim_id"] == claim["claim_id"] and c["state"] == "active" for c in central["claims"]):
            home_id = self.config["home_id"]
            session = self.state["requests"].get(self.session_key(), {}).get("reply", {})
            if not any(p["home_id"] == home_id and p["generation"] == session.get("generation") and p["session_id"] == session.get("session_id") for p in central["participants"]):
                self.state["session_epoch"] = self.state.get("session_epoch", 0) + 1
            task["admission"] = task.get("admission", 0) + 1
            task["intent_id"] = f"{home_id}:{task['repo']}:{task_id}:{task['admission']}"
            for field in ("claim", "claim_attempt", "version", "resources", "published_head", "renew_key"):
                task.pop(field, None)
            for key, item in list(self.state["requests"].items()):
                if "reply" not in item and item["payload"].get("claim_id") == claim["claim_id"]:
                    del self.state["requests"][key]
            self.save()
        if not task.get("claim", {}).get("ok"):
            attempt = task.get("claim_attempt", 0)
            key = f"{self.key(task_id, task)}:claim" + (f":{attempt}" if attempt else "")
            if "reply" in self.state["requests"].get(key, {}):
                task["claim_attempt"] = attempt + 1
                self.save()
            self.ensure_task(task_id)
        self.required(task["repo"], bool(task.get("claim", {}).get("ok")), f"{task_id} claim remains denied")
        task["amend_attempt"] = task.get("amend_attempt", 0) + 1
        self.save()
        self.scope(task_id, worktree)

    def land(self, task_id, task, url, head):
        """Advance this task's queue item to an attempting slot from the observed central state.

        Each transition is guarded by the central queue state, so a lost reply is
        recovered by re-reading that state rather than replaying a journaled request.
        The wrapper's live GitHub view (FM_PR_GITHUB_VIEW) and required checks
        (FM_PR_GITHUB_REQUIRED) are the check, base, and validation evidence, and the
        forge compares the head with that base so a stale local worktree cannot refuse
        it; the wrapper has already passed the captain hold, away, and merge authority checks.
        """
        live = self.live_claim(task_id)
        if not live or head != task.get("published_head"):
            warn(f"{task_id}: merge head {head} is not the live published head")
            return
        view = json.loads(os.environ.get("FM_PR_GITHUB_VIEW") or "{}")
        required = json.loads(os.environ.get("FM_PR_GITHUB_REQUIRED") or "[]")
        base_oid = view.get("baseRefOid")
        compare = subprocess.run(["gh", "api", f"repos/{task['repo']}/compare/{base_oid}...{head}", "--jq", ".status"], capture_output=True, text=True, timeout=30, check=False) if base_oid else None
        contains = compare is not None and compare.returncode == 0 and compare.stdout.strip() in {"ahead", "identical"}
        # ponytail: the wrapper already judged reruns and waivers; any ok run of a name counts here.
        ok = {}
        for check in view.get("statusCheckRollup", []):
            name = check.get("name") or check.get("context")
            ok[name] = ok.get(name, False) or check.get("conclusion", check.get("state")) in {"SUCCESS", "NEUTRAL", "SKIPPED"}
        checks = [{"name": name, "head_oid": head, "conclusion": "success" if green else "failure"} for name, green in ok.items()]
        owner = {**live, "intent_id": task["intent_id"]}
        evidence = {"current_head_oid": head, "current_base_oid": base_oid, "head_contains_base": contains}
        for _ in range(10):
            central = self.call("inspect", {})
            if central is None:
                return
            intent = next((i for i in central["intents"] if i["intent_id"] == task["intent_id"]), None)
            item = next((q for q in central["queue"] if q["intent_id"] == task["intent_id"]), None)
            slot = next((s for s in central["slots"] if s["intent_id"] == task["intent_id"]), None)
            state = item["state"] if item else None
            if intent is None or state in {"attempting", "outcome-unknown", "merged"}:
                return
            fresh = {"request_id": str(uuid.uuid4())}
            if intent["pr_url"] is None:
                step = ("attach-pr", {**owner, "pr_url": url})
            elif state in {None, "sync-needed", "repair-needed", "refused"}:
                step = ("queue-ready", {**owner, "head_oid": head})
            elif state == "ready":
                granted = self.call("queue-next", {**fresh, "repo": task["repo"], "base": task["base"]})
                if not granted or granted.get("intent_id") != task["intent_id"]:
                    warn(f"{task_id}: integration slot is held by another candidate")
                    return
                continue
            elif slot is None:
                return
            elif state == "syncing":
                step = ("queue-synced", {**owner, **evidence, "slot_generation": slot["generation"]})
            elif state == "validating":
                step = ("queue-validated", {**owner, **evidence, "slot_generation": slot["generation"], "validation_passed": True, "validation_id": f"fm-pr-merge:{head}"})
            elif item["manifest_version"] is None:
                step = ("queue-checks", {**owner, **evidence, "slot_generation": slot["generation"], "protection_available": True, "forge_required_checks": sorted({c["context"] for c in required}), "checks": checks})
            else:
                step = ("queue-attempt", {**owner, **evidence, "slot_generation": slot["generation"], "captain_hold_released": True, "away_merge_allowed": True, "merge_authorized": True})
            if self.call(step[0], {**fresh, **step[1]}) is None:
                return

    def pre_merge(self, task_id, url, head):
        repo = self.repo = pull_repo(url)
        if repo not in self.enforced_repos:
            return
        if not OID.fullmatch(head):
            raise ValueError("merge head must be a full Git object ID")
        task = self.state["tasks"].get(task_id)
        if task and task["repo"] == repo:
            self.land(task_id, task, url, head)
        receipt = self.call("merge-guard", {"pr_url": url, "head_oid": head})
        self.required(repo, receipt is not None and receipt.get("ok") is True, "integration slot is absent, stale, or unreachable")

    def merge_result(self, task_id, url, outcome):
        """Settle this task's attempted slot from the merge wrapper's forge outcome.

        Only a refusal the wrapper proved unlanded releases the slot directly; any
        other outcome is recorded as outcome-unknown and settles as merged only when
        queue-reconcile's live forge read proves the exact head landed.
        """
        if outcome not in {"merged", "refused", "unknown"}:
            raise ValueError("merge outcome must be merged, refused, or unknown")
        repo = self.repo = pull_repo(url)
        task = self.state["tasks"].get(task_id)
        if repo not in self.enforced_repos or not task or task["repo"] != repo:
            return
        central = self.call("inspect", {})
        if central is None:
            return
        item = next((q for q in central["queue"] if q["intent_id"] == task["intent_id"]), None)
        slot = next((s for s in central["slots"] if s["intent_id"] == task["intent_id"]), None)
        if item is None or slot is None:
            return
        attempt = {"intent_id": task["intent_id"], "generation": slot["generation"]}
        state = item["state"]
        if state == "attempting" and outcome == "refused":
            view = json.loads(os.environ.get("FM_PR_GITHUB_VIEW") or "{}")
            self.call("queue-result", {"request_id": str(uuid.uuid4()), **attempt, "outcome": "refused", "wrapper_refused": True, "pr_merged": False, "observed_base_oid": view.get("baseRefOid")})
            return
        if state == "attempting" and self.call("queue-result", {"request_id": str(uuid.uuid4()), **attempt, "outcome": "unknown"}):
            state = "outcome-unknown"
        if state == "outcome-unknown" and self.call("queue-reconcile", {"request_id": str(uuid.uuid4()), **attempt, "outcome": "merged", "pr_url": url, "base": task["base"]}) is None:
            warn(f"{task_id}: merge outcome stays unknown until a live forge read proves the landing")

    def pre_ci(self, task_id, batch_id):
        task = self.state["tasks"].get(task_id)
        if not task:
            raise ValueError(f"{task_id}: no local intent record for CI pulse")
        key = f"{self.key(task_id, task)}:pulse:{batch_id}"
        prior = self.state["requests"].get(key)
        answered = prior is not None and "reply" in prior
        self.required(task["repo"], not answered, f"batch {batch_id} pulse was already requested")
        if answered:
            return
        task["pending_ci"] = True
        self.save()
        live = self.live_claim(task_id)
        self.required(task["repo"], bool(live), f"{task_id} CI pulse lacks current branch writer generation")
        if not live:
            return
        if not task.get("published_head"):
            self.required(task["repo"], False, f"{task_id} CI pulse has no published head")
            return
        payload = {k: v for k, v in prior["payload"].items() if k != "request_id"} if prior else {**live, "intent_id": task["intent_id"], "head_oid": task["published_head"], "batch_id": batch_id}
        receipt = self.send(key, "pulse-batch", payload)
        self.required(task["repo"], receipt is not None and receipt.get("ok") is True, f"batch {batch_id} pulse is unconfirmed or already issued")
        if receipt and receipt.get("ok") is True:
            task.pop("pending_ci", None)
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
    if len(sys.argv) < 2 or sys.argv[1] not in {"dispatch", "pre-push", "pre-ci", "pre-merge", "merge-result", "readmit", "heartbeat", "replay", "view"}:
        print("usage: fm-coord-adapter.py <dispatch TASK PROJECT BRIEF BRANCH HARNESS|pre-push TASK WORKTREE|pre-ci TASK [BATCH]|pre-merge TASK PR_URL HEAD|merge-result TASK PR_URL merged|refused|unknown|readmit TASK WORKTREE|heartbeat TASK|replay|view>", file=sys.stderr)
        return 2
    home = os.environ.get("FM_HOME")
    if not home:
        warn("FM_HOME is required")
        return 1
    command = sys.argv[1]
    adapter = None
    undispatched = False
    try:
        adapter = Adapter(Path(home))
        if not adapter.enabled:
            return 0
        if command in {"pre-push", "pre-ci", "heartbeat"} and len(sys.argv) > 2:
            dispatched = {**{task_id: task["repo"] for task_id, task in adapter.state["tasks"].items()}, **adapter.state.get("task_repos", {})}
            undispatched = sys.argv[2] not in dispatched
            adapter.repo = dispatched.get(sys.argv[2])
            if undispatched and command == "pre-push" and len(sys.argv) == 4:
                adapter.repo = adapter.resolve_repo(sys.argv[3])
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
        elif command == "readmit" and len(sys.argv) == 4:
            adapter.readmit(sys.argv[2], sys.argv[3])
        elif command == "pre-ci" and len(sys.argv) in {3, 4}:
            adapter.pre_ci(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else sys.argv[2])
        elif command == "pre-merge" and len(sys.argv) == 5:
            adapter.pre_merge(sys.argv[2], sys.argv[3], sys.argv[4])
        elif command == "merge-result" and len(sys.argv) == 5:
            adapter.merge_result(sys.argv[2], sys.argv[3], sys.argv[4])
        elif command == "replay" and len(sys.argv) == 2:
            adapter.replay()
        elif command == "view" and len(sys.argv) == 2:
            adapter.view()
        else:
            raise ValueError("wrong adapter arguments")
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        warn(str(exc))
        unowned = undispatched and command == "pre-ci" and adapter.enforced_repos
        return 0 if adapter is not None and command in {"dispatch", "pre-push", "pre-ci", "pre-merge", "heartbeat"} and adapter.repo not in adapter.enforced_repos and not unowned else 1


if __name__ == "__main__":
    sys.exit(main())
