#!/usr/bin/env python3
"""Mailbox verification and landing for one cloud secondmate compartment.

R2/R3 design B.4: THE MONITOR OWNS CHAIN VERIFICATION. The lifecycle CLI's
message-collect is dumb transport (it fetches session/out/ blobs into a local
mailbox directory and verifies nothing), and the session runner's own
verify_against_store only defends the guest side. This helper is the local
authority: it re-derives the whole outbox chain from the collected files and
refuses the ENTIRE mailbox on any gap, reorder, duplication, substitution, or
tamper - retain-and-investigate, never skip.

Chain contract (must match bin/fm-secondmate-session.py exactly):
  message blobs are session/out/<seq8>-<sha256>.json, collected locally as
  <seq8>-<sha256>.json; the name digest is the content address of the
  canonical unsigned message (the message without its content_sha256 and
  chain_digest fields, json.dumps sort_keys separators=(",",":")
  ensure_ascii=False); sequence counts from 1 with no gaps; and
  chain_digest = sha256(previous_chain_digest_hex + content_sha256_hex) with
  a genesis previous of 64 zeros. Bundle blobs (bundle-<seq8>-<sha256>.bundle)
  are not chain entries; they are declared inside chained leg summaries and
  verified size-and-digest against that declaration before any landing.

Verification is STATEFUL: the durable state file carries the verified tip
(sequence + chain_digest), so a store that was rewound below what was
already delivered, or wiped and re-minted as a fresh self-consistent chain
from genesis, refuses instead of verifying - a chain that merely hangs
together is not the chain this compartment was speaking on.

On a chain break this helper writes a loud .chain-break marker into the
mailbox, delivers NOTHING (not even entries before the break - the whole
mailbox is refused), retains every file, and exits 3. The marker is sticky:
while it exists every later invocation refuses immediately, so a break is
investigated by an operator, never healed by a retry loop.

Verified fm.secondmate-message/v1 text is delivered to stdout (the monitor
pane). Verified leg summaries update the durable state file the bash monitor
reads its renewal decision from. Declared bundles are landed into the local
secondmate home worktree by fast-forward only when the worktree is clean and
the bundle applies cleanly; otherwise the bundle file is kept in the mailbox
and its path reported - landing authority stays local and nothing is ever
force-applied (the outcome-landing doctrine in docs/azure-workers.md).

THE CHILD RELAY (design B.5 steps 2-5), the `child-relay` subcommand:
process-mailbox LANDS verified fm.secondmate-child-request/v1 and
fm.secondmate-attach-request/v1 messages under the compartment's
`<id>.cloud-childreq/` directory and acts on NEITHER; `child-relay` is the
one place that validates them and spends anything.

  - Validation is closed and local: exactly the field set the session runner
    emits (an unknown key refuses), the self digest recomputed over the
    payload, the parent identity triple equal to THIS compartment's
    task/generation/assignment, child_kind in {ship, scout}, and the brief
    bounded. Chain position is already guaranteed by the verifier above.
  - ANY failure writes `.refused-<digest>.json` AND delivers a refusal
    message into the compartment's own inbox naming the exact failed check,
    so the agent can never conclude "lost, resend": a resend carries the same
    self digest, and a self digest already accepted or refused refuses again,
    loudly, as a duplicate (durable dedupe, the delivered-refusal ack rule).
    An invalid request therefore never reaches command_request at all.
  - A valid request spawns through the EXISTING lane and nothing else:
    bin/fm-spawn.sh <child> <project> --harness pi, with
    --parent-task/--parent-task-generation forwarded into the lifecycle
    request so compartment children cannot dodge the bounds (AMENDMENT 1).
    FM_HOME is left exactly as this monitor received it, which is the
    controller's own home, so the money document needs no pin and none is set
    (see spawn_environment for why a pin here would be a durable trap and why
    moving FM_HOME aims at a second money document). Nothing about home,
    account, worktree, harness, SKU, project, or repository comes from the
    cloud side - the project is local policy (FM_SECONDMATE_CHILD_PROJECT,
    else that home's single project), and the harness is the cloud lane's only
    runtime. The child's backlog row is filed first, because fm-spawn refuses
    a new ship/scout task that has none.
  - NOT YET POSSIBLE, and refused loudly: fm-spawn derives owner_kind from its
    own home marker, so a request minted from the controller's home is
    primary-owned and verify_request refuses a primary-owned request that
    carries a parent pair. The controller itself is ready - `--owner-kind` is
    an ordinary argv flag and a secondmate-owned request with the pair is
    admitted under all four bounds - so the missing pieces are an assertable
    owner_kind on the spawn side and an authorized task-home parameter on
    authoritative_request_bindings.
  - ACCEPTANCE IS PROVEN BY THE QUEUE. A zero exit from fm-spawn is evidence
    the script ran, never that the controller admitted a bounded child, so a
    served request is confirmed by reading the one controller document back
    and finding the child's entry carrying THIS compartment's parent pair.
  - An admission refusal from command_request (fan-out cap, lifetime total,
    parent liveness, depth) is a spawn failure: its exact text round-trips
    into the inbox the same way, and no queue item exists.
  - Terminal child status is mirrored into the inbox once per child, read
    from the controller queue (complete) and the child's own recorded
    execution result (the complete/failed split).

THE ATTACH CONTRACT (`fm.secondmate-attach-request/v1`), decided here: the
session runner does not emit this kind yet, so this monitor PINS the shape and
the runner-side emission is a follow-up change. It is symmetric with the child
request and just as closed: exactly {kind, parent_task, parent_task_generation,
parent_assignment_generation, attach_sequence, self_digest} plus the chain
framing, and NO selector of any kind. `attach_sequence` selects nothing; it is
a bounded monotone discriminator (1..32, strictly past what has been served),
without which the payload would be CONSTANT for a whole assignment: every ask
would hash to one self digest and the second would refuse as a duplicate of
the first, leaving a 72-hour compartment exactly one attach.

WHAT THE DELTA IS, AND WHAT IT IS NOT. The bundle is always the commits the
local secondmate HOME worktree has gained over the compartment's dispatched
repository_generation, so no base, ref, path, or repository field is
expressible from the cloud side and the guest cannot name a tree it was never
given. That is a decision, not an oversight: a child crewmate commits into a
worktree of its PROJECT repository, whose history shares no ancestor with the
home repository the compartment holds at /mnt/task/repo, so a project bundle
could not be fast-forwarded there even if it were shipped. What genuinely
reaches the compartment is the home's own delta - the child's report and other
home artifacts - and the delivered text and the doc now say exactly that
instead of promising the child's code commits. Shipping project work to a
compartment would need a per-child repository binding and a selector, which
this closed schema deliberately does not have.

The bundle rides the claim-exempt `message-put --attach` lane as
session/in/attach/<sha256>.bundle and is announced by an
fm.secondmate-attach/v1 inbox message carrying name+sha256+bytes, which is
exactly what the runner's size-checked fetch_attach path requires. The
announcement is SIZE-BEFORE-FETCH: it is built from the upload receipt only
after the receipt's digest and byte count both equal the local bundle's, so a
mismatched announcement is never sent rather than sent and refused later. An
ask that finds no delta serves nothing, records no acceptance, and so burns no
attach_sequence.

Exit codes: 0 verified (possibly nothing new), 3 chain break (sticky), 2 bad
invocation or unreadable durable state.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

GENESIS_CHAIN_DIGEST = "0" * 64
HEX = re.compile(r"^[0-9a-f]{64}$")
MESSAGE_NAME = re.compile(r"^([0-9]{8})-([0-9a-f]{64})\.json$")
BUNDLE_NAME = re.compile(r"^bundle-([0-9]{8})-([0-9a-f]{64})\.bundle$")
OUTBOX_PREFIX = "session/out/"
ATTACH_PREFIX = "session/in/attach/"

MESSAGE_KIND = "fm.secondmate-message/v1"
REFUSAL_KIND = "fm.secondmate-refusal/v1"
LEG_SUMMARY_KIND = "fm.secondmate-leg-summary/v1"
CHILD_REQUEST_KIND = "fm.secondmate-child-request/v1"
ATTACH_REQUEST_KIND = "fm.secondmate-attach-request/v1"
ATTACH_KIND = "fm.secondmate-attach/v1"

MAX_MESSAGE_BYTES = 256 * 1024
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_BRIEF_BYTES = 256 * 1024
MAX_DELIVERED_TEXT_CHARS = 8000

# The chain framing every emitted outbox message carries; it is never part of
# the payload the self digest is computed over.
CHAIN_FIELDS = ("sequence", "content_sha256", "chain_digest")
CHILD_REQUEST_REQUIRED = (
    "kind", "parent_task", "parent_task_generation", "parent_assignment_generation",
    "child_kind", "brief", "self_digest",
)
CHILD_REQUEST_OPTIONAL = ("child_model", "child_effort")
ATTACH_REQUEST_REQUIRED = (
    "kind", "parent_task", "parent_task_generation", "parent_assignment_generation",
    "self_digest",
)
# The attach request carries no selector, so without a discriminator its
# payload would be CONSTANT for a whole assignment: every ask would hash to the
# same self digest and the second would refuse as a duplicate, leaving one
# attach for a 72-hour compartment that may own up to 32 children over its
# lifetime. attach_sequence is that discriminator: an integer, bounded by the
# lifetime child cap, and strictly increasing over the asks this monitor has
# actually served. It selects nothing - the delta is still always the same
# locally-decided range - it only distinguishes one ask from the next.
ATTACH_REQUEST_COUNTED = "attach_sequence"
MAX_ATTACH_SEQUENCE = 32
# Child model/effort ride the child's spawn argv, so the monitor is stricter
# than the runner: a bounded shell-safe token or nothing.
SAFE_OPTION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# The cloud lane runs exactly one runtime: fm-spawn refuses every other
# harness under cloud placement and forces this one itself.
CLOUD_CHILD_HARNESS = "pi"

GIT_TIMEOUT = 600
SPAWN_TIMEOUT = 900
LIFECYCLE_TIMEOUT = 900

CHAIN_BREAK_MARKER = ".chain-break"


class HelperError(RuntimeError):
    pass


class ChainBreak(RuntimeError):
    pass


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()


def sha256_hex(body):
    return hashlib.sha256(body).hexdigest()


def write_atomic(path, body):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".fm-secondmate-", dir=str(path.parent))
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


def load_state(path):
    path = Path(path)
    if not path.is_file():
        return {
            "delivered_sequence": 0,
            "landed_bundles": [],
            "kept_bundles": [],
            "last_summary": None,
        }
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HelperError("durable monitor state is unreadable: {}".format(exc))
    if not isinstance(state, dict):
        raise HelperError("durable monitor state is malformed")
    state.setdefault("delivered_sequence", 0)
    state.setdefault("landed_bundles", [])
    state.setdefault("kept_bundles", [])
    state.setdefault("last_summary", None)
    state.setdefault("verified_tip", None)
    return state


def save_state(path, state):
    write_atomic(path, canonical(state) + b"\n")


def verify_mailbox(mailbox):
    """Verify the whole collected outbox chain. Returns the ordered verified
    messages [(sequence, message_dict)]. Raises ChainBreak on ANY divergence:
    the caller refuses the entire mailbox, delivering nothing."""
    by_sequence = {}
    for entry in sorted(mailbox.iterdir()):
        if not entry.is_file():
            continue
        match = MESSAGE_NAME.fullmatch(entry.name)
        if not match:
            continue
        sequence = int(match.group(1))
        if sequence in by_sequence:
            raise ChainBreak("duplicate outbox sequence {:08d}".format(sequence))
        by_sequence[sequence] = (match.group(2), entry)
    total = len(by_sequence)
    if sorted(by_sequence) != list(range(1, total + 1)):
        raise ChainBreak(
            "collected sequences are not exactly 1..{} (a dropped or reordered blob)".format(total)
        )
    chain = GENESIS_CHAIN_DIGEST
    verified = []
    for sequence in range(1, total + 1):
        content_digest, entry = by_sequence[sequence]
        try:
            body = entry.read_bytes()
        except OSError as exc:
            raise ChainBreak("entry {:08d} is unreadable: {}".format(sequence, exc))
        if len(body) > MAX_MESSAGE_BYTES:
            raise ChainBreak("entry {:08d} exceeds the message byte cap".format(sequence))
        try:
            message = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ChainBreak("entry {:08d} is not valid JSON".format(sequence))
        if not isinstance(message, dict):
            raise ChainBreak("entry {:08d} is not a JSON object".format(sequence))
        unsigned = dict(message)
        claimed_content = unsigned.pop("content_sha256", None)
        claimed_chain = unsigned.pop("chain_digest", None)
        if sha256_hex(canonical(unsigned)) != content_digest:
            raise ChainBreak(
                "entry {:08d} content differs from its content address (tampered or substituted)".format(sequence)
            )
        if claimed_content != content_digest:
            raise ChainBreak("entry {:08d} content_sha256 differs from its name".format(sequence))
        if message.get("sequence") != sequence:
            raise ChainBreak("entry {:08d} sequence field differs from its name".format(sequence))
        expected_chain = sha256_hex((chain + content_digest).encode())
        if claimed_chain != expected_chain:
            raise ChainBreak(
                "entry {:08d} chain_digest does not extend the previous entry".format(sequence)
            )
        chain = expected_chain
        verified.append((sequence, message))
    return verified


def render_message(task, sequence, message, out):
    kind = message.get("kind")
    if kind == MESSAGE_KIND:
        exit_code = message.get("agent_exit_code")
        suffix = ""
        if isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code != 0:
            suffix = " (agent exit code {})".format(exit_code)
        if message.get("text_truncated"):
            suffix += " (text truncated)"
        out.write("secondmate {} says (seq {:08d}){}:\n".format(task, sequence, suffix))
        out.write(str(message.get("text", "")).rstrip("\n") + "\n")
    elif kind == REFUSAL_KIND:
        out.write(
            "secondmate {} REFUSED input (seq {:08d}): {} [{}]\n".format(
                task, sequence, message.get("check", ""), message.get("refused", "")
            )
        )
    elif kind == LEG_SUMMARY_KIND:
        out.write(
            "secondmate {} leg summary (seq {:08d}): reason={} legs_completed={} bundles={}\n".format(
                task,
                sequence,
                message.get("reason", ""),
                message.get("legs_completed", ""),
                len(message.get("bundles") or []),
            )
        )
    elif kind == CHILD_REQUEST_KIND:
        out.write(
            "secondmate {} child request (seq {:08d}): kind={} (landed for the child relay; validated and spent there, never here)\n".format(
                task, sequence, message.get("child_kind", "")
            )
        )
    elif kind == ATTACH_REQUEST_KIND:
        out.write(
            "secondmate {} attach request (seq {:08d}): landed for the child relay\n".format(
                task, sequence
            )
        )
    else:
        out.write(
            "secondmate {} message of unrecognized kind {!r} (seq {:08d}); retained verbatim in the mailbox\n".format(
                task, kind, sequence
            )
        )


def git_in(worktree, *arguments):
    return subprocess.run(
        ["git", "-C", str(worktree), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=GIT_TIMEOUT,
        check=False,
    )


def declared_bundles(verified):
    """Every bundle declaration carried by any verified leg summary, in chain
    order. A re-declared bundle (crash between summary emissions) appears
    once, keyed by digest - the dedupe the runner's contract names."""
    seen = set()
    ordered = []
    for _sequence, message in verified:
        if message.get("kind") != LEG_SUMMARY_KIND:
            continue
        for declaration in message.get("bundles") or []:
            if not isinstance(declaration, dict):
                continue
            digest = declaration.get("sha256")
            if not isinstance(digest, str) or digest in seen:
                continue
            seen.add(digest)
            ordered.append(declaration)
    return ordered


