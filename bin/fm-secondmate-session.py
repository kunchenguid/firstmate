#!/usr/bin/env python3
"""Secondmate compartment session runner: one leg of a long-lived cloud agent.

R2/R3 design section C item 2 (R2R3-DESIGN.md). This program is guest-side
only: the dispatching monitor (PR 4) sends it as the argv of an ordinary leg
`execute`, so it runs on the Azure worker under the pinned supervisor's
scrubbed environment (PATH=/usr/local/bin:/usr/bin:/bin, HOME=/mnt/account,
cwd inside the /mnt/task worktree).  It drives one session leg: poll the
inbox, run one pi turn per captain message, emit chained outbox replies,
sweep child-spawn intents, bundle new commits home, and exit cleanly on
close, idle, or the approaching wall.  It holds no provider credential, no
launcher, and no public ingress; its only reach is the slot's own private
state container, and only the `session/` blob namespace inside it.

CLI/env contract (the supervisor scrubs the environment, so the monitor
passes everything as flags; every flag also reads an environment fallback so
direct invocation and the hermetic tests can use either):

  --task                  FM_WORKER_TASK                  parent identity
  --task-generation       FM_WORKER_TASK_GENERATION       parent identity
  --assignment-generation FM_WORKER_ASSIGNMENT_GENERATION parent identity
  --repository-generation FM_WORKER_REPOSITORY_GENERATION dispatched base SHA
  --repo-dir              FM_SECONDMATE_REPO_DIR          default /mnt/task/repo
  --state-dir             FM_SECONDMATE_STATE_DIR         default /mnt/task/.fm-secondmate
  --storage-account       FM_AZURE_STORAGE_NAME           imds backend
  --container             FM_SECONDMATE_CONTAINER         slot's worker-state-NN
  --blob-dir              FM_SECONDMATE_BLOB_DIR          dir backend (fixtures)
  --pi-bin                FM_SECONDMATE_PI_BIN            default pi
  --pi-ext                FM_SECONDMATE_PI_EXT            staged extension path
  --agent-dir             FM_SECONDMATE_AGENT_DIR         default /mnt/account/pi-agent
  --poll-seconds          FM_SECONDMATE_POLL_SECONDS      default 10, floor 5
  --idle-seconds          FM_SECONDMATE_IDLE_SECONDS      default 7200
  --leg-seconds           FM_SECONDMATE_LEG_SECONDS       default 14400, ceiling 21600

Every pi turn runs with PI_CODING_AGENT_DIR set to the configured agent
directory: the supervisor's scrubbed environment drops the variable, and
without it pi would root its agent state at $HOME/.pi/agent instead of the
staged auth projection at /mnt/account/pi-agent (the D.1 gate ran with it
set, and fm-spawn.sh's cloud launch line sets it explicitly).

Captain message text that begins with '-' is refused with a loud refusal
outbox message rather than passed to pi: pi 0.84.1 does NOT honor a '--'
end-of-options separator (probed 2026-08-20: `pi --print -- "--x"` fails
with "Unknown options: --, --x"), so a leading-dash prompt argv could be
parsed as a pi flag and is never sent.

Monitor contract (PR 4): the supervisor `wall_seconds` for a leg dispatch
must be at least leg_seconds plus the finish-leg budget - the leg-end
bundling and summary run AFTER the internal wall-margin exit and can spend
up to GIT_BUNDLE_TIMEOUT (600s) + BLOB_PUT_TIMEOUT (600s) beyond the capped
300-second margin. --leg-seconds itself is refused above 21600, the pinned
supervisor's MAX_WALL_SECONDS.

Backend selection: FM_SECONDMATE_BLOB_DIR / --blob-dir selects the local
directory backend the hermetic tests drive; otherwise the IMDS backend needs
both the storage account and the container.  Both backends sit UNDER the one
namespace guard: every blob name must live under `session/`, enforced as a
refusal in the transport itself, not in its callers (design D.3).

Outbox chain: messages are `session/out/<seq8>-<sha256>.json` where the name
digest is the content address of the canonical unsigned message (the message
without its `content_sha256`/`chain_digest` fields), `sequence` counts from 1,
and `chain_digest` = sha256(previous_chain_digest_hex + content_sha256_hex)
with a genesis previous of 64 zeros.  The chain tip is durable on the task
disk; on every start the runner re-derives the stored chain from the store's
blob names and refuses to continue on any gap, reorder, or substitution.  The
single tolerated divergence is exactly one store entry past the durable tip
(the PUT-then-record crash window), and only when its content verifies.

Inbox: content-addressed `session/in/<sha256>.json`, deduped by a durable
processed-set, so a replayed message is a no-op.  Child-result delta bundles
arrive as `session/in/attach/<sha256>.bundle` and are fetched only on demand,
size-checked against the announcing message before the fetch.  A processed
marker is written after the message's effects complete, so a crash mid-turn
replays that turn on the next leg (at-least-once, never silently dropped).

Commit bundling: at leg end and on a `flush` control message, the commits
added over the durable last-bundled tip (initially the dispatched
FM_WORKER_REPOSITORY_GENERATION base) ride home as
`session/out/bundle-<seq8>-<sha256>.bundle` and are declared inside the
chained leg summary.  The last-bundled tip advances durably only after the
upload, and the pending declaration list is cleared only after the summary
that carries it is emitted, so a crash never loses a declaration (it can at
worst repeat one, which the local side dedupes by digest).

Child intents: the staged pi extension writes intent files into the spool
directory (it does no blob I/O); after each turn the runner sweeps the spool,
validates the closed intent schema (exactly kind/brief and optional
model/effort; kind in ship|scout), and emits `fm.secondmate-child-request/v1`
outbox messages carrying only the parent identity triple, the child kind, the
inline brief, and a self digest - no home, account, worktree, harness, SKU,
or repository field can even be expressed.  An invalid intent becomes a
refusal message naming the exact failed check and is never emitted.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ElementTree


SESSION_PREFIX = "session/"
INBOX_PREFIX = "session/in/"
ATTACH_PREFIX = "session/in/attach/"
OUTBOX_PREFIX = "session/out/"

MESSAGE_KIND = "fm.secondmate-message/v1"
CONTROL_KIND = "fm.secondmate-control/v1"
ATTACH_KIND = "fm.secondmate-attach/v1"
CHILD_REQUEST_KIND = "fm.secondmate-child-request/v1"
REFUSAL_KIND = "fm.secondmate-refusal/v1"
LEG_SUMMARY_KIND = "fm.secondmate-leg-summary/v1"

MAX_MESSAGE_BYTES = 256 * 1024
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_REPLY_TEXT_BYTES = 200 * 1024
MAX_INTENT_FILE_BYTES = MAX_MESSAGE_BYTES + 4096
MAX_OPTION_CHARS = 128

DEFAULT_POLL_SECONDS = 10
FLOOR_POLL_SECONDS = 5
DEFAULT_IDLE_SECONDS = 7200
DEFAULT_LEG_SECONDS = 14400
# The pinned supervisor's MAX_WALL_SECONDS: a leg longer than the guest wall
# ceiling could never exit cleanly, so it refuses here at configuration time.
MAX_LEG_SECONDS = 6 * 60 * 60
WALL_MARGIN_CEILING_SECONDS = 300
DEFAULT_AGENT_DIR = "/mnt/account/pi-agent"

GENESIS_CHAIN_DIGEST = "0" * 64
HEX = re.compile(r"^[0-9a-f]{64}$")
OUTBOX_MESSAGE_NAME = re.compile(r"^session/out/([0-9]{8})-([0-9a-f]{64})\.json$")
INBOX_MESSAGE_NAME = re.compile(r"^session/in/([0-9a-f]{64})\.json$")
SAFE_BLOB_SEGMENT = r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}"
SAFE_BLOB_NAME = re.compile(r"^{0}(/{0})*$".format(SAFE_BLOB_SEGMENT))

IMDS_TOKEN_URL = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F"
)
BLOB_API_VERSION = "2021-08-06"
IMDS_TOKEN_TIMEOUT = 30
BLOB_LIST_TIMEOUT = 60
BLOB_GET_TIMEOUT = 300
BLOB_PUT_TIMEOUT = 600
TOKEN_REFRESH_MARGIN_SECONDS = 300

GIT_COUNT_TIMEOUT = 120
GIT_BUNDLE_TIMEOUT = 600
GIT_FETCH_TIMEOUT = 600

REFUSED_PREFIX = "SECONDMATE SESSION REFUSED: "
CHAIN_BROKEN = "outbox chain is broken"


class SessionError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256_hex(body):
    return hashlib.sha256(body).hexdigest()


def write_atomic(path, body):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".secondmate-", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SessionError("blob transport request was redirected, which is refused")


class DirBackend:
    """Local directory standing in for the state container (hermetic tests).

    Same semantics as the IMDS backend: list-by-prefix with sizes, whole-blob
    GET/PUT, PUT overwrites (Azure block-blob PUT overwrites too, and every
    name this runner writes is content-addressed so an overwrite is a replay
    of identical bytes).
    """

    def __init__(self, root):
        self.root = Path(root)
        if not self.root.is_dir():
            raise SessionError("blob fixture directory is unavailable: {}".format(self.root))

    def _path(self, name):
        return self.root / name

    def list(self, prefix):
        entries = []
        for path in sorted(self.root.rglob("*")):
            if not path.is_file():
                continue
            name = path.relative_to(self.root).as_posix()
            if name.startswith(prefix):
                entries.append({"name": name, "bytes": path.stat().st_size})
        entries.sort(key=lambda entry: entry["name"])
        return entries

    def get(self, name, max_bytes):
        path = self._path(name)
        try:
            size = path.stat().st_size
        except OSError as exc:
            raise SessionError("blob is unreadable: {}: {}".format(name, exc))
        if size > max_bytes:
            raise SessionError("blob exceeds its bounded allowance: {}".format(name))
        return path.read_bytes()

    def put(self, name, body):
        write_atomic(self._path(name), body)


class ImdsBackend:
    """Azure Blob REST over IMDS bearer tokens against the private endpoint.

    The worker has exactly one user-assigned identity, so the IMDS token
    request names no client_id.  The endpoint hostname resolves privately on
    the worker; nothing here follows a redirect.
    """

    def __init__(self, storage_account, container):
        if not storage_account or not container:
            raise SessionError("imds blob backend needs a storage account and container")
        self.base = "https://{}.blob.core.windows.net/{}".format(storage_account, container)
        self.opener = urllib.request.build_opener(_NoRedirect())
        self._token = ""
        self._token_expires = 0

    def _bearer(self):
        now = int(time.time())
        if self._token and now < self._token_expires - TOKEN_REFRESH_MARGIN_SECONDS:
            return self._token
        request = urllib.request.Request(IMDS_TOKEN_URL, headers={"Metadata": "true"})
        try:
            with self.opener.open(request, timeout=IMDS_TOKEN_TIMEOUT) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (OSError, ValueError) as exc:
            raise SessionError("imds token acquisition failed: {}".format(exc))
        token = payload.get("access_token")
        if not isinstance(token, str) or not token:
            raise SessionError("imds token response carried no access token")
        self._token = token
        try:
            self._token_expires = int(payload.get("expires_on", 0))
        except (TypeError, ValueError):
            self._token_expires = now + 600
        return self._token

    def _headers(self):
        return {
            "Authorization": "Bearer " + self._bearer(),
            "x-ms-version": BLOB_API_VERSION,
        }

    def list(self, prefix):
        entries = []
        marker = ""
        while True:
            url = "{}?restype=container&comp=list&prefix={}".format(
                self.base, urllib.parse.quote(prefix, safe="")
            )
            if marker:
                url += "&marker=" + urllib.parse.quote(marker, safe="")
            request = urllib.request.Request(url, headers=self._headers())
            try:
                with self.opener.open(request, timeout=BLOB_LIST_TIMEOUT) as response:
                    body = response.read()
            except OSError as exc:
                raise SessionError("blob list failed: {}".format(exc))
            try:
                root = ElementTree.fromstring(body)
            except ElementTree.ParseError as exc:
                raise SessionError("blob list response is malformed: {}".format(exc))
            for blob in root.iter("Blob"):
                name = blob.findtext("Name", "")
                length = blob.findtext("Properties/Content-Length", "0")
                try:
                    size = int(length)
                except ValueError:
                    raise SessionError("blob list size is malformed for {}".format(name))
                entries.append({"name": name, "bytes": size})
            marker = root.findtext("NextMarker", "") or ""
            if not marker:
                break
        entries.sort(key=lambda entry: entry["name"])
        return entries

    def get(self, name, max_bytes):
        url = "{}/{}".format(self.base, urllib.parse.quote(name, safe="/"))
        request = urllib.request.Request(url, headers=self._headers())
        try:
            with self.opener.open(request, timeout=BLOB_GET_TIMEOUT) as response:
                body = response.read(max_bytes + 1)
        except OSError as exc:
            raise SessionError("blob get failed: {}: {}".format(name, exc))
        if len(body) > max_bytes:
            raise SessionError("blob exceeds its bounded allowance: {}".format(name))
        return body

    def put(self, name, body):
        url = "{}/{}".format(self.base, urllib.parse.quote(name, safe="/"))
        headers = self._headers()
        headers["x-ms-blob-type"] = "BlockBlob"
        headers["Content-Type"] = "application/octet-stream"
        headers["Content-Length"] = str(len(body))
        request = urllib.request.Request(url, data=body, method="PUT", headers=headers)
        try:
            with self.opener.open(request, timeout=BLOB_PUT_TIMEOUT) as response:
                status = response.status
        except OSError as exc:
            raise SessionError("blob put failed: {}: {}".format(name, exc))
        if status not in (201, 202):
            raise SessionError("blob put was rejected: {}: status={}".format(name, status))


class SessionTransport:
    """The one blob door, with the namespace boundary enforced INSIDE it.

    Design D.3: the runner may only touch blob names under `session/`.  The
    refusal lives here, above the backend split, so both the fixture and the
    IMDS backend enforce it and no caller can reach a blob outside the
    session namespace even by constructing the name itself.
    """

    def __init__(self, backend):
        self.backend = backend

    def _admit(self, name, allow_prefix=False):
        if not isinstance(name, str) or not name.startswith(SESSION_PREFIX):
            raise SessionError(
                "blob name is outside the session/ namespace: {!r}".format(name)
            )
        candidate = name[:-1] if allow_prefix and name.endswith("/") else name
        if not SAFE_BLOB_NAME.fullmatch(candidate):
            raise SessionError(
                "blob name is outside the session/ namespace: {!r}".format(name)
            )

    def list(self, prefix):
        self._admit(prefix, allow_prefix=True)
        return [
            entry for entry in self.backend.list(prefix)
            if entry["name"].startswith(SESSION_PREFIX)
        ]

    def get(self, name, max_bytes):
        self._admit(name)
        return self.backend.get(name, max_bytes)

    def put(self, name, body):
        self._admit(name)
        self.backend.put(name, body)


class DurableState:
    """All leg-crossing state, on the retained task disk, atomically written."""

    def __init__(self, state_dir):
        self.root = Path(state_dir)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.processed_dir = self.root / "processed"
        self.processed_dir.mkdir(exist_ok=True, mode=0o700)
        self.spool_dir = self.root / "spool"
        self.spool_dir.mkdir(exist_ok=True, mode=0o700)
        self.pi_session_dir = self.root / "pi-session"
        self.pi_session_dir.mkdir(exist_ok=True, mode=0o700)
        self.attach_dir = self.root / "attach"
        self.attach_dir.mkdir(exist_ok=True, mode=0o700)

    def _read_json(self, name, fallback):
        path = self.root / name
        if not path.is_file():
            return fallback
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SessionError("durable state {} is unreadable: {}".format(name, exc))

    def _write_json(self, name, value):
        write_atomic(self.root / name, canonical(value) + b"\n")

    def chain(self):
        state = self._read_json(
            "outbox-chain.json", {"sequence": 0, "chain_digest": GENESIS_CHAIN_DIGEST}
        )
        sequence = state.get("sequence")
        digest_value = state.get("chain_digest")
        if (
            not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0
            or not isinstance(digest_value, str) or not HEX.fullmatch(digest_value)
        ):
            raise SessionError("durable outbox chain state is malformed")
        return sequence, digest_value

    def record_chain(self, sequence, chain_digest):
        self._write_json("outbox-chain.json", {"sequence": sequence, "chain_digest": chain_digest})

    def session_id(self):
        path = self.root / "session-id"
        if path.is_file():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
        value = str(uuid.uuid4())
        write_atomic(path, value.encode() + b"\n")
        return value

    def bundles(self, base):
        state = self._read_json("bundles.json", {"last_bundled": base, "pending": []})
        if not isinstance(state.get("last_bundled"), str) or not isinstance(state.get("pending"), list):
            raise SessionError("durable bundle state is malformed")
        return state

    def record_bundles(self, state):
        self._write_json("bundles.json", state)

    def legs_completed(self):
        state = self._read_json("legs.json", {"legs_completed": 0})
        count = state.get("legs_completed")
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise SessionError("durable leg counter is malformed")
        return count

    def record_legs_completed(self, count):
        self._write_json("legs.json", {"legs_completed": count})

    def is_processed(self, digest_hex):
        return (self.processed_dir / digest_hex).is_file()

    def mark_processed(self, digest_hex):
        write_atomic(self.processed_dir / digest_hex, b"")


class Outbox:
    """Sequence-numbered hash-chained emitter over the transport."""

    def __init__(self, transport, state):
        self.transport = transport
        self.state = state
        self.sequence, self.chain_digest = state.chain()

    def verify_against_store(self):
        """Refuse to continue on any divergence between the durable chain tip
        and what the store actually holds.  A gap, reorder, or substitution in
        this runner's own outbox is never skipped or renumbered."""
        by_sequence = {}
        for entry in self.transport.list(OUTBOX_PREFIX):
            match = OUTBOX_MESSAGE_NAME.fullmatch(entry["name"])
            if not match:
                continue
            sequence = int(match.group(1))
            if sequence in by_sequence:
                raise SessionError(
                    "{}: duplicate outbox sequence {:08d}".format(CHAIN_BROKEN, sequence)
                )
            by_sequence[sequence] = match.group(2)
        stored = len(by_sequence)
        if sorted(by_sequence) != list(range(1, stored + 1)):
            raise SessionError(
                "{}: stored sequences are not exactly 1..{}".format(CHAIN_BROKEN, stored)
            )
        if stored not in (self.sequence, self.sequence + 1):
            raise SessionError(
                "{}: store holds {} entries but the durable tip is {}".format(
                    CHAIN_BROKEN, stored, self.sequence
                )
            )
        chain = GENESIS_CHAIN_DIGEST
        for sequence in range(1, self.sequence + 1):
            chain = sha256_hex((chain + by_sequence[sequence]).encode())
        if chain != self.chain_digest:
            raise SessionError(
                "{}: stored entries do not reproduce the durable chain tip".format(CHAIN_BROKEN)
            )
        if stored == self.sequence + 1:
            # Exactly one entry past the durable tip is the PUT-then-record
            # crash window.  Adopt it only when its content verifies: the blob
            # must parse, its unsigned canonical form must reproduce the name
            # digest, and its own chain field must extend the durable tip.
            content_digest = by_sequence[stored]
            name = "session/out/{:08d}-{}.json".format(stored, content_digest)
            body = self.transport.get(name, MAX_MESSAGE_BYTES)
            try:
                message = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise SessionError(
                    "{}: entry {:08d} past the durable tip is unreadable".format(
                        CHAIN_BROKEN, stored
                    )
                )
            unsigned = dict(message)
            unsigned.pop("content_sha256", None)
            claimed_chain = unsigned.pop("chain_digest", None)
            expected_chain = sha256_hex((self.chain_digest + content_digest).encode())
            if (
                not isinstance(message, dict)
                or sha256_hex(canonical(unsigned)) != content_digest
                or message.get("sequence") != stored
                or claimed_chain != expected_chain
            ):
                raise SessionError(
                    "{}: entry {:08d} past the durable tip does not verify".format(
                        CHAIN_BROKEN, stored
                    )
                )
            self.sequence = stored
            self.chain_digest = expected_chain
            self.state.record_chain(self.sequence, self.chain_digest)

    def emit(self, payload):
        sequence = self.sequence + 1
        unsigned = dict(payload)
        unsigned["sequence"] = sequence
        content_digest = sha256_hex(canonical(unsigned))
        chain_digest = sha256_hex((self.chain_digest + content_digest).encode())
        message = dict(unsigned)
        message["content_sha256"] = content_digest
        message["chain_digest"] = chain_digest
        body = canonical(message)
        if len(body) > MAX_MESSAGE_BYTES:
            raise SessionError(
                "outbox message exceeds the {} byte cap".format(MAX_MESSAGE_BYTES)
            )
        name = "session/out/{:08d}-{}.json".format(sequence, content_digest)
        self.transport.put(name, body)
        self.sequence = sequence
        self.chain_digest = chain_digest
        self.state.record_chain(sequence, chain_digest)
        return name


