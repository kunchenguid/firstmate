#!/usr/bin/env python3
"""Local lifecycle adapter for advisory and opt-in enforced coordination.

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


class Usage(ValueError):
    """A command-line mistake, refused even for a shadow repository."""


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
    if not isinstance(parsed, list):
        raise ValueError("brief coordination resources must be a JSON array")
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

    def required(self, repo, condition, message):
        if not condition and repo in self.enforced_repos:
            raise ValueError(f"{repo}: enforcement paused: {message}")

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
        # An unsettled remote attempt keeps its own identity and attempt-keyed exit request; session requests start fresh.
        held = (f"{task_id}:exit:",) if task.get("attempt") else ()
        for key in [k for k in self.state["requests"] if k.startswith(f"{task_id}:") and not k.startswith(held)]:
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
        key = f"{task_id}:submit"
        scope = self.state["requests"][key]["payload"]["resources"] if key in self.state["requests"] else self.claim_scope(task)
        submitted = self.send(key, "submit", {**common, "repo": task["repo"], "base": task["base"], "base_oid": task["base_oid"], "branch": task["branch"], "task_id": task_id, "goal": task["goal"], "resources": scope, **({"issue": task["issue"]} if task["issue"] else {})})
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

    def claim_scope(self, task):
        # Claim scope is durable task state: a replacement claim covers the brief, every amendment, and the work already in the worktree.
        paths = set(task.get("amended", []))
        if task.get("worktree"):
            paths |= set(self.changed_paths(task, task["worktree"]))
        return task["declared"] + [r for r in ({"type": "file", "name": p} for p in sorted(paths)) if r not in task["declared"]]

    def resolve_repo(self, project):
        return self.config.get("project_repos", {}).get(str(Path(project).resolve())) or repo_name(project)

    def dispatch(self, task_id, project, worktree, brief, branch, harness):
        # Record the owning repository first so a later checkpoint can tell a shadow task from an undispatched one.
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
        self.required(repo, bool(task.get("claim", {}).get("ok")), f"{task_id} has no admitted claim")

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
        """The live writer payload when the worktree HEAD is the centrally published head, else None."""
        live = self.live_claim(task_id)
        if not live:
            return None
        head = git(worktree, "rev-parse", "HEAD")
        if head != self.state["tasks"][task_id].get("published_head"):
            warn(f"{task_id}: HEAD {head} is not the published head; run pre-push before requesting CI")
            return None
        return live

    def changed_paths(self, task, worktree):
        output = subprocess.run(["git", "-C", str(worktree), "diff", "--name-only", "--no-renames", "-z", f"origin/{task['base']}...HEAD"], check=True, capture_output=True).stdout
        return sorted({x.decode("utf-8", "surrogateescape") for x in output.split(b"\0") if x})

    def scope(self, task_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            raise ValueError(f"{task_id}: no local intent record for scope check")
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
                task["amended"] = sorted(set(task.get("amended", [])) | added)
                self.save()
            elif amended:
                for conflict in amended["conflicts"]:
                    warn(f"{task_id}: amendment conflict held by {conflict['home_id']} intent {conflict['intent_id']}")
        if self.reset:
            return
        self.required(task["repo"], bool(live), f"{task_id} has no current branch writer generation")
        self.required(task["repo"], not task.get("pending_paths"), f"{task_id} has undeclared scope; re-admission required")
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
            self.required(task["repo"], reply is not None, f"{task_id} head publication is unconfirmed")
        else:
            task.pop("pending_head", None)
            self.save()

    def replay(self):
        for key, item in list(self.state["requests"].items()):
            if self.reset:
                return
            if "reply" not in item and item["op"] not in {"publish-head", "release", "queue-attempt", "queue-wrapper-exited"}:
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
                elif task["repo"] not in self.enforced_repos and self.ci_ready(task_id, task["worktree"]):
                    task.pop("pending_ci", None)
                    self.save()
            if task.get("renew_key") and "reply" in self.state["requests"].get(task["renew_key"], {}):
                task.pop("renew_key", None)
                self.save()

    def readmit(self, task_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            raise ValueError(f"{task_id}: no local intent to readmit")
        self.repo = task["repo"]
        # live_claim rotates a revoked claim or an expired session; the run loop then readmits under the new intent.
        live = self.live_claim(task_id)
        if self.reset:
            return
        self.required(task["repo"], bool(live), f"{task_id} claim remains denied")
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
        # Only the forge's answer decides containment; an unavailable comparison is unknown, never "lacks base".
        status, reason = "", "pull request view has no base OID"
        if base_oid:
            try:
                compare = subprocess.run(["gh", "api", f"repos/{task['repo']}/compare/{base_oid}...{head}", "--jq", ".status"], capture_output=True, text=True, timeout=30, check=False)
                status = compare.stdout.strip() if compare.returncode == 0 else ""
                reason = compare.stderr.strip() or f"status {compare.stdout.strip()!r}, exit {compare.returncode}"
            except (OSError, subprocess.TimeoutExpired) as exc:
                reason = str(exc)
        contains = {"ahead": True, "identical": True, "behind": False, "diverged": False}.get(status)
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
            if intent is None or state in {"attempting", "merged"} or (state == "outcome-unknown" and slot is None):
                return
            fresh = {"request_id": str(uuid.uuid4())}
            if state == "outcome-unknown" and slot is not None:
                # A new merge run means the prior wrapper is gone; settle that attempt from the forge before re-queueing.
                step = ("queue-reconcile", {"intent_id": task["intent_id"], "generation": slot["generation"], "pr_url": url, "base": task["base"], "head_oid": item["head_oid"]})
            elif intent["pr_url"] is None:
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
            elif contains is None:
                warn(f"{task_id}: queue synchronization paused: forge comparison of {head} with base {base_oid} is unavailable ({reason}); retry the merge")
                return
            elif state == "syncing":
                step = ("queue-synced", {**owner, **evidence, "slot_generation": slot["generation"]})
            elif state == "validating":
                step = ("queue-validated", {**owner, **evidence, "slot_generation": slot["generation"], "validation_passed": True, "validation_id": f"fm-pr-merge:{head}"})
            elif item["manifest_version"] is None:
                step = ("queue-checks", {**owner, **evidence, "slot_generation": slot["generation"], "protection_available": True, "forge_required_checks": sorted({c["context"] for c in required}), "checks": checks})
            else:
                # The merge wrapper (fm-pr-merge.sh) is this adapter's parent process.
                self.attempt(task_id, {**evidence, "slot_generation": slot["generation"], "captain_hold_released": True, "away_merge_allowed": True, "merge_authorized": True, "wrapper_pid": os.getppid()})
                return
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

        A landing the live forge read proves settles merged at once; any other
        outcome is recorded as outcome-unknown, and queue-reconcile settles it
        from the forge only after this wrapper has exited (the next merge run).
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
        reconcile = {"request_id": str(uuid.uuid4()), **attempt, "pr_url": url, "base": task["base"], "head_oid": item["head_oid"]}
        if state == "attempting" and outcome == "merged" and self.call("queue-reconcile", reconcile):
            return
        if state == "attempting" and self.call("queue-result", {"request_id": str(uuid.uuid4()), **attempt, "outcome": "refused" if outcome == "refused" else "unknown"}):
            state = "outcome-unknown"
        if state == "outcome-unknown" and self.call("queue-reconcile", {**reconcile, "request_id": str(uuid.uuid4())}) is None:
            warn(f"{task_id}: merge outcome stays unknown until a live forge read settles it after the wrapper exits")

    def pre_ci(self, task_id, batch_id, worktree):
        task = self.state["tasks"].get(task_id)
        if not task:
            raise ValueError(f"{task_id}: no local intent record for CI pulse")
        worktree = worktree or task.get("worktree")
        if not worktree:
            raise Usage(f"{task_id}: pre-ci needs a WORKTREE argument; this task has no recorded worktree")
        key = f"{task_id}:pulse:{batch_id}"
        prior = self.state["requests"].get(key)
        if prior is not None and prior.get("reply", {}).get("admitted") is False:
            # A queued batch is polled with a fresh request; the coordinator hands its one authorization to the first poll after admission.
            del self.state["requests"][key]
            prior = None
        answered = prior is not None and "reply" in prior
        if answered and prior["reply"].get("ok") is True and task.get("pending_ci") == batch_id:
            # replay received this batch's authorization; hand it to the worker once.
            task.pop("pending_ci")
            self.save()
            return
        self.required(task["repo"], not answered, f"batch {batch_id} pulse was already requested")
        if answered:
            return
        task["worktree"] = worktree
        task["pending_ci"] = batch_id
        self.save()
        # The batch is authorized only for the head the worker is about to validate.
        live = self.ci_ready(task_id, worktree)
        if self.reset:
            return
        self.required(task["repo"], bool(live), f"{task_id} CI pulse needs a live claim on the published HEAD")
        if not live:
            return
        payload = {k: v for k, v in prior["payload"].items() if k != "request_id"} if prior else {**live, "intent_id": task["intent_id"], "head_oid": task["published_head"], "batch_id": batch_id}
        receipt = self.send(key, "pulse-batch", payload)
        self.required(task["repo"], receipt is not None and receipt.get("ok") is True, f"batch {batch_id} pulse is unconfirmed or already issued")
        if receipt and receipt.get("admitted") is False:
            warn(f"{task_id}: batch {batch_id} is queued for CI capacity at position {receipt['position']}; rerun pre-ci for this batch before requesting CI")
            self.required(task["repo"], False, f"batch {batch_id} awaits a CI slot")
            return
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
        for flag in ("pending_dispatch", "pending_head", "pending_ci", "pending_paths", "amended", "worktree"):
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
        if reply and self.state["requests"]["enroll"]["payload"].get("host_id"):
            # Only this adapter can report a remote wrapper's exit; keep the attempt identity until it does.
            self.state["tasks"][task_id]["attempt"] = {"attempt_event_id": reply["attempt_event_id"], "intent_id": payload["intent_id"], "wrapper_pid": fields["wrapper_pid"], "wrapper_start": start}
            self.save()
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
        attempt = task.get("attempt", {})
        recorded = attempt.get("attempt_event_id") == fields.get("attempt_event_id")
        payload = {**fields, "intent_id": attempt["intent_id"] if recorded else task["intent_id"], "home_id": self.config["home_id"], "generation": generation, "exit_verified_host_id": self.state["requests"]["enroll"]["payload"].get("host_id")}
        key = f"{task_id}:exit:{fields.get('attempt_event_id')}"
        if key in self.state["requests"] and "reply" not in self.state["requests"][key]:
            # The coordinator keys this receipt to the attempt, not the session, so a new session reuses the request ID.
            self.state["requests"][key]["payload"]["generation"] = generation
        reply = self.send(key, "queue-wrapper-exited", payload)
        if reply and recorded:
            task.pop("attempt")
            self.save()
        if reply:
            print(json.dumps(reply, sort_keys=True))

    def view(self):
        central = self.call("view", {})
        pending = [{"key": key, "operation": item["op"], "request_id": item["payload"]["request_id"]} for key, item in self.state["requests"].items() if "reply" not in item]
        pending.extend({"key": task_id, "operation": action} for task_id, task in self.state["tasks"].items() for action, flag in (("dispatch", task.get("pending_dispatch")), ("pre-push", task.get("pending_head")), ("pre-ci", task.get("pending_ci")), ("scope-amend", task.get("pending_paths")), ("heartbeat", task.get("renew_key"))) if flag)
        print(json.dumps({"mode": self.config["mode"], "central": central, "local_pending": pending, "local_tasks": self.state["tasks"]}, sort_keys=True))


def run(adapter, command):
    argv = sys.argv
    if command == "dispatch" and len(argv) == 8:
        adapter.dispatch(*argv[2:])
    elif command == "pre-push" and len(argv) == 4:
        task = adapter.state["tasks"].get(argv[2])
        if task:
            task["worktree"] = argv[3]
            task["pending_head"] = git(argv[3], "rev-parse", "HEAD")
            adapter.save()
        adapter.scope(argv[2], argv[3])
    elif command == "heartbeat" and len(argv) == 3:
        adapter.heartbeat(argv[2])
    elif command == "readmit" and len(argv) == 4:
        adapter.readmit(argv[2], argv[3])
    elif command == "pre-ci" and len(argv) in {3, 4, 5}:
        adapter.pre_ci(argv[2], argv[3] if len(argv) > 3 else argv[2], argv[4] if len(argv) == 5 else None)
    elif command == "pre-merge" and len(argv) == 5:
        adapter.pre_merge(argv[2], argv[3], argv[4])
    elif command == "merge-result" and len(argv) == 5:
        adapter.merge_result(argv[2], argv[3], argv[4])
    elif command in {"attempt", "wrapper-exited"} and len(argv) == 4:
        fields = json.loads(argv[3])
        if not isinstance(fields, dict):
            raise Usage(f"{command} fields must be a JSON object")
        (adapter.attempt if command == "attempt" else adapter.wrapper_exited)(argv[2], fields)
    elif command == "release" and len(argv) == 3:
        adapter.release(argv[2])
    elif command == "replay" and len(argv) == 2:
        adapter.replay()
    elif command == "view" and len(argv) == 2:
        adapter.view()
    else:
        raise Usage("wrong adapter arguments")


COMMANDS = {"dispatch", "pre-push", "pre-ci", "pre-merge", "merge-result", "readmit", "heartbeat", "attempt", "wrapper-exited", "release", "replay", "view"}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("usage: fm-coord-adapter.py <dispatch TASK PROJECT WORKTREE BRIEF BRANCH HARNESS|pre-push TASK WORKTREE|pre-ci TASK [BATCH [WORKTREE]]|pre-merge TASK PR_URL HEAD|merge-result TASK PR_URL merged|refused|unknown|readmit TASK WORKTREE|heartbeat TASK|attempt TASK JSON|wrapper-exited TASK JSON|release TASK|replay|view>", file=sys.stderr)
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
        for _ in range(3):
            adapter.reset = False
            run(adapter, command)
            if not adapter.reset:
                break
        adapter.required(adapter.repo, not adapter.reset, "coordination session kept resetting; no grant assumed")
        return 0
    except Usage as exc:
        warn(str(exc))
        return 1
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        warn(str(exc))
        unowned = undispatched and command == "pre-ci" and adapter.enforced_repos
        return 0 if adapter is not None and command in {"dispatch", "pre-push", "pre-ci", "pre-merge", "heartbeat"} and adapter.repo not in adapter.enforced_repos and not unowned else 1


if __name__ == "__main__":
    sys.exit(main())