def land_bundle(task, mailbox, worktree, declaration, out):
    """Verify one declared bundle against its declaration and fast-forward it
    into the local secondmate home worktree. Returns "landed", "kept", or
    "pending" (not yet collected; retry on a later pass). Never forces: any
    unclean or non-fast-forward condition keeps the bundle and reports its
    path for manual landing."""
    name = declaration.get("name")
    digest = declaration.get("sha256")
    declared_size = declaration.get("bytes")
    if (
        not isinstance(name, str)
        or not name.startswith(OUTBOX_PREFIX)
        or not isinstance(digest, str)
        or not BUNDLE_NAME.fullmatch(name[len(OUTBOX_PREFIX):])
    ):
        out.write(
            "secondmate {}: leg summary declares a malformed bundle name {!r}; refusing to land it\n".format(task, name)
        )
        return "kept"
    local = mailbox / name[len(OUTBOX_PREFIX):]
    if not local.is_file():
        out.write(
            "secondmate {}: declared bundle {} is not collected yet; will retry\n".format(task, local.name)
        )
        return "pending"
    body = local.read_bytes()
    if (
        len(body) > MAX_BUNDLE_BYTES
        or (isinstance(declared_size, int) and not isinstance(declared_size, bool) and len(body) != declared_size)
        or sha256_hex(body) != digest
    ):
        out.write(
            "secondmate {}: collected bundle {} differs from its chained declaration; kept at {} for investigation\n".format(task, local.name, local)
        )
        return "kept"
    if worktree is None or not worktree.is_dir():
        out.write(
            "secondmate {}: home worktree is unavailable; bundle kept at {} for manual landing\n".format(task, local)
        )
        return "kept"
    head = git_in(worktree, "rev-parse", "HEAD")
    if head.returncode != 0:
        out.write(
            "secondmate {}: home worktree head is unreadable; bundle kept at {} for manual landing\n".format(task, local)
        )
        return "kept"
    listed = git_in(worktree, "bundle", "list-heads", str(local))
    tip = listed.stdout.decode("utf-8", errors="replace").split()
    tip = tip[0] if tip else ""
    if listed.returncode == 0 and tip:
        ancestor = git_in(worktree, "merge-base", "--is-ancestor", tip, "HEAD")
        if ancestor.returncode == 0:
            out.write("secondmate {}: bundle {} already landed in {}\n".format(task, local.name, worktree))
            return "landed"
    status = git_in(worktree, "status", "--porcelain", "--untracked-files=no")
    if status.returncode != 0 or status.stdout.strip():
        out.write(
            "secondmate {}: home worktree has uncommitted changes; bundle kept at {} for manual landing\n".format(task, local)
        )
        return "kept"
    verified_bundle = git_in(worktree, "bundle", "verify", str(local))
    if verified_bundle.returncode != 0:
        out.write(
            "secondmate {}: bundle {} does not apply to the current home worktree state (missing prerequisites or corrupt); kept at {} for manual landing\n".format(task, local.name, local)
        )
        return "kept"
    fetched = git_in(worktree, "fetch", "--quiet", "--no-tags", str(local), "HEAD")
    if fetched.returncode != 0:
        out.write(
            "secondmate {}: bundle {} could not be fetched; kept at {} for manual landing\n".format(task, local.name, local)
        )
        return "kept"
    merged = git_in(worktree, "merge", "--ff-only", "FETCH_HEAD")
    if merged.returncode != 0:
        out.write(
            "secondmate {}: bundle {} is not a fast-forward of the home worktree; kept at {} for manual landing\n".format(task, local.name, local)
        )
        return "kept"
    out.write(
        "secondmate {}: landed bundle {} ({} commit(s)) into {}\n".format(
            task, local.name, declaration.get("commits", "?"), worktree
        )
    )
    return "landed"