def positive_int(value, name, floor=1):
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise SessionError("{} is not an integer: {!r}".format(name, value))
    if number < floor:
        raise SessionError("{} must be at least {}".format(name, floor))
    return number


def wall_margin(leg_seconds):
    return min(WALL_MARGIN_CEILING_SECONDS, max(1, leg_seconds // 10))


def git_in(repo, *arguments, timeout=GIT_BUNDLE_TIMEOUT):
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=timeout, check=False,
    )


class SessionRunner:
    def __init__(self, config):
        self.config = config
        self.state = DurableState(config["state_dir"])
        if config.get("blob_dir"):
            backend = DirBackend(config["blob_dir"])
        else:
            backend = ImdsBackend(config.get("storage_account"), config.get("container"))
        self.transport = SessionTransport(backend)
        self.outbox = Outbox(self.transport, self.state)
        self.repo = Path(config["repo_dir"])
        self.parent = {
            "parent_task": config["task"],
            "parent_task_generation": config["task_generation"],
            "parent_assignment_generation": config["assignment_generation"],
        }
        self.session_id = self.state.session_id()
        self.close_requested = False
        self.wall_deadline = time.monotonic() + config["leg_seconds"] - wall_margin(
            config["leg_seconds"]
        )
        self.last_activity = time.monotonic()

    # -- refusal messages ---------------------------------------------------

    def refuse_input(self, refused, check):
        self.outbox.emit({"kind": REFUSAL_KIND, "refused": refused, "check": check})

    # -- inbox --------------------------------------------------------------

    def poll_inbox(self):
        pending = []
        for entry in self.transport.list(INBOX_PREFIX):
            match = INBOX_MESSAGE_NAME.fullmatch(entry["name"])
            if not match:
                # Attach bundles and any non-message name under session/in/
                # are not inbox messages; attachments are fetched on demand.
                continue
            if self.state.is_processed(match.group(1)):
                continue
            pending.append((entry["name"], match.group(1), entry["bytes"]))
        pending.sort()
        return pending

    def read_message(self, name, digest_hex, size):
        if size > MAX_MESSAGE_BYTES:
            self.refuse_input(digest_hex, "message exceeds the {} byte cap".format(MAX_MESSAGE_BYTES))
            return None
        body = self.transport.get(name, MAX_MESSAGE_BYTES)
        if sha256_hex(body) != digest_hex:
            self.refuse_input(digest_hex, "message content digest differs from its name")
            return None
        try:
            message = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self.refuse_input(digest_hex, "message is not valid JSON")
            return None
        if not isinstance(message, dict):
            self.refuse_input(digest_hex, "message is not a JSON object")
            return None
        return message

    def validate_closed(self, message, digest_hex, required, optional):
        allowed = set(required) | set(optional) | {"kind", "nonce"}
        for key in sorted(message):
            if key not in allowed:
                self.refuse_input(digest_hex, "message carries unknown key: {}".format(key))
                return False
        for key in required:
            if not isinstance(message.get(key), str) or not message[key]:
                self.refuse_input(digest_hex, "message field {} is missing or malformed".format(key))
                return False
        return True

    def handle_message(self, message, digest_hex):
        """Handle one inbox message. Returns False only when the message was
        deliberately DEFERRED (not processed) so the caller must not mark it:
        a turn that no longer fits before the wall replays on the next leg
        rather than being silently swallowed."""
        kind = message.get("kind")
        if kind == MESSAGE_KIND:
            if not self.validate_closed(message, digest_hex, ("text",), ()):
                return True
            if message["text"].startswith("-"):
                # pi 0.84.1 rejects a '--' end-of-options separator, so a
                # leading-dash prompt argv could be parsed as a pi flag.
                # Refused loudly, never silently reshaped or passed through.
                self.refuse_input(
                    digest_hex,
                    "message text begins with '-' and cannot ride the pi argv",
                )
                return True
            return self.agent_turn(message["text"])
        if kind == CONTROL_KIND:
            if not self.validate_closed(message, digest_hex, ("action",), ()):
                return True
            action = message["action"]
            if action == "close":
                self.close_requested = True
            elif action == "flush":
                self.bundle_commits()
            else:
                self.refuse_input(digest_hex, "control action is unsupported: {}".format(action))
            return True
        if kind == ATTACH_KIND:
            if self.validate_closed(message, digest_hex, ("name", "sha256"), ("bytes",)):
                self.handle_attach(message, digest_hex)
            return True
        self.refuse_input(digest_hex, "message kind is unsupported: {!r}".format(kind))
        return True

    def handle_attach(self, message, digest_hex):
        name = message["name"]
        declared_digest = message["sha256"]
        declared_bytes = message.get("bytes")
        if not name.startswith(ATTACH_PREFIX):
            self.refuse_input(digest_hex, "attach name is outside session/in/attach/")
            return
        if not HEX.fullmatch(declared_digest):
            self.refuse_input(digest_hex, "attach digest is malformed")
            return
        if (
            not isinstance(declared_bytes, int) or isinstance(declared_bytes, bool)
            or not 0 < declared_bytes <= MAX_BUNDLE_BYTES
        ):
            self.refuse_input(digest_hex, "attach size is malformed or unbounded")
            return
        listed = {
            entry["name"]: entry["bytes"] for entry in self.transport.list(ATTACH_PREFIX)
        }
        if listed.get(name) != declared_bytes:
            self.refuse_input(
                digest_hex,
                "attach blob size differs from the declared {} bytes".format(declared_bytes),
            )
            return
        body = self.transport.get(name, declared_bytes)
        if len(body) != declared_bytes or sha256_hex(body) != declared_digest:
            self.refuse_input(digest_hex, "attach blob differs from its declared digest")
            return
        local = self.state.attach_dir / "{}.bundle".format(declared_digest)
        write_atomic(local, body)
        fetched = git_in(
            self.repo, "fetch", "--no-tags", str(local), timeout=GIT_FETCH_TIMEOUT,
        )
        if fetched.returncode != 0:
            self.refuse_input(
                digest_hex,
                "attach bundle fetch failed: {}".format(
                    fetched.stderr.decode("utf-8", errors="replace")[-300:]
                ),
            )

    # -- agent turns ----------------------------------------------------------

    def agent_turn(self, text):
        remaining = self.wall_deadline - time.monotonic()
        if remaining <= 1:
            # Too close to the wall for an honest turn: defer, do not mark
            # processed, so the next leg replays this message.
            return False
        argv = [
            self.config["pi_bin"], "--print",
            "--session-id", self.session_id,
            "--session-dir", str(self.state.pi_session_dir),
        ]
        if self.config.get("pi_ext"):
            argv += ["-e", self.config["pi_ext"]]
        argv.append(text)
        env = dict(os.environ)
        env["FM_SECONDMATE_SPOOL_DIR"] = str(self.state.spool_dir)
        # The supervisor's scrubbed environment drops PI_CODING_AGENT_DIR;
        # without it pi roots agent state at $HOME/.pi/agent instead of the
        # staged auth projection, and every turn fails authentication.
        env["PI_CODING_AGENT_DIR"] = self.config["agent_dir"]
        try:
            completed = subprocess.run(
                argv, cwd=str(self.repo), env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=remaining, check=False,
            )
            reply = completed.stdout
            exit_code = completed.returncode
        except subprocess.TimeoutExpired as exc:
            reply = exc.stdout or b""
            exit_code = 124
        except OSError as exc:
            raise SessionError("agent invocation failed: {}".format(exc))
        truncated = len(reply) > MAX_REPLY_TEXT_BYTES
        if truncated:
            reply = reply[:MAX_REPLY_TEXT_BYTES]
        self.outbox.emit({
            "kind": MESSAGE_KIND,
            "text": reply.decode("utf-8", errors="replace"),
            "agent_exit_code": exit_code,
            "text_truncated": truncated,
        })
        self.sweep_spool()
        self.last_activity = time.monotonic()
        return True

    # -- child intents --------------------------------------------------------

    def sweep_spool(self):
        for path in sorted(self.state.spool_dir.glob("*.json")):
            name = path.name
            try:
                if path.stat().st_size > MAX_INTENT_FILE_BYTES:
                    raise ValueError("intent file exceeds its bounded allowance")
                intent = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                self.refuse_input(name, "child intent is unreadable: {}".format(exc))
                self.archive_intent(path)
                continue
            check = self.intent_check(intent)
            if check:
                self.refuse_input(name, check)
                self.archive_intent(path)
                continue
            # The closed request schema: constructed from a fixed key set, so
            # no home/account/worktree/harness/SKU/repository field can even
            # be expressed, whatever the intent file carried.
            payload = dict(self.parent)
            payload["kind"] = CHILD_REQUEST_KIND
            payload["child_kind"] = intent["kind"]
            payload["brief"] = intent["brief"]
            if "model" in intent:
                payload["child_model"] = intent["model"]
            if "effort" in intent:
                payload["child_effort"] = intent["effort"]
            payload["self_digest"] = sha256_hex(canonical(payload))
            # A brief at the 256KiB bound plus chain framing can overrun the
            # outbox message cap; that refuses the one intent, not the leg.
            probe = dict(payload)
            probe["sequence"] = self.outbox.sequence + 1
            probe["content_sha256"] = GENESIS_CHAIN_DIGEST
            probe["chain_digest"] = GENESIS_CHAIN_DIGEST
            if len(canonical(probe)) > MAX_MESSAGE_BYTES:
                self.refuse_input(name, "child request exceeds the outbox message cap")
                self.archive_intent(path)
                continue
            self.outbox.emit(payload)
            path.unlink()

    def archive_intent(self, path):
        try:
            os.replace(path, path.with_suffix(".refused"))
        except OSError:
            path.unlink(missing_ok=True)

    def intent_check(self, intent):
        if not isinstance(intent, dict):
            return "child intent is not a JSON object"
        for key in sorted(intent):
            if key not in ("kind", "brief", "model", "effort"):
                return "child intent carries unknown key: {}".format(key)
        if intent.get("kind") not in ("ship", "scout"):
            return "child intent kind must be ship or scout"
        brief = intent.get("brief")
        if not isinstance(brief, str) or not brief:
            return "child intent brief is missing or malformed"
        if len(brief.encode("utf-8")) > MAX_MESSAGE_BYTES:
            return "child intent brief exceeds the {} byte cap".format(MAX_MESSAGE_BYTES)
        for key in ("model", "effort"):
            if key in intent and (
                not isinstance(intent[key], str)
                or not intent[key]
                or len(intent[key]) > MAX_OPTION_CHARS
            ):
                return "child intent {} is malformed".format(key)
        return ""

    # -- commit bundling ------------------------------------------------------

    def bundle_commits(self):
        """Bundle the commits added over the durable last-bundled tip and
        upload them; advance the tip only after the upload succeeds."""
        bundles = self.state.bundles(self.config["repository_generation"])
        base = bundles["last_bundled"]
        counted = git_in(
            self.repo, "rev-list", "--count", "{}..HEAD".format(base),
            timeout=GIT_COUNT_TIMEOUT,
        )
        if counted.returncode != 0:
            raise SessionError(
                "commit range is unreadable: {}".format(
                    counted.stderr.decode("utf-8", errors="replace")[-300:]
                )
            )
        try:
            commits = int(counted.stdout.decode().strip())
        except ValueError:
            raise SessionError("commit count is not a number")
        if commits == 0:
            return
        head = git_in(self.repo, "rev-parse", "HEAD", timeout=GIT_COUNT_TIMEOUT)
        if head.returncode != 0:
            raise SessionError("repository head is unreadable")
        tip = head.stdout.decode().strip()
        with tempfile.TemporaryDirectory(dir=str(self.state.root)) as scratch:
            local = Path(scratch) / "leg.bundle"
            created = git_in(
                self.repo, "bundle", "create", str(local), "{}..HEAD".format(base),
                timeout=GIT_BUNDLE_TIMEOUT,
            )
            if created.returncode != 0 or not local.is_file():
                raise SessionError(
                    "commit bundle creation failed: {}".format(
                        created.stderr.decode("utf-8", errors="replace")[-300:]
                    )
                )
            body = local.read_bytes()
        if len(body) > MAX_BUNDLE_BYTES:
            raise SessionError("commit bundle exceeds its bounded allowance")
        digest_hex = sha256_hex(body)
        name = "session/out/bundle-{:08d}-{}.bundle".format(self.outbox.sequence + 1, digest_hex)
        self.transport.put(name, body)
        bundles["last_bundled"] = tip
        bundles["pending"].append({
            "name": name, "sha256": digest_hex, "bytes": len(body), "commits": commits,
        })
        self.state.record_bundles(bundles)

    # -- leg lifecycle ----------------------------------------------------------

    def finish_leg(self, reason):
        self.bundle_commits()
        bundles = self.state.bundles(self.config["repository_generation"])
        legs_completed = self.state.legs_completed() + 1
        self.outbox.emit({
            "kind": LEG_SUMMARY_KIND,
            "reason": reason,
            "bundles": bundles["pending"],
            "legs_completed": legs_completed,
        })
        # Clear the pending declarations only after the summary that carries
        # them is emitted; a crash in between re-declares (harmless), never
        # drops a declaration.
        bundles["pending"] = []
        self.state.record_bundles(bundles)
        self.state.record_legs_completed(legs_completed)

    def run(self):
        self.outbox.verify_against_store()
        poll = self.config["poll_seconds"]
        idle = self.config["idle_seconds"]
        reason = ""
        while True:
            now = time.monotonic()
            if now >= self.wall_deadline:
                reason = "wall"
                break
            if now - self.last_activity >= idle:
                reason = "idle"
                break
            for name, digest_hex, size in self.poll_inbox():
                if time.monotonic() >= self.wall_deadline:
                    break
                message = self.read_message(name, digest_hex, size)
                handled = True
                if message is not None:
                    handled = self.handle_message(message, digest_hex)
                if handled:
                    self.state.mark_processed(digest_hex)
                self.last_activity = time.monotonic()
            if self.close_requested:
                reason = "close"
                break
            now = time.monotonic()
            sleep_for = min(
                float(poll),
                max(self.wall_deadline - now, 0.0),
                max(idle - (now - self.last_activity), 0.0),
            )
            time.sleep(max(sleep_for, 0.1))
        self.finish_leg(reason)
        return 0


def flag_or_env(args, attribute, env_name, default=""):
    value = getattr(args, attribute)
    if value is None or value == "":
        value = os.environ.get(env_name, "")
    if value == "":
        value = default
    return value


def build_config(args):
    config = {}
    for attribute, env_name in (
        ("task", "FM_WORKER_TASK"),
        ("task_generation", "FM_WORKER_TASK_GENERATION"),
        ("assignment_generation", "FM_WORKER_ASSIGNMENT_GENERATION"),
        ("repository_generation", "FM_WORKER_REPOSITORY_GENERATION"),
    ):
        value = flag_or_env(args, attribute, env_name)
        if not value:
            raise SessionError("session identity {} is missing".format(attribute))
        config[attribute] = value
    config["repo_dir"] = flag_or_env(args, "repo_dir", "FM_SECONDMATE_REPO_DIR", "/mnt/task/repo")
    config["state_dir"] = flag_or_env(
        args, "state_dir", "FM_SECONDMATE_STATE_DIR", "/mnt/task/.fm-secondmate"
    )
    config["blob_dir"] = flag_or_env(args, "blob_dir", "FM_SECONDMATE_BLOB_DIR")
    config["storage_account"] = flag_or_env(args, "storage_account", "FM_AZURE_STORAGE_NAME")
    config["container"] = flag_or_env(args, "container", "FM_SECONDMATE_CONTAINER")
    if not config["blob_dir"] and not (config["storage_account"] and config["container"]):
        raise SessionError(
            "no blob backend: set FM_SECONDMATE_BLOB_DIR or both "
            "FM_AZURE_STORAGE_NAME and FM_SECONDMATE_CONTAINER"
        )
    config["pi_bin"] = flag_or_env(args, "pi_bin", "FM_SECONDMATE_PI_BIN", "pi")
    config["pi_ext"] = flag_or_env(args, "pi_ext", "FM_SECONDMATE_PI_EXT")
    config["agent_dir"] = flag_or_env(
        args, "agent_dir", "FM_SECONDMATE_AGENT_DIR", DEFAULT_AGENT_DIR
    )
    config["poll_seconds"] = max(
        positive_int(
            flag_or_env(args, "poll_seconds", "FM_SECONDMATE_POLL_SECONDS", DEFAULT_POLL_SECONDS),
            "poll seconds",
        ),
        FLOOR_POLL_SECONDS,
    )
    config["idle_seconds"] = positive_int(
        flag_or_env(args, "idle_seconds", "FM_SECONDMATE_IDLE_SECONDS", DEFAULT_IDLE_SECONDS),
        "idle seconds",
    )
    config["leg_seconds"] = positive_int(
        flag_or_env(args, "leg_seconds", "FM_SECONDMATE_LEG_SECONDS", DEFAULT_LEG_SECONDS),
        "leg seconds", floor=2,
    )
    if config["leg_seconds"] > MAX_LEG_SECONDS:
        raise SessionError(
            "leg seconds must be at most {} (the supervisor wall ceiling)".format(MAX_LEG_SECONDS)
        )
    if not Path(config["repo_dir"]).is_dir():
        raise SessionError("session repository is unavailable: {}".format(config["repo_dir"]))
    return config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", default=None)
    parser.add_argument("--task-generation", default=None)
    parser.add_argument("--assignment-generation", default=None)
    parser.add_argument("--repository-generation", default=None)
    parser.add_argument("--repo-dir", default=None)
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--blob-dir", default=None)
    parser.add_argument("--storage-account", default=None)
    parser.add_argument("--container", default=None)
    parser.add_argument("--pi-bin", default=None)
    parser.add_argument("--pi-ext", default=None)
    parser.add_argument("--agent-dir", default=None)
    parser.add_argument("--poll-seconds", default=None)
    parser.add_argument("--idle-seconds", default=None)
    parser.add_argument("--leg-seconds", default=None)
    args = parser.parse_args()
    runner = SessionRunner(build_config(args))
    raise SystemExit(runner.run())


if __name__ == "__main__":
    try:
        main()
    except SessionError as exc:
        print(REFUSED_PREFIX + str(exc), file=sys.stderr)
        raise SystemExit(2)
