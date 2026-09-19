#!/usr/bin/env python3
"""Restricted account-task protocol (v1), NOT remote-secondmate provisioning.

Usage:
  python3 -I bin/fm-account-task.py receive /absolute/installed-binding.json
  python3 -I bin/fm-account-task.py send /absolute/local-route.json < request.json
  python3 -I bin/fm-account-task.py digest /absolute/qualified-file-or-directory

Requires Python 3.9+, POSIX ownership, flock and fsync. Installation, key setup,
qualification, service repair, authentication and re-enablement are NEVER verbs.
`receive` is an installed SSH forced command, with a separate key per binding;
its only allowed SSH_ORIGINAL_COMMAND is `fm-account-task-v1`. Local invocation
has the destination account's existing authority, not authority from JSON.
The key MUST prohibit shell/PTY, rc, environment and forwarding access. See
 docs/account-task-route.md for the attended installation/qualification boundary.

WIRE (one strict UTF-8 JSON object, <=65536 bytes, EOF within 10 seconds):
  schema='fm-account-task.v1', route, epoch (32 lowercase hex), operation (32 hex),
  expires (unix seconds, at most 1 hour ahead), verb, payload.
  submit: payload={task: safe slug, repository: installed selector, intent: text}
  status/result/stop/checkpoint: payload={task: slug, submit: accepted digest}
  steer: payload={task: slug, submit: accepted digest, text: text}
  disable: payload={}
Text is <=16384 UTF-8 bytes, with no controls except tab/newline. No fields for
commands, paths, callbacks, env, home, backend, profile or repair exist. A task
name is never reused within an epoch. All verbs are bound to operation+digest;
repeat identical bytes semantically -> same result, conflict -> refusal. status
and result are fresh observations only with a NEW operation id. Expired retries
refuse; they never cause execution. Responses are bounded JSON, never raw child
output, errors, transcripts or home paths. Result returns one UTF-8 report with
its SHA-256 bound to submit digest, epoch, task and local spawn generation.

BINDING (owner-only JSON, exact fields; examples and receipt limits in the doc):
 schema='fm-account-route.v1', route, epoch, user, uid, account_home, home,
 code_root, workspace_root, search_path (directory list), tools (fixed executable
 name -> absolute path), repositories (selector -> name under home/projects),
 profile={kind: scout|ship,model,effort}, runtime={socket,session,pid,
 environment_sha256}, guards (absolute file/directory -> digest), absent
 (absolute paths), denied (existing unreadable non-secret canary paths), receipt
 (64 hex), expires.
Only pi on an ALREADY RUNNING, destination-owned tmux server is supported in v1;
ship is no-mistakes, yolo off. No raw command, secondmate, automatic restart,
merge, delete, discard, service lifecycle or generic file read is exposed.
Runtime Firstmate surfaces, home config, repo .git/config and every required
mutable executable must be pinned guards. System utilities and the remaining
import/history/auth/OS isolation facts belong to the attended receipt. Any pinned
source or dependency change invalidates admission.

Ledger: home/state/account-route/{lock,ledger.json}; private owner-only files.
The ledger pins the ENTIRE installed binding. Once disabled/drifted it cannot be
re-enabled over the wire, even if the old bytes return. Accepted operations and
launches are fsynced BEFORE side effects. A crashed pending operation is unknown
and not re-executed. A later lifecycle operation may commit a launching task only
from its exact published binding; this neither replays submit nor claims liveness.
No journal entry is silently evicted: at 4096 operations or 128 tasks, new
operations refuse,
except that the idempotent disable latch remains available without journal growth.
Disable prevents new tasks and steers; observation, exact-task checkpoint and
preserving stop remain available only if installed identity/guards still match.
Maintenance requires disabling first; this dedicated home has ONE mutation
owner. Workers are trusted destination-account code, not mutually sandboxed.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import resource
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time

WIRE = "fm-account-task.v1"
BINDING = "fm-account-route.v1"
LIMIT = 65536
TEXT_LIMIT = 16384
SLUG = re.compile(r"[a-z][a-z0-9-]{0,47}\Z")
HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
MAX_LEDGER = 16 * 1024 * 1024
SEND_TIMEOUT = 390
REQUIRED_TOOLS = {"bash", "git", "jq", "pi", "python3", "tasks-axi", "tmux", "treehouse"}
SHIP_TOOLS = {"gh-axi", "no-mistakes"}


class Refusal(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def pairs(items):
    out = {}
    for key, value in items:
        require(key not in out, "duplicate-field")
        out[key] = value
    return out


def decode(raw):
    try:
        return json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refusal("invalid-json")))
    except (ValueError, UnicodeError, RecursionError):
        raise Refusal("invalid-json") from None


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def keys(value, fields):
    require(type(value) is dict and set(value) == set(fields.split()), "invalid-fields")


def token(value, pattern=SLUG):
    require(type(value) is str and pattern.fullmatch(value), "invalid-identity")
    return value


def text(value):
    require(type(value) is str and value.strip(), "empty-text")
    try:
        require(len(value.encode("utf-8")) <= TEXT_LIMIT, "text-too-large")
    except UnicodeError:
        raise Refusal("invalid-text") from None
    require(all(ord(c) >= 32 and ord(c) != 127 or c in "\n\t" for c in value), "invalid-text")
    return value


def short_text(value, bound=256):
    try:
        require(type(value) is str and value and len(value.encode("utf-8")) <= bound,
                "invalid-result")
    except UnicodeError:
        raise Refusal("invalid-result") from None
    require(all(32 <= ord(c) < 127 for c in value), "invalid-result")
    return value


def absolute(value):
    require(type(value) is str and value.startswith("/") and
            str(Path(value)) == value and value != "/" and
            all(x not in (".", "..") for x in value.split("/")[1:]) and
            all(ord(c) >= 32 and ord(c) != 127 for c in value), "invalid-path")
    return Path(value)


def within(path, root):
    return path != root and root in path.parents


def safe_path(path, uid, private=False, owned=False, directory=None):
    """No symlink ancestry, foreign writable ancestor, or multiply linked file.

    Cross-account security relies on OS permissions plus the attended custody
    receipt, not on resisting malicious code running as this same UID.
    """
    path = absolute(str(path))
    for part in reversed((path, *path.parents)):
        info = part.lstat()
        require(not stat.S_ISLNK(info.st_mode), "linked-path")
        require(info.st_uid in (0, uid) and not info.st_mode & 0o022, "unsafe-custody")
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode) or
            stat.S_ISSOCK(info.st_mode), "unsafe-type")
    if stat.S_ISREG(info.st_mode):
        require(info.st_nlink == 1, "hardlinked-file")
    if directory is not None:
        require(stat.S_ISDIR(info.st_mode) == directory, "wrong-type")
    if private:
        require(info.st_uid == uid and not info.st_mode & 0o077, "not-private")
    elif owned:
        require(info.st_uid == uid, "wrong-owner")
    return info


def read_file(path, uid, bound=LIMIT, private=False, owned=False):
    safe_path(path, uid, private, owned, directory=False)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= bound,
                "unsafe-file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(bound + 1)
        require(len(raw) <= bound, "file-too-large")
        return raw
    finally:
        os.close(fd)


def fingerprint(path, uid, owned=False):
    """Bounded tree hash includes names, modes, ownership and regular bytes."""
    h = hashlib.sha256()
    count = 0
    total = 0

    def walk(entry, name):
        nonlocal count, total
        info = safe_path(entry, uid, owned=owned)
        count += 1
        require(count <= 20000, "guard-too-large")
        h.update(encoded([name, info.st_uid, stat.S_IMODE(info.st_mode)]))
        if stat.S_ISDIR(info.st_mode):
            h.update(b"directory\0")
            for child in sorted(entry.iterdir()):
                walk(child, name + "/" + child.name)
        else:
            raw = read_file(entry, uid, 64 * 1024 * 1024)
            total += len(raw)
            require(total <= 256 * 1024 * 1024, "guard-too-large")
            h.update(b"file\0" + hashlib.sha256(raw).digest())
    walk(path, "")
    return h.hexdigest()


def atomic(path, value):
    raw = encoded(value)
    require(len(raw) <= MAX_LEDGER, "ledger-full")
    fd, name = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def bounded_stdin():
    data = bytearray()
    end = time.monotonic() + 10
    # Regular files cannot be registered with epoll on Linux.
    if stat.S_ISREG(os.fstat(0).st_mode):
        raw = sys.stdin.buffer.read(LIMIT + 1)
        require(len(raw) <= LIMIT, "request-too-large")
        return raw
    with selectors.DefaultSelector() as poll:
        poll.register(0, selectors.EVENT_READ)
        while True:
            wait = end - time.monotonic()
            require(wait > 0 and poll.select(wait), "request-timeout")
            part = os.read(0, min(4096, LIMIT + 1 - len(data)))
            if not part:
                return bytes(data)
            data.extend(part)
            require(len(data) <= LIMIT, "request-too-large")


def command(argv, env, cwd, timeout=15, output=False):
    """No shell, inherited descriptors, raw diagnostic propagation or daemon kill."""
    proc = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE if output else subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
    data = bytearray()
    try:
        end = time.monotonic() + timeout
        if output:
            with selectors.DefaultSelector() as poll:
                poll.register(proc.stdout, selectors.EVENT_READ)
                while poll.get_map():
                    wait = end - time.monotonic()
                    require(wait > 0, "local-operation-unknown")
                    for key, _ in poll.select(min(wait, 0.2)):
                        part = os.read(key.fd, 4096)
                        if not part:
                            poll.unregister(key.fileobj)
                        data.extend(part)
                        require(len(data) <= LIMIT, "local-operation-unknown")
        proc.wait(timeout=max(0.01, end - time.monotonic()))
        require(proc.returncode == 0, "local-operation-unknown")
        return bytes(data)
    finally:
        if proc.poll() is None:
            # Only the process group we just created; never an endpoint/service.
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        if proc.stdout:
            proc.stdout.close()


def binding_file(path):
    uid = os.geteuid()
    require(uid == os.getuid() and uid != 0, "wrong-account")
    b = decode(read_file(absolute(path), uid, private=True))
    keys(b, "schema route epoch user uid account_home home code_root workspace_root search_path "
            "tools repositories profile runtime guards absent denied receipt expires")
    require(b["schema"] == BINDING and type(b["uid"]) is int and b["uid"] == uid,
            "wrong-account")
    token(b["user"])
    try:
        require(pwd.getpwuid(uid).pw_name == b["user"], "wrong-account")
    except KeyError:
        raise Refusal("wrong-account") from None
    token(b["route"])
    token(b["epoch"], HEX32)
    token(b["receipt"], HEX64)
    require(type(b["expires"]) is int, "invalid-expiry")
    for name in ("account_home", "home", "workspace_root", "code_root"):
        safe_path(absolute(b[name]), uid, owned=True, directory=True)
    account = Path(b["account_home"])
    home = Path(b["home"])
    for name in ("home", "workspace_root", "code_root"):
        require(within(Path(b[name]), account), "outside-account")
    roots = [Path(b[k]) for k in ("home", "workspace_root", "code_root")]
    require(all(a != c and not within(a, c) for a in roots for c in roots if a is not c),
            "overlapping-roots")
    require(Path(__file__).absolute() == Path(b["code_root"]) / "bin/fm-account-task.py",
            "wrong-code-root")
    safe_path(home, uid, private=True, directory=True)
    for directory in ("state", "data", "projects", "config"):
        safe_path(home / directory, uid, private=True, directory=True)
    keys(b["profile"], "kind model effort")
    require(b["profile"]["kind"] in ("scout", "ship"), "unsupported-profile")
    require(b["profile"]["effort"] in ("low", "medium", "high", "xhigh"), "unsupported-profile")
    require(type(b["profile"]["model"]) is str and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}", b["profile"]["model"]),
            "unsupported-profile")
    required_tools = REQUIRED_TOOLS | (SHIP_TOOLS if b["profile"]["kind"] == "ship" else set())
    require(type(b["tools"]) is dict and set(b["tools"]) == required_tools, "invalid-tools")
    for name, path in b["tools"].items():
        token(name)
        absolute(path)
    require(type(b["repositories"]) is dict and 0 < len(b["repositories"]) <= 32,
            "invalid-repositories")
    for selector, name in b["repositories"].items():
        token(selector)
        token(name)
        safe_path(home / "projects" / name, uid, owned=True, directory=True)
    require(type(b["search_path"]) is list and 0 < len(b["search_path"]) <= 16, "invalid-path")
    for entry in b["search_path"]:
        safe_path(absolute(entry), uid, directory=True)
    keys(b["runtime"], "socket session pid environment_sha256")
    absolute(b["runtime"]["socket"])
    token(b["runtime"]["session"])
    require(b["runtime"]["session"] not in ("default", "firstmate", "fm-remote"), "shared-session")
    require(type(b["runtime"]["pid"]) is int and b["runtime"]["pid"] > 1, "invalid-runtime")
    token(b["runtime"]["environment_sha256"], HEX64)
    require(type(b["guards"]) is dict and 0 < len(b["guards"]) <= 128, "invalid-guards")
    for path, expected in b["guards"].items():
        absolute(path)
        token(expected, HEX64)
    for field in ("absent", "denied"):
        require(type(b[field]) is list and 0 < len(b[field]) <= 128, "invalid-guards")
        for path in b[field]:
            absolute(path)
    return b


class Route:
    def __init__(self, b):
        self.b = b
        self.uid = b["uid"]
        self.home = Path(b["home"])
        self.root = Path(b["code_root"])
        self.store = self.home / "state/account-route"
        if not self.store.exists():
            self.store.mkdir(mode=0o700)
        safe_path(self.store, self.uid, private=True, directory=True)
        lock = self.store / "lock"
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, "rb")
        safe_path(lock, self.uid, private=True, directory=False)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refusal("route-busy") from None
        self.path = self.store / "ledger.json"
        if self.path.exists():
            self.ledger = decode(read_file(self.path, self.uid, MAX_LEDGER, private=True))
            keys(self.ledger, "schema binding disabled operations tasks")
            require(self.ledger["schema"] == WIRE and type(self.ledger["disabled"]) is bool and
                    type(self.ledger["operations"]) is dict and type(self.ledger["tasks"]) is dict,
                    "invalid-ledger")
            for operation, record in self.ledger["operations"].items():
                token(operation, HEX32)
                keys(record, "digest result")
                token(record["digest"], HEX64)
                require(record["result"] is None or type(record["result"]) is dict,
                        "invalid-ledger")
            for name, task in self.ledger["tasks"].items():
                token(name)
                keys(task, "local repository submit phase binding result")
                token(task["local"])
                token(task["repository"])
                token(task["submit"], HEX64)
                require(task["phase"] in ("launching", "active") and
                        (task["binding"] is None or type(task["binding"]) is dict) and
                        (task["result"] is None or type(task["result"]) is dict), "invalid-ledger")
        else:
            require(not self.path.is_symlink(), "linked-ledger")
            # Never reconstruct a lost acceptance journal over existing work.
            require(not any((self.home / "state").glob("acct-*.meta")) and
                    not any((self.home / "data").glob("acct-*")), "lost-ledger")
            self.ledger = dict(schema=WIRE, binding=digest(b), disabled=False, operations={}, tasks={})
            self.save()
        if any(item.get("result") is None for item in self.ledger["operations"].values()):
            self.disable()
        self.env = dict(HOME=b["account_home"], USER=b["user"], LOGNAME=b["user"],
                        PATH=":".join(b["search_path"]), FM_HOME=b["home"],
                        FM_ROOT_OVERRIDE=b["code_root"], LANG="C.UTF-8", TERM="xterm-256color",
                        COMPACT_ADVISER_DISABLE="1",
                        FM_ACCOUNT_TASK_SESSION=b["runtime"]["session"],
                        FM_ACCOUNT_TASK_WORKSPACE_ROOT=b["workspace_root"],
                        TMUX=f'{b["runtime"]["socket"]},{b["runtime"]["pid"]},0')

    def save(self):
        atomic(self.path, self.ledger)

    def disable(self):
        self.ledger["disabled"] = True
        self.save()

    def tool(self, name):
        expected = self.b["tools"].get(name)
        require(expected is not None, "missing-tool")
        resolved = None
        for directory in self.b["search_path"]:
            candidate = Path(directory) / name
            if candidate.exists():
                resolved = str(candidate)
                break
        require(resolved == expected, "tool-drift")
        info = safe_path(Path(expected), self.uid, directory=False)
        require(not info.st_mode & (stat.S_ISUID | stat.S_ISGID), "unsafe-tool")
        require(os.access(expected, os.X_OK), "missing-tool")
        return expected

    def admission(self):
        require(self.ledger["binding"] == digest(self.b), "binding-drift")
        require(self.b["expires"] > int(time.time()), "qualification-expired")
        runtime_surfaces = [self.root / "bin", self.root / "AGENTS.md", self.root / "CLAUDE.md",
                            self.root / ".agents/skills/captain-hold-lifecycle/SKILL.md"]
        owned_guards = {str(path) for path in runtime_surfaces}
        owned_guards.add(str(self.home / "config"))
        owned_guards.update(str(self.home / "projects" / name / ".git/config")
                            for name in self.b["repositories"].values())
        required = set(owned_guards)
        required.update(self.tool(name) for name in self.b["tools"])
        require(required <= set(self.b["guards"]), "incomplete-guards")
        for path, expected in self.b["guards"].items():
            require(fingerprint(Path(path), self.uid, path in owned_guards) == expected,
                    "guard-drift")
        absent = [self.home / p for p in (".env", ".fm-secondmate-home", ".fm-secondmate-parent",
                  "data/captain.md", "data/captain-shared.md", "data/secondmates.md", "data/learnings.md",
                  "config/x-mode.env", "state/mail.check.sh", "state/public-followup", "state/procevent")]
        absent.extend(Path(p) for p in self.b["absent"])
        require(all(not os.path.lexists(p) for p in absent), "forbidden-material")
        for parent, pattern in ((self.home / "config", "signal*"), (self.home / "data", "signal*"),
                                (self.home / "state", "signal*"), (self.home / "state", "x-*"),
                                (self.home / "state", ".mail-*")):
            require(not any(parent.glob(pattern)), "forbidden-material")
        require(all(os.path.lexists(p) and not os.access(p, os.R_OK)
                    for p in self.b["denied"]), "canary-readable")
        require(read_file(self.home / "config/launch-env-allowlist", self.uid).strip() == b"",
                "environment-filter-required")
        # No configurable daemon selection or primary memory is imported.
        runtime = self.b["runtime"]
        socket = Path(runtime["socket"])
        require(within(socket, Path(self.b["account_home"])), "foreign-socket")
        info = safe_path(socket, self.uid, private=True)
        require(stat.S_ISSOCK(info.st_mode), "not-socket")
        # The trailing colon establishes session context without selecting a window.
        server = command([self.tool("tmux"), "-S", str(socket), "display-message", "-p", "-t",
                          "=" + runtime["session"] + ":", "#{pid}\t#{session_name}\t#{socket_path}"],
                         self.env, self.home, output=True).decode().strip()
        require(server == f'{runtime["pid"]}\t{runtime["session"]}\t{socket}', "runtime-drift")
        env = command([self.tool("tmux"), "-S", str(socket), "show-environment", "-g"],
                      self.env, self.home, output=True)
        require(hashlib.sha256(env).hexdigest() == runtime["environment_sha256"], "runtime-drift")

    def script(self, name, args, output=False):
        return command([str(self.root / "bin" / name), *args], self.env, self.home,
                       timeout=360, output=output)

    def meta(self, task):
        raw = read_file(self.home / "state" / (task["local"] + ".meta"), self.uid, owned=True)
        meta = {}
        for line in raw.decode("utf-8").splitlines():
            key, sep, value = line.partition("=")
            require(sep and key not in meta, "invalid-task-record")
            meta[key] = value
        required = dict(harness="pi", kind=self.b["profile"]["kind"],
                        window=self.b["runtime"]["session"] + ":fm-" + task["local"])
        require((meta.get("backend") or "tmux") == "tmux" and
                all(meta.get(k) == v for k, v in required.items()), "task-binding-mismatch")
        require(meta.get("spawn_gen") and meta.get("worktree") and
                meta.get("project") == str(self.home / "projects" / task["repository"]),
                "task-binding-mismatch")
        worktree = absolute(meta["worktree"])
        require(within(worktree, Path(self.b["workspace_root"])), "foreign-workspace")
        safe_path(worktree, self.uid, owned=True, directory=True)
        binding = {"backend": "tmux", **{k: meta[k] for k in (*required, "spawn_gen", "worktree", "project")}}
        if task.get("binding"):
            require(binding == task["binding"], "task-binding-mismatch")
        return binding

    def commit_binding(self, task):
        binding = self.meta(task)
        task["binding"] = binding
        task["phase"] = "active"
        self.save()

    def start(self, name, payload, request_digest):
        require(name not in self.ledger["tasks"], "task-already-used")
        require(len(self.ledger["tasks"]) < 128, "task-limit")
        repository = self.b["repositories"].get(payload["repository"])
        require(repository is not None, "unknown-repository")
        local = "acct-" + hashlib.sha256((self.b["epoch"] + ":" + name).encode()).hexdigest()[:24]
        task = dict(local=local, repository=repository, submit=request_digest, phase="launching",
                    binding=None, result=None)
        self.ledger["tasks"][name] = task
        self.save()
        kind = self.b["profile"]["kind"]
        self.script("fm-tasks-axi.sh", ["add", local, "Account task " + name, "--kind", kind])
        brief_args = [local, repository] + (["--scout"] if kind == "scout" else ["--mode", "no-mistakes"])
        self.script("fm-brief.sh", brief_args)
        brief = self.home / "data" / local / "brief.md"
        source = read_file(brief, self.uid, owned=True).decode()
        require(source.count("{TASK}") == 1 and source.count("{FIRSTMATE_SPEC}") == 1, "brief-contract-drift")
        spec = ("Use only this task's non-private repository context. Do not import personal homes, "
                "Signal, credentials, or service/session controls. Preserve all work. "
                "Leave the complete non-private result in the task's report.md; a status line alone "
                "is not a result. End with the identity-bound result receipt described below.\n")
        # A worker writes a result.json in its fixed task directory. The receiver
        # never executes it and accepts neither path pointers nor status prose.
        spec += ("When complete, write result.json beside this brief with exactly these JSON fields: "
                 + json.dumps(dict(schema="fm-account-result.v1", epoch=self.b["epoch"],
                                   task=name, submit=request_digest, uid=self.uid,
                                   report_sha256="SHA256_OF_REPORT_MD"))
                 + ". Replace only the hash placeholder after writing report.md. No private diagnostics.")
        body = source.replace("{TASK}", payload["intent"]).replace("{FIRSTMATE_SPEC}", spec)
        # Exclusive home owner, existing file verified above; never follow links.
        fd = os.open(brief, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        with os.fdopen(fd, "w") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        args = [local, str(self.home / "projects" / repository), "--harness", "pi", "--model",
                self.b["profile"]["model"], "--effort", self.b["profile"]["effort"], "--backend", "tmux",
                ]
        if kind == "scout":
            args.append("--scout")
        else:
            args.extend(["--mode", "no-mistakes", "--yolo", "off"])
        self.script("fm-spawn.sh", args)
        self.commit_binding(task)
        return dict(state="active", task=name, submit=request_digest)

    def task_operation(self, verb, payload):
        name = payload["task"]
        task = self.ledger["tasks"].get(name)
        require(type(task) is dict and payload["submit"] == task["submit"], "unknown-task")
        if verb == "result" and task.get("result") is not None:
            return task["result"]
        if task["phase"] == "launching":
            self.commit_binding(task)
        self.meta(task)
        if verb == "status":
            # Active means a committed launch binding, NOT proof of a live agent.
            return dict(state="accepted", task=name, submit=task["submit"])
        if verb == "result":
            try:
                folder = self.home / "data" / task["local"]
                receipt = decode(read_file(folder / "result.json", self.uid, owned=True))
                keys(receipt, "schema epoch task submit uid report_sha256")
                require(receipt == dict(schema="fm-account-result.v1", epoch=self.b["epoch"],
                                        task=name, submit=task["submit"], uid=self.uid,
                                        report_sha256=receipt["report_sha256"]), "result-mismatch")
                token(receipt["report_sha256"], HEX64)
                raw = read_file(folder / "report.md", self.uid, TEXT_LIMIT, owned=True)
                report = text(raw.decode("utf-8", "strict"))
                require(hashlib.sha256(raw).hexdigest() == receipt["report_sha256"], "result-mismatch")
                outcome = dict(state="complete", task=name, submit=task["submit"],
                               generation=task["binding"]["spawn_gen"],
                               sha256=receipt["report_sha256"], report=report)
                task["result"] = outcome
                self.save()
                return outcome
            except (OSError, UnicodeError, Refusal):
                return dict(state="incomplete", task=name, submit=task["submit"])
        if verb in ("steer", "checkpoint"):
            message = payload["text"] if verb == "steer" else (
                "Stop taking new work. Finish the current safe step, preserve all unlanded work, "
                "and report the checkpoint and any unresolved outcome. Do not discard or stop services.")
            self.script("fm-send.sh", [task["local"], message])
            return dict(state="recorded", task=name)
        if verb == "stop":
            self.script("fm-control.sh", [task["local"], "exit"])
            return dict(state="stopped", task=name)
        raise Refusal("unknown-verb")

    def handle(self, req):
        keys(req, "schema route epoch operation expires verb payload")
        require(req["schema"] == WIRE and req["route"] == self.b["route"] and
                req["epoch"] == self.b["epoch"], "wrong-route")
        token(req["operation"], HEX32)
        now = int(time.time())
        require(type(req["expires"]) is int and now < req["expires"] <= now + 3600, "expired-request")
        verb = req["verb"]
        fields = {"submit": "task repository intent", "status": "task submit", "result": "task submit",
                  "steer": "task submit text", "checkpoint": "task submit", "stop": "task submit", "disable": ""}
        require(type(verb) is str and verb in fields, "unknown-verb")
        payload = req["payload"]
        keys(payload, fields[verb])
        if verb != "disable":
            token(payload["task"])
        if verb == "submit":
            token(payload["repository"])
            text(payload["intent"])
            require("{TASK}" not in payload["intent"] and "{FIRSTMATE_SPEC}" not in payload["intent"],
                    "reserved-text")
        if verb not in ("disable", "submit"):
            token(payload["submit"], HEX64)
        if verb == "steer":
            text(payload["text"])
            # Never reach fm-send's local typed/harness-native plane.
            require(not payload["text"].lstrip().startswith(("/", "$")), "native-command-refused")
        operations = self.ledger["operations"]
        request_digest = digest(req)
        old = operations.get(req["operation"])
        if old is not None:
            require(old["digest"] == request_digest, "operation-conflict")
        try:
            self.admission()
        except (Refusal, OSError, ValueError, subprocess.TimeoutExpired):
            self.disable()
            if verb != "disable":
                raise Refusal("route-drift-disabled") from None
        if old is not None:
            return old["result"] or dict(state="unknown")
        require(not self.ledger["disabled"] or verb in ("disable", "status", "result", "checkpoint", "stop"),
                "route-disabled")
        if len(operations) >= 4096:
            if verb == "disable":
                self.disable()
                return dict(state="disabled")
            raise Refusal("operation-limit")
        record = dict(digest=request_digest, result=None)
        operations[req["operation"]] = record
        self.save()
        try:
            if verb == "disable":
                self.disable()
                result = dict(state="disabled")
            elif verb == "submit":
                result = self.start(payload["task"], payload, request_digest)
            else:
                result = self.task_operation(verb, payload)
        except (OSError, Refusal, ValueError, subprocess.TimeoutExpired):
            result = dict(state="unknown")
            self.disable()
        record["result"] = result
        self.save()
        return result


def exchange(proc, raw):
    """Bound stdin and stdout under one deadline without pipe deadlock."""
    data = bytearray()
    sent = 0
    end = time.monotonic() + SEND_TIMEOUT
    os.set_blocking(proc.stdin.fileno(), False)
    os.set_blocking(proc.stdout.fileno(), False)
    with selectors.DefaultSelector() as poll:
        poll.register(proc.stdin, selectors.EVENT_WRITE, "write")
        poll.register(proc.stdout, selectors.EVENT_READ, "read")
        while poll.get_map():
            wait = end - time.monotonic()
            require(wait > 0, "transport-unknown")
            for key, _ in poll.select(min(wait, 0.2)):
                if key.data == "write":
                    try:
                        sent += os.write(key.fd, raw[sent:sent + 4096])
                    except BrokenPipeError:
                        sent = -1
                    if sent < 0 or sent == len(raw):
                        poll.unregister(key.fileobj)
                        proc.stdin.close()
                else:
                    part = os.read(key.fd, 4096)
                    if not part:
                        poll.unregister(key.fileobj)
                    data.extend(part)
                    require(len(data) <= LIMIT, "transport-unknown")
    require(sent == len(raw), "transport-unknown")
    proc.wait(timeout=max(0.01, end - time.monotonic()))
    require(proc.returncode == 0, "transport-unknown")
    return bytes(data)


def validate_outcome(req, outcome):
    require(type(outcome) is dict and type(outcome.get("state")) is str,
            "result-binding-mismatch")
    state = outcome["state"]
    verb = req["verb"]
    payload = req["payload"]
    if state == "unknown":
        require(set(outcome) in ({"state"}, {"state", "task", "submit"}),
                "result-binding-mismatch")
        if "task" in outcome:
            require(outcome["task"] == payload.get("task") and
                    outcome["submit"] == payload.get("submit"), "result-binding-mismatch")
        return
    if verb == "disable":
        keys(outcome, "state")
        require(state == "disabled", "result-binding-mismatch")
        return
    task = payload["task"]
    if verb == "submit":
        keys(outcome, "state task submit")
        require(state == "active" and outcome["task"] == task and
                outcome["submit"] == digest(req), "result-binding-mismatch")
        return
    submit = payload["submit"]
    if verb == "status":
        keys(outcome, "state task submit")
        require(state == "accepted" and outcome["task"] == task and
                outcome["submit"] == submit, "result-binding-mismatch")
    elif verb == "result" and state == "incomplete":
        keys(outcome, "state task submit")
        require(outcome["task"] == task and outcome["submit"] == submit,
                "result-binding-mismatch")
    elif verb == "result" and state == "complete":
        keys(outcome, "state task submit generation sha256 report")
        require(outcome["task"] == task and outcome["submit"] == submit,
                "result-binding-mismatch")
        short_text(outcome["generation"])
        token(outcome["sha256"], HEX64)
        report = text(outcome["report"])
        require(hashlib.sha256(report.encode("utf-8")).hexdigest() == outcome["sha256"],
                "result-binding-mismatch")
    elif verb in ("steer", "checkpoint"):
        keys(outcome, "state task")
        require(state == "recorded" and outcome["task"] == task,
                "result-binding-mismatch")
    elif verb == "stop":
        keys(outcome, "state task")
        require(state == "stopped" and outcome["task"] == task,
                "result-binding-mismatch")
    else:
        raise Refusal("result-binding-mismatch")


def send(path, raw):
    uid = os.geteuid()
    local = decode(read_file(absolute(path), uid, private=True))
    keys(local, "schema route epoch host ssh")
    require(local["schema"] == "fm-account-sender.v1", "invalid-sender")
    token(local["route"])
    token(local["epoch"], HEX32)
    token(local["host"])
    safe_path(absolute(local["ssh"]), uid, directory=False)
    req = decode(raw)
    require(type(req) is dict and req.get("schema") == WIRE and
            req.get("route") == local["route"] and req.get("epoch") == local["epoch"], "wrong-route")
    token(req.get("operation"), HEX32)
    argv = [local["ssh"], "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "SendEnv=-*",
            "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", "--", local["host"], "fm-account-task-v1"]
    # No retry: uncertainty is resolved with the identical operation identity.
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            close_fds=True, env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())},
                            start_new_session=True)
    try:
        data = exchange(proc, raw)
        result = decode(data)
        keys(result, "schema route epoch operation outcome")
        require(result["schema"] == WIRE and result["route"] == req["route"] and
                result["epoch"] == req["epoch"] and result["operation"] == req["operation"],
                "result-binding-mismatch")
        validate_outcome(req, result["outcome"])
        return result
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        if proc.stdin and not proc.stdin.closed:
            proc.stdin.close()
        proc.stdout.close()


def main():
    require(len(sys.argv) == 3, "usage")
    mode, path = sys.argv[1:]
    if mode == "digest":
        print(fingerprint(absolute(path), os.geteuid()))
        return
    require(mode in ("receive", "send"), "usage")
    maximum = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    os.closerange(3, 1048576 if maximum == resource.RLIM_INFINITY else int(maximum))
    raw = bounded_stdin()
    if mode == "send":
        result = send(path, raw)
    else:
        require(os.environ.get("SSH_ORIGINAL_COMMAND", "fm-account-task-v1") == "fm-account-task-v1",
                "wrong-entrypoint")
        b = binding_file(path)
        req = decode(raw)
        require(type(req) is dict and req.get("schema") == WIRE and
                req.get("route") == b["route"] and req.get("epoch") == b["epoch"], "wrong-route")
        route = Route(b)
        try:
            outcome = route.handle(req)
        finally:
            route.lock.close()
        result = dict(schema=WIRE, route=b["route"], epoch=b["epoch"],
                      operation=req["operation"], outcome=outcome)
    out = encoded(result)
    require(len(out) <= LIMIT, "response-too-large")
    print(out.decode())


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, KeyError, TypeError, AttributeError,
            UnicodeError, subprocess.TimeoutExpired) as error:
        # Never disclose paths, child output, credentials or arbitrary exception text.
        reason = str(error) if isinstance(error, Refusal) else "unsafe-local-state"
        print(json.dumps({"schema": WIRE, "refused": reason}))
        sys.exit(78)
