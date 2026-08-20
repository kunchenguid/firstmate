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

Exit codes: 0 verified (possibly nothing new), 3 chain break (sticky), 2 bad
invocation or unreadable durable state.
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

GENESIS_CHAIN_DIGEST = "0" * 64
MESSAGE_NAME = re.compile(r"^([0-9]{8})-([0-9a-f]{64})\.json$")
BUNDLE_NAME = re.compile(r"^bundle-([0-9]{8})-([0-9a-f]{64})\.bundle$")
OUTBOX_PREFIX = "session/out/"

MESSAGE_KIND = "fm.secondmate-message/v1"
REFUSAL_KIND = "fm.secondmate-refusal/v1"
LEG_SUMMARY_KIND = "fm.secondmate-leg-summary/v1"
CHILD_REQUEST_KIND = "fm.secondmate-child-request/v1"

MAX_MESSAGE_BYTES = 256 * 1024
MAX_BUNDLE_BYTES = 256 * 1024 * 1024

GIT_TIMEOUT = 600

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
            "secondmate {} child request (seq {:08d}): kind={} (child relay is a later change; not acted on here)\n".format(
                task, sequence, message.get("child_kind", "")
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
    args = parser.parse_args(argv)
    if args.command == "process-mailbox":
        return command_process_mailbox(args, sys.stdout)
    raise HelperError("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HelperError as exc:
        print("SECONDMATE MONITOR REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