def chain_break_refuse(task, mailbox, reason, out):
    marker = mailbox / CHAIN_BREAK_MARKER
    if not marker.exists():
        write_atomic(
            marker,
            canonical({
                "reason": reason,
                "task": task,
                "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }) + b"\n",
        )
    out.write("SECONDMATE MAILBOX REFUSED for {}: {}\n".format(task, reason))
    out.write(
        "SECONDMATE MAILBOX REFUSED: the whole mailbox is retained at {} for investigation; nothing was or will be relayed past this break, and {} is sticky until an operator removes it\n".format(mailbox, marker)
    )


def land_relay_requests(verified, mailbox, childreq, out):
    """Copy verified child/attach request entries into the relay directory.

    The landed name is the chain name (<seq8>-<content>.json), so landing is
    idempotent, ordered by sequence, and distinct per EMISSION: a resent
    intent carries a new sequence and therefore a new content address, which
    is exactly what lets the relay see it as a duplicate of the same self
    digest rather than silently converging on the first file.
    """
    if not childreq:
        return
    childreq = Path(childreq)
    childreq.mkdir(parents=True, exist_ok=True, mode=0o700)
    for sequence, message in verified:
        if message.get("kind") not in (CHILD_REQUEST_KIND, ATTACH_REQUEST_KIND):
            continue
        content = message.get("content_sha256")
        if not isinstance(content, str) or not HEX.fullmatch(content):
            continue
        name = "{:08d}-{}.json".format(sequence, content)
        target = childreq / name
        if target.exists():
            continue
        source = mailbox / name
        try:
            body = source.read_bytes()
        except OSError as exc:
            out.write(
                "secondmate: verified request {} could not be landed for the relay: {}\n".format(name, exc)
            )
            continue
        write_atomic(target, body)


# --- the child relay ----------------------------------------------------------


def deliver_inbox(inbox, assignment, payload):
    """Write one canonical envelope into the compartment's own inbox.

    Same shape, same sequence-claim discipline and same content-addressed name
    as fm-send's compartment route, so refusals, attach announcements and
    child status share one ordered lane with captain text and the monitor's
    existing relay picks them up without knowing who wrote them.
    """
    inbox = Path(inbox)
    claims = inbox / ".claims"
    claims.mkdir(parents=True, exist_ok=True, mode=0o700)
    with contextlib.suppress(OSError):
        os.chmod(str(inbox), 0o700)
    existing = [
        int(entry.name) for entry in claims.iterdir()
        if entry.name.isdigit() and len(entry.name) == 8
    ]
    sequence = max(existing) + 1 if existing else 1
    for _attempt in range(10000):
        try:
            handle = os.open(
                str(claims / "{:08d}".format(sequence)),
                os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600,
            )
        except FileExistsError:
            sequence += 1
            continue
        os.close(handle)
        break
    else:
        raise HelperError("could not claim a compartment inbox sequence")
    message = dict(payload)
    message["nonce"] = "{}/{:08d}".format(assignment, sequence)
    if isinstance(message.get("text"), str) and len(message["text"]) > MAX_DELIVERED_TEXT_CHARS:
        message["text"] = message["text"][:MAX_DELIVERED_TEXT_CHARS] + " [truncated]"
    body = canonical(message)
    if len(body) > MAX_MESSAGE_BYTES:
        raise HelperError("compartment inbox envelope exceeds its byte cap")
    name = "{:08d}-{}.json".format(sequence, sha256_hex(body))
    write_atomic(inbox / name, body)
    return inbox / name


def deliver_text(inbox, assignment, text):
    return deliver_inbox(inbox, assignment, {"kind": MESSAGE_KIND, "text": text})


def payload_of(message):
    """The self-digest payload: the message without its own digest field and
    without the chain framing the outbox emitter adds around it."""
    payload = dict(message)
    payload.pop("self_digest", None)
    for field in CHAIN_FIELDS:
        payload.pop(field, None)
    return payload


def check_request_shape(message, required, optional):
    """Closed-schema check. Returns the exact failed check name, or "".

    Type-checks the OPTIONAL fields too, not only the required ones: a present
    optional field carrying an int, list, dict, or null used to reach the
    later regex checks and raise instead of refusing, and a raised validator
    defeats the delivered-refusal rule outright. Every string field this
    schema admits is proven a non-empty string HERE, before any check that
    assumes one.
    """
    allowed = set(required) | set(optional) | set(CHAIN_FIELDS)
    for key in sorted(message):
        if key not in allowed:
            return "request carries unknown key: {}".format(key)
    return check_request_body(message, required, optional)


def check_request_body(message, required, optional):
    """The type and digest half of the closed check, with no key-set opinion."""
    for key in required:
        value = message.get(key)
        if not isinstance(value, str) or not value:
            return "request field {} is missing or malformed".format(key)
    for key in optional:
        if key in message and (not isinstance(message[key], str) or not message[key]):
            return "request field {} is present but is not a non-empty string".format(key)
    if not HEX.fullmatch(message["self_digest"]):
        return "request self_digest is not a sha256 hex digest"
    if sha256_hex(canonical(payload_of(message))) != message["self_digest"]:
        return "request self_digest does not recompute over its payload"
    return ""


def check_parent_triple(message, task, generation, assignment):
    if message["parent_task"] != task:
        return "request parent_task {!r} is not this compartment".format(message["parent_task"])
    if message["parent_task_generation"] != generation:
        return "request parent_task_generation {!r} is not this compartment's generation".format(
            message["parent_task_generation"])
    if message["parent_assignment_generation"] != assignment:
        return "request parent_assignment_generation {!r} is not the current assignment".format(
            message["parent_assignment_generation"])
    return ""


def check_child_request(message, task, generation, assignment):
    failed = check_request_shape(message, CHILD_REQUEST_REQUIRED, CHILD_REQUEST_OPTIONAL)
    if failed:
        return failed
    if message["kind"] != CHILD_REQUEST_KIND:
        return "request kind {!r} is not {}".format(message["kind"], CHILD_REQUEST_KIND)
    failed = check_parent_triple(message, task, generation, assignment)
    if failed:
        return failed
    if message["child_kind"] not in ("ship", "scout"):
        return "request child_kind must be ship or scout, not {!r}".format(message["child_kind"])
    if len(message["brief"].encode("utf-8")) > MAX_BRIEF_BYTES:
        return "request brief exceeds the {} byte bound".format(MAX_BRIEF_BYTES)
    if message["brief"].startswith("-"):
        # The brief becomes ONE pi argv element on the worker
        # (fm-spawn.sh's cloud launch line), so a leading dash could be parsed
        # as a pi flag rather than a prompt - the same reason
        # fm-secondmate-session.py refuses leading-dash inbox text, and the
        # same reason child_model/child_effort carry a strict charset here.
        return "request brief begins with '-' and cannot ride the pi argv"
    for key in CHILD_REQUEST_OPTIONAL:
        if key in message and not SAFE_OPTION.fullmatch(message[key]):
            return "request {} is malformed".format(key)
    return ""


def check_attach_request(message, task, generation, assignment, served):
    allowed = set(ATTACH_REQUEST_REQUIRED) | {ATTACH_REQUEST_COUNTED} | set(CHAIN_FIELDS)
    for key in sorted(message):
        if key not in allowed:
            return "request carries unknown key: {}".format(key)
    counter = message.get(ATTACH_REQUEST_COUNTED)
    if not isinstance(counter, int) or isinstance(counter, bool):
        return "request attach_sequence is missing or is not an integer"
    if not 1 <= counter <= MAX_ATTACH_SEQUENCE:
        return "request attach_sequence must be between 1 and {}".format(MAX_ATTACH_SEQUENCE)
    if counter <= served:
        return (
            "request attach_sequence {} is not past the {} already served; "
            "attach requests count strictly upward".format(counter, served)
        )
    failed = check_request_body(message, ATTACH_REQUEST_REQUIRED, ())
    if failed:
        return failed
    if message["kind"] != ATTACH_REQUEST_KIND:
        return "request kind {!r} is not {}".format(message["kind"], ATTACH_REQUEST_KIND)
    return check_parent_triple(message, task, generation, assignment)


class Relay:
    """One child-relay pass over the landed requests of one compartment."""

    def __init__(self, args, out):
        self.args = args
        self.out = out
        self.task = args.task
        self.generation = args.task_generation
        self.assignment = args.assignment_generation
        self.childreq = Path(args.childreq)
        self.childreq.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.inbox = Path(args.inbox)
        # TWO HOMES, deliberately separate (see spawn_environment):
        self.spawn_home = Path(args.spawn_home)
        self.home = Path(args.home) if args.home else None
        self.controller = Path(args.controller)
        self.spawn_bin = args.spawn_bin
        self.lifecycle_bin = args.lifecycle_bin

    # -- durable records ------------------------------------------------------

    def record(self, name, value):
        write_atomic(self.childreq / name, canonical(value) + b"\n")

    def refuse(self, digest, landed, check):
        """Refuse one request: a durable .refused-<digest>.json AND a delivered
        refusal naming the exact failed check. Both, always - a refusal the
        agent never sees is indistinguishable from a lost message, and a
        delivered refusal with no record cannot dedupe a resend."""
        self.record(".refused-{}.json".format(digest), {
            "task": self.task,
            "digest": digest,
            "landed": landed,
            "check": check,
            "refused_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        deliver_text(
            self.inbox, self.assignment,
            "FIRSTMATE REFUSED your request ({}): {}. This is the durable answer; "
            "resending the same intent refuses again as a duplicate.".format(digest[:12], check),
        )
        self.out.write(
            "secondmate {}: REFUSED request {}: {}\n".format(self.task, digest[:12], check)
        )

    # -- controller reads -----------------------------------------------------

    def controller_state(self):
        try:
            with open(str(self.controller), encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return {}

    def admitted_child(self, child_task):
        """This compartment's own queue entry for child_task, or None.

        Ownership is the parent pair, not the name: an entry that exists but
        names another parent (or no parent) is not this compartment's child
        and never counts as admission under its bounds.
        """
        state = self.controller_state()
        for entry in (state.get("queue") or {}).values():
            if not isinstance(entry, dict):
                continue
            if (
                entry.get("task") == child_task
                and entry.get("parent_task") == self.task
                and entry.get("parent_task_generation") == self.generation
            ):
                return entry
        return None

    def compartment_repository_generation(self):
        state = self.controller_state()
        item = (state.get("queue") or {}).get("{}@{}".format(self.task, self.generation)) or {}
        worker = (state.get("workers") or {}).get(str(item.get("slot"))) or {}
        return ((worker.get("bindings") or {}).get("repository_generation") or "")

    # -- the pass -------------------------------------------------------------

    def run(self):
        for entry in sorted(self.childreq.glob("[0-9]*.json")):
            match = MESSAGE_NAME.fullmatch(entry.name)
            if not match:
                continue
            handled = self.childreq / ".handled-{}".format(entry.name[:-len(".json")])
            if handled.exists():
                continue
            # The marker is written AFTER the handler on purpose: a crash mid
            # handling replays this request on the next pass, where the durable
            # self-digest verdict turns an already-spent intent into a loud
            # duplicate refusal. Marking first would instead drop a request
            # silently, which is the one outcome the delivered-refusal rule
            # exists to prevent.
            try:
                self.handle(entry, match.group(2))
            except Exception as exc:  # noqa: BLE001 - deliberate, see below
                # THE ALWAYS-AN-ANSWER BACKSTOP. A validator or spawn bug that
                # raises must never become silence: an escaping exception used
                # to kill this whole pass, so no refusal was recorded, no
                # refusal was delivered, every later request in the pass went
                # unanswered, and child status mirroring stopped for good
                # while the bash monitor logged a 15-second warning. Any
                # unexpected failure is therefore routed into the ordinary
                # durable-and-delivered refusal, and the loop continues.
                self.refuse(
                    match.group(2), entry.name,
                    "request handling failed unexpectedly ({}: {}); refused rather than "
                    "left unanswered".format(type(exc).__name__, exc),
                )
            write_atomic(handled, b"")
        self.mirror_child_status()
        return 0

    def handle(self, entry, content_digest):
        try:
            message = json.loads(entry.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            self.refuse(content_digest, entry.name, "landed request is unreadable: {}".format(exc))
            return
        if not isinstance(message, dict):
            self.refuse(content_digest, entry.name, "landed request is not a JSON object")
            return
        kind = message.get("kind")
        if kind == CHILD_REQUEST_KIND:
            check = check_child_request(message, self.task, self.generation, self.assignment)
        elif kind == ATTACH_REQUEST_KIND:
            check = check_attach_request(
                message, self.task, self.generation, self.assignment, self.attach_served()
            )
        else:
            self.refuse(content_digest, entry.name, "request kind is not relayed: {!r}".format(kind))
            return
        # The self digest names the INTENT; the content digest names this
        # emission of it. A malformed self digest cannot key anything, so the
        # refusal record falls back to the emission.
        self_digest = message.get("self_digest")
        digest = self_digest if isinstance(self_digest, str) and HEX.fullmatch(self_digest) else content_digest
        if check:
            self.refuse(digest, entry.name, check)
            return
        prior = self.prior_verdict(digest)
        if prior:
            self.refuse(
                content_digest, entry.name,
                "duplicate request: self digest {} was already {} and is not spent twice".format(
                    digest[:12], prior),
            )
            return
        if kind == CHILD_REQUEST_KIND:
            self.spawn_child(message, digest, entry.name)
        else:
            self.send_delta_bundle(message, digest, entry.name)

    def attach_served(self) -> int:
        """The highest attach_sequence this monitor has actually SERVED.

        Durable, and deliberately advanced only by a served attach: an ask
        that found no delta serves nothing, so it burns no sequence and the
        compartment may ask again with the same number.
        """
        highest = 0
        for record in self.childreq.glob(".accepted-*.json"):
            try:
                accepted = json.loads(record.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            counter = accepted.get(ATTACH_REQUEST_COUNTED)
            if isinstance(counter, int) and not isinstance(counter, bool):
                highest = max(highest, counter)
        return highest

    def prior_verdict(self, digest):
        if (self.childreq / ".accepted-{}.json".format(digest)).exists():
            return "accepted"
        if (self.childreq / ".refused-{}.json".format(digest)).exists():
            return "refused"
        return ""

    # -- spawn ----------------------------------------------------------------

    def resolve_project(self):
        """Local policy, never the request's: the child's project directory.

        Returns (path, "") or ("", failed check). Nothing about the repository
        is expressible from the cloud side, so this is decided here from the
        secondmate home alone.
        """
        if not self.spawn_home.is_dir():
            return "", "child spawn refused: the requesting home is unavailable locally"
        projects = self.spawn_home / "projects"
        chosen = os.environ.get("FM_SECONDMATE_CHILD_PROJECT", "")
        if chosen:
            if "/" in chosen or chosen in ("", ".", ".."):
                return "", "child spawn refused: FM_SECONDMATE_CHILD_PROJECT is not a bare project name"
            path = projects / chosen
            if not path.is_dir():
                return "", "child spawn refused: FM_SECONDMATE_CHILD_PROJECT={} is not a project of this home".format(chosen)
            return str(path), ""
        candidates = sorted(entry for entry in projects.iterdir() if entry.is_dir()) if projects.is_dir() else []
        if not candidates:
            return "", "child spawn refused: the secondmate home has no project directory to work in"
        if len(candidates) > 1:
            return "", "child spawn refused: the secondmate home has {} projects; set FM_SECONDMATE_CHILD_PROJECT to name one".format(len(candidates))
        return str(candidates[0]), ""

    def ensure_backlog_row(self, child_task, kind, project, brief):
        """File the child's backlog row before dispatch.

        fm-spawn refuses a NEW ship/scout task that has no In-flight or Queued
        backlog row, so without this the relay's every child request would
        refuse at that gate in any real home - the exact failure the real-spawn
        unit surfaced. The sanctioned writer is tried first; the manual
        markdown append is the documented fallback shape fm-spawn itself scans
        when the tasks-axi backend is unavailable. Returns "" or a failed
        check.
        """
        data = self.spawn_home / "data"
        backlog = data / "backlog.md"
        summary = ""
        for line in brief.splitlines():
            if line.strip():
                summary = line.strip()
                break
        summary = (summary or "compartment child")[:120].lstrip("-").strip()
        summary = summary or "compartment child"
        repo = Path(project).name or "unknown"
        writer = Path(__file__).resolve().parent / "fm-data-write.py"
        if writer.is_file():
            try:
                subprocess.run(
                    [
                        sys.executable, str(writer), "--data", str(data), "--",
                        "tasks-axi", "add", child_task, summary,
                        "--kind", kind, "--repo", repo, "--start",
                        "--backend", "markdown", "--file", str(backlog),
                    ],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, timeout=120, check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.backlog_row_present(backlog, child_task):
            return ""
        try:
            body = backlog.read_text(encoding="utf-8") if backlog.is_file() else ""
            row = "- **{}** {}\n".format(child_task, summary)
            if "## In flight" in body:
                head, _, tail = body.partition("## In flight")
                newline, _, rest = tail.partition("\n")
                body = "{}## In flight{}\n{}{}".format(head, newline, row, rest)
            else:
                body = body.rstrip("\n") + "\n\n## In flight\n\n" + row
            write_atomic(backlog, body.encode("utf-8"))
        except OSError as exc:
            return "child backlog row could not be filed locally: {}".format(exc)
        if not self.backlog_row_present(backlog, child_task):
            return "child backlog row could not be filed locally: the row is absent after writing it"
        return ""

    @staticmethod
    def backlog_row_present(backlog, child_task):
        """The same rule fm-spawn's manual scan applies: an In-flight or
        Queued section row whose key is the task id."""
        try:
            body = backlog.read_text(encoding="utf-8")
        except OSError:
            return False
        active = False
        for line in body.splitlines():
            if re.fullmatch(r"##\s+(In flight|Queued)\s*", line):
                active = True
                continue
            if line.startswith("## "):
                active = False
                continue
            if not active:
                continue
            entry = re.sub(r"^\s*-\s*", "", line)
            entry = re.sub(r"^\[[ xX]\]\s*", "", entry)
            if entry.startswith("**"):
                closing = entry[2:].find("**")
                key = entry[2:2 + closing] if closing >= 0 else ""
            else:
                key = entry.split()[0] if entry.split() else ""
            if key == child_task:
                return True
        return False

    def spawn_environment(self):
        """The child spawn's environment: this home, no pins, no overrides.

        WHAT ACTUALLY BLOCKS A COMPARTMENT CHILD, stated correctly (an earlier
        revision of this comment blamed verify_state's home fence, which is
        wrong and pointed at the one guard here that must NOT be weakened):

        The controller already admits a compartment child. `--owner-kind` is a
        plain argv flag on `request`; the controller never inspects FM_HOME to
        decide it. A request minted with FM_HOME set to the controller's own
        home and `--owner-kind secondmate` plus the parent pair is admitted
        with all four B.1 bounds enforced and children_total incremented.

        The pinch point is that FM_HOME does three separable jobs at once:
        (1) where the requesting task's local authorities live, because
        authoritative_request_bindings reads `env["home"]/state/<task>.meta`
        (bin/fm-worker-lifecycle.py:2446); (2) the identity stamped into the
        request's home_binding; and (3) the identity of the money document.
        Jobs 1 and 2 belong to the requester, job 3 belongs to the controller,
        and the compartment child is the first case where they differ. The
        missing capability is an authorized task-home parameter on
        authoritative_request_bindings, plus a way for fm-spawn to assert
        owner_kind rather than derive it from its own home marker
        (bin/fm-spawn.sh:4429).

        So this method deliberately does NOTHING clever: it leaves FM_HOME as
        the monitor's own home, which is the controller's home, so the default
        worker state directory is already the right one. Two earlier ideas are
        rejected on evidence:
          - Pinning FM_AZURE_WORKER_STATE_DIR is a DURABLE TRAP, not a
            one-shot: that name is inside SPAWN_CLOUD_ENV_ALLOWLIST
            (bin/fm-spawn.sh:4332), so it is persisted into the child's
            <id>.cloud-env and would permanently pair a foreign FM_HOME with
            this state dir for every later execute and release.
          - Moving FM_HOME to the secondmate home aims the request at a SECOND
            money document (the one the documented local-secondmate lane
            already creates) and refuses at parent liveness, which is both the
            outcome the design forbids and a refusal that names the wrong
            cause.
        With neither, the lane refuses early and honestly at verify_request,
        naming owner_kind: the exact capability that is missing.
        """
        env = dict(os.environ)
        # The compartment's own leg configuration and any state override must
        # not travel into an ordinary crewmate spawn.
        env.pop("FM_STATE_OVERRIDE", None)
        for key in list(env):
            if key.startswith("FM_SECONDMATE_"):
                env.pop(key, None)
        env["FM_SPAWN_CLOUD"] = "azure"
        env["FM_SPAWN_PARENT_TASK"] = self.task
        env["FM_SPAWN_PARENT_TASK_GENERATION"] = self.generation
        return env

    def spawn_child(self, message, digest, landed):
        project, failed = self.resolve_project()
        if failed:
            self.refuse(digest, landed, failed)
            return
        child_task = "{}-c{}".format(self.task, digest[:8])
        brief = self.spawn_home / "data" / child_task / "brief.md"
        try:
            write_atomic(brief, message["brief"].encode("utf-8"))
        except OSError as exc:
            self.refuse(digest, landed, "child brief could not be written locally: {}".format(exc))
            return
        failed = self.ensure_backlog_row(child_task, message["child_kind"], project, message["brief"])
        if failed:
            self.refuse(digest, landed, failed)
            return
        # --harness is passed EXPLICITLY rather than left to resolution. A
        # home carrying config/crew-dispatch.json refuses a crewmate spawn
        # that resolves its harness implicitly (the consultation backstop),
        # and the primary propagates that file into secondmate homes, so an
        # implicit-harness child request would refuse in most real homes. The
        # cloud lane runs exactly one runtime - it rejects every harness but
        # pi and forces pi itself - so naming pi here is the resolution, not a
        # guess, and it keeps the relay off the implicit path entirely.
        argv = [self.spawn_bin, child_task, project, "--harness", CLOUD_CHILD_HARNESS]
        if message["child_kind"] == "scout":
            argv.append("--scout")
        for flag, key in (("--model", "child_model"), ("--effort", "child_effort")):
            if key in message:
                argv += [flag, message[key]]
        try:
            completed = subprocess.run(
                argv, env=self.spawn_environment(), cwd=str(self.spawn_home),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=SPAWN_TIMEOUT, check=False,
            )
            output = completed.stdout.decode("utf-8", errors="replace")
            code = completed.returncode
        except subprocess.TimeoutExpired:
            output = "the spawn did not finish within {} seconds".format(SPAWN_TIMEOUT)
            code = 124
        except OSError as exc:
            output = "the spawn could not be invoked: {}".format(exc)
            code = 127
        if code != 0:
            # An admission refusal (fan-out cap, lifetime total, parent
            # liveness, depth) arrives exactly here, as the spawn's failure
            # text, and round-trips verbatim. No queue item exists.
            self.refuse(
                digest, landed,
                "child spawn was refused (exit {}): {}".format(code, output.strip()[-1200:]),
            )
            return
        # ADMISSION IS PROVEN BY THE QUEUE, NOT BY AN EXIT CODE. fm-spawn is a
        # long script with at least one exit-0 path that silently downgrades
        # placement, so a zero exit is evidence the script ran, never evidence
        # the controller admitted a bounded child. Read the one money
        # authority back and require the child's own entry carrying THIS
        # compartment's parent pair; anything else refuses loudly. This also
        # bounds the crash window: a replay mints a fresh spawn generation and
        # so a different queue key, and the readback is what would catch a
        # second admission for one intent.
        admitted = self.admitted_child(child_task)
        if admitted is None:
            self.refuse(
                digest, landed,
                "child spawn exited 0 but the controller holds no queue entry for {} owned by "
                "this compartment ({}@{}); the child was not admitted under the child bounds".format(
                    child_task, self.task, self.generation),
            )
            return
        self.record(".accepted-{}.json".format(digest), {
            "task": self.task,
            "digest": digest,
            "landed": landed,
            "child_task": child_task,
            "child_kind": message["child_kind"],
            "child_task_generation": admitted.get("task_generation"),
            "project": project,
            "accepted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        deliver_text(
            self.inbox, self.assignment,
            "FIRSTMATE ACCEPTED your {} request ({}): child {} is admitted on the local controller "
            "under this compartment's bounds. Its terminal status will arrive here.".format(
                message["child_kind"], digest[:12], child_task),
        )
        self.out.write(
            "secondmate {}: spawned child {} ({}) for request {}\n".format(
                self.task, child_task, message["child_kind"], digest[:12])
        )

    # -- terminal status -------------------------------------------------------

    def mirror_child_status(self):
        state = self.controller_state()
        queue = state.get("queue") or {}
        for record in sorted(self.childreq.glob(".accepted-*.json")):
            try:
                accepted = json.loads(record.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            child_task = accepted.get("child_task")
            if not isinstance(child_task, str) or not child_task:
                continue
            marker = self.childreq / ".status-{}.json".format(child_task)
            if marker.exists():
                continue
            item = None
            for entry in queue.values():
                if entry.get("task") == child_task and entry.get("parent_task") == self.task:
                    item = entry
                    break
            if item is None or item.get("status") != "complete":
                continue
            classification = self.child_classification(child_task)
            deliver_text(
                self.inbox, self.assignment,
                "CHILD {} is {}. Its code commits live in the project repository, which is NOT "
                "the repository you hold; what can reach you is this home's own delta (its "
                "report and home artifacts), which you can ask for with an attach request.".format(
                    child_task, classification),
            )
            self.record(".status-{}.json".format(child_task), {
                "child_task": child_task,
                "classification": classification,
                "mirrored_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })
            self.out.write(
                "secondmate {}: mirrored child {} terminal status: {}\n".format(
                    self.task, child_task, classification)
            )

    def child_classification(self, child_task):
        """complete vs failed, from the child's own recorded execution result.

        The controller queue records reaching a terminal state, never whether
        the work succeeded, so the split comes from the result the child's own
        lane wrote; absent, the honest answer says so rather than guessing.
        """
        path = self.spawn_home / "state" / "{}.worker-result.json".format(child_task)
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return "complete (no recorded execution result)"
        code = result.get("exit_code")
        if not isinstance(code, int) or isinstance(code, bool):
            return "complete (execution result carries no exit code)"
        if result.get("timed_out"):
            return "failed (its execution hit the bounded wall)"
        return "complete" if code == 0 else "failed (exit code {})".format(code)

    # -- delta bundles ---------------------------------------------------------

    def send_delta_bundle(self, message, digest, landed):
        base = self.compartment_repository_generation()
        if not base:
            self.refuse(digest, landed, "attach refused: this compartment's dispatched repository generation is unknown locally")
            return
        if self.home is None or not (self.home / ".git").exists():
            self.refuse(digest, landed, "attach refused: the secondmate home worktree is unavailable locally")
            return
        counted = git_in(self.home, "rev-list", "--count", "{}..HEAD".format(base))
        if counted.returncode != 0:
            self.refuse(
                digest, landed,
                "attach refused: the delta over the dispatched base is unreadable: {}".format(
                    counted.stderr.decode("utf-8", errors="replace").strip()[-300:]),
            )
            return
        try:
            commits = int(counted.stdout.decode().strip())
        except ValueError:
            self.refuse(digest, landed, "attach refused: the delta commit count is not a number")
            return
        if commits == 0:
            # An empty delta SERVES NOTHING, so it records no acceptance and
            # burns no attach_sequence: the compartment may ask again with the
            # same number once its child's report has actually landed.
            deliver_text(
                self.inbox, self.assignment,
                "No delta to attach: this home's worktree holds no commits over the dispatched "
                "base, so attach_sequence {} is not spent and you may ask again with it.".format(
                    message[ATTACH_REQUEST_COUNTED]),
            )
            return
        with tempfile.TemporaryDirectory(dir=str(self.childreq)) as scratch:
            local = Path(scratch) / "delta.bundle"
            created = git_in(self.home, "bundle", "create", str(local), "{}..HEAD".format(base))
            if created.returncode != 0 or not local.is_file():
                self.refuse(
                    digest, landed,
                    "attach refused: the delta bundle could not be created: {}".format(
                        created.stderr.decode("utf-8", errors="replace").strip()[-300:]),
                )
                return
            body = local.read_bytes()
            if len(body) > MAX_BUNDLE_BYTES:
                self.refuse(digest, landed, "attach refused: the delta bundle exceeds its {} byte bound".format(MAX_BUNDLE_BYTES))
                return
            local_digest = sha256_hex(body)
            local_bytes = len(body)
            receipt, failed = self.upload_attachment(local)
        if failed:
            self.refuse(digest, landed, failed)
            return
        # SIZE-BEFORE-FETCH: the announcement is built from the receipt only
        # once the receipt's own digest and byte count both equal the bundle
        # the monitor hashed locally. A mismatch is never announced, because
        # the runner's fetch is size-checked against exactly these numbers and
        # an announcement it must refuse is worse than none.
        if (
            receipt.get("sha256") != local_digest
            or receipt.get("bytes") != local_bytes
            or not str(receipt.get("blob_name", "")).startswith(ATTACH_PREFIX)
        ):
            self.refuse(
                digest, landed,
                "attach refused: the upload receipt ({} bytes, {}) differs from the bundle this "
                "monitor hashed ({} bytes, {}); nothing was announced".format(
                    receipt.get("bytes"), str(receipt.get("sha256"))[:12],
                    local_bytes, local_digest[:12]),
            )
            return
        deliver_inbox(self.inbox, self.assignment, {
            "kind": ATTACH_KIND,
            "name": receipt["blob_name"],
            "sha256": local_digest,
            "bytes": local_bytes,
        })
        self.record(".accepted-{}.json".format(digest), {
            "task": self.task, "digest": digest, "landed": landed,
            "attach": receipt["blob_name"], "sha256": local_digest, "bytes": local_bytes,
            "commits": commits, "base": base,
            ATTACH_REQUEST_COUNTED: message[ATTACH_REQUEST_COUNTED],
            "accepted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        self.out.write(
            "secondmate {}: announced delta bundle {} ({} commit(s), {} bytes)\n".format(
                self.task, receipt["blob_name"], commits, local_bytes)
        )

    def upload_attachment(self, local):
        argv = [
            self.lifecycle_bin, "message-put",
            "--task", self.task, "--task-generation", self.generation,
            "--assignment-generation", self.assignment, "--attach", str(local),
        ]
        try:
            completed = subprocess.run(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=LIFECYCLE_TIMEOUT, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {}, "attach refused: the message lane could not be driven: {}".format(exc)
        if completed.returncode != 0:
            return {}, "attach refused: message-put failed: {}".format(
                completed.stderr.decode("utf-8", errors="replace").strip()[-600:])
        try:
            receipt = json.loads(completed.stdout.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}, "attach refused: the message-put receipt is not readable JSON"
        if not isinstance(receipt, dict):
            return {}, "attach refused: the message-put receipt is not an object"
        return receipt, ""


def command_child_relay(args, out):
    return Relay(args, out).run()


def command_process_mailbox(args, out):
    mailbox = Path(args.mailbox)
    if not mailbox.is_dir():
        # Nothing collected yet is not an error; the monitor polls again.
        return 0
    marker = mailbox / CHAIN_BREAK_MARKER
    state = load_state(args.state_file)
    if marker.exists():
        out.write(
            "SECONDMATE MAILBOX REFUSED for {}: a prior chain break is recorded at {}; retained for investigation\n".format(args.task, marker)
        )
        return 3
    try:
        verified = verify_mailbox(mailbox)
    except ChainBreak as exc:
        chain_break_refuse(args.task, mailbox, str(exc), out)
        return 3
    delivered = state.get("delivered_sequence") or 0
    # The durable tip is what makes verification stateful across passes: a
    # self-consistent chain is NOT enough, because an attacker who can write
    # the store can wipe it and mint a fresh chain from genesis. Two checks,
    # both BEFORE anything is delivered:
    #   1. the store may never hold fewer entries than were already
    #      delivered (a rewound outbox), and
    #   2. the recomputed chain at the durable verified tip's sequence must
    #      reproduce the tip's chain_digest exactly (a re-genesis or a
    #      substitution below the tip changes every digest above it).
    total = len(verified)
    if total < delivered:
        chain_break_refuse(
            args.task, mailbox,
            "store holds {} entries but {} were already delivered (rewound outbox)".format(total, delivered),
            out,
        )
        return 3
    tip = state.get("verified_tip")
    if isinstance(tip, dict):
        tip_sequence = tip.get("sequence")
        tip_digest = tip.get("chain_digest")
        if isinstance(tip_sequence, int) and not isinstance(tip_sequence, bool) and tip_sequence > 0:
            if total < tip_sequence:
                chain_break_refuse(
                    args.task, mailbox,
                    "store holds {} entries but the durable verified tip is {} (rewound outbox)".format(total, tip_sequence),
                    out,
                )
                return 3
            if verified[tip_sequence - 1][1].get("chain_digest") != tip_digest:
                chain_break_refuse(
                    args.task, mailbox,
                    "recomputed chain at sequence {} does not reproduce the durable verified tip (re-genesis or substitution)".format(tip_sequence),
                    out,
                )
                return 3
    for sequence, message in verified:
        if sequence <= delivered:
            continue
        render_message(args.task, sequence, message, out)
        delivered = sequence
    state["delivered_sequence"] = delivered
    # Land (never act on) the request kinds the child relay owns. Landing is
    # content-addressed by the verified chain name, so it is idempotent, and
    # it happens only for entries that already passed the whole chain
    # verification above - a refused mailbox lands nothing.
    land_relay_requests(verified, mailbox, args.childreq, out)
    if total > 0:
        state["verified_tip"] = {
            "sequence": total,
            "chain_digest": verified[-1][1].get("chain_digest"),
        }
    summaries = [message for _s, message in verified if message.get("kind") == LEG_SUMMARY_KIND]
    if summaries:
        latest = summaries[-1]
        state["last_summary"] = {
            "reason": latest.get("reason"),
            "legs_completed": latest.get("legs_completed"),
        }
    worktree = Path(args.worktree) if args.worktree else None
    landed = set(state.get("landed_bundles") or [])
    kept = set(state.get("kept_bundles") or [])
    for declaration in declared_bundles(verified):
        digest = declaration.get("sha256")
        if digest in landed or digest in kept:
            continue
        outcome = land_bundle(args.task, mailbox, worktree, declaration, out)
        if outcome == "landed":
            landed.add(digest)
        elif outcome == "kept":
            kept.add(digest)
        # "pending": leave it out of both sets so a later pass retries.
    state["landed_bundles"] = sorted(landed)
    state["kept_bundles"] = sorted(kept)
    save_state(args.state_file, state)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    process = sub.add_parser(
        "process-mailbox",
        help="verify the collected outbox chain, deliver new messages, land declared bundles",
    )
    process.add_argument("--task", required=True)
    process.add_argument("--mailbox", required=True)
    process.add_argument("--state-file", required=True)
    process.add_argument("--worktree", default="")
    process.add_argument(
        "--childreq", default="",
        help="directory verified child/attach requests land in for the child relay",
    )
    relay = sub.add_parser(
        "child-relay",
        help="validate landed child/attach requests, spawn or refuse, mirror child status",
    )
    relay.add_argument("--task", required=True)
    relay.add_argument("--task-generation", required=True)
    relay.add_argument("--assignment-generation", required=True)
    relay.add_argument("--childreq", required=True)
    relay.add_argument("--inbox", required=True)
    relay.add_argument(
        "--spawn-home", required=True,
        help="the home the child spawn runs under, which is the controller's own home",
    )
    relay.add_argument(
        "--home", required=True,
        help="the compartment's local secondmate home (delta bundles only)",
    )
    relay.add_argument("--controller", required=True, help="the ONE money authority document")
    relay.add_argument("--spawn-bin", required=True)
    relay.add_argument("--lifecycle-bin", required=True)
    args = parser.parse_args(argv)
    if args.command == "process-mailbox":
        return command_process_mailbox(args, sys.stdout)
    if args.command == "child-relay":
        return command_child_relay(args, sys.stdout)
    raise HelperError("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HelperError as exc:
        print("SECONDMATE MONITOR REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
